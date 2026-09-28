//! Protobuf → flat bridge records. Pure and synchronous: used by the live pipeline (after its
//! async pre-pass has resolved JIDs and decrypted add-ons) and by history sync on a blocking thread.

use std::collections::HashMap;
use std::sync::Mutex;

use whatsapp_rust::Jid;
use whatsapp_rust::prelude::{MessageExt, wa};
use whatsapp_rust::wacore::download::MediaType;
use whatsapp_rust::wacore_binary::JidExt;
use whatsapp_rust::waproto::buffa::Enumeration;

use crate::canon::{Canon, parse};
use crate::types::*;

/// Who/where/when of one message, with JIDs already canonicalised.
#[derive(Debug, Clone)]
pub struct Envelope {
    pub id: String,
    pub chat: Jid,
    pub sender: Jid,
    /// Raw group participant as the key carries it (may be a LID); `None` in DMs.
    pub participant: Option<String>,
    pub from_me: bool,
    pub timestamp: i64,
    pub push_name: Option<String>,
    pub status: Option<MessageStatus>,
}

pub enum Mapped {
    Message(Box<BridgeMessage>),
    Update(BridgeMessageUpdate),
    Skip,
}

/// Poll id → option names, so decrypted vote hashes can be resolved to names.
#[derive(Default)]
pub struct PollCache(Mutex<HashMap<String, Vec<String>>>);

impl PollCache {
    const MAX: usize = 50_000;

    pub fn insert(&self, id: &str, options: &[String]) {
        let mut map = self.0.lock().unwrap();
        if map.len() >= Self::MAX {
            map.clear();
        }
        map.insert(id.to_string(), options.to_vec());
    }

    /// Resolves SHA-256 option hashes to names; unknown hashes come back as lowercase hex.
    pub fn resolve(&self, poll_id: &str, hashes: &[Vec<u8>]) -> Vec<String> {
        let map = self.0.lock().unwrap();
        let options = map.get(poll_id);
        hashes
            .iter()
            .map(|h| {
                options
                    .and_then(|opts| {
                        opts.iter().find(|name| {
                            whatsapp_rust::wacore::poll::compute_option_hash(name).as_slice() == h.as_slice()
                        })
                    })
                    .cloned()
                    .unwrap_or_else(|| hex::encode(h))
            })
            .collect()
    }
}

pub fn chat_kind(jid: &Jid) -> ChatKind {
    if jid.is_group() {
        ChatKind::Group
    } else if jid.is_status_broadcast() {
        ChatKind::Status
    } else if jid.is_broadcast_list() {
        ChatKind::Broadcast
    } else if jid.is_newsletter() {
        ChatKind::Newsletter
    } else {
        ChatKind::Dm
    }
}

/// Translates a key written in the *sender's* frame (reactions, revokes, poll votes: `from_me`
/// means "the sender of this add-on wrote the target") into our frame.
pub fn target_key(key: &wa::MessageKey, env: &Envelope, canon: &Canon) -> BridgeMessageKey {
    let id = key.id.clone().unwrap_or_default();
    let key_from_me = key.from_me.unwrap_or(false);
    // Status updates are multi-party like groups: the key needs the author.
    let is_group = env.chat.is_group() || env.chat.is_status_broadcast();
    let (from_me, participant) = if env.from_me {
        (key_from_me, if key_from_me { env.participant.clone() } else { key.participant.clone() })
    } else if key_from_me {
        // The add-on's sender targets their own message.
        (false, env.participant.clone())
    } else if is_group {
        let p = key.participant.clone();
        let mine = p.as_deref().and_then(parse).is_some_and(|j| canon.is_own(&j));
        (mine, p)
    } else {
        // DM, sender targets a message they did not write: it is ours.
        (true, None)
    };
    BridgeMessageKey {
        chat_jid: env.chat.to_string(),
        id,
        from_me,
        participant: if is_group { participant } else { None },
    }
}

/// Edits only ever target the editor's own message.
fn edit_target(key: Option<&wa::MessageKey>, env: &Envelope) -> BridgeMessageKey {
    BridgeMessageKey {
        chat_jid: env.chat.to_string(),
        id: key.and_then(|k| k.id.clone()).unwrap_or_default(),
        from_me: env.from_me,
        participant: env.participant.clone(),
    }
}

