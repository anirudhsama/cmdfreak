uniffi::setup_scaffolding!();

mod bridge;
mod canon;
mod history;
mod import;
mod json;
mod live;
mod logging;
mod map;
mod media;
mod remux;
mod types;
#[cfg(test)]
mod tests;

pub use bridge::*;
pub use json::bridge_event_json;
pub use types::*;

#[uniffi::export]
pub fn bridge_hello() -> String {
    format!("wa-bridge {} ready", env!("CARGO_PKG_VERSION"))
}
