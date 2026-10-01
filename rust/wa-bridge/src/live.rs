//! Library `Event` → `BridgeEvent`s for live traffic. Async because canonicalisation may consult the
//! library's LID store and add-ons (poll votes, encrypted edits) need the parent's message secret.

use std::sync::Arc;

use whatsapp_rust::Jid;
use whatsapp_rust::features::message_edit;
use whatsapp_rust::prelude::*;
use whatsapp_rust::types::events::{
    ChatPresenceUpdate, ConnectFailureReason, Receipt as LibReceipt,
};
use whatsapp_rust::wacore::poll::PollVoteCiphertext;
use whatsapp_rust::wacore::types::presence::{ChatPresence, ChatPresenceMedia, ReceiptType};
use whatsapp_rust::wacore_binary::JidExt;
use whatsapp_rust::waproto::buffa::Message as _;

use crate::canon::{Canon, parse};
use crate::map::{self, Envelope, Mapped, PollCache};
use crate::types::*;

/// Event kinds the bridge maps; everything else is filtered on the bus before materialising.
pub const INTEREST: &[EventKind] = &[
    EventKind::Connected,
    EventKind::Disconnected,
    EventKind::PairSuccess,
    EventKind::PairError,
    EventKind::LoggedOut,
    EventKind::PairingQrCode,
    EventKind::PairingCode,
    EventKind::PairingCodeError,
    EventKind::PairingQrCodesExhausted,
    EventKind::ClientOutdated,
    EventKind::Messages,
    EventKind::Receipt,
    EventKind::ServerAck,
    EventKind::UndecryptableMessage,
    EventKind::ChatPresence,
    EventKind::Presence,
    EventKind::PictureUpdate,
    EventKind::ContactNumberChanged,
    EventKind::GroupUpdate,
    EventKind::ContactUpdate,
    EventKind::SelfPushNameUpdated,
    EventKind::PinUpdate,
    EventKind::MuteUpdate,
    EventKind::ArchiveUpdate,
    EventKind::MarkChatAsReadUpdate,
    EventKind::DeleteChatUpdate,
    EventKind::ClearChatUpdate,
    EventKind::DeleteMessageForMeUpdate,
    EventKind::HistorySync,
    EventKind::OfflineSyncCompleted,
    EventKind::StreamReplaced,
    EventKind::TemporaryBan,
    EventKind::ConnectFailure,
];

pub struct MapCtx<'a> {
    pub canon: &'a Canon,
    pub polls: &'a PollCache,
    pub client: Option<&'a Arc<Client>>,
}

fn ts(t: &whatsapp_rust::chrono::DateTime<whatsapp_rust::chrono::Utc>) -> i64 {
    t.timestamp()
}

fn disconnected(reason: impl Into<String>) -> BridgeEvent {
    BridgeEvent::Connection { state: BridgeConnection::Disconnected { reason: reason.into() } }
}

fn failure_reason(r: &ConnectFailureReason) -> String {
    format!("{r:?} ({})", r.code())
}