pub fn map_message(msg: &wa::Message, env: &Envelope, canon: &Canon, polls: &PollCache) -> Mapped {
    let base = msg.get_base_message();

    if let Some(pm) = base.protocol_message.as_option() {
        return map_protocol(pm, env, canon);
    }
    // `get_base_message` peels the `edited_message` wrapper; an edit wrapped that way still
    // carries a protocol message inside and was handled above.
    if let Some(r) = base.reaction_message.as_option() {
        let Some(key) = r.key.as_option() else { return Mapped::Skip };
        return Mapped::Update(BridgeMessageUpdate::Reaction {
            target: target_key(key, env, canon),
            reaction: BridgeReaction {
                sender_jid: env.sender.to_string(),
                from_me: env.from_me,
                emoji: r.text.clone().unwrap_or_default(),
                timestamp: r.sender_timestamp_ms.map(|ms| ms / 1000).unwrap_or(env.timestamp),
            },
        });
    }
    if base.poll_update_message.is_set()
        || base.secret_encrypted_message.is_set()
        || base.enc_reaction_message.is_set()
        || base.enc_comment_message.is_set()
        || base.keep_in_chat_message.is_set()
    {
        // Encrypted add-ons are decrypted by the live pipeline before reaching here; what is
        // left could not be opened (logged there). Keep-in-chat has no v1 surface.
        return Mapped::Skip;
    }

    let Some(content) = map_content(base, canon, polls, &env.id) else {
        return Mapped::Skip;
    };
    Mapped::Message(Box::new(BridgeMessage {
        id: env.id.clone(),
        chat_jid: env.chat.to_string(),
        sender_jid: env.sender.to_string(),
        participant: env.participant.clone(),
        from_me: env.from_me,
        timestamp: env.timestamp,
        kind: content.kind,
        text: content.text,
        quoted: content.quoted,
        media: content.media,
        location: content.location,
        contact: content.contact,
        poll: content.poll,
        reactions: Vec::new(),
        type_name: content.type_name,
        push_name: env.push_name.clone().filter(|n| !n.is_empty()),
        status: env.status,
        is_forwarded: content.is_forwarded,
        revoked: false,
        edited_at: None,
    }))
}

fn map_protocol(pm: &wa::message::ProtocolMessage, env: &Envelope, canon: &Canon) -> Mapped {
    use wa::message::protocol_message::Type;
    match pm.r#type {
        Some(Type::REVOKE) => {
            let Some(key) = pm.key.as_option() else { return Mapped::Skip };
            Mapped::Update(BridgeMessageUpdate::Revoke {
                target: target_key(key, env, canon),
                revoked_by: env.sender.to_string(),
                timestamp: env.timestamp,
            })
        }
        Some(Type::MESSAGE_EDIT) | None if pm.edited_message.is_set() => {
            let edited = pm.edited_message.as_option().map(|m| m.get_base_message());
            Mapped::Update(BridgeMessageUpdate::Edit {
                target: edit_target(pm.key.as_option(), env),
                text: edited.and_then(message_text),
                edited_at: pm.timestamp_ms.map(|ms| ms / 1000).unwrap_or(env.timestamp),
            })
        }
        Some(Type::EPHEMERAL_SETTING) => Mapped::Message(Box::new(system_message(
            env,
            "ephemeral_setting",
            Some(format!("{}", pm.ephemeral_expiration.unwrap_or(0))),
        ))),
        _ => Mapped::Skip,
    }
}

fn system_message(env: &Envelope, type_name: &str, text: Option<String>) -> BridgeMessage {
    BridgeMessage {
        id: env.id.clone(),
        chat_jid: env.chat.to_string(),
        sender_jid: env.sender.to_string(),
        participant: env.participant.clone(),
        from_me: env.from_me,
        timestamp: env.timestamp,
        kind: MessageKind::System,
        text,
        quoted: None,
        media: None,
        location: None,
        contact: None,
        poll: None,
        reactions: Vec::new(),
        type_name: Some(type_name.to_string()),
        push_name: env.push_name.clone().filter(|n| !n.is_empty()),
        status: env.status,
        is_forwarded: false,
        revoked: false,
        edited_at: None,
    }
}

