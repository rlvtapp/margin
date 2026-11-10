//! Settings read from environment variables at startup.

use std::env;
use std::fmt;

/// Everything the relay needs to run. Missing values stop startup with a clear message.
#[derive(Clone)]
pub struct Config {
    /// Port to listen on (all interfaces).
    pub port: u16,
    /// Path of the SQLite file.
    pub database_path: String,
    /// Public base address of this relay, used to build the hook URLs handed to the phone.
    pub public_url: String,
    /// The APNs signing key (.p8): a file, or its contents given directly.
    pub apns_key: ApnsKey,
    /// Key id of the APNs signing key.
    pub apns_key_id: String,
    /// Apple developer team id.
    pub apns_team_id: String,
    /// Shared secret that the Pub/Sub push subscription adds as `?token=`.
    pub gmail_push_token: String,
}

/// Where the APNs signing key comes from.
#[derive(Clone)]
pub enum ApnsKey {
    /// Path of the .p8 file.
    Path(String),
    /// The .p8 file's contents.
    Contents(String),
}

impl ApnsKey {
    /// The key's PEM bytes.
    pub fn read(&self) -> Result<Vec<u8>, String> {
        match self {
            ApnsKey::Path(path) => {
                std::fs::read(path).map_err(|e| format!("could not read APNS_KEY_PATH: {e}"))
            }
            ApnsKey::Contents(contents) => Ok(contents.clone().into_bytes()),
        }
    }
}

impl fmt::Debug for ApnsKey {
    // Keeps the key itself out of any debug output.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ApnsKey::Path(path) => write!(f, "Path({path:?})"),
            ApnsKey::Contents(_) => write!(f, "Contents(<redacted>)"),
        }
    }
}

impl fmt::Debug for Config {
    // Keeps the shared secret out of any debug output.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("port", &self.port)
            .field("database_path", &self.database_path)
            .field("public_url", &self.public_url)
            .field("apns_key", &self.apns_key)
            .field("apns_key_id", &self.apns_key_id)
            .field("apns_team_id", &self.apns_team_id)
            .field("gmail_push_token", &"<redacted>")
            .finish()
    }
}

impl Config {
    /// Reads the configuration from the process environment.
    pub fn from_env() -> Result<Self, String> {
        Self::from_lookup(|name| env::var(name).ok())
    }

    /// Reads the configuration through `lookup`, so it can be tested without touching the
    /// process environment.
    pub fn from_lookup(lookup: impl Fn(&str) -> Option<String>) -> Result<Self, String> {
        let mut missing = Vec::new();
        let mut required = |name: &'static str| match lookup(name).map(|v| v.trim().to_string()) {
            Some(value) if !value.is_empty() => value,
            _ => {
                missing.push(name);
                String::new()
            }
        };

        let database_path = required("DATABASE_PATH");
        let public_url = required("PUBLIC_URL");
        // The key's contents (APNS_KEY) suit hosts that keep secrets as variables; otherwise a
        // path to the .p8 file.
        let apns_key = match lookup("APNS_KEY").map(|v| v.trim().to_string()) {
            Some(contents) if !contents.is_empty() => ApnsKey::Contents(contents.replace("\\n", "\n")),
            _ => ApnsKey::Path(required("APNS_KEY_PATH")),
        };
        let apns_key_id = required("APNS_KEY_ID");
        let apns_team_id = required("APNS_TEAM_ID");
        let gmail_push_token = required("GMAIL_PUSH_TOKEN");

        if !missing.is_empty() {
            return Err(format!(
                "missing required environment variables: {}",
                missing.join(", ")
            ));
        }

        let port = match lookup("PORT").map(|v| v.trim().to_string()) {
            Some(value) if !value.is_empty() => value
                .parse::<u16>()
                .map_err(|_| format!("PORT must be a port number, got {value:?}"))?,
            _ => 8080,
        };

        if !(public_url.starts_with("https://") || public_url.starts_with("http://")) {
            return Err("PUBLIC_URL must start with https:// or http://".to_string());
        }

        Ok(Config {
            port,
            database_path,
            public_url: public_url.trim_end_matches('/').to_string(),
            apns_key,
            apns_key_id,
            apns_team_id,
            gmail_push_token,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn lookup(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        move |name| map.get(name).cloned()
    }

    #[test]
    fn reports_every_missing_variable() {
        let err = Config::from_lookup(lookup(&[("PUBLIC_URL", "https://relay.test")])).unwrap_err();
        assert!(err.contains("DATABASE_PATH"));
        assert!(err.contains("GMAIL_PUSH_TOKEN"));
        assert!(!err.contains("PUBLIC_URL"));
    }

    #[test]
    fn defaults_port_and_trims_url() {
        let config = Config::from_lookup(lookup(&[
            ("DATABASE_PATH", "relay.db"),
            ("PUBLIC_URL", "https://relay.test/"),
            ("APNS_KEY_PATH", "key.p8"),
            ("APNS_KEY_ID", "KEY"),
            ("APNS_TEAM_ID", "TEAM"),
            ("GMAIL_PUSH_TOKEN", "secret"),
        ]))
        .unwrap();
        assert_eq!(config.port, 8080);
        assert_eq!(config.public_url, "https://relay.test");
        assert!(!format!("{config:?}").contains("secret"));
    }

    #[test]
    fn takes_the_key_contents_instead_of_a_path() {
        let config = Config::from_lookup(lookup(&[
            ("DATABASE_PATH", "relay.db"),
            ("PUBLIC_URL", "https://relay.test"),
            ("APNS_KEY", "-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----"),
            ("APNS_KEY_ID", "KEY"),
            ("APNS_TEAM_ID", "TEAM"),
            ("GMAIL_PUSH_TOKEN", "secret"),
        ]))
        .unwrap();
        assert_eq!(
            config.apns_key.read().unwrap(),
            b"-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"
        );
        assert!(!format!("{config:?}").contains("abc"));
    }
}
