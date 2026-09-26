uniffi::setup_scaffolding!();

#[uniffi::export]
pub fn bridge_hello() -> String {
    format!("wa-bridge {} ready", env!("CARGO_PKG_VERSION"))
}