pub fn undecryptable(env: &Envelope) -> BridgeMessage {
    BridgeMessage {
        kind: MessageKind::Undecryptable,
        type_name: None,
        ..system_message(env, "", None)
    }
}

struct Content {
    kind: MessageKind,
    text: Option<String>,
    quoted: Option<BridgeQuoted>,
    media: Option<BridgeMedia>,
    location: Option<BridgeLocation>,
    contact: Option<BridgeContactCard>,
    poll: Option<BridgePoll>,
    type_name: Option<String>,
    is_forwarded: bool,
}

impl Content {
    fn new(kind: MessageKind) -> Self {
        Self {
            kind,
            text: None,
            quoted: None,
            media: None,
            location: None,
            contact: None,
            poll: None,
            type_name: None,
            is_forwarded: false,
        }
    }
}

/// Body text of text messages, caption of media.
pub fn message_text(m: &wa::Message) -> Option<String> {
    m.text_content().or_else(|| m.get_caption()).map(str::to_string)
}

fn some_nonempty(s: &Option<String>) -> Option<String> {
    s.clone().filter(|s| !s.is_empty())
}

fn nonzero(v: Option<u32>) -> Option<u32> {
    v.filter(|v| *v > 0)
}

fn direct_path(direct: &Option<String>, url: &Option<String>) -> Option<String> {
    some_nonempty(direct).or_else(|| {
        let url = url.as_deref()?;
        let start = url.find("/v/")?;
        Some(url[start..].to_string())
    })
}

#[allow(clippy::too_many_arguments)]
fn media(
    media_type: BridgeMediaType,
    direct: &Option<String>,
    url: &Option<String>,
    media_key: &Option<Vec<u8>>,
    file_sha256: &Option<Vec<u8>>,
    file_enc_sha256: &Option<Vec<u8>>,
    file_length: Option<u64>,
    mimetype: &Option<String>,
) -> Option<BridgeMedia> {
    Some(BridgeMedia {
        direct_path: direct_path(direct, url)?,
        media_key: media_key.clone()?,
        file_sha256: file_sha256.clone().unwrap_or_default(),
        file_enc_sha256: file_enc_sha256.clone().unwrap_or_default(),
        file_length: file_length.unwrap_or(0),
        media_type,
        mimetype: some_nonempty(mimetype),
        file_name: None,
        width: None,
        height: None,
        duration_secs: None,
        jpeg_thumbnail: None,
        waveform: None,
        page_count: None,
        is_animated: None,
    })
}

fn quoted(ctx: Option<&wa::ContextInfo>, canon: &Canon, polls: &PollCache) -> Option<BridgeQuoted> {
    let ctx = ctx?;
    let id = ctx.stanza_id.clone().filter(|s| !s.is_empty())?;
    let (kind, snippet) = match ctx.quoted_message.as_option() {
        Some(q) => {
            let base = q.get_base_message();
            let content = map_content(base, canon, polls, "");
            let kind = content.as_ref().map_or(MessageKind::Unsupported, |c| c.kind);
            // Quoted media usually lacks download params, so the document name is read directly.
            let mut snippet = content
                .as_ref()
                .and_then(quote_snippet)
                .or_else(|| message_text(base))
                .or_else(|| {
                    let d = base.document_message.as_option()?;
                    some_nonempty(&d.file_name).or_else(|| some_nonempty(&d.title))
                })
                .unwrap_or_default();
            if snippet.chars().count() > 200 {
                snippet = snippet.chars().take(200).collect();
            }
            (kind, snippet)
        }
        None => (MessageKind::Unsupported, String::new()),
    };
    Some(BridgeQuoted {
        id,
        sender_jid: ctx.participant.as_deref().and_then(parse).map(|j| canon.cached_str(&j)),
        kind,
        snippet,
    })
}

/// What a quote block shows for the quoted content: its text (body, caption, business/template
/// text), else a poll question, document name, contact name or place name.
fn quote_snippet(c: &Content) -> Option<String> {
    let nonempty = |s: Option<&str>| s.map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
    nonempty(c.text.as_deref())
        .or_else(|| nonempty(c.poll.as_ref().map(|p| p.question.as_str())))
        .or_else(|| nonempty(c.media.as_ref().and_then(|m| m.file_name.as_deref())))
        .or_else(|| nonempty(c.contact.as_ref().map(|k| k.display_name.as_str())))
        .or_else(|| {
            let l = c.location.as_ref()?;
            nonempty(l.name.as_deref()).or_else(|| nonempty(l.address.as_deref()))
        })
}

