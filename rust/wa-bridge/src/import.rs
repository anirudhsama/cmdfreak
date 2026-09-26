//! Dev-only replay of a `wa-link` capture directory through the live mapping and sink:
//! `history/*.zlib` (raw `HistorySync` payloads) and the app-state events of `events.jsonl`.
//! `Event` is Serialize-only, so JSON lines are read as `serde_json::Value`.

use std::path::Path;

use serde_json::Value;
use whatsapp_rust::Jid;
use whatsapp_rust::prelude::wa;
use whatsapp_rust::wacore::history_sync::{HistorySyncStream, MAX_DECOMPRESSED};

use crate::bridge::Shared;
use crate::history::{self, HistoryInput};
use crate::live::mute_until;
use crate::types::*;

type R<T> = Result<T, BridgeError>;

const EVENT_BATCH: usize = 200;

fn io(e: impl std::fmt::Display) -> BridgeError {
    BridgeError::Io(e.to_string())
}

fn jid_of(v: &Value) -> Option<Jid> {
    let user = v.get("user")?.as_str()?;
    let server = v.get("server")?.as_str()?;
    format!("{user}@{server}").parse().ok()
}

fn ts_of(v: &Value) -> i64 {
    v.as_str()
        .and_then(|s| whatsapp_rust::chrono::DateTime::parse_from_rfc3339(s).ok())
        .map_or(0, |d| d.timestamp())
}

fn str_of<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key)?.as_str().filter(|s| !s.is_empty())
}

/// `<seq>-type<t>-chunk<n>.zlib` → (type, chunk).
fn parse_name(name: &str) -> (i32, u32) {
    let num_after = |tag: &str| -> Option<u32> {
        let rest = &name[name.find(tag)? + tag.len()..];
        rest.chars().take_while(char::is_ascii_digit).collect::<String>().parse().ok()
    };
    (num_after("-type").map_or(-1, |t| t as i32), num_after("-chunk").unwrap_or(0))
}

/// `range_cutoff` over a serialized `ClearChatAction`/`DeleteChatAction`.
fn json_cutoff(action: &Value, timestamp: &Value) -> i64 {
    let range = action.get("message_range").or_else(|| action.get("messageRange"));
    let field = |k: &str| range.and_then(|r| r.get(k)).and_then(Value::as_i64);
    let parsed = range.map(|_| wa::sync_action_value::SyncActionMessageRange {
        last_message_timestamp: field("last_message_timestamp"),
        last_system_message_timestamp: field("last_system_message_timestamp"),
        ..Default::default()
    });
    crate::live::range_cutoff(parsed.as_ref(), ts_of(timestamp))
}

