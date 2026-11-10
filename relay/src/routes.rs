//! HTTP routes: the phone's device and subscription calls, and the hooks providers call.
//!
//! Bodies are read as raw bytes and parsed here, so a provider's handshake or an odd content
//! type never gets in the way, and every error maps to the status codes in the protocol.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Path, Query, Request, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use base64::engine::general_purpose::{STANDARD, URL_SAFE};
use base64::Engine;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::apns::{Push, PushOutcome, PushSender, PushType};
use crate::store::{constant_time_eq, Device, Environment, Kind, Store, Target};

/// Largest request body accepted, in bytes.
pub const BODY_LIMIT: usize = 64 * 1024;

/// Shortest gap between two new-mail pushes for one subscription, in milliseconds.
pub const PUSH_INTERVAL_MS: i64 = 10_000;

/// Current time in milliseconds. Replaceable so tests can move time forward.
pub type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

/// The wall clock.
pub fn system_clock() -> Clock {
    Arc::new(|| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    })
}

/// Shared state for every request.
#[derive(Clone)]
pub struct AppState {
    pub store: Arc<Store>,
    pub sender: Arc<dyn PushSender>,
    /// Base address used to build hook URLs, without a trailing slash.
    pub public_url: String,
    pub gmail_push_token: String,
    pub clock: Clock,
}

/// Builds the router with all routes, the body limit and request logging.
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/v1/devices", post(register_device))
        .route("/v1/devices/{id}", delete(delete_device))
        .route("/v1/subscriptions", post(create_subscription))
        .route("/v1/subscriptions/{id}", delete(delete_subscription))
        .route("/v1/hooks/graph/{id}", post(graph_hook))
        .route("/v1/hooks/jmap/{id}", post(jmap_hook))
        .route("/v1/hooks/gmail", post(gmail_hook))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
        .layer(middleware::from_fn(log_request))
        .with_state(state)
}

/// Logs method, path and status only. Query strings are left out because they carry tokens.
async fn log_request(request: Request, next: Next) -> Response {
    let method = request.method().clone();
    let path = request.uri().path().to_string();
    let response = next.run(request).await;
    tracing::info!(%method, %path, status = response.status().as_u16(), "request");
    response
}

/// An error answer: a status and a short reason in JSON.
struct ApiError(StatusCode, &'static str);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({ "error": self.1 }))).into_response()
    }
}

impl From<rusqlite::Error> for ApiError {
    fn from(error: rusqlite::Error) -> Self {
        tracing::error!(%error, "database error");
        ApiError(StatusCode::INTERNAL_SERVER_ERROR, "internal error")
    }
}

type ApiResult = Result<Response, ApiError>;

fn parse_json<T: for<'de> Deserialize<'de>>(body: &[u8]) -> Result<T, ApiError> {
    serde_json::from_slice(body).map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid JSON body"))
}

/// Finds the device behind `Authorization: Bearer <secret>`.
fn authenticate(state: &AppState, headers: &HeaderMap) -> Result<Device, ApiError> {
    let unauthorized = ApiError(StatusCode::UNAUTHORIZED, "missing or invalid device secret");
    let secret = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim)
        .filter(|secret| !secret.is_empty())
        .ok_or(ApiError(unauthorized.0, unauthorized.1))?;
    state.store.authenticate(secret)?.ok_or(unauthorized)
}

fn is_hex(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|b| b.is_ascii_hexdigit())
}

// ---- Devices ----

#[derive(Deserialize)]
struct RegisterDevice {
    token: String,
    environment: String,
    topic: String,
}

async fn register_device(State(state): State<AppState>, body: Bytes) -> ApiResult {
    let request: RegisterDevice = parse_json(&body)?;
    let token = request.token.trim().to_ascii_lowercase();
    if !is_hex(&token) || token.len() > 200 {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "token must be the APNs token in hex",
        ));
    }
    let environment = Environment::parse(&request.environment).ok_or(ApiError(
        StatusCode::BAD_REQUEST,
        "environment must be production or sandbox",
    ))?;
    let topic = request.topic.trim();
    if topic.is_empty() || topic.len() > 200 {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "topic must be the app bundle id",
        ));
    }
    let (device, secret) =
        state
            .store
            .register_device(&token, environment, topic, (state.clock)())?;
    Ok((
        StatusCode::CREATED,
        Json(json!({ "device": device, "secret": secret })),
    )
        .into_response())
}