fn map_content(base: &wa::Message, canon: &Canon, polls: &PollCache, id: &str) -> Option<Content> {
    let with_ctx = |mut c: Content, ctx: Option<&wa::ContextInfo>| {
        c.quoted = quoted(ctx, canon, polls);
        c.is_forwarded = ctx.and_then(|c| c.is_forwarded).unwrap_or(false);
        c
    };

    // Album items arrive wrapped; the album header itself has nothing to show.
    if let Some(inner) = base.associated_child_message.as_option().and_then(|w| w.message.as_option()) {
        return map_content(inner.get_base_message(), canon, polls, id);
    }
    if base.album_message.is_set() {
        return None;
    }
    if let Some(text) = &base.conversation {
        let mut c = Content::new(MessageKind::Text);
        c.text = Some(text.clone());
        return Some(c);
    }
    if let Some(t) = base.extended_text_message.as_option() {
        let mut c = Content::new(MessageKind::Text);
        c.text = t.text.clone();
        return Some(with_ctx(c, t.context_info.as_option()));
    }
    if let Some(m) = base.image_message.as_option() {
        let mut c = Content::new(MessageKind::Image);
        c.text = some_nonempty(&m.caption);
        c.media = media(
            BridgeMediaType::Image,
            &m.direct_path,
            &m.url,
            &m.media_key,
            &m.file_sha256,
            &m.file_enc_sha256,
            m.file_length,
            &m.mimetype,
        )
        .map(|mut md| {
            md.width = nonzero(m.width);
            md.height = nonzero(m.height);
            md.jpeg_thumbnail = m.jpeg_thumbnail.clone();
            md
        });
        return Some(with_ctx(c, m.context_info.as_option()));
    }
    if let Some(m) = base.video_message.as_option().or(base.ptv_message.as_option()) {
        let gif = m.gif_playback.unwrap_or(false);
        let mut c = Content::new(if gif { MessageKind::Gif } else { MessageKind::Video });
        c.text = some_nonempty(&m.caption);
        c.media = media(
            BridgeMediaType::Video,
            &m.direct_path,
            &m.url,
            &m.media_key,
            &m.file_sha256,
            &m.file_enc_sha256,
            m.file_length,
            &m.mimetype,
        )
        .map(|mut md| {
            md.width = nonzero(m.width);
            md.height = nonzero(m.height);
            md.duration_secs = nonzero(m.seconds);
            md.jpeg_thumbnail = m.jpeg_thumbnail.clone();
            md.is_animated = gif.then_some(true);
            md
        });
        return Some(with_ctx(c, m.context_info.as_option()));
    }
    if let Some(m) = base.audio_message.as_option() {
        let ptt = m.ptt.unwrap_or(false);
        let mut c = Content::new(if ptt { MessageKind::Voice } else { MessageKind::Audio });
        c.media = media(
            BridgeMediaType::Audio,
            &m.direct_path,
            &m.url,
            &m.media_key,
            &m.file_sha256,
            &m.file_enc_sha256,
            m.file_length,
            &m.mimetype,
        )
        .map(|mut md| {
            md.duration_secs = nonzero(m.seconds);
            md.waveform = m.waveform.clone();
            md
        });
        return Some(with_ctx(c, m.context_info.as_option()));
    }
    if let Some(m) = base.document_message.as_option() {
        let mut c = Content::new(MessageKind::Document);
        c.text = some_nonempty(&m.caption);
        c.media = media(
            BridgeMediaType::Document,
            &m.direct_path,
            &m.url,
            &m.media_key,
            &m.file_sha256,
            &m.file_enc_sha256,
            m.file_length,
            &m.mimetype,
        )
        .map(|mut md| {
            md.file_name = some_nonempty(&m.file_name).or_else(|| some_nonempty(&m.title));
            md.page_count = nonzero(m.page_count);
            md.jpeg_thumbnail = m.jpeg_thumbnail.clone();
            md
        });
        return Some(with_ctx(c, m.context_info.as_option()));
    }
    let sticker = base.sticker_message.as_option().or_else(|| {
        base.lottie_sticker_message
            .as_option()
            .and_then(|w| w.message.as_option())
            .and_then(|m| m.sticker_message.as_option())
    });
    if let Some(m) = sticker {
        let mut c = Content::new(MessageKind::Sticker);
        c.media = media(
            BridgeMediaType::Sticker,
            &m.direct_path,
            &m.url,
            &m.media_key,
            &m.file_sha256,
            &m.file_enc_sha256,
            m.file_length,
            &m.mimetype,
        )
        .map(|mut md| {
            md.width = nonzero(m.width);
            md.height = nonzero(m.height);
            md.is_animated = m.is_animated;
            md.jpeg_thumbnail = m.png_thumbnail.clone();
            md
        });
        return Some(with_ctx(c, m.context_info.as_option()));
    }
    if let Some(m) = base.location_message.as_option() {
        let mut c = Content::new(MessageKind::Location);
        c.location = Some(BridgeLocation {
            latitude: m.degrees_latitude.unwrap_or(0.0),
            longitude: m.degrees_longitude.unwrap_or(0.0),
            name: some_nonempty(&m.name),
            address: some_nonempty(&m.address),
            is_live: m.is_live.unwrap_or(false),
        });
        c.text = some_nonempty(&m.comment);
        return Some(with_ctx(c, m.context_info.as_option()));
    }
    if let Some(m) = base.live_location_message.as_option() {
        let mut c = Content::new(MessageKind::Location);
        c.location = Some(BridgeLocation {
            latitude: m.degrees_latitude.unwrap_or(0.0),
            longitude: m.degrees_longitude.unwrap_or(0.0),
            name: None,
            address: None,
            is_live: true,
        });
        c.text = some_nonempty(&m.caption);
        return Some(with_ctx(c, m.context_info.as_option()));
    }
    if let Some(m) = base.contact_message.as_option() {
        let mut c = Content::new(MessageKind::Contact);
        c.contact = Some(BridgeContactCard {
            display_name: m.display_name.clone().unwrap_or_default(),
            vcard: m.vcard.clone().unwrap_or_default(),
        });
        return Some(with_ctx(c, m.context_info.as_option()));
    }
    if let Some(m) = base.contacts_array_message.as_option() {
        let mut c = Content::new(MessageKind::Contact);
        let first = m.contacts.first();
        c.contact = Some(BridgeContactCard {
            display_name: m
                .display_name
                .clone()
                .or_else(|| first.and_then(|f| f.display_name.clone()))
                .unwrap_or_default(),
            vcard: m.contacts.iter().filter_map(|c| c.vcard.clone()).collect::<Vec<_>>().join("\n"),
        });
        return Some(with_ctx(c, m.context_info.as_option()));
    }
    let poll = base
        .poll_creation_message
        .as_option()
        .or(base.poll_creation_message_v2.as_option())
        .or(base.poll_creation_message_v3.as_option())
        .or(base.poll_creation_message_v5.as_option())
        .or(base.poll_creation_message_v6.as_option());
    if let Some(p) = poll {
        let options: Vec<String> = p.options.iter().filter_map(|o| o.option_name.clone()).collect();
        if !id.is_empty() {
            polls.insert(id, &options);
        }
        let mut c = Content::new(MessageKind::Poll);
        c.poll = Some(BridgePoll {
            question: p.name.clone().unwrap_or_default(),
            options,
            selectable_count: p.selectable_options_count.unwrap_or(0),
        });
        return Some(with_ctx(c, p.context_info.as_option()));
    }
    if base.call_log_messsage.is_set() {
        let mut c = Content::new(MessageKind::System);
        c.type_name = Some("call_log".into());
        return Some(c);
    }
    if base.pin_in_chat_message.is_set() {
        let mut c = Content::new(MessageKind::System);
        c.type_name = Some("pin_in_chat".into());
        return Some(c);
    }
    if let Some((text, ctx)) = business_text(base) {
        let mut c = Content::new(MessageKind::Text);
        c.text = Some(text);
        return Some(with_ctx(c, ctx));
    }
    unsupported_type_name(base).map(|name| {
        let mut c = Content::new(MessageKind::Unsupported);
        c.type_name = Some(name);
        c
    })
}

