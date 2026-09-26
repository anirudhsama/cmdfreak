//! JSON rendering of bridge events for tools (`wa-cli events`). Thumbnails and waveforms are
//! summarised as byte counts; keys and hashes are hex.

use serde::Serializer;

use crate::types::BridgeEvent;

pub fn hex<S: Serializer>(bytes: &[u8], s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&::hex::encode(bytes))
}

pub fn byte_count<S: Serializer>(bytes: &Option<Vec<u8>>, s: S) -> Result<S::Ok, S::Error> {
    match bytes {
        Some(b) => s.serialize_str(&format!("<{} bytes>", b.len())),
        None => s.serialize_none(),
    }
}

/// One-line JSON for a bridge event (debug tooling only; not a stable format).
#[uniffi::export]
pub fn bridge_event_json(event: BridgeEvent) -> String {
    serde_json::to_string(&event).unwrap_or_else(|e| format!("{{\"error\":\"{e}\"}}"))
}
