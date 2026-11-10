//! Starts the relay: reads the configuration, opens the database, loads the APNs key and serves.

use std::process::ExitCode;
use std::sync::Arc;

use margin_relay::apns::ApnsSender;
use margin_relay::config::Config;
use margin_relay::routes::{router, system_clock, AppState};
use margin_relay::store::Store;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("margin-relay: {message}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<(), String> {
    let config = Config::from_env()?;

    let key = config.apns_key.read()?;
    let sender = ApnsSender::new(&key, &config.apns_key_id, &config.apns_team_id)?;

    let store = Store::open(&config.database_path)
        .map_err(|e| format!("could not open DATABASE_PATH: {e}"))?;

    let state = AppState {
        store: Arc::new(store),
        sender: Arc::new(sender),
        public_url: config.public_url.clone(),
        gmail_push_token: config.gmail_push_token.clone(),
        clock: system_clock(),
    };

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", config.port))
        .await
        .map_err(|e| format!("could not listen on port {}: {e}", config.port))?;
    tracing::info!(port = config.port, "margin relay listening");

    axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|e| format!("server error: {e}"))
}

/// Resolves on Ctrl-C or SIGTERM so in-flight requests can finish.
async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut signal) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            signal.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
}