/// Maps one non-history event. `HistorySync` is handled by the history worker, not here.
pub async fn map_event(ctx: &MapCtx<'_>, event: &Event) -> Vec<BridgeEvent> {
    let canon = ctx.canon;
    let client = ctx.client.map(|c| &**c);
    let mut out = Vec::new();
    match event {
        Event::Connected(_) => {
            if let Some(c) = client {
                canon.set_own(c.pn(), c.lid());
            }
            out.push(BridgeEvent::Connection { state: BridgeConnection::Connected });
            out.push(BridgeEvent::OwnJid {
                pn: canon.own_pn().map(|j| j.to_string()),
                lid: canon.own_lid().map(|j| j.to_string()),
            });
        }
        Event::Disconnected(d) => out.push(disconnected(d.reason.to_string())),
        Event::StreamReplaced(_) => out.push(disconnected("stream replaced by another connection")),
        Event::TemporaryBan(b) => out.push(disconnected(format!("temporary ban: {}", b.code))),
        Event::ConnectFailure(f) => out.push(disconnected(format!(
            "connect failure: {}{}",
            failure_reason(&f.reason),
            f.message.as_deref().map(|m| format!(" {m}")).unwrap_or_default()
        ))),
        Event::ClientOutdated(_) => out.push(disconnected("client outdated")),
        Event::PairingQrCode(q) => out.push(BridgeEvent::Pairing {
            state: BridgePairing::Qr { code: q.code.clone(), timeout_secs: q.timeout.as_secs() as u32 },
        }),
        Event::PairingCode(p) => out.push(BridgeEvent::Pairing {
            state: BridgePairing::PairCode {
                code: p.code.clone(),
                timeout_secs: p.timeout.as_secs() as u32,
            },
        }),
        Event::PairingCodeError(e) => out.push(BridgeEvent::Pairing {
            state: BridgePairing::Error { message: e.error.clone() },
        }),
        Event::PairingQrCodesExhausted(_) => out.push(BridgeEvent::Pairing {
            state: BridgePairing::Error { message: "QR codes exhausted".into() },
        }),
        Event::PairSuccess(p) => {
            canon.set_own(Some(p.id.clone()), Some(p.lid.clone()));
            out.push(BridgeEvent::Pairing {
                state: BridgePairing::Success {
                    jid: p.id.to_non_ad_string(),
                    push_name: (!p.business_name.is_empty()).then(|| p.business_name.clone()),
                },
            });
            out.push(BridgeEvent::OwnJid {
                pn: Some(p.id.to_non_ad_string()),
                lid: Some(p.lid.to_non_ad_string()),
            });
        }
        Event::PairError(p) => out.push(BridgeEvent::Pairing {
            state: BridgePairing::Error { message: p.error.clone() },
        }),
        Event::LoggedOut(l) => out.push(BridgeEvent::Pairing {
            state: BridgePairing::LoggedOut { reason: failure_reason(&l.reason) },
        }),
        Event::Messages(batch) => {
            let (messages, updates) = map_batch(ctx, batch.messages.as_ref()).await;
            push_aliases(canon, &mut out);
            if !messages.is_empty() || !updates.is_empty() {
                out.push(BridgeEvent::Messages { messages, updates });
            }
        }
        Event::UndecryptableMessage(u) => {
            use whatsapp_rust::wacore::types::events::DecryptFailMode;
            // Hidden failures are reactions/poll votes: nothing to show.
            if u.decrypt_fail_mode != DecryptFailMode::Hide {
                let env = envelope(ctx, &u.info).await;
                push_aliases(canon, &mut out);
                out.push(BridgeEvent::Messages { messages: vec![map::undecryptable(&env)], updates: vec![] });
            }
        }
        Event::Receipt(r) => {
            // Aliases first, so a reader seen before under their LID is folded before this receipt counts.
            let receipt = receipt(ctx, r).await;
            push_aliases(canon, &mut out);
            out.push(BridgeEvent::Receipt { receipt });
        }
        // Acks also cover receipts, notifications and calls; only message acks mark a send.
        Event::ServerAck(a) if a.class.as_deref() == Some("message") => {
            let chat_jid = match &a.from {
                Some(from) => Some(ctx.canon.resolve(client, from).await.to_string()),
                None => None,
            };
            push_aliases(canon, &mut out);
            out.push(BridgeEvent::ServerAck {
                ack: BridgeServerAck { chat_jid, message_id: a.id.clone(), error: a.error.clone() },
            });
        }
        Event::ChatPresence(p) => {
            out.push(BridgeEvent::ChatPresence { presence: chat_presence(ctx, p).await });
        }
        Event::Presence(p) => out.push(BridgeEvent::Presence {
            presence: BridgePresence {
                jid: canon.resolve(client, &p.from).await.to_string(),
                available: !p.unavailable,
                last_seen: p.last_seen.as_ref().map(ts),
            },
        }),
        Event::PictureUpdate(p) => out.push(BridgeEvent::PictureChanged {
            jid: canon.resolve(client, &p.jid).await.to_string(),
        }),
        Event::ContactNumberChanged(c) => {
            if let Some(l) = &c.old_lid {
                canon.learn_pair(l, &c.old_jid);
            }
            if let Some(l) = &c.new_lid {
                canon.learn_pair(l, &c.new_jid);
            }
            push_aliases(canon, &mut out);
        }
        Event::GroupUpdate(g) => {
            use whatsapp_rust::wacore::stanza::groups::GroupNotificationAction;
            // Subject changes carry the new name. Membership changes only mark the stored count
            // stale (subject `None`, count 0); the app re-fetches it with the batched overviews.
            // The participant list itself is fetched lazily when the group is opened.
            // A group created with us, or our own add, is a join: until then we knew nothing of it,
            // and its name and size come from the same re-fetch.
            let joined = Some(g.timestamp.timestamp());
            let change = match &*g.action {
                GroupNotificationAction::Subject { subject, .. } => Some((Some(subject.clone()), false, None)),
                // A community's own `<group>` carries `<parent>`: not a chat to list.
                GroupNotificationAction::Create { raw } => {
                    let community =
                        raw.get_optional_child("group").is_some_and(|g| g.get_optional_child("parent").is_some());
                    Some((None, true, if community { None } else { joined }))
                }
                GroupNotificationAction::Add { participants, .. } => {
                    let ours = participants
                        .iter()
                        .any(|p| canon.is_own(&p.jid) || p.phone_number.as_ref().is_some_and(|pn| canon.is_own(pn)));
                    Some((None, true, if ours { joined } else { None }))
                }
                GroupNotificationAction::Remove { .. } => Some((None, true, None)),
                _ => None,
            };
            if let Some((subject, membership_changed, joined_at)) = change {
                out.push(BridgeEvent::Group {
                    group: BridgeGroup {
                        jid: g.group_jid.to_string(),
                        subject,
                        participant_count: 0,
                        participants: vec![],
                        membership_changed,
                        joined_at,
                        is_community: false,
                    },
                });
            }
        }
        Event::ContactUpdate(c) => {
            if let Some(contact) = contact_from_action(canon, &c.jid, &c.action) {
                push_aliases(canon, &mut out);
                out.push(BridgeEvent::Contacts { contacts: vec![contact] });
            }
        }
        Event::SelfPushNameUpdated(s) => {
            if let Some(pn) = canon.own_pn() {
                out.push(BridgeEvent::Contacts {
                    contacts: vec![BridgeContact {
                        jid: pn.to_string(),
                        full_name: None,
                        first_name: None,
                        push_name: Some(s.new_name.clone()),
                        phone: Some(pn.user.to_string()),
                    }],
                });
            }
        }
        Event::PinUpdate(p) => out.push(action(BridgeChatAction::Pin {
            chat_jid: canon.resolve(client, &p.jid).await.to_string(),
            pinned_at: p.action.pinned.unwrap_or(false).then(|| p.timestamp.timestamp()),
        })),
        Event::MuteUpdate(m) => out.push(action(BridgeChatAction::Mute {
            chat_jid: canon.resolve(client, &m.jid).await.to_string(),
            muted_until: mute_until(m.action.muted, m.action.mute_end_timestamp),
        })),
        Event::ArchiveUpdate(a) => out.push(action(BridgeChatAction::Archive {
            chat_jid: canon.resolve(client, &a.jid).await.to_string(),
            archived: a.action.archived.unwrap_or(false),
        })),
        Event::MarkChatAsReadUpdate(m) => {
            let read = m.action.read.unwrap_or(true);
            out.push(action(BridgeChatAction::MarkRead {
                chat_jid: canon.resolve(client, &m.jid).await.to_string(),
                read,
                // Only a range the sender synced: our own mark-read carries none, and the action
                // time would also cover messages still on their way to the phone.
                read_through: if read { range_last(m.action.message_range.as_option()) } else { None },
                read_at: read.then(|| m.timestamp.timestamp()),
            }))
        }
        Event::DeleteChatUpdate(d) => out.push(action(BridgeChatAction::Delete {
            chat_jid: canon.resolve(client, &d.jid).await.to_string(),
            cutoff: Some(range_cutoff(d.action.message_range.as_option(), d.timestamp.timestamp())),
        })),
        Event::ClearChatUpdate(c) => out.push(action(BridgeChatAction::Clear {
            chat_jid: canon.resolve(client, &c.jid).await.to_string(),
            cutoff: Some(range_cutoff(c.action.message_range.as_option(), c.timestamp.timestamp())),
        })),
        Event::DeleteMessageForMeUpdate(d) => out.push(action(BridgeChatAction::DeleteMessageForMe {
            target: BridgeMessageKey {
                chat_jid: canon.resolve(client, &d.chat_jid).await.to_string(),
                id: d.message_id.clone(),
                from_me: d.from_me,
                participant: d.participant_jid.as_ref().map(|j| j.to_string()),
            },
        })),
        Event::OfflineSyncCompleted(o) => {
            out.push(BridgeEvent::OfflineSyncCompleted { count: o.count.max(0) as u32 })
        }
        _ => {}
    }
    out
}

