//! End-to-end tests that drive the router directly with an in-memory database and a fake
//! push sender.

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use axum::Router;
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use http_body_util::BodyExt;
use margin_relay::apns::{Push, PushFuture, PushOutcome, PushSender, PushType};
use margin_relay::routes::{router, AppState};
use margin_relay::store::{Environment, Store};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tower::ServiceExt;

const GMAIL_TOKEN: &str = "pubsub-shared-secret";

/// Records pushes and answers with a configurable outcome.
struct FakeSender {
    pushes: Mutex<Vec<Push>>,
    outcome: Mutex<PushOutcome>,
}

impl PushSender for FakeSender {
    fn send(&self, push: Push) -> PushFuture<'_> {
        self.pushes.lock().unwrap().push(push);
        let outcome = self.outcome.lock().unwrap().clone();
        Box::pin(async move { outcome })
    }
}

struct Harness {
    app: Router,
    store: Arc<Store>,
    sender: Arc<FakeSender>,
    now: Arc<AtomicI64>,
}

impl Harness {
    fn new() -> Self {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sender = Arc::new(FakeSender {
            pushes: Mutex::new(Vec::new()),
            outcome: Mutex::new(PushOutcome::Delivered),
        });
        let now = Arc::new(AtomicI64::new(1_000_000));
        let clock_now = now.clone();
        let app = router(AppState {
            store: store.clone(),
            sender: sender.clone(),
            public_url: "https://relay.test".to_string(),
            gmail_push_token: GMAIL_TOKEN.to_string(),
            clock: Arc::new(move || clock_now.load(Ordering::SeqCst)),
        });
        Harness {
            app,
            store,
            sender,
            now,
        }
    }

    fn pushes(&self) -> Vec<Push> {
        self.sender.pushes.lock().unwrap().clone()
    }

    fn advance(&self, ms: i64) {
        self.now.fetch_add(ms, Ordering::SeqCst);
    }

    async fn call(
        &self,
        method: &str,
        uri: &str,
        bearer: Option<&str>,
        body: Option<Value>,
    ) -> (StatusCode, Option<String>, String) {
        let mut request = Request::builder().method(method).uri(uri);
        if let Some(secret) = bearer {
            request = request.header(header::AUTHORIZATION, format!("Bearer {secret}"));
        }
        let body = match body {
            Some(value) => {
                request = request.header(header::CONTENT_TYPE, "application/json");
                Body::from(value.to_string())
            }
            None => Body::empty(),
        };
        let response = self
            .app
            .clone()
            .oneshot(request.body(body).unwrap())
            .await
            .unwrap();
        let status = response.status();
        let content_type = response
            .headers()
            .get(header::CONTENT_TYPE)
            .map(|v| v.to_str().unwrap().to_string());
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        (
            status,
            content_type,
            String::from_utf8(bytes.to_vec()).unwrap(),
        )
    }

    async fn register(&self, token: &str) -> (String, String) {
        let (status, _, body) = self
            .call(
                "POST",
                "/v1/devices",
                None,
                Some(json!({"token": token, "environment": "sandbox", "topic": "app.margin.ios"})),
            )
            .await;
        assert_eq!(status, StatusCode::CREATED);
        let body: Value = serde_json::from_str(&body).unwrap();
        (
            body["device"].as_str().unwrap().to_string(),
            body["secret"].as_str().unwrap().to_string(),
        )
    }

    async fn subscribe(&self, secret: &str, body: Value) -> Value {
        let (status, _, body) = self
            .call("POST", "/v1/subscriptions", Some(secret), Some(body))
            .await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        serde_json::from_str(&body).unwrap()
    }
}

fn sha256_hex(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}

fn gmail_body(address: &str) -> Value {
    let data = STANDARD.encode(json!({"emailAddress": address, "historyId": "12345"}).to_string());
    json!({"message": {"data": data, "messageId": "1"}, "subscription": "projects/x/subscriptions/y"})
}