fn join_lines(parts: &[Option<&str>]) -> Option<String> {
    let text = parts
        .iter()
        .flatten()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n");
    (!text.is_empty()).then_some(text)
}

/// Business templates, button/list messages and their replies, flattened to their visible text.
fn business_text(base: &wa::Message) -> Option<(String, Option<&wa::ContextInfo>)> {
    use wa::__buffa::oneof::message::buttons_response_message::Response;
    use wa::__buffa::oneof::message::template_message::Format;
    if let Some(t) = base.template_message.as_option() {
        let hydrated = t.hydrated_template.as_option().or(match &t.format {
            Some(Format::HydratedFourRowTemplate(h)) => Some(&**h),
            _ => None,
        });
        let text = match (hydrated, &t.format) {
            (Some(h), _) => join_lines(&[
                h.hydrated_content_text.as_deref(),
                h.hydrated_footer_text.as_deref(),
            ]),
            (None, Some(Format::InteractiveMessageTemplate(i))) => {
                join_lines(&[i.body.as_option().and_then(|b| b.text.as_deref())])
            }
            _ => None,
        }?;
        return Some((text, t.context_info.as_option()));
    }
    if let Some(b) = base.buttons_message.as_option() {
        let text = join_lines(&[b.content_text.as_deref(), b.footer_text.as_deref()])?;
        return Some((text, b.context_info.as_option()));
    }
    if let Some(l) = base.list_message.as_option() {
        let text = join_lines(&[l.title.as_deref(), l.description.as_deref(), l.footer_text.as_deref()])?;
        return Some((text, l.context_info.as_option()));
    }
    if let Some(i) = base.interactive_message.as_option() {
        let text = join_lines(&[i.body.as_option().and_then(|b| b.text.as_deref())])?;
        return Some((text, i.context_info.as_option()));
    }
    if let Some(r) = base.buttons_response_message.as_option() {
        let Some(Response::SelectedDisplayText(t)) = &r.response else { return None };
        return Some((t.clone(), r.context_info.as_option()));
    }
    if let Some(r) = base.template_button_reply_message.as_option() {
        return Some((r.selected_display_text.clone()?, r.context_info.as_option()));
    }
    None
}