fn action(a: BridgeChatAction) -> BridgeEvent {
    BridgeEvent::ChatAction { action: a }
}

/// Newest message time a clear/delete covers: the synced message range when present (its
/// timestamps are seconds, but tolerate milliseconds), else the action's own time.
pub fn range_cutoff(range: Option<&wa::sync_action_value::SyncActionMessageRange>, action_ts: i64) -> i64 {
    range_last(range).unwrap_or(action_ts)
}

/// Newest message time in a synced message range; None when it names none.
pub fn range_last(range: Option<&wa::sync_action_value::SyncActionMessageRange>) -> Option<i64> {
    let secs = |t: i64| if t > 100_000_000_000 { t / 1000 } else { t };
    range
        .into_iter()
        .flat_map(|r| {
            [r.last_message_timestamp, r.last_system_message_timestamp]
                .into_iter()
                .flatten()
                .chain(r.messages.iter().filter_map(|m| m.timestamp))
        })
        .filter(|t| *t > 0)
        .map(secs)
        .max()
}

pub fn push_aliases(canon: &Canon, out: &mut Vec<BridgeEvent>) {
    let aliases = canon.take_pending();
    if !aliases.is_empty() {
        out.push(BridgeEvent::JidAliases { aliases });
    }
}

/// `MuteAction` end timestamps are milliseconds; `-1` (or a muted action without one) is forever.
pub fn mute_until(muted: Option<bool>, end_ms: Option<i64>) -> Option<i64> {
    if !muted.unwrap_or(false) {
        return None;
    }
    match end_ms {
        Some(ms) if ms > 0 => Some(ms / 1000),
        _ => Some(i64::MAX),
    }
}