#[tokio::test]
async fn healthz_answers() {
    let h = Harness::new();
    let (status, _, _) = h.call("GET", "/healthz", None, None).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn device_registration_and_auth() {
    let h = Harness::new();
    let (device, secret) = h.register("abcdef0123").await;
    assert!(device.len() >= 22 && secret.len() >= 22);

    // Bad input is rejected.
    let (status, _, _) = h
        .call(
            "POST",
            "/v1/devices",
            None,
            Some(json!({"token": "not hex", "environment": "sandbox", "topic": "a"})),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _, _) = h
        .call(
            "POST",
            "/v1/devices",
            None,
            Some(json!({"token": "ab", "environment": "staging", "topic": "a"})),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // No secret, or a wrong one, is unauthorized.
    let sub = json!({"kind": "jmap", "account": "a1"});
    let (status, _, _) = h
        .call("POST", "/v1/subscriptions", None, Some(sub.clone()))
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _, _) = h
        .call("POST", "/v1/subscriptions", Some("wrong"), Some(sub))
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Another device's secret can't delete this one.
    let (_, other_secret) = h.register("ffff").await;
    let (status, _, _) = h
        .call(
            "DELETE",
            &format!("/v1/devices/{device}"),
            Some(&other_secret),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Deleting the device removes its subscriptions.
    h.subscribe(&secret, json!({"kind": "jmap", "account": "a1"}))
        .await;
    assert_eq!(h.store.subscription_count().unwrap(), 1);
    let (status, _, _) = h
        .call(
            "DELETE",
            &format!("/v1/devices/{device}"),
            Some(&secret),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(h.store.subscription_count().unwrap(), 0);
    let (status, _, _) = h
        .call(
            "DELETE",
            &format!("/v1/devices/{device}"),
            Some(&secret),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn re_registering_keeps_subscriptions() {
    let h = Harness::new();
    let (_, old_secret) = h.register("abcd").await;
    h.subscribe(&old_secret, json!({"kind": "jmap", "account": "a1"}))
        .await;
    let (_, new_secret) = h.register("ABCD").await;
    assert_eq!(h.store.device_count().unwrap(), 1);
    assert_eq!(h.store.subscription_count().unwrap(), 1);
    let (status, _, _) = h
        .call(
            "POST",
            "/v1/subscriptions",
            Some(&old_secret),
            Some(json!({"kind": "jmap", "account": "a"})),
        )
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    h.subscribe(&new_secret, json!({"kind": "jmap", "account": "a2"}))
        .await;
}

#[tokio::test]
async fn subscription_create_and_delete() {
    let h = Harness::new();
    let (_, secret) = h.register("abcd").await;

    let graph = h
        .subscribe(&secret, json!({"kind": "graph", "account": "acct-1"}))
        .await;
    let id = graph["id"].as_str().unwrap();
    assert_eq!(
        graph["url"],
        format!("https://relay.test/v1/hooks/graph/{id}")
    );
    assert!(graph["client_state"].as_str().unwrap().len() >= 22);

    let jmap = h
        .subscribe(&secret, json!({"kind": "jmap", "account": "acct-2"}))
        .await;
    assert!(jmap["url"]
        .as_str()
        .unwrap()
        .starts_with("https://relay.test/v1/hooks/jmap/"));
    assert!(jmap.get("client_state").is_none());

    let gmail = h
        .subscribe(
            &secret,
            json!({"kind": "gmail", "account": "acct-3", "address_hash": sha256_hex("a@b.test")}),
        )
        .await;
    assert_eq!(gmail["url"], "https://relay.test/v1/hooks/gmail");

    // Gmail without a valid hash, or an unknown kind, is rejected.
    for body in [
        json!({"kind": "gmail", "account": "x"}),
        json!({"kind": "gmail", "account": "x", "address_hash": "a@b.test"}),
        json!({"kind": "imap", "account": "x"}),
    ] {
        let (status, _, _) = h
            .call("POST", "/v1/subscriptions", Some(&secret), Some(body))
            .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    // Only the owning device can delete.
    let (_, other) = h.register("ffff").await;
    let uri = format!("/v1/subscriptions/{id}");
    let (status, _, _) = h.call("DELETE", &uri, Some(&other), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _, _) = h.call("DELETE", &uri, Some(&secret), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _, _) = h.call("DELETE", &uri, Some(&secret), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(h.store.subscription_count().unwrap(), 2);
}

#[tokio::test]
async fn graph_validation_token_is_echoed() {
    let h = Harness::new();
    // Answered even for an id the relay doesn't know.
    let (status, content_type, body) = h
        .call(
            "POST",
            "/v1/hooks/graph/unknown?validationToken=Validation%3A%20abc%2B1",
            None,
            None,
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert!(content_type.unwrap().starts_with("text/plain"));
    assert_eq!(body, "Validation: abc+1");
}

#[tokio::test]
async fn graph_notifications_check_client_state() {
    let h = Harness::new();
    let (_, secret) = h.register("abcd").await;
    let sub = h
        .subscribe(&secret, json!({"kind": "graph", "account": "acct-1"}))
        .await;
    let id = sub["id"].as_str().unwrap();
    let uri = format!("/v1/hooks/graph/{id}");

    let wrong = json!({"value": [{"subscriptionId": "g1", "clientState": "nope", "changeType": "created", "resource": "x"}]});
    let (status, _, _) = h.call("POST", &uri, None, Some(wrong)).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert!(h.pushes().is_empty());

    let right = json!({"value": [{"subscriptionId": "g1", "clientState": sub["client_state"], "changeType": "created", "resource": "x"}]});
    let (status, _, _) = h.call("POST", &uri, None, Some(right)).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    let pushes = h.pushes();
    assert_eq!(pushes.len(), 1);
    let push = &pushes[0];
    assert_eq!(push.push_type, PushType::Alert);
    assert_eq!(push.collapse_id.as_deref(), Some(id));
    assert_eq!(push.device_token, "abcd");
    assert_eq!(push.environment, Environment::Sandbox);
    assert_eq!(push.topic, "app.margin.ios");
    assert_eq!(push.payload["aps"]["alert"]["loc-key"], "PUSH_NEW_MAIL");
    assert_eq!(
        push.payload["aps"]["alert"]["title-loc-key"],
        "PUSH_NEW_MAIL_TITLE"
    );
    assert_eq!(push.payload["aps"]["content-available"], 1);
    assert_eq!(push.payload["aps"]["mutable-content"], 1);
    assert_eq!(push.payload["aps"]["thread-id"], "acct-1");
    assert_eq!(push.payload["margin"]["account"], "acct-1");
    assert_eq!(push.payload["margin"]["subscription"], id);

    let (status, _, _) = h
        .call(
            "POST",
            "/v1/hooks/graph/unknown",
            None,
            Some(json!({"value": []})),
        )
        .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn gmail_decodes_and_checks_token() {
    let h = Harness::new();
    let (_, secret) = h.register("abcd").await;
    let (_, secret2) = h.register("ef01").await;
    let hash = sha256_hex("person@example.test");
    h.subscribe(
        &secret,
        json!({"kind": "gmail", "account": "a1", "address_hash": hash}),
    )
    .await;
    h.subscribe(
        &secret2,
        json!({"kind": "gmail", "account": "a2", "address_hash": hash}),
    )
    .await;
    h.subscribe(
        &secret,
        json!({"kind": "gmail", "account": "a3", "address_hash": sha256_hex("other@example.test")}),
    )
    .await;

    for uri in ["/v1/hooks/gmail", "/v1/hooks/gmail?token=wrong"] {
        let (status, _, _) = h
            .call("POST", uri, None, Some(gmail_body("Person@Example.test")))
            .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
    }
    assert!(h.pushes().is_empty());

    let (status, _, _) = h
        .call(
            "POST",
            &format!("/v1/hooks/gmail?token={GMAIL_TOKEN}"),
            None,
            Some(gmail_body("Person@Example.test")),
        )
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let mut accounts: Vec<String> = h
        .pushes()
        .iter()
        .map(|p| p.payload["margin"]["account"].as_str().unwrap().to_string())
        .collect();
    accounts.sort();
    assert_eq!(accounts, ["a1", "a2"]);
}

#[tokio::test]
async fn jmap_state_change_and_verification() {
    let h = Harness::new();
    let (_, secret) = h.register("abcd").await;
    let sub = h
        .subscribe(&secret, json!({"kind": "jmap", "account": "acct"}))
        .await;
    let id = sub["id"].as_str().unwrap();
    let uri = format!("/v1/hooks/jmap/{id}");

    let (status, _, _) = h
        .call(
            "POST",
            &uri,
            None,
            Some(json!({"@type": "PushVerification", "pushSubscriptionId": "P1", "verificationCode": "code-123"})),
        )
        .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    let pushes = h.pushes();
    assert_eq!(pushes.len(), 1);
    assert_eq!(pushes[0].push_type, PushType::Background);
    assert_eq!(
        pushes[0].payload,
        json!({"aps": {"content-available": 1}, "margin": {"subscription": id, "verify": "code-123"}})
    );

    let (status, _, _) = h
        .call(
            "POST",
            &uri,
            None,
            Some(json!({"@type": "StateChange", "changed": {"acct": {"Email": "s2"}}})),
        )
        .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    let pushes = h.pushes();
    assert_eq!(pushes.len(), 2);
    assert_eq!(pushes[1].push_type, PushType::Alert);

    // A graph id doesn't work on the jmap hook.
    let graph = h
        .subscribe(&secret, json!({"kind": "graph", "account": "g"}))
        .await;
    let (status, _, _) = h
        .call(
            "POST",
            &format!("/v1/hooks/jmap/{}", graph["id"].as_str().unwrap()),
            None,
            Some(json!({"@type": "StateChange", "changed": {}})),
        )
        .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn new_mail_pushes_are_rate_limited() {
    let h = Harness::new();
    let (_, secret) = h.register("abcd").await;
    let sub = h
        .subscribe(&secret, json!({"kind": "jmap", "account": "acct"}))
        .await;
    let uri = format!("/v1/hooks/jmap/{}", sub["id"].as_str().unwrap());
    let change = json!({"@type": "StateChange", "changed": {}});

    h.call("POST", &uri, None, Some(change.clone())).await;
    h.advance(5_000);
    let (status, _, _) = h.call("POST", &uri, None, Some(change.clone())).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(h.pushes().len(), 1);
    h.advance(5_000);
    h.call("POST", &uri, None, Some(change)).await;
    assert_eq!(h.pushes().len(), 2);
}

#[tokio::test]
async fn unregistered_device_is_removed() {
    let h = Harness::new();
    let (_, secret) = h.register("abcd").await;
    let sub = h
        .subscribe(&secret, json!({"kind": "jmap", "account": "acct"}))
        .await;
    h.subscribe(&secret, json!({"kind": "graph", "account": "acct2"}))
        .await;
    *h.sender.outcome.lock().unwrap() = PushOutcome::Unregistered;

    let (status, _, _) = h
        .call(
            "POST",
            &format!("/v1/hooks/jmap/{}", sub["id"].as_str().unwrap()),
            None,
            Some(json!({"@type": "StateChange", "changed": {}})),
        )
        .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(h.store.device_count().unwrap(), 0);
    assert_eq!(h.store.subscription_count().unwrap(), 0);
    let (status, _, _) = h
        .call(
            "POST",
            "/v1/subscriptions",
            Some(&secret),
            Some(json!({"kind": "jmap", "account": "a"})),
        )
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn large_bodies_are_refused() {
    let h = Harness::new();
    let big = "a".repeat(70 * 1024);
    let (status, _, _) = h
        .call(
            "POST",
            "/v1/devices",
            None,
            Some(json!({"token": big, "environment": "sandbox", "topic": "a"})),
        )
        .await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
}