/// Fields that never make a message user-visible on their own.
const IGNORED_FIELDS: &[&str] = &[
    "sender_key_distribution_message",
    "fast_ratchet_key_sender_key_distribution_message",
    "message_context_info",
    "device_sent_message",
    "protocol_message",
    "keep_in_chat_message",
    "placeholder_message",
    "sticker_sync_rmr_message",
    "bot_invoke_message",
    "group_root_key_share",
    "root_secret_distribute_message",
];

/// Name of the first populated content field, or `None` for a message with nothing to show.
/// Slow path (serialises the message), only reached for kinds the bridge does not model.
fn unsupported_type_name(base: &wa::Message) -> Option<String> {
    let value = serde_json::to_value(base).ok()?;
    let obj = value.as_object()?;
    obj.iter()
        .find(|(k, v)| {
            !v.is_null()
                && !IGNORED_FIELDS.contains(&k.as_str())
                && !(v.is_array() && v.as_array().is_some_and(Vec::is_empty))
        })
        .map(|(k, _)| k.clone())
}

pub fn status_from_web(status: Option<wa::web_message_info::Status>) -> Option<MessageStatus> {
    use wa::web_message_info::Status;
    Some(match status? {
        Status::ERROR => MessageStatus::Failed,
        Status::PENDING => MessageStatus::Pending,
        Status::SERVER_ACK => MessageStatus::Sent,
        Status::DELIVERY_ACK => MessageStatus::Delivered,
        Status::READ => MessageStatus::Read,
        Status::PLAYED => MessageStatus::Played,
    })
}

