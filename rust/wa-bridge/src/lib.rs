uniffi::setup_scaffolding!();

mod bridge;
mod types;

pub use bridge::*;
pub use types::*;

#[uniffi::export]
pub fn bridge_hello() -> String {
    format!("wa-bridge {} ready", env!("CARGO_PKG_VERSION"))
}