async fn delete_device(
    State(state): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> ApiResult {
    let device = authenticate(&state, &headers)?;
    if !constant_time_eq(device.id.as_bytes(), id.as_bytes()) {
        return Err(ApiError(StatusCode::FORBIDDEN, "not this device"));
    }
    state.store.delete_device(&device.id)?;
    Ok(StatusCode::NO_CONTENT.into_response())
}

// ---- Subscriptions ----

#[derive(Deserialize)]
struct CreateSubscription {
    kind: String,
    account: String,
    address_hash: Option<String>,
}

async fn create_subscription(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> ApiResult {
    let device = authenticate(&state, &headers)?;
    let request: CreateSubscription = parse_json(&body)?;
    let kind = Kind::parse(&request.kind).ok_or(ApiError(
        StatusCode::BAD_REQUEST,
        "kind must be graph, gmail or jmap",
    ))?;
    let account = request.account.trim();
    if account.is_empty() || account.len() > 256 {
        return Err(ApiError(StatusCode::BAD_REQUEST, "account is required"));
    }
    let address_hash = match kind {
        Kind::Gmail => {
            let hash = request
                .address_hash
                .map(|hash| hash.trim().to_ascii_lowercase())
                .filter(|hash| hash.len() == 64 && is_hex(hash))
                .ok_or(ApiError(
                    StatusCode::BAD_REQUEST,
                    "address_hash must be the sha256 hex of the lowercased address",
                ))?;
            Some(hash)
        }
        // Only gmail needs the hash; it is not stored for the others.
        Kind::Graph | Kind::Jmap => None,
    };
    let created = state.store.create_subscription(
        &device.id,
        kind,
        account,
        address_hash.as_deref(),
        (state.clock)(),
    )?;
    let url = match kind {
        Kind::Graph => format!("{}/v1/hooks/graph/{}", state.public_url, created.id),
        Kind::Jmap => format!("{}/v1/hooks/jmap/{}", state.public_url, created.id),
        // Gmail pings arrive through the one shared Pub/Sub push endpoint.
        Kind::Gmail => format!("{}/v1/hooks/gmail", state.public_url),
    };
    let mut answer = json!({ "id": created.id, "url": url });
    if let Some(client_state) = created.client_state {
        answer["client_state"] = Value::String(client_state);
    }
    Ok((StatusCode::CREATED, Json(answer)).into_response())
}

async fn delete_subscription(
    State(state): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> ApiResult {
    let device = authenticate(&state, &headers)?;
    if state.store.delete_subscription(&device.id, &id)? {
        Ok(StatusCode::NO_CONTENT.into_response())
    } else {
        Err(ApiError(StatusCode::NOT_FOUND, "no such subscription"))
    }
}

// ---- Hooks ----

#[derive(Deserialize)]
struct GraphNotifications {
    #[serde(default)]
    value: Vec<GraphNotification>,
}

#[derive(Deserialize)]
struct GraphNotification {
    #[serde(rename = "clientState")]
    client_state: Option<String>,
}

async fn graph_hook(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
    body: Bytes,
) -> ApiResult {
    // The validation handshake is answered first, whatever else is going on.
    if let Some(token) = query.get("validationToken") {
        return Ok((
            StatusCode::OK,
            [(header::CONTENT_TYPE, "text/plain")],
            token.clone(),
        )
            .into_response());
    }
    let target = state
        .store
        .target(Kind::Graph, &id)?
        .ok_or(ApiError(StatusCode::NOT_FOUND, "no such subscription"))?;
    let notifications: GraphNotifications = parse_json(&body)?;
    let expected = target.client_state.clone().unwrap_or_default();
    for item in notifications.value {
        let matches = item.client_state.is_some_and(|given| {
            !expected.is_empty() && constant_time_eq(given.as_bytes(), expected.as_bytes())
        });
        if matches {
            push_new_mail(&state, &target).await?;
        }
    }
    Ok(StatusCode::ACCEPTED.into_response())
}

async fn jmap_hook(
    State(state): State<AppState>,
    Path(id): Path<String>,
    body: Bytes,
) -> ApiResult {
    let target = state
        .store
        .target(Kind::Jmap, &id)?
        .ok_or(ApiError(StatusCode::NOT_FOUND, "no such subscription"))?;
    let object: Value = parse_json(&body)?;
    match object.get("@type").and_then(Value::as_str) {
        Some("StateChange") => push_new_mail(&state, &target).await?,
        Some("PushVerification") => {
            let code = object
                .get("verificationCode")
                .and_then(Value::as_str)
                .ok_or(ApiError(
                    StatusCode::BAD_REQUEST,
                    "verificationCode is missing",
                ))?;
            push_verification(&state, &target, code).await?;
        }
        _ => {}
    }
    Ok(StatusCode::ACCEPTED.into_response())
}

#[derive(Deserialize)]
struct PubSubPush {
    message: PubSubMessage,
}

#[derive(Deserialize)]
struct PubSubMessage {
    data: String,
}

#[derive(Deserialize)]
struct GmailNotification {
    #[serde(rename = "emailAddress")]
    email_address: String,
}

async fn gmail_hook(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
    body: Bytes,
) -> ApiResult {
    let given = query.get("token").map(String::as_str).unwrap_or("");
    if given.is_empty() || !constant_time_eq(given.as_bytes(), state.gmail_push_token.as_bytes()) {
        return Err(ApiError(StatusCode::FORBIDDEN, "wrong token"));
    }
    // A message that can't be read is acknowledged anyway: redelivering it won't help.
    let Some(address_hash) = gmail_address_hash(&body) else {
        tracing::warn!("ignored an unreadable gmail notification");
        return Ok(StatusCode::NO_CONTENT.into_response());
    };
    for target in state.store.gmail_targets(&address_hash)? {
        push_new_mail(&state, &target).await?;
    }
    Ok(StatusCode::NO_CONTENT.into_response())
}

/// Decodes a Pub/Sub push body and returns the sha256 hex of the lowercased address.
fn gmail_address_hash(body: &[u8]) -> Option<String> {
    let push: PubSubPush = serde_json::from_slice(body).ok()?;
    let data = push.message.data.trim();
    let decoded = STANDARD
        .decode(data)
        .or_else(|_| URL_SAFE.decode(data))
        .ok()?;
    let notification: GmailNotification = serde_json::from_slice(&decoded).ok()?;
    let address = notification.email_address.trim().to_lowercase();
    if address.is_empty() {
        return None;
    }
    Some(hex::encode(Sha256::digest(address.as_bytes())))
}

// ---- Pushes ----

/// Sends the "new mail" alert for a subscription, at most once per [`PUSH_INTERVAL_MS`].
async fn push_new_mail(state: &AppState, target: &Target) -> Result<(), ApiError> {
    if !state
        .store
        .claim_push(&target.subscription_id, (state.clock)(), PUSH_INTERVAL_MS)?
    {
        return Ok(());
    }
    let payload = json!({
        "aps": {
            "alert": {
                "title-loc-key": "PUSH_NEW_MAIL_TITLE",
                "loc-key": "PUSH_NEW_MAIL",
            },
            "sound": "default",
            "content-available": 1,
            "mutable-content": 1,
            "thread-id": target.account,
        },
        "margin": {
            "account": target.account,
            "subscription": target.subscription_id,
        },
    });
    deliver(
        state,
        target,
        PushType::Alert,
        Some(target.subscription_id.clone()),
        payload,
    )
    .await
}

/// Sends the silent push that carries a JMAP verification code to the phone.
async fn push_verification(state: &AppState, target: &Target, code: &str) -> Result<(), ApiError> {
    let payload = json!({
        "aps": { "content-available": 1 },
        "margin": { "subscription": target.subscription_id, "verify": code },
    });
    deliver(state, target, PushType::Background, None, payload).await
}

async fn deliver(
    state: &AppState,
    target: &Target,
    push_type: PushType,
    collapse_id: Option<String>,
    payload: Value,
) -> Result<(), ApiError> {
    let push = Push {
        device_token: target.device.token.clone(),
        environment: target.device.environment,
        topic: target.device.topic.clone(),
        push_type,
        collapse_id,
        payload,
    };
    match state.sender.send(push).await {
        PushOutcome::Delivered => {}
        PushOutcome::Unregistered => {
            tracing::info!(
                kind = target.kind.as_str(),
                "device unregistered; removing it"
            );
            state.store.delete_device(&target.device.id)?;
        }
        PushOutcome::Failed(reason) => {
            tracing::warn!(kind = target.kind.as_str(), %reason, "push failed");
        }
    }
    Ok(())
}