/// Maps one history-sync `WebMessageInfo` in conversation `chat` (canonical): the message itself
/// (or a system/revoked/undecryptable placeholder from its stub) plus inline reactions and votes.
pub fn map_web_message(
    wmi: &wa::WebMessageInfo,
    chat: &Jid,
    resolve: &dyn Fn(&Jid) -> Jid,
    canon: &Canon,
    polls: &PollCache,
    out_messages: &mut Vec<BridgeMessage>,
    out_updates: &mut Vec<BridgeMessageUpdate>,
) {
    let Some(key) = wmi.key.as_option() else { return };
    let Some(id) = key.id.clone().filter(|s| !s.is_empty()) else { return };
    let from_me = key.from_me.unwrap_or(false);
    let is_group = chat.is_group() || chat.is_status_broadcast();
    let participant = key
        .participant
        .clone()
        .or_else(|| wmi.participant.clone())
        .filter(|s| !s.is_empty());
    let sender = if from_me {
        canon.own_pn().unwrap_or_else(|| chat.clone())
    } else if is_group {
        participant.as_deref().and_then(parse).map(|j| resolve(&j)).unwrap_or_else(|| chat.clone())
    } else {
        chat.clone()
    };
    let env = Envelope {
        id,
        chat: chat.clone(),
        sender,
        participant: if is_group { participant } else { None },
        from_me,
        timestamp: wmi.message_timestamp.unwrap_or(0) as i64,
        push_name: wmi.push_name.clone(),
        status: if from_me { status_from_web(wmi.status) } else { None },
    };

    let mut message = match wmi.message.as_option() {
        Some(m) => match map_message(m, &env, canon, polls) {
            Mapped::Message(b) => Some(*b),
            Mapped::Update(u) => {
                out_updates.push(u);
                None
            }
            Mapped::Skip => None,
        },
        None => None,
    };

    if message.is_none()
        && let Some(stub) = wmi.message_stub_type
    {
        use wa::web_message_info::StubType;
        message = match stub {
            StubType::REVOKE => {
                let mut m = system_message(&env, "revoked", None);
                m.kind = MessageKind::Text;
                m.type_name = None;
                m.revoked = true;
                Some(m)
            }
            StubType::CIPHERTEXT => Some(undecryptable(&env)),
            StubType::UNKNOWN => None,
            other => {
                let params = wmi.message_stub_parameters.join("\u{1f}");
                Some(system_message(
                    &env,
                    &other.proto_name().to_ascii_lowercase(),
                    (!params.is_empty()).then_some(params),
                ))
            }
        };
    }

    if let Some(mut m) = message {
        for r in &wmi.reactions {
            let Some(rkey) = r.key.as_option() else { continue };
            let text = r.text.clone().unwrap_or_default();
            if text.is_empty() {
                continue;
            }
            let r_from_me = rkey.from_me.unwrap_or(false);
            let reactor = if r_from_me {
                canon.own_pn()
            } else {
                rkey.participant
                    .as_deref()
                    .or(rkey.remote_jid.as_deref())
                    .and_then(parse)
                    .map(|j| resolve(&j))
            };
            m.reactions.push(BridgeReaction {
                sender_jid: reactor.map(|j| j.to_string()).unwrap_or_default(),
                from_me: r_from_me,
                emoji: text,
                timestamp: r.sender_timestamp_ms.unwrap_or(0) / 1000,
            });
        }
        if m.kind == MessageKind::Poll {
            let target = BridgeMessageKey {
                chat_jid: chat.to_string(),
                id: m.id.clone(),
                from_me,
                participant: m.participant.clone(),
            };
            for pu in &wmi.poll_updates {
                let Some(vote) = pu.vote.as_option() else { continue };
                let voter_key = pu.poll_update_message_key.as_option();
                let voter_from_me = voter_key.and_then(|k| k.from_me).unwrap_or(false);
                let voter = if voter_from_me {
                    canon.own_pn()
                } else {
                    voter_key
                        .and_then(|k| k.participant.as_deref().or(k.remote_jid.as_deref()))
                        .and_then(parse)
                        .map(|j| resolve(&j))
                };
                out_updates.push(BridgeMessageUpdate::PollVote {
                    target: target.clone(),
                    voter_jid: voter.map(|j| j.to_string()).unwrap_or_default(),
                    selected: polls.resolve(&m.id, &vote.selected_options),
                    timestamp: pu.sender_timestamp_ms.unwrap_or(0) / 1000,
                });
            }
        }
        out_messages.push(m);
    }
}

pub fn media_type(t: BridgeMediaType) -> MediaType {
    match t {
        BridgeMediaType::Image => MediaType::Image,
        BridgeMediaType::Video => MediaType::Video,
        BridgeMediaType::Audio => MediaType::Audio,
        BridgeMediaType::Document => MediaType::Document,
        BridgeMediaType::Sticker => MediaType::Sticker,
    }
}