pub fn contact_from_action(
    canon: &Canon,
    jid: &Jid,
    a: &wa::sync_action_value::ContactAction,
) -> Option<BridgeContact> {
    canon.learn_strs(a.lid_jid.as_deref(), a.pn_jid.as_deref());
    canon.learn_strs(Some(&jid.to_string()), a.lid_jid.as_deref());
    canon.learn_strs(Some(&jid.to_string()), a.pn_jid.as_deref());
    let c = canon.cached(jid);
    if a.full_name.is_none() && a.first_name.is_none() {
        return None;
    }
    Some(BridgeContact {
        phone: c.is_pn().then(|| c.user.to_string()),
        jid: c.to_string(),
        full_name: a.full_name.clone().filter(|s| !s.is_empty()),
        first_name: a.first_name.clone().filter(|s| !s.is_empty()),
        push_name: None,
    })
}

async fn receipt(ctx: &MapCtx<'_>, r: &LibReceipt) -> BridgeReceipt {
    let client = ctx.client.map(|c| &**c);
    let src = &r.source;
    if let Some(alt) = &src.sender_alt {
        ctx.canon.learn_pair(&src.sender, alt);
    }
    let kind = match &r.r#type {
        ReceiptType::Delivered => ReceiptKind::Delivered,
        ReceiptType::Sent => ReceiptKind::Sent,
        ReceiptType::Retry => ReceiptKind::Retry,
        ReceiptType::Read => ReceiptKind::Read,
        ReceiptType::ReadSelf => ReceiptKind::ReadSelf,
        ReceiptType::Played => ReceiptKind::Played,
        ReceiptType::PlayedSelf => ReceiptKind::PlayedSelf,
        _ => ReceiptKind::Other,
    };
    BridgeReceipt {
        chat_jid: ctx.canon.resolve(client, &src.chat).await.to_string(),
        sender_jid: ctx.canon.resolve(client, &src.sender).await.to_string(),
        message_ids: r.message_ids.iter().map(|m| m.to_string()).collect(),
        kind,
        timestamp: r.timestamp.timestamp(),
    }
}

