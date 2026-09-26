//! History-sync payload → `BridgeHistoryChunk`s. Synchronous; runs on a blocking thread.
//!
//! Conversations are streamed one at a time (`next_conversation_into`) and emitted every
//! [`CHUNK_CONVERSATIONS`]; `remainder()` (push names, LID mappings) is read only after the
//! conversations are drained and goes out in the final chunk. Only one chunk is ever held.

use whatsapp_rust::Jid;
use whatsapp_rust::prelude::wa;
use whatsapp_rust::wacore::history_sync::HistorySyncStream;
use whatsapp_rust::waproto::buffa::Message as _;

use crate::canon::{Canon, parse};
use crate::map::{self, PollCache};
use crate::types::*;

pub const CHUNK_CONVERSATIONS: usize = 50;

pub fn sync_type(raw: i32) -> HistorySyncType {
    match raw {
        0 => HistorySyncType::InitialBootstrap,
        1 => HistorySyncType::InitialStatus,
        2 => HistorySyncType::Full,
        3 => HistorySyncType::Recent,
        4 => HistorySyncType::PushName,
        5 => HistorySyncType::NonBlockingData,
        6 => HistorySyncType::OnDemand,
        _ => HistorySyncType::Other,
    }
}

#[derive(Debug, Default, Clone)]
pub struct HistorySummary {
    pub chunks: usize,
    pub chats: usize,
    pub messages: usize,
    pub updates: usize,
    pub contacts: usize,
    pub aliases: usize,
    pub skipped_conversations: usize,
}

pub struct HistoryInput<'a> {
    pub stream: HistorySyncStream<'a>,
    pub sync_type: HistorySyncType,
    pub chunk_order: u32,
    pub progress: Option<u32>,
}

/// Drains `input`, calling `emit` per chunk. `emit` returning false aborts (sink gone).
pub fn process(
    input: HistoryInput<'_>,
    canon: &Canon,
    polls: &PollCache,
    resolve: &dyn Fn(&Jid) -> Jid,
    emit: &mut dyn FnMut(BridgeHistoryChunk) -> bool,
) -> Result<HistorySummary, BridgeError> {
    let HistoryInput { mut stream, sync_type, chunk_order, progress } = input;
    let mut summary = HistorySummary::default();
    let new_chunk = || BridgeHistoryChunk {
        sync_type,
        chunk_order,
        progress,
        chats: Vec::new(),
        messages: Vec::new(),
        updates: Vec::new(),
        contacts: Vec::new(),
        aliases: Vec::new(),
        is_last_in_payload: false,
    };
    let mut chunk = new_chunk();
    let mut conv = wa::Conversation::default();

    let mut flush = |chunk: &mut BridgeHistoryChunk, summary: &mut HistorySummary, last: bool| {
        let mut out = std::mem::replace(chunk, new_chunk());
        out.aliases.extend(canon.take_pending());
        out.is_last_in_payload = last;
        summary.chunks += 1;
        summary.chats += out.chats.len();
        summary.messages += out.messages.len();
        summary.updates += out.updates.len();
        summary.contacts += out.contacts.len();
        summary.aliases += out.aliases.len();
        emit(out)
    };

    loop {
        conv.clear();
        let more = stream
            .next_conversation_into(&mut conv)
            .map_err(|e| BridgeError::Protocol(format!("history sync: {e}")))?;
        if !more {
            break;
        }
        map_conversation(&conv, canon, polls, resolve, &mut chunk);
        if chunk.chats.len() >= CHUNK_CONVERSATIONS && !flush(&mut chunk, &mut summary, false) {
            return Err(BridgeError::Cancelled);
        }
    }
    summary.skipped_conversations = stream.skipped_conversations();

    let rest = stream
        .remainder()
        .map_err(|e| BridgeError::Protocol(format!("history sync remainder: {e}")))?;
    for m in &rest.phone_number_to_lid_mappings {
        canon.learn_strs(m.pn_jid.as_deref(), m.lid_jid.as_deref());
    }
    for p in &rest.pushnames {
        let (Some(id), Some(name)) = (p.id.as_deref(), p.pushname.as_deref()) else { continue };
        let Some(jid) = parse(id) else { continue };
        if name.is_empty() {
            continue;
        }
        let jid = canon.cached(&jid);
        chunk.contacts.push(BridgeContact {
            phone: jid.is_pn().then(|| jid.user.to_string()),
            jid: jid.to_string(),
            full_name: None,
            first_name: None,
            push_name: Some(name.to_string()),
        });
    }
    if !flush(&mut chunk, &mut summary, true) {
        return Err(BridgeError::Cancelled);
    }
    Ok(summary)
}

fn map_conversation(
    conv: &wa::Conversation,
    canon: &Canon,
    polls: &PollCache,
    resolve: &dyn Fn(&Jid) -> Jid,
    chunk: &mut BridgeHistoryChunk,
) {
    let Some(raw) = parse(&conv.id) else { return };
    // The conversation names both of its identities on recent payloads.
    canon.learn_strs(conv.lid_jid.as_deref(), conv.pn_jid.as_deref());
    if raw.is_lid() {
        canon.learn_strs(Some(&conv.id), conv.pn_jid.as_deref());
    } else if raw.is_pn() {
        canon.learn_strs(Some(&conv.id), conv.lid_jid.as_deref());
    }
    let chat = resolve(&raw);

    let muted_until = conv.mute_end_time.filter(|&t| t > 0).map(|t| {
        // Seconds on the wire; a far-future sentinel means "forever".
        let secs = if t > 100_000_000_000 { t / 1000 } else { t };
        if secs > 4_000_000_000 { i64::MAX } else { secs as i64 }
    });
    chunk.chats.push(BridgeChat {
        jid: chat.to_string(),
        kind: map::chat_kind(&chat),
        name: conv
            .name
            .clone()
            .or_else(|| conv.display_name.clone())
            .filter(|n| !n.is_empty()),
        last_activity_at: conv
            .conversation_timestamp
            .or(conv.last_msg_timestamp)
            .filter(|&t| t > 0)
            .map(|t| t as i64),
        unread_count: conv.unread_count.unwrap_or(0),
        marked_unread: conv.marked_as_unread.unwrap_or(false),
        pinned_at: conv.pinned.filter(|&p| p > 0).map(i64::from),
        muted_until,
        archived: conv.archived.unwrap_or(false),
        read_only: conv.read_only.unwrap_or(false),
    });

    for hm in &conv.messages {
        if let Some(wmi) = hm.message.as_option() {
            map::map_web_message(
                wmi,
                &chat,
                resolve,
                canon,
                polls,
                &mut chunk.messages,
                &mut chunk.updates,
            );
        }
    }
}