pub fn import_capture(shared: &Shared, dir: &str) -> R<()> {
    let dir = Path::new(dir);
    let events_text = std::fs::read_to_string(dir.join("events.jsonl")).unwrap_or_default();
    let events: Vec<Value> =
        events_text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
    let canon = &shared.canon;

    // Pass 1: identities, so history is canonicalised from its first chunk.
    for e in &events {
        if let Some(p) = e.get("PairSuccess") {
            let pn = p.get("id").and_then(jid_of);
            let lid = p.get("lid").and_then(jid_of);
            canon.set_own(pn, lid);
        }
        if let Some(c) = e.get("ContactUpdate") {
            learn_contact(shared, c);
        }
    }
    let mut files: Vec<_> = std::fs::read_dir(dir.join("history"))
        .map_err(io)?
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "zlib"))
        .collect();
    files.sort();
    for f in &files {
        let bytes = std::fs::read(f).map_err(io)?;
        let mut stream = HistorySyncStream::new(&bytes, MAX_DECOMPRESSED);
        while stream.next_conversation_bytes().map_err(|e| BridgeError::Protocol(e.to_string()))?.is_some() {}
        if let Ok(rest) = stream.remainder() {
            for m in &rest.phone_number_to_lid_mappings {
                canon.learn_strs(m.pn_jid.as_deref(), m.lid_jid.as_deref());
            }
        }
    }
    let mut head = vec![BridgeEvent::OwnJid {
        pn: canon.own_pn().map(|j| j.to_string()),
        lid: canon.own_lid().map(|j| j.to_string()),
    }];
    crate::live::push_aliases(canon, &mut head);
    if !shared.emit_blocking(head) {
        return Err(BridgeError::Cancelled);
    }

    // Pass 2: history payloads, in capture order.
    let resolve = |j: &Jid| canon.cached(j);
    for f in &files {
        let name = f.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let (sync_type, chunk_order) = parse_name(&name);
        let bytes = std::fs::read(f).map_err(io)?;
        let input = HistoryInput {
            stream: HistorySyncStream::new(&bytes, MAX_DECOMPRESSED),
            sync_type: history::sync_type(sync_type),
            chunk_order,
            progress: None,
        };
        let summary = history::process(input, canon, &shared.polls, &resolve, &mut |chunk| {
            shared.emit_blocking(vec![BridgeEvent::HistoryChunk { chunk }])
        })?;
        log::info!("import {name}: {summary:?}");
    }

    // Pass 3: app-state events.
    let mut batch = Vec::new();
    let mut contacts = Vec::new();
    for e in &events {
        let Some((kind, body)) = e.as_object().and_then(|o| o.iter().next()) else { continue };
        let chat = || body.get("jid").and_then(jid_of).map(|j| canon.cached_str(&j));
        let action = body.get("action").unwrap_or(&Value::Null);
        let mapped = match kind.as_str() {
            "ContactUpdate" => {
                if let Some(c) = contact_of(shared, body) {
                    contacts.push(c);
                }
                None
            }
            "PinUpdate" => chat().map(|chat_jid| BridgeChatAction::Pin {
                chat_jid,
                pinned_at: action
                    .get("pinned")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
                    .then(|| ts_of(&body["timestamp"])),
            }),
            "MuteUpdate" => chat().map(|chat_jid| BridgeChatAction::Mute {
                chat_jid,
                muted_until: mute_until(
                    action.get("muted").and_then(Value::as_bool),
                    action.get("mute_end_timestamp").and_then(Value::as_i64),
                ),
            }),
            "ArchiveUpdate" => chat().map(|chat_jid| BridgeChatAction::Archive {
                chat_jid,
                archived: action.get("archived").and_then(Value::as_bool).unwrap_or(false),
            }),
            "MarkChatAsReadUpdate" => chat().map(|chat_jid| BridgeChatAction::MarkRead {
                chat_jid,
                read: action.get("read").and_then(Value::as_bool).unwrap_or(true),
            }),
            "DeleteChatUpdate" => chat().map(|chat_jid| BridgeChatAction::Delete {
                chat_jid,
                cutoff: Some(json_cutoff(action, &body["timestamp"])),
            }),
            "ClearChatUpdate" => chat().map(|chat_jid| BridgeChatAction::Clear {
                chat_jid,
                cutoff: Some(json_cutoff(action, &body["timestamp"])),
            }),
            _ => None,
        };
        if let Some(a) = mapped {
            batch.push(BridgeEvent::ChatAction { action: a });
        }
        if contacts.len() >= EVENT_BATCH {
            batch.push(BridgeEvent::Contacts { contacts: std::mem::take(&mut contacts) });
        }
        if batch.len() >= EVENT_BATCH && !shared.emit_blocking(std::mem::take(&mut batch)) {
            return Err(BridgeError::Cancelled);
        }
    }
    if !contacts.is_empty() {
        batch.push(BridgeEvent::Contacts { contacts });
    }
    crate::live::push_aliases(canon, &mut batch);
    if !batch.is_empty() && !shared.emit_blocking(batch) {
        return Err(BridgeError::Cancelled);
    }
    Ok(())
}

fn learn_contact(shared: &Shared, body: &Value) {
    let action = body.get("action").unwrap_or(&Value::Null);
    let jid = body.get("jid").and_then(jid_of).map(|j| j.to_string());
    let lid = str_of(action, "lid_jid");
    let pn = str_of(action, "pn_jid");
    shared.canon.learn_strs(lid, pn);
    shared.canon.learn_strs(jid.as_deref(), lid);
    shared.canon.learn_strs(jid.as_deref(), pn);
}

fn contact_of(shared: &Shared, body: &Value) -> Option<BridgeContact> {
    learn_contact(shared, body);
    let action = body.get("action")?;
    let jid = shared.canon.cached(&body.get("jid").and_then(jid_of)?);
    let full_name = str_of(action, "full_name").map(str::to_string);
    let first_name = str_of(action, "first_name").map(str::to_string);
    if full_name.is_none() && first_name.is_none() {
        return None;
    }
    Some(BridgeContact {
        phone: jid.is_pn().then(|| jid.user.to_string()),
        jid: jid.to_string(),
        full_name,
        first_name,
        push_name: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_file_names() {
        assert_eq!(parse_name("001190-type3-chunk1.zlib"), (3, 1));
        assert_eq!(parse_name("000653-type5-chunk0.zlib"), (5, 0));
    }
}