async fn chat_presence(ctx: &MapCtx<'_>, p: &ChatPresenceUpdate) -> BridgeChatPresence {
    let client = ctx.client.map(|c| &**c);
    let state = match (p.state, p.media) {
        (ChatPresence::Composing, ChatPresenceMedia::Audio) => ChatState::Recording,
        (ChatPresence::Composing, _) => ChatState::Composing,
        (ChatPresence::Paused, _) => ChatState::Paused,
    };
    BridgeChatPresence {
        chat_jid: ctx.canon.resolve(client, &p.source.chat).await.to_string(),
        sender_jid: ctx.canon.resolve(client, &p.source.sender).await.to_string(),
        state,
    }
}

/// Canonical envelope for a live message. Learns the envelope's own LID↔PN pairing first.
pub async fn envelope(ctx: &MapCtx<'_>, info: &MessageInfo) -> Envelope {
    let canon = ctx.canon;
    let client = ctx.client.map(|c| &**c);
    let src = &info.source;
    if let Some(alt) = &src.sender_alt {
        canon.learn_pair(&src.sender, alt);
    }
    if let Some(alt) = &src.recipient_alt
        && !src.is_group
    {
        canon.learn_pair(&src.chat, alt);
    }
    let chat = canon.resolve(client, &src.chat).await;
    let sender = if src.is_from_me {
        canon.own_pn().unwrap_or(canon.resolve(client, &src.sender).await)
    } else {
        canon.resolve(client, &src.sender).await
    };
    let is_group = src.is_group || src.chat.is_group() || src.chat.is_status_broadcast();
    Envelope {
        id: info.id.to_string(),
        chat,
        sender,
        participant: is_group.then(|| src.sender.to_non_ad_string()),
        from_me: src.is_from_me,
        timestamp: info.timestamp.timestamp(),
        push_name: (!info.push_name.is_empty()).then(|| info.push_name.to_string()),
        verified_name: info.verified_name.as_ref().and_then(|v| v.name.clone()),
        status: None,
    }
}

pub async fn map_batch(
    ctx: &MapCtx<'_>,
    batch: &[InboundMessage],
) -> (Vec<BridgeMessage>, Vec<BridgeMessageUpdate>) {
    let mut messages = Vec::new();
    let mut updates = Vec::new();
    for m in batch {
        let env = envelope(ctx, &m.info).await;
        match map_inbound(ctx, &env, m, true).await {
            Mapped::Message(b) => messages.push(*b),
            Mapped::Update(u) => updates.push(u),
            Mapped::Skip => {}
        }
    }
    (messages, updates)
}

/// Outcome of opening an encrypted add-on (poll vote, edit).
enum Addon<T> {
    Opened(T),
    /// The parent's secret is not known (yet): the add-on arrived before its original.
    NoSecret(BridgeMessageKey),
    Skip,
}

/// `park`: emit add-ons whose parent secret is missing as `BridgeMessageUpdate::Encrypted` so the
/// app can retry them once the parent is stored; `false` when retrying a parked one.
async fn map_inbound(ctx: &MapCtx<'_>, env: &Envelope, m: &InboundMessage, park: bool) -> Mapped {
    let base = m.message.get_base_message();
    if let Some(pu) = base.poll_update_message.as_option() {
        return match decrypt_poll_vote(ctx, env, m, pu).await {
            Addon::Opened(u) => Mapped::Update(u),
            Addon::NoSecret(target) if park => parked(target, m),
            _ => Mapped::Skip,
        };
    }
    if base.secret_encrypted_message.is_set() {
        match decrypt_edit_fallback(ctx, env, m).await {
            Addon::Opened(rewrapped) => return map::map_message(&rewrapped, env, ctx.canon, ctx.polls),
            Addon::NoSecret(target) if park => return parked(target, m),
            _ => {}
        }
    }
    map::map_message(&m.message, env, ctx.canon, ctx.polls)
}

