//! `WaBridge`: the object Swift holds. Owns the tokio runtime and the whatsapp-rust client.

use std::sync::Arc;

use crate::types::*;

type R<T> = Result<T, BridgeError>;

fn todo_(name: &str) -> BridgeError {
    BridgeError::NotImplemented(name.into())
}

#[derive(uniffi::Object)]
pub struct WaBridge {
    data_dir: String,
    sink: Arc<dyn EventSink>,
}

#[uniffi::export]
impl WaBridge {
    /// `data_dir` holds `wa-session.sqlite`. Events are delivered in ordered batches to `sink`.
    #[uniffi::constructor]
    pub fn new(data_dir: String, sink: Arc<dyn EventSink>) -> R<Arc<Self>> {
        Ok(Arc::new(Self { data_dir, sink }))
    }

    pub fn data_dir(&self) -> String {
        self.data_dir.clone()
    }

    pub fn stats(&self) -> BridgeStats {
        BridgeStats { events_received: 0, events_dropped: 0, batches_flushed: 0 }
    }

    // Session
    pub async fn connect(&self) -> R<()> { Err(todo_("connect")) }
    pub async fn disconnect(&self) -> R<()> { Err(todo_("disconnect")) }
    pub async fn logout(&self) -> R<()> { Err(todo_("logout")) }
    pub fn nudge_reconnect(&self) {}
    pub async fn start_pairing_qr(&self) -> R<()> { Err(todo_("start_pairing_qr")) }
    pub async fn pair_with_phone(&self, _number: String) -> R<String> { Err(todo_("pair_with_phone")) }
    pub async fn cancel_pairing(&self) -> R<()> { Err(todo_("cancel_pairing")) }

    // Sending
    pub async fn send_text(&self, _chat: String, _text: String, _reply_to: Option<BridgeMessageKey>) -> R<BridgeSendResult> { Err(todo_("send_text")) }
    pub async fn send_media(&self, _chat: String, _media: BridgeOutgoingMedia, _reply_to: Option<BridgeMessageKey>, _progress: Option<Arc<dyn ProgressSink>>) -> R<BridgeSendResult> { Err(todo_("send_media")) }
    pub async fn send_reaction(&self, _target: BridgeMessageKey, _emoji: String) -> R<()> { Err(todo_("send_reaction")) }
    pub async fn edit_message(&self, _target: BridgeMessageKey, _text: String) -> R<()> { Err(todo_("edit_message")) }
    pub async fn revoke_message(&self, _target: BridgeMessageKey) -> R<()> { Err(todo_("revoke_message")) }

    // Receipts, presence
    pub async fn mark_read(&self, _chat: String, _messages: Vec<BridgeMessageKey>) -> R<()> { Err(todo_("mark_read")) }
    pub async fn send_chat_state(&self, _chat: String, _state: ChatState) -> R<()> { Err(todo_("send_chat_state")) }
    pub async fn subscribe_presence(&self, _jid: String) -> R<()> { Err(todo_("subscribe_presence")) }

    // Groups, contacts
    pub async fn fetch_group_overviews(&self, _jids: Vec<String>) -> R<Vec<BridgeGroup>> { Err(todo_("fetch_group_overviews")) }
    pub async fn fetch_group_metadata(&self, _jid: String) -> R<BridgeGroup> { Err(todo_("fetch_group_metadata")) }
    /// Downloads the picture to `dest_path`; returns false when the user has none.
    pub async fn profile_picture(&self, _jid: String, _preview: bool, _dest_path: String) -> R<bool> { Err(todo_("profile_picture")) }

    // Media
    pub async fn download_media(&self, _media: BridgeMedia, _dest_path: String, _progress: Option<Arc<dyn ProgressSink>>) -> R<()> { Err(todo_("download_media")) }

    // Development: replays a wa-link capture (`history/*.zlib` + `events.jsonl`) through the same
    // mapping and sink as live traffic, without connecting. Lets the app DB be built without re-pairing.
    pub async fn import_capture(&self, _capture_dir: String) -> R<()> { Err(todo_("import_capture")) }

    // Chat actions (synced to other devices via app state)
    pub async fn pin_chat(&self, _chat: String, _pinned: bool) -> R<()> { Err(todo_("pin_chat")) }
    pub async fn archive_chat(&self, _chat: String, _archived: bool) -> R<()> { Err(todo_("archive_chat")) }
    /// `None` unmutes; `Some(i64::MAX)` mutes forever.
    pub async fn mute_chat(&self, _chat: String, _until: Option<i64>) -> R<()> { Err(todo_("mute_chat")) }
    pub async fn mark_chat_read(&self, _chat: String, _read: bool) -> R<()> { Err(todo_("mark_chat_read")) }
}

/// Remuxes an Ogg/Opus voice note into CAF so Core Audio can play it.
#[uniffi::export]
pub fn remux_ogg_to_caf(_src: String, _dst: String) -> R<()> {
    Err(todo_("remux_ogg_to_caf"))
}

/// Routes the `log` facade and `tracing` output to `sink`. Call once, before `WaBridge::new`.
#[uniffi::export]
pub fn install_logger(_sink: Arc<dyn LogSink>, _max_level: LogLevel) {}
