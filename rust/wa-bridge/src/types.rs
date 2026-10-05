//! Flat UniFFI records exchanged with Swift. No protobuf or whatsapp-rust type crosses this boundary.
//!
//! Conventions: JIDs are canonical strings (phone-number JID when a LID→PN mapping is known),
//! timestamps are unix seconds, byte blobs are `Vec<u8>` (Swift `Data`).

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum BridgeError {
    #[error("not connected")]
    NotConnected,
    #[error("invalid jid: {0}")]
    InvalidJid(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("io: {0}")]
    Io(String),
    #[error("store: {0}")]
    Store(String),
    #[error("network: {0}")]
    Network(String),
    /// Sent, but the server never acked it (the id is the stanza's): it may or may not have landed.
    #[error("no server ack for {0}")]
    Timeout(String),
    /// The server asked us to slow down; callers back off before trying again.
    #[error("rate limited")]
    RateLimited,
    #[error("protocol: {0}")]
    Protocol(String),
    #[error("cancelled")]
    Cancelled,
    #[error("not implemented: {0}")]
    NotImplemented(String),
    #[error("{0}")]
    Other(String),
}

// MARK: - Chats, contacts, groups

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, uniffi::Enum)]
pub enum ChatKind {
    Dm,
    Group,
    Broadcast,
    Status,
    Newsletter,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeChat {
    pub jid: String,
    pub kind: ChatKind,
    pub name: Option<String>,
    pub last_activity_at: Option<i64>,
    pub unread_count: u32,
    pub marked_unread: bool,
    pub pinned_at: Option<i64>,
    /// `Some(i64::MAX)` for "muted forever".
    pub muted_until: Option<i64>,
    pub archived: bool,
    pub read_only: bool,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeContact {
    pub jid: String,
    pub full_name: Option<String>,
    pub first_name: Option<String>,
    pub push_name: Option<String>,
    pub phone: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeJidAlias {
    pub lid: String,
    pub pn: String,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeGroupParticipant {
    pub jid: String,
    pub is_admin: bool,
    pub is_super_admin: bool,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeGroup {
    pub jid: String,
    pub subject: Option<String>,
    pub participant_count: u32,
    /// Empty for overviews; populated by `fetch_group_metadata`.
    pub participants: Vec<BridgeGroupParticipant>,
    /// Members were added or removed: a stored participant count is stale (re-fetch it).
    #[uniffi(default = false)]
    pub membership_changed: bool,
    /// We joined (the group was created with us, or we were added) at this time: the chat
    /// shows in the list before its first message.
    #[uniffi(default)]
    pub joined_at: Option<i64>,
    /// A community itself (its parent group): not a chat, never listed.
    #[uniffi(default = false)]
    pub is_community: bool,
}

/// Whether a user is a WhatsApp Business account, from `check_business`.
#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeBusinessCheck {
    /// As passed to `check_business`.
    pub jid: String,
    pub is_business: bool,
    /// The business's verified display name, when it has one.
    pub verified_name: Option<String>,
}

// MARK: - Messages

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, uniffi::Enum)]
pub enum MessageKind {
    Text,
    Image,
    Video,
    Gif,
    Sticker,
    Document,
    Audio,
    Voice,
    Location,
    Contact,
    Poll,
    System,
    /// Placeholder; the library requests a retry and the real message later arrives with the same
    /// `(chat_jid, id)`, which should replace it.
    Undecryptable,
    Unsupported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, uniffi::Enum)]
pub enum BridgeMediaType {
    Image,
    Video,
    Audio,
    Document,
    Sticker,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeMedia {
    pub direct_path: String,
    #[serde(serialize_with = "crate::json::hex")]
    pub media_key: Vec<u8>,
    #[serde(serialize_with = "crate::json::hex")]
    pub file_sha256: Vec<u8>,
    #[serde(serialize_with = "crate::json::hex")]
    pub file_enc_sha256: Vec<u8>,
    pub file_length: u64,
    pub media_type: BridgeMediaType,
    pub mimetype: Option<String>,
    pub file_name: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_secs: Option<u32>,
    #[serde(serialize_with = "crate::json::byte_count")]
    pub jpeg_thumbnail: Option<Vec<u8>>,
    /// Voice notes: 64 amplitude samples, 0–100.
    #[serde(serialize_with = "crate::json::byte_count")]
    pub waveform: Option<Vec<u8>>,
    pub page_count: Option<u32>,
    pub is_animated: Option<bool>,
}

/// Enough to rebuild a `wa::MessageKey` for reactions, revokes, edits and quotes.
#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize, uniffi::Record)]
pub struct BridgeMessageKey {
    pub chat_jid: String,
    pub id: String,
    pub from_me: bool,
    /// Group sender; `None` in DMs.
    pub participant: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeQuoted {
    pub id: String,
    pub sender_jid: Option<String>,
    pub kind: MessageKind,
    pub snippet: String,
    /// JIDs the quoted text mentions, as its sender wrote them (see `BridgeMessage::mentions`).
    #[uniffi(default)]
    pub mentions: Vec<String>,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeLocation {
    pub latitude: f64,
    pub longitude: f64,
    pub name: Option<String>,
    pub address: Option<String>,
    pub is_live: bool,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeContactCard {
    pub display_name: String,
    pub vcard: String,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgePoll {
    pub question: String,
    pub options: Vec<String>,
    pub selectable_count: u32,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeReaction {
    pub sender_jid: String,
    pub from_me: bool,
    pub emoji: String,
    pub timestamp: i64,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeMessage {
    pub id: String,
    pub chat_jid: String,
    pub sender_jid: String,
    /// Raw participant JID for group messages (needed to rebuild the key); `None` in DMs.
    pub participant: Option<String>,
    pub from_me: bool,
    pub timestamp: i64,
    pub kind: MessageKind,
    /// Body text for text messages, caption for media.
    pub text: Option<String>,
    /// JIDs mentioned in `text` (each appears there as "@<user>"), LID or phone number as the sender
    /// wrote them.
    #[uniffi(default)]
    pub mentions: Vec<String>,
    pub quoted: Option<BridgeQuoted>,
    pub media: Option<BridgeMedia>,
    pub location: Option<BridgeLocation>,
    pub contact: Option<BridgeContactCard>,
    pub poll: Option<BridgePoll>,
    /// Reactions already attached (history sync carries them inline).
    pub reactions: Vec<BridgeReaction>,
    /// For `System`: human-readable description. For `Unsupported`: the protobuf field name.
    pub type_name: Option<String>,
    pub push_name: Option<String>,
    /// A business sender's verified display name.
    #[uniffi(default)]
    pub verified_name: Option<String>,
    /// Status known at ingest (history rows carry one); `None` for live incoming messages.
    pub status: Option<MessageStatus>,
    pub is_forwarded: bool,
    pub revoked: bool,
    pub edited_at: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, serde::Serialize, uniffi::Enum)]
pub enum MessageStatus {
    Pending,
    Sent,
    Delivered,
    Read,
    Played,
    Failed,
}

/// Mutations of an existing message. They can arrive before the target (history sync, retries),
/// so the app parks them until the target row exists.
#[derive(Debug, Clone, serde::Serialize, uniffi::Enum)]
pub enum BridgeMessageUpdate {
    Edit {
        target: BridgeMessageKey,
        text: Option<String>,
        /// JIDs mentioned in the new text.
        mentions: Vec<String>,
        edited_at: i64,
    },
    Revoke {
        target: BridgeMessageKey,
        revoked_by: String,
        timestamp: i64,
    },
    /// Empty `emoji` removes the sender's reaction.
    Reaction {
        target: BridgeMessageKey,
        reaction: BridgeReaction,
    },
    PollVote {
        target: BridgeMessageKey,
        voter_jid: String,
        /// Option names; empty clears the vote. When the bridge has not seen the poll itself this
        /// session (live votes on older polls), an entry is the lowercase hex SHA-256 of the option
        /// name instead; match it against `sha256(optionName)` of the stored poll.
        selected: Vec<String>,
        timestamp: i64,
    },
    /// An encrypted edit or poll vote whose parent secret is not known yet (it arrived before its
    /// original). Park it with the target; once the target message has been stored, pass
    /// `envelope` to `WaBridge::decrypt_parked`, which returns the decrypted `Edit`/`PollVote`.
    /// `envelope` is opaque to Swift.
    Encrypted {
        target: BridgeMessageKey,
        #[serde(serialize_with = "crate::json::hex")]
        envelope: Vec<u8>,
    },
}

// MARK: - Receipts, presence

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, uniffi::Enum)]
pub enum ReceiptKind {
    Sent,
    Delivered,
    Read,
    ReadSelf,
    Played,
    PlayedSelf,
    Retry,
    /// Includes `sender` receipts: our other devices confirming delivery of a message we sent.
    Other,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeReceipt {
    pub chat_jid: String,
    /// Who produced the receipt (the reader); for `ReadSelf` it's our own JID.
    pub sender_jid: String,
    pub message_ids: Vec<String>,
    pub kind: ReceiptKind,
    pub timestamp: i64,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeServerAck {
    /// None when the server omitted it.
    pub chat_jid: Option<String>,
    pub message_id: String,
    /// Nack code, e.g. "479".
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, uniffi::Enum)]
pub enum ChatState {
    Composing,
    Recording,
    Paused,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeChatPresence {
    pub chat_jid: String,
    pub sender_jid: String,
    pub state: ChatState,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgePresence {
    pub jid: String,
    pub available: bool,
    pub last_seen: Option<i64>,
}

// MARK: - Chat actions (app-state sync from other devices)

#[derive(Debug, Clone, serde::Serialize, uniffi::Enum)]
pub enum BridgeChatAction {
    Pin { chat_jid: String, pinned_at: Option<i64> },
    Mute { chat_jid: String, muted_until: Option<i64> },
    Archive { chat_jid: String, archived: bool },
    /// `read == false` means "marked unread". A read covers messages up to `read_through` (unix
    /// seconds, from the synced message range; None without one), including ones not here yet.
    /// `read_at` is when it was done: without a range, it bounds the messages already here that
    /// it read. Both None for our own reads, which cover everything.
    MarkRead {
        chat_jid: String,
        read: bool,
        #[uniffi(default)]
        read_through: Option<i64>,
        #[uniffi(default)]
        read_at: Option<i64>,
    },
    /// Deletes messages at or before `cutoff` (unix seconds; the synced message range, else the
    /// action time) and the chat itself when nothing newer remains. `None`: everything.
    Delete {
        chat_jid: String,
        #[uniffi(default)]
        cutoff: Option<i64>,
    },
    /// Clears messages at or before `cutoff` (as for `Delete`); the chat stays.
    Clear {
        chat_jid: String,
        #[uniffi(default)]
        cutoff: Option<i64>,
    },
    DeleteMessageForMe { target: BridgeMessageKey },
}

// MARK: - Session

#[derive(Debug, Clone, serde::Serialize, uniffi::Enum)]
pub enum BridgePairing {
    Qr { code: String, timeout_secs: u32 },
    PairCode { code: String, timeout_secs: u32 },
    Success { jid: String, push_name: Option<String> },
    Error { message: String },
    LoggedOut { reason: String },
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Enum)]
pub enum BridgeConnection {
    Connecting,
    Connected,
    Disconnected { reason: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, uniffi::Enum)]
pub enum HistorySyncType {
    InitialBootstrap,
    InitialStatus,
    Full,
    Recent,
    PushName,
    NonBlockingData,
    OnDemand,
    Other,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeHistoryChunk {
    pub sync_type: HistorySyncType,
    pub chunk_order: u32,
    /// 0–100 when the server reports it.
    pub progress: Option<u32>,
    pub chats: Vec<BridgeChat>,
    pub messages: Vec<BridgeMessage>,
    pub updates: Vec<BridgeMessageUpdate>,
    pub contacts: Vec<BridgeContact>,
    pub aliases: Vec<BridgeJidAlias>,
    /// Last chunk emitted for this history-sync payload.
    pub is_last_in_payload: bool,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Enum)]
pub enum BridgeEvent {
    Connection { state: BridgeConnection },
    Pairing { state: BridgePairing },
    /// One `MessageBatch` from the library; never split across bridge batches. Inbound user
    /// messages are delivered from the library's durability hook: the server ack waits until
    /// `on_events` has returned for them, and a crash before that redelivers them (so ingest must
    /// be idempotent on `(chat_jid, id)`).
    Messages {
        messages: Vec<BridgeMessage>,
        updates: Vec<BridgeMessageUpdate>,
    },
    Receipt { receipt: BridgeReceipt },
    /// The server accepted (`error == None`) or rejected one of our messages. Until then a sent
    /// message was only written to the socket, which a dying connection can swallow.
    ServerAck { ack: BridgeServerAck },
    ChatPresence { presence: BridgeChatPresence },
    Presence { presence: BridgePresence },
    Contacts { contacts: Vec<BridgeContact> },
    JidAliases { aliases: Vec<BridgeJidAlias> },
    ChatAction { action: BridgeChatAction },
    /// Group subject or membership changed. `participant_count == 0` means unknown here. A
    /// membership change (members added or removed) sets `membership_changed`: the stored count is
    /// stale, re-fetch it (`fetch_group_overviews`).
    Group { group: BridgeGroup },
    PictureChanged { jid: String },
    HistoryChunk { chunk: BridgeHistoryChunk },
    OfflineSyncCompleted { count: u32 },
    /// Our own JID once known (after connect or pairing).
    OwnJid { pn: Option<String>, lid: Option<String> },
}

// MARK: - Sending

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, uniffi::Enum)]
pub enum SendMediaKind {
    Image,
    Video,
    Gif,
    Document,
}

/// Metadata the Swift side computes natively before a media send.
#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeOutgoingMedia {
    pub kind: SendMediaKind,
    pub file_path: String,
    pub mimetype: String,
    pub file_name: Option<String>,
    pub caption: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_secs: Option<u32>,
    #[serde(serialize_with = "crate::json::byte_count")]
    pub jpeg_thumbnail: Option<Vec<u8>>,
    /// Size of `jpeg_thumbnail`; documents use it to lay out their preview.
    pub thumbnail_width: Option<u32>,
    pub thumbnail_height: Option<u32>,
    pub page_count: Option<u32>,
    /// JIDs the caption mentions (see `WaBridge::send_text`).
    #[uniffi(default)]
    pub mentions: Vec<String>,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeSendResult {
    pub message_id: String,
    pub timestamp: i64,
    /// The message as it would be ingested (media params filled in after upload).
    pub message: BridgeMessage,
}

#[derive(Debug, Clone, serde::Serialize, uniffi::Record)]
pub struct BridgeStats {
    pub events_received: u64,
    pub events_dropped: u64,
    pub batches_flushed: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, uniffi::Enum)]
pub enum LogLevel {
    Error,
    Warn,
    Info,
    Debug,
    Trace,
}

// MARK: - Callbacks

#[uniffi::export(with_foreign)]
pub trait EventSink: Send + Sync {
    /// Returns whether the batch was handled (persisted, for events the app stores). `false`
    /// fails the durability hook for any inbound messages in the batch, so the library leaves
    /// them unacked and the server redelivers them (bounded, see `DurabilityHook`).
    fn on_events(&self, events: Vec<BridgeEvent>) -> bool;
}

#[uniffi::export(with_foreign)]
pub trait LogSink: Send + Sync {
    fn on_log(&self, level: LogLevel, target: String, message: String);
}

#[uniffi::export(with_foreign)]
pub trait ProgressSink: Send + Sync {
    fn on_progress(&self, done: u64, total: u64);
}
