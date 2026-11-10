//! Sending pushes to Apple Push Notification service.
//!
//! Push sending sits behind the [`PushSender`] trait so tests can record pushes instead of
//! sending them. [`ApnsSender`] is the real one: HTTP/2 to APNs with ES256 token auth.

use std::future::Future;
use std::pin::Pin;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use jsonwebtoken::{Algorithm, EncodingKey, Header};
use serde::Serialize;
use serde_json::Value;

use crate::store::Environment;

/// How long a signed provider token is reused before a new one is made. Apple accepts tokens
/// for an hour and rejects refreshing more than once every 20 minutes.
const TOKEN_LIFETIME: Duration = Duration::from_secs(50 * 60);

/// The kind of push, which sets `apns-push-type` and `apns-priority`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PushType {
    /// A visible notification, priority 10.
    Alert,
    /// A silent wake-up, priority 5.
    Background,
}

impl PushType {
    pub fn header(self) -> &'static str {
        match self {
            PushType::Alert => "alert",
            PushType::Background => "background",
        }
    }

    pub fn priority(self) -> &'static str {
        match self {
            PushType::Alert => "10",
            PushType::Background => "5",
        }
    }
}

/// One push to one device.
#[derive(Clone, Debug)]
pub struct Push {
    pub device_token: String,
    pub environment: Environment,
    pub topic: String,
    pub push_type: PushType,
    pub collapse_id: Option<String>,
    pub payload: Value,
}

/// What came of a push.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PushOutcome {
    Delivered,
    /// Apple answered 410: the token is no longer valid and the device should be forgotten.
    Unregistered,
    /// Anything else; the text is safe to log (status and Apple's reason code).
    Failed(String),
}

pub type PushFuture<'a> = Pin<Box<dyn Future<Output = PushOutcome> + Send + 'a>>;

/// Something that can deliver a push.
pub trait PushSender: Send + Sync {
    fn send(&self, push: Push) -> PushFuture<'_>;
}

/// Signs and caches the provider token used to authenticate with APNs.
struct TokenSigner {
    key: EncodingKey,
    key_id: String,
    team_id: String,
    cached: Mutex<Option<(String, Instant)>>,
}

#[derive(Serialize)]
struct Claims<'a> {
    iss: &'a str,
    iat: u64,
}

impl TokenSigner {
    fn token(&self) -> Result<String, String> {
        let mut cached = self.cached.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((token, made)) = cached.as_ref() {
            if made.elapsed() < TOKEN_LIFETIME {
                return Ok(token.clone());
            }
        }
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.key_id.clone());
        let iat = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let token = jsonwebtoken::encode(
            &header,
            &Claims {
                iss: &self.team_id,
                iat,
            },
            &self.key,
        )
        .map_err(|e| format!("could not sign the APNs token: {e}"))?;
        *cached = Some((token.clone(), Instant::now()));
        Ok(token)
    }

    fn forget(&self) {
        *self.cached.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

/// Sends pushes to APNs over HTTP/2.
pub struct ApnsSender {
    client: reqwest::Client,
    signer: TokenSigner,
}

impl ApnsSender {
    /// Builds a sender from the .p8 key's contents, its key id and the team id. Fails if the key
    /// can't be read or used for signing.
    pub fn new(key_pem: &[u8], key_id: &str, team_id: &str) -> Result<Self, String> {
        let key = EncodingKey::from_ec_pem(key_pem)
            .map_err(|e| format!("APNS_KEY_PATH is not a usable .p8 key: {e}"))?;
        let signer = TokenSigner {
            key,
            key_id: key_id.to_string(),
            team_id: team_id.to_string(),
            cached: Mutex::new(None),
        };
        signer.token()?;
        let client = reqwest::Client::builder()
            .use_rustls_tls()
            .timeout(Duration::from_secs(10))
            .pool_idle_timeout(Duration::from_secs(600))
            .build()
            .map_err(|e| format!("could not build the HTTP client: {e}"))?;
        Ok(ApnsSender { client, signer })
    }

    async fn deliver(&self, push: Push) -> PushOutcome {
        let token = match self.signer.token() {
            Ok(token) => token,
            Err(e) => return PushOutcome::Failed(e),
        };
        let host = match push.environment {
            Environment::Production => "https://api.push.apple.com",
            Environment::Sandbox => "https://api.sandbox.push.apple.com",
        };
        let mut request = self
            .client
            .post(format!("{host}/3/device/{}", push.device_token))
            .bearer_auth(token)
            .header("apns-topic", &push.topic)
            .header("apns-push-type", push.push_type.header())
            .header("apns-priority", push.push_type.priority())
            .json(&push.payload);
        if let Some(collapse_id) = &push.collapse_id {
            request = request.header("apns-collapse-id", collapse_id);
        }
        let response = match request.send().await {
            Ok(response) => response,
            Err(e) => return PushOutcome::Failed(format!("request failed: {}", e.without_url())),
        };
        let status = response.status();
        if status.is_success() {
            return PushOutcome::Delivered;
        }
        if status.as_u16() == 410 {
            return PushOutcome::Unregistered;
        }
        let reason = response
            .json::<Value>()
            .await
            .ok()
            .and_then(|body| {
                body.get("reason")
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .unwrap_or_default();
        if reason == "ExpiredProviderToken" {
            self.signer.forget();
        }
        PushOutcome::Failed(format!("APNs answered {} {reason}", status.as_u16()))
    }
}

impl PushSender for ApnsSender {
    fn send(&self, push: Push) -> PushFuture<'_> {
        Box::pin(self.deliver(push))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // A throwaway P-256 key made for this test only.
    const TEST_KEY: &str = "-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgkWIQu4gm7DPWCZ3C
WZvAJeAlhTjNJGWKWSlNHCkCMaehRANCAATMtqsiwzuyRC4neGLccU7+inNunRO7
vNZB/RLuYnVi+S+B/15J4YneSHIvFFZ0UsBIwFgX11dBcTYGhZneEEFv
-----END PRIVATE KEY-----
";

    #[test]
    fn signs_and_caches_the_provider_token() {
        let sender = ApnsSender::new(TEST_KEY.as_bytes(), "KEYID", "TEAMID").unwrap();
        let first = sender.signer.token().unwrap();
        assert_eq!(first, sender.signer.token().unwrap());
        let header = jsonwebtoken::decode_header(&first).unwrap();
        assert_eq!(header.alg, Algorithm::ES256);
        assert_eq!(header.kid.as_deref(), Some("KEYID"));
    }

    #[test]
    fn rejects_a_bad_key() {
        assert!(ApnsSender::new(b"not a key", "KEYID", "TEAMID").is_err());
    }
}