/// What `decrypt_parked` needs to rebuild the add-on: the raw (not canonicalised) source and the
/// encoded message. Private to the bridge; Swift stores it as opaque bytes.
#[derive(serde::Serialize, serde::Deserialize)]
struct ParkedEnvelope {
    chat: String,
    sender: String,
    sender_alt: Option<String>,
    from_me: bool,
    is_group: bool,
    id: String,
    timestamp: i64,
    push_name: String,
    message: String,
}

fn parked(target: BridgeMessageKey, m: &InboundMessage) -> Mapped {
    let src = &m.info.source;
    let envelope = ParkedEnvelope {
        chat: src.chat.to_string(),
        sender: src.sender.to_string(),
        sender_alt: src.sender_alt.as_ref().map(|j| j.to_string()),
        from_me: src.is_from_me,
        is_group: src.is_group,
        id: m.info.id.to_string(),
        timestamp: m.info.timestamp.timestamp(),
        push_name: m.info.push_name.to_string(),
        message: hex::encode(m.message.encode_to_vec()),
    };
    match serde_json::to_vec(&envelope) {
        Ok(envelope) => Mapped::Update(BridgeMessageUpdate::Encrypted { target, envelope }),
        Err(_) => Mapped::Skip,
    }
}

pub(crate) fn unpark(bytes: &[u8]) -> Option<InboundMessage> {
    let p: ParkedEnvelope = serde_json::from_slice(bytes).ok()?;
    let message = wa::Message::decode_from_slice(&hex::decode(&p.message).ok()?).ok()?;
    let info = MessageInfo {
        source: whatsapp_rust::wacore::types::message::MessageSource {
            chat: parse(&p.chat)?,
            sender: parse(&p.sender)?,
            is_from_me: p.from_me,
            is_group: p.is_group,
            sender_alt: p.sender_alt.as_deref().and_then(parse),
            ..Default::default()
        },
        id: p.id.into(),
        push_name: p.push_name.into(),
        timestamp: whatsapp_rust::chrono::DateTime::from_timestamp(p.timestamp, 0)?,
        ..Default::default()
    };
    Some(InboundMessage::builder().message(Arc::new(message)).info(Arc::new(info)).build())
}

/// Retries one parked add-on (see `BridgeMessageUpdate::Encrypted`).
pub async fn decrypt_parked(ctx: &MapCtx<'_>, bytes: &[u8]) -> Option<BridgeMessageUpdate> {
    let m = unpark(bytes)?;
    let env = envelope(ctx, &m.info).await;
    match map_inbound(ctx, &env, &m, false).await {
        Mapped::Update(u @ (BridgeMessageUpdate::Edit { .. } | BridgeMessageUpdate::PollVote { .. })) => Some(u),
        _ => None,
    }
}

/// Secret lookups try every combination of the chat's and the author's PN/LID spellings, since the
/// library stores the secret under whichever form the parent arrived with.
pub(crate) async fn lookup_secret(
    client: &Client,
    canon: &Canon,
    chat: &Jid,
    author: &Jid,
    msg_id: &str,
) -> Option<Vec<u8>> {
    let backend = client.persistence_manager().backend();
    let chats: Vec<Jid> = std::iter::once(chat.to_non_ad()).chain(canon.alternate(chat)).collect();
    let authors: Vec<Jid> =
        std::iter::once(author.to_non_ad()).chain(canon.alternate(author)).collect();
    for c in &chats {
        for a in &authors {
            if let Ok(Some(secret)) =
                backend.get_msg_secret(&c.to_string(), &a.to_string(), msg_id).await
            {
                return Some(secret);
            }
        }
    }
    None
}

