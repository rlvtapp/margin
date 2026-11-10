//! Margin's push relay: forwards "new mail" pings from mail providers to Apple Push
//! Notification service. It never sees mail content or credentials.

pub mod apns;
pub mod config;
pub mod routes;
pub mod store;