async fn decrypt_poll_vote(
    ctx: &MapCtx<'_>,
    env: &Envelope,
    m: &InboundMessage,
    pu: &wa::message::PollUpdateMessage,
) -> Addon<BridgeMessageUpdate> {
    let Some(key) = pu.poll_creation_message_key.as_option() else { return Addon::Skip };
    let Some(poll_id) = key.id.clone() else { return Addon::Skip };
    let Some(vote) = pu.vote.as_option() else { return Addon::Skip };
    let (Some(payload), Some(iv)) = (vote.enc_payload.as_deref(), vote.enc_iv.as_deref()) else {
        return Addon::Skip;
    };
    let target = map::target_key(key, env, ctx.canon);
    // Without a client (not connected) there is no secret store to look in yet.
    let Some(client) = ctx.client else { return Addon::NoSecret(target) };
    let src = &m.info.source;
    let Some(own) = ctx.canon.own_pn().or_else(|| client.pn()) else { return Addon::Skip };
    let creator = if target.from_me {
        own.clone()
    } else if let Some(p) = target.participant.as_deref().and_then(parse) {
        p
    } else {
        src.chat.to_non_ad()
    };
    let voter = if src.is_from_me { own } else { src.sender.to_non_ad() };
    let Some(secret) = lookup_secret(client, ctx.canon, &src.chat, &creator, &poll_id).await else {
        log::info!("poll vote {}: parent secret unknown", env.id);
        return Addon::NoSecret(target);
    };
    let hashes = match client
        .polls()
        .decrypt_vote(
            PollVoteCiphertext { enc_payload: payload, enc_iv: iv },
            &secret,
            &poll_id,
            &creator,
            &voter,
        )
        .await
    {
        Ok(h) => h,
        Err(e) => {
            log::warn!("poll vote {} decrypt failed: {e}", env.id);
            return Addon::Skip;
        }
    };
    Addon::Opened(BridgeMessageUpdate::PollVote {
        selected: ctx.polls.resolve(&poll_id, &hashes),
        target,
        voter_jid: env.sender.to_string(),
        timestamp: pu.sender_timestamp_ms.map(|ms| ms / 1000).unwrap_or(env.timestamp),
    })
}

/// The library decrypts `secret_encrypted_message` edits on dispatch at this commit; this is the
/// fallback for when it could not (e.g. the secret landed after the edit), using the library's own
/// secret store: `get_msg_secret` → `decrypt` → `rewrap_as_legacy_edit`.
async fn decrypt_edit_fallback(
    ctx: &MapCtx<'_>,
    env: &Envelope,
    m: &InboundMessage,
) -> Addon<wa::Message> {
    let base = m.message.get_base_message();
    let Some(edit) = message_edit::extract_envelope(base) else { return Addon::Skip };
    let Some(target_id) = edit.target_id().map(str::to_string) else { return Addon::Skip };
    // Edits only ever target the editor's own message.
    let target = BridgeMessageKey {
        chat_jid: env.chat.to_string(),
        id: target_id.clone(),
        from_me: env.from_me,
        participant: env.participant.clone(),
    };
    let Some(client) = ctx.client else { return Addon::NoSecret(target) };
    let src = &m.info.source;
    let Some(own) = ctx.canon.own_pn().or_else(|| client.pn()) else { return Addon::Skip };
    let author = edit.original_sender_for_dispatch(src.is_from_me, &src.sender, &own);
    let Some(secret) = lookup_secret(client, ctx.canon, &src.chat, &author, &target_id).await else {
        log::info!("encrypted edit {}: parent secret unknown", env.id);
        return Addon::NoSecret(target);
    };
    let alt_author = ctx.canon.alternate(&author);
    let alt_editor = src.sender_alt.clone().or_else(|| ctx.canon.alternate(&src.sender));
    match message_edit::decrypt_with_fallback(
        edit.enc_payload,
        edit.enc_iv,
        &secret,
        &target_id,
        &author,
        &src.sender,
        alt_author.as_ref(),
        alt_editor.as_ref(),
    ) {
        Ok(inner) => message_edit::rewrap_as_legacy_edit(inner).map_or(Addon::Skip, Addon::Opened),
        Err(e) => {
            log::warn!("encrypted edit {} decrypt failed: {e}", env.id);
            Addon::Skip
        }
    }
}
