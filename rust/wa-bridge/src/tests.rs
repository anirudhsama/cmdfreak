//! Mapping tests over synthetic history payloads (fictitious JIDs only), plus an `#[ignore]`d
//! smoke test over a local wa-link capture (`WA_CAPTURE_DIR`, default the app's capture dir).

use std::io::Write;

use flate2::Compression;
use flate2::write::ZlibEncoder;
use whatsapp_rust::Jid;
use whatsapp_rust::prelude::{MessageField, wa};
use whatsapp_rust::wacore::history_sync::{HistorySyncStream, MAX_DECOMPRESSED};
use whatsapp_rust::waproto::buffa::Message as _;

use crate::canon::Canon;
use crate::history::{self, HistoryInput};
use crate::map::{self, Envelope, Mapped, PollCache};
use crate::types::*;

const ME_PN: &str = "15550000000";
const ME_LID: &str = "100000000000000";
const BOB_PN: &str = "15550001111";
const BOB_LID: &str = "100000000000001";
const CAROL_PN: &str = "15550002222";
const CAROL_LID: &str = "100000000000002";
const GROUP: &str = "120363000000000001@g.us";

fn key(remote: &str, from_me: bool, id: &str, participant: Option<&str>) -> MessageField<wa::MessageKey> {
    MessageField::some(wa::MessageKey {
        remote_jid: Some(remote.into()),
        from_me: Some(from_me),
        id: Some(id.into()),
        participant: participant.map(Into::into),
    })
}

fn wmi(key: MessageField<wa::MessageKey>, ts: u64, message: Option<wa::Message>) -> wa::HistorySyncMsg {
    wa::HistorySyncMsg {
        message: MessageField::some(wa::WebMessageInfo {
            key,
            message: message.map(MessageField::some).unwrap_or_default(),
            message_timestamp: Some(ts),
            ..Default::default()
        }),
        msg_order_id: None,
    }
}

fn text(t: &str) -> wa::Message {
    wa::Message { conversation: Some(t.into()), ..Default::default() }
}

fn fixture() -> Vec<u8> {
    let bob_chat = format!("{BOB_LID}@lid");
    let mut revoked = wmi(key(&bob_chat, false, "M3", None), 1_700_000_300, None);
    revoked.message.as_option_mut().unwrap().message_stub_type =
        Some(wa::web_message_info::StubType::REVOKE);

    let mut image = wmi(
        key(&bob_chat, true, "M2", None),
        1_700_000_200,
        Some(wa::Message {
            image_message: MessageField::some(wa::message::ImageMessage {
                direct_path: Some("/v/t62.7118-24/fake.enc".into()),
                media_key: Some(vec![1; 32]),
                file_sha256: Some(vec![2; 32]),
                file_enc_sha256: Some(vec![3; 32]),
                file_length: Some(1234),
                mimetype: Some("image/jpeg".into()),
                width: Some(640),
                height: Some(480),
                caption: Some("a caption".into()),
                ..Default::default()
            }),
            ..Default::default()
        }),
    );
    {
        let info = image.message.as_option_mut().unwrap();
        info.status = Some(wa::web_message_info::Status::READ);
        info.reactions.push(wa::Reaction {
            key: key(&bob_chat, false, "R1", None),
            text: Some("👍".into()),
            sender_timestamp_ms: Some(1_700_000_250_000),
            ..Default::default()
        });
    }

    let edit = wmi(
        key(&bob_chat, false, "E1", None),
        1_700_000_400,
        Some(wa::Message {
            protocol_message: MessageField::some(wa::message::ProtocolMessage {
                key: key(&bob_chat, true, "M1", None),
                r#type: Some(wa::message::protocol_message::Type::MESSAGE_EDIT),
                edited_message: MessageField::some(text("hello, edited")),
                timestamp_ms: Some(1_700_000_400_000),
                ..Default::default()
            }),
            ..Default::default()
        }),
    );

    let mut hello = wmi(key(&bob_chat, false, "M1", None), 1_700_000_100, Some(text("hello")));
    hello.message.as_option_mut().unwrap().verified_biz_name = Some("Bob's Bakery".into());

    let dm = wa::Conversation {
        id: bob_chat.clone(),
        pn_jid: Some(format!("{BOB_PN}@s.whatsapp.net")),
        unread_count: Some(2),
        conversation_timestamp: Some(1_700_000_400),
        messages: vec![
            hello,
            image,
            revoked,
            edit,
        ],
        ..Default::default()
    };

    let carol = format!("{CAROL_LID}@lid");
    let mut poll = wmi(
        key(GROUP, false, "P1", Some(&carol)),
        1_700_000_500,
        Some(wa::Message {
            poll_creation_message_v3: MessageField::some(wa::message::PollCreationMessage {
                name: Some("Lunch?".into()),
                options: vec![
                    wa::message::poll_creation_message::Option {
                        option_name: Some("Yes".into()),
                        ..Default::default()
                    },
                    wa::message::poll_creation_message::Option {
                        option_name: Some("No".into()),
                        ..Default::default()
                    },
                ],
                selectable_options_count: Some(1),
                ..Default::default()
            }),
            ..Default::default()
        }),
    );
    poll.message.as_option_mut().unwrap().poll_updates.push(wa::PollUpdate {
        poll_update_message_key: key(GROUP, true, "V1", None),
        vote: MessageField::some(wa::message::PollVoteMessage {
            selected_options: vec![whatsapp_rust::wacore::poll::compute_option_hash("No").to_vec()],
        }),
        sender_timestamp_ms: Some(1_700_000_600_000),
        ..Default::default()
    });
    let group = wa::Conversation {
        id: GROUP.into(),
        name: Some("Test group".into()),
        messages: vec![poll],
        ..Default::default()
    };

    let hs = wa::HistorySync {
        sync_type: wa::history_sync::HistorySyncType::RECENT,
        conversations: vec![dm, group],
        pushnames: vec![wa::Pushname {
            id: Some(format!("{CAROL_PN}@s.whatsapp.net")),
            pushname: Some("Carol".into()),
        }],
        phone_number_to_lid_mappings: vec![wa::PhoneNumberToLIDMapping {
            pn_jid: Some(format!("{CAROL_PN}@s.whatsapp.net")),
            lid_jid: Some(carol),
        }],
        ..Default::default()
    };
    let mut enc = ZlibEncoder::new(Vec::new(), Compression::default());
    enc.write_all(&hs.encode_to_vec()).unwrap();
    enc.finish().unwrap()
}

fn canon() -> Canon {
    let c = Canon::default();
    c.set_own(Some(Jid::pn(ME_PN)), Some(Jid::lid(ME_LID)));
    c.take_pending();
    c
}

fn run(bytes: &[u8], canon: &Canon) -> Vec<BridgeHistoryChunk> {
    let polls = PollCache::default();
    let mut chunks = Vec::new();
    let input = HistoryInput {
        stream: HistorySyncStream::new(bytes, MAX_DECOMPRESSED),
        sync_type: HistorySyncType::Recent,
        chunk_order: 1,
        progress: Some(10),
    };
    history::process(input, canon, &polls, &|j| canon.cached(j), &mut |c| {
        chunks.push(c);
        true
    })
    .unwrap();
    chunks
}

#[test]
fn history_maps_chats_messages_and_updates() {
    let canon = canon();
    let chunks = run(&fixture(), &canon);
    assert_eq!(chunks.len(), 1);
    let c = &chunks[0];
    assert!(c.is_last_in_payload);
    assert_eq!(c.sync_type, HistorySyncType::Recent);

    let bob = format!("{BOB_PN}@s.whatsapp.net");
    let dm = c.chats.iter().find(|ch| ch.kind == ChatKind::Dm).unwrap();
    assert_eq!(dm.jid, bob, "LID conversation is keyed by its PN");
    assert_eq!(dm.unread_count, 2);
    assert_eq!(dm.last_activity_at, Some(1_700_000_400));
    let group = c.chats.iter().find(|ch| ch.kind == ChatKind::Group).unwrap();
    assert_eq!(group.name.as_deref(), Some("Test group"));

    let msg = |id: &str| c.messages.iter().find(|m| m.id == id).unwrap();
    let m1 = msg("M1");
    assert_eq!((m1.kind, m1.text.as_deref(), m1.chat_jid.as_str()), (MessageKind::Text, Some("hello"), bob.as_str()));
    assert_eq!(m1.sender_jid, bob);
    assert!(!m1.from_me);
    assert_eq!(m1.verified_name.as_deref(), Some("Bob's Bakery"));

    let m2 = msg("M2");
    assert_eq!(m2.kind, MessageKind::Image);
    assert!(m2.from_me);
    assert_eq!(m2.sender_jid, format!("{ME_PN}@s.whatsapp.net"));
    assert_eq!(m2.status, Some(MessageStatus::Read));
    let media = m2.media.as_ref().unwrap();
    assert_eq!((media.file_length, media.width, media.media_type), (1234, Some(640), BridgeMediaType::Image));
    assert_eq!(m2.text.as_deref(), Some("a caption"));
    assert_eq!(m2.reactions.len(), 1);
    assert_eq!(m2.reactions[0].emoji, "👍");
    assert_eq!(m2.reactions[0].sender_jid, bob);

    assert!(msg("M3").revoked);

    let edit = c
        .updates
        .iter()
        .find_map(|u| match u {
            BridgeMessageUpdate::Edit { target, text, edited_at, .. } => Some((target, text, edited_at)),
            _ => None,
        })
        .unwrap();
    assert_eq!(edit.0.id, "M1");
    assert!(!edit.0.from_me, "Bob edited his own message");
    assert_eq!(edit.1.as_deref(), Some("hello, edited"));
    assert_eq!(*edit.2, 1_700_000_400);

    let poll = msg("P1");
    assert_eq!(poll.kind, MessageKind::Poll);
    assert_eq!(poll.poll.as_ref().unwrap().options, vec!["Yes", "No"]);
    assert_eq!(poll.participant.as_deref(), Some(format!("{CAROL_LID}@lid").as_str()));
    let vote = c
        .updates
        .iter()
        .find_map(|u| match u {
            BridgeMessageUpdate::PollVote { selected, voter_jid, .. } => Some((selected, voter_jid)),
            _ => None,
        })
        .unwrap();
    assert_eq!(vote.0, &vec!["No".to_string()]);
    assert_eq!(vote.1, &format!("{ME_PN}@s.whatsapp.net"));

    // Remainder: push name keyed by PN, LID mapping surfaced as an alias.
    assert_eq!(c.contacts.len(), 1);
    assert_eq!(c.contacts[0].push_name.as_deref(), Some("Carol"));
    assert!(c.aliases.iter().any(|a| a.lid == format!("{BOB_LID}@lid") && a.pn == bob));
    assert!(c.aliases.iter().any(|a| a.lid == format!("{CAROL_LID}@lid")));
}

#[test]
fn history_chunks_every_fifty_conversations() {
    let convs: Vec<wa::Conversation> = (0..120)
        .map(|i| wa::Conversation { id: format!("1555{i:07}@s.whatsapp.net"), ..Default::default() })
        .collect();
    let hs = wa::HistorySync {
        sync_type: wa::history_sync::HistorySyncType::INITIAL_BOOTSTRAP,
        conversations: convs,
        ..Default::default()
    };
    let mut enc = ZlibEncoder::new(Vec::new(), Compression::default());
    enc.write_all(&hs.encode_to_vec()).unwrap();
    let chunks = run(&enc.finish().unwrap(), &canon());
    let sizes: Vec<usize> = chunks.iter().map(|c| c.chats.len()).collect();
    assert_eq!(sizes, vec![50, 50, 20]);
    assert_eq!(chunks.iter().filter(|c| c.is_last_in_payload).count(), 1);
    assert!(chunks.last().unwrap().is_last_in_payload);
}

fn env(chat: &str, sender: &str, participant: Option<&str>, from_me: bool) -> Envelope {
    Envelope {
        id: "X1".into(),
        chat: chat.parse().unwrap(),
        sender: sender.parse().unwrap(),
        participant: participant.map(Into::into),
        from_me,
        timestamp: 1_700_000_000,
        push_name: None,
        verified_name: None,
        status: None,
    }
}

#[test]
fn live_reaction_and_revoke_keys_are_translated_to_our_frame() {
    let canon = canon();
    let polls = PollCache::default();
    let bob = format!("{BOB_PN}@s.whatsapp.net");
    // Bob reacts (DM) to a message he did not write → it is ours.
    let reaction = wa::Message {
        reaction_message: MessageField::some(wa::message::ReactionMessage {
            key: key(&format!("{ME_PN}@s.whatsapp.net"), false, "MINE", None),
            text: Some("❤️".into()),
            sender_timestamp_ms: Some(1_700_000_001_000),
            ..Default::default()
        }),
        ..Default::default()
    };
    let Mapped::Update(BridgeMessageUpdate::Reaction { target, reaction }) =
        map::map_message(&reaction, &env(&bob, &bob, None, false), &canon, &polls)
    else {
        panic!("expected reaction");
    };
    assert!(target.from_me);
    assert_eq!(target.chat_jid, bob);
    assert_eq!(reaction.emoji, "❤️");
    assert_eq!(reaction.timestamp, 1_700_000_001);

    // Carol revokes her own group message: key.from_me is true in her frame.
    let carol_lid = format!("{CAROL_LID}@lid");
    let revoke = wa::Message {
        protocol_message: MessageField::some(wa::message::ProtocolMessage {
            key: key(GROUP, true, "HERS", None),
            r#type: Some(wa::message::protocol_message::Type::REVOKE),
            ..Default::default()
        }),
        ..Default::default()
    };
    let Mapped::Update(BridgeMessageUpdate::Revoke { target, .. }) = map::map_message(
        &revoke,
        &env(GROUP, &format!("{CAROL_PN}@s.whatsapp.net"), Some(&carol_lid), false),
        &canon,
        &polls,
    ) else {
        panic!("expected revoke");
    };
    assert!(!target.from_me);
    assert_eq!(target.participant.as_deref(), Some(carol_lid.as_str()));

    // Carol reacts in the group to our message (participant = our LID).
    let react_group = wa::Message {
        reaction_message: MessageField::some(wa::message::ReactionMessage {
            key: key(GROUP, false, "OURS", Some(&format!("{ME_LID}@lid"))),
            text: Some("😂".into()),
            ..Default::default()
        }),
        ..Default::default()
    };
    let Mapped::Update(BridgeMessageUpdate::Reaction { target, .. }) = map::map_message(
        &react_group,
        &env(GROUP, &format!("{CAROL_PN}@s.whatsapp.net"), Some(&carol_lid), false),
        &canon,
        &polls,
    ) else {
        panic!("expected reaction");
    };
    assert!(target.from_me);

    // A contact deletes their status: the target keeps its author.
    let status_revoke = wa::Message {
        protocol_message: MessageField::some(wa::message::ProtocolMessage {
            key: key("status@broadcast", true, "STATUS1", None),
            r#type: Some(wa::message::protocol_message::Type::REVOKE),
            ..Default::default()
        }),
        ..Default::default()
    };
    let Mapped::Update(BridgeMessageUpdate::Revoke { target, .. }) = map::map_message(
        &status_revoke,
        &env("status@broadcast", &bob, Some(&format!("{BOB_LID}@lid")), false),
        &canon,
        &polls,
    ) else {
        panic!("expected revoke");
    };
    assert_eq!((target.from_me, target.participant.as_deref()), (false, Some(format!("{BOB_LID}@lid").as_str())));

    // Protocol noise (key shares etc.) never becomes a message.
    let noise = wa::Message {
        protocol_message: MessageField::some(wa::message::ProtocolMessage {
            r#type: Some(wa::message::protocol_message::Type::APP_STATE_SYNC_KEY_SHARE),
            ..Default::default()
        }),
        ..Default::default()
    };
    assert!(matches!(map::map_message(&noise, &env(&bob, &bob, None, false), &canon, &polls), Mapped::Skip));
}

#[test]
fn unknown_content_is_unsupported_with_type_name() {
    let canon = canon();
    let polls = PollCache::default();
    let bob = format!("{BOB_PN}@s.whatsapp.net");
    let m = wa::Message {
        event_message: MessageField::some(Default::default()),
        ..Default::default()
    };
    let Mapped::Message(b) = map::map_message(&m, &env(&bob, &bob, None, false), &canon, &polls) else {
        panic!("expected message");
    };
    assert_eq!(b.kind, MessageKind::Unsupported);
    assert_eq!(b.type_name.as_deref(), Some("event_message"));
}

#[test]
fn clear_and_delete_cutoff_comes_from_the_message_range() {
    use crate::live::range_cutoff;
    let range = wa::sync_action_value::SyncActionMessageRange {
        last_message_timestamp: Some(1_700_000_100),
        last_system_message_timestamp: Some(1_700_000_050),
        messages: vec![wa::sync_action_value::SyncActionMessage {
            key: MessageField::none(),
            timestamp: Some(1_700_000_080),
        }],
    };
    assert_eq!(range_cutoff(Some(&range), 1_800_000_000), 1_700_000_100);
    let ms = wa::sync_action_value::SyncActionMessageRange {
        last_message_timestamp: Some(1_700_000_100_000),
        ..Default::default()
    };
    assert_eq!(range_cutoff(Some(&ms), 1_800_000_000), 1_700_000_100);
    // No range (or an empty one): the action's own time.
    assert_eq!(range_cutoff(None, 1_800_000_000), 1_800_000_000);
    assert_eq!(range_cutoff(Some(&Default::default()), 1_800_000_000), 1_800_000_000);
}

fn reply_quoting(quoted: wa::Message) -> wa::Message {
    wa::Message {
        extended_text_message: MessageField::some(wa::message::ExtendedTextMessage {
            text: Some("reply".into()),
            context_info: MessageField::some(wa::ContextInfo {
                stanza_id: Some("Q1".into()),
                quoted_message: MessageField::some(quoted),
                ..Default::default()
            }),
            ..Default::default()
        }),
        ..Default::default()
    }
}

#[test]
fn quotes_of_business_documents_contacts_and_wrapped_text_get_a_snippet() {
    let canon = canon();
    let polls = PollCache::default();
    let bob = format!("{BOB_PN}@s.whatsapp.net");
    let quote = |q: wa::Message| {
        let Mapped::Message(b) = map::map_message(&reply_quoting(q), &env(&bob, &bob, None, false), &canon, &polls)
        else {
            panic!("expected message")
        };
        let q = b.quoted.unwrap();
        (q.kind, q.snippet)
    };
    let buttons = wa::Message {
        buttons_message: MessageField::some(wa::message::ButtonsMessage {
            content_text: Some("Pick a slot".into()),
            ..Default::default()
        }),
        ..Default::default()
    };
    assert_eq!(quote(buttons), (MessageKind::Text, "Pick a slot".into()));
    let template = wa::Message {
        template_message: MessageField::some(wa::message::TemplateMessage {
            hydrated_template: MessageField::some(wa::message::template_message::HydratedFourRowTemplate {
                hydrated_content_text: Some("Your order shipped".into()),
                ..Default::default()
            }),
            ..Default::default()
        }),
        ..Default::default()
    };
    assert_eq!(quote(template), (MessageKind::Text, "Your order shipped".into()));
    let document = wa::Message {
        document_message: MessageField::some(wa::message::DocumentMessage {
            file_name: Some("invoice.pdf".into()),
            ..Default::default()
        }),
        ..Default::default()
    };
    assert_eq!(quote(document), (MessageKind::Document, "invoice.pdf".into()));
    let contact = wa::Message {
        contact_message: MessageField::some(wa::message::ContactMessage {
            display_name: Some("Carol".into()),
            ..Default::default()
        }),
        ..Default::default()
    };
    assert_eq!(quote(contact), (MessageKind::Contact, "Carol".into()));
    let ephemeral_text = wa::Message {
        ephemeral_message: MessageField::some(wa::message::FutureProofMessage {
            message: MessageField::some(wa::Message {
                extended_text_message: MessageField::some(wa::message::ExtendedTextMessage {
                    text: Some("vanishing".into()),
                    ..Default::default()
                }),
                ..Default::default()
            }),
        }),
        ..Default::default()
    };
    assert_eq!(quote(ephemeral_text), (MessageKind::Text, "vanishing".into()));
}

#[test]
fn mentioned_jids_come_through_for_messages_quotes_and_edits() {
    let canon = canon();
    let polls = PollCache::default();
    let group = "120363000000000001@g.us";
    let bob = format!("{BOB_PN}@s.whatsapp.net");
    let mentioning = |text: &str, jids: &[&str]| wa::Message {
        extended_text_message: MessageField::some(wa::message::ExtendedTextMessage {
            text: Some(text.into()),
            context_info: MessageField::some(wa::ContextInfo {
                mentioned_jid: jids.iter().map(|j| j.to_string()).collect(),
                ..Default::default()
            }),
            ..Default::default()
        }),
        ..Default::default()
    };
    let Mapped::Message(m) = map::map_message(
        &mentioning("@99887766 hi", &["99887766@lid"]),
        &env(group, &bob, Some(&bob), false),
        &canon,
        &polls,
    ) else {
        panic!("expected message")
    };
    assert_eq!(m.mentions, vec!["99887766@lid".to_string()]);

    let Mapped::Message(r) = map::map_message(
        &reply_quoting(mentioning("@15552220000 look", &["15552220000@s.whatsapp.net"])),
        &env(group, &bob, Some(&bob), false),
        &canon,
        &polls,
    ) else {
        panic!("expected message")
    };
    assert!(r.mentions.is_empty());
    assert_eq!(r.quoted.unwrap().mentions, vec!["15552220000@s.whatsapp.net".to_string()]);

    let edit = wa::Message {
        protocol_message: MessageField::some(wa::message::ProtocolMessage {
            r#type: Some(wa::message::protocol_message::Type::MESSAGE_EDIT),
            key: key(group, false, "M1", Some(&bob)),
            edited_message: MessageField::some(mentioning("@99887766 edited", &["99887766@lid"])),
            ..Default::default()
        }),
        ..Default::default()
    };
    let Mapped::Update(BridgeMessageUpdate::Edit { mentions, .. }) =
        map::map_message(&edit, &env(group, &bob, Some(&bob), false), &canon, &polls)
    else {
        panic!("expected edit")
    };
    assert_eq!(mentions, vec!["99887766@lid".to_string()]);
}

#[test]
fn poll_vote_without_a_known_parent_secret_is_parked_and_round_trips() {
    use std::sync::Arc;
    use whatsapp_rust::prelude::{InboundMessage, MessageInfo};
    use whatsapp_rust::wacore::types::message::MessageSource;
    let canon = canon();
    let polls = PollCache::default();
    let bob = format!("{BOB_PN}@s.whatsapp.net");
    let vote = wa::Message {
        poll_update_message: MessageField::some(wa::message::PollUpdateMessage {
            poll_creation_message_key: key(&bob, false, "POLL1", None),
            vote: MessageField::some(wa::message::PollEncValue {
                enc_payload: Some(vec![1, 2, 3]),
                enc_iv: Some(vec![4, 5, 6]),
            }),
            sender_timestamp_ms: Some(1_700_000_000_000),
            ..Default::default()
        }),
        ..Default::default()
    };
    let info = MessageInfo {
        source: MessageSource { chat: bob.parse().unwrap(), sender: bob.parse().unwrap(), ..Default::default() },
        id: "VOTE1".into(),
        timestamp: whatsapp_rust::chrono::DateTime::from_timestamp(1_700_000_000, 0).unwrap(),
        ..Default::default()
    };
    let inbound = InboundMessage::builder().message(Arc::new(vote.clone())).info(Arc::new(info)).build();
    let ctx = crate::live::MapCtx { canon: &canon, polls: &polls, client: None };
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let Some(BridgeEvent::Messages { messages, updates, stanzas }) =
        rt.block_on(crate::live::map_batch(&ctx, std::slice::from_ref(&inbound)))
    else {
        panic!("expected a batch");
    };
    assert!(messages.is_empty());
    // Never stored as a message, so a read-self receipt listing it must still resolve.
    assert_eq!(stanzas, vec![BridgeStanza { chat_jid: bob.clone(), id: "VOTE1".into(), timestamp: 1_700_000_000 }]);
    let [BridgeMessageUpdate::Encrypted { target, envelope }] = updates.as_slice() else {
        panic!("expected a parked vote, got {updates:?}");
    };
    // Bob voted on a poll we created in our DM.
    assert_eq!(target.id, "POLL1");
    assert_eq!(target.chat_jid, bob);
    assert!(target.from_me);
    let back = crate::live::unpark(envelope).unwrap();
    assert_eq!(*back.message, vote);
    assert_eq!(back.info.id.as_str(), "VOTE1");
    assert_eq!(back.info.source.sender.to_string(), bob);
    // Retrying without a client decrypts nothing and never re-parks.
    assert!(rt.block_on(crate::live::decrypt_parked(&ctx, envelope)).is_none());
}

/// `WA_CAPTURE_DIR=… cargo test -- --ignored --nocapture real_capture`
#[test]
#[ignore]
fn real_capture_summary() {
    let dir = std::env::var("WA_CAPTURE_DIR").unwrap_or_else(|_| {
        format!("{}/Library/Application Support/CmdFreak/capture", std::env::var("HOME").unwrap())
    });
    let mut files: Vec<_> = std::fs::read_dir(format!("{dir}/history"))
        .unwrap()
        .filter_map(Result::ok)
        .map(|e| e.path())
        .collect();
    files.sort();
    let canon = canon();
    let polls = PollCache::default();
    let mut kinds = std::collections::BTreeMap::<String, usize>::new();
    let (mut chats, mut messages, mut updates, mut contacts, mut aliases, mut lid_chats) = (0, 0, 0, 0, 0, 0);
    let mut max_chunk_messages = 0;
    for f in files {
        let bytes = std::fs::read(&f).unwrap();
        let input = HistoryInput {
            stream: HistorySyncStream::new(&bytes, MAX_DECOMPRESSED),
            sync_type: HistorySyncType::Other,
            chunk_order: 0,
            progress: None,
        };
        let s = history::process(input, &canon, &polls, &|j| canon.cached(j), &mut |c| {
            max_chunk_messages = max_chunk_messages.max(c.messages.len());
            lid_chats += c.chats.iter().filter(|ch| ch.jid.ends_with("@lid")).count();
            for m in &c.messages {
                *kinds.entry(format!("{:?}", m.kind)).or_default() += 1;
                if matches!(m.kind, MessageKind::Unsupported | MessageKind::System) {
                    *kinds.entry(format!("{:?}:{}", m.kind, m.type_name.as_deref().unwrap_or("-"))).or_default() += 1;
                }
            }
            true
        })
        .unwrap();
        println!("{}: {s:?}", f.file_name().unwrap().to_string_lossy());
        chats += s.chats;
        messages += s.messages;
        updates += s.updates;
        contacts += s.contacts;
        aliases += s.aliases;
    }
    println!("TOTAL chats={chats} messages={messages} updates={updates} contacts={contacts} aliases={aliases} lid_chats={lid_chats} max_chunk_messages={max_chunk_messages}");
    println!("kinds: {kinds:?}");
    assert!(messages > 0);
}

/// Shape of a quoted payload: its populated top-level fields, descending one level into wrappers.
fn quote_shape(v: &serde_json::Value) -> String {
    const TEXT: &[&str] = &[
        "text", "caption", "title", "description", "content_text", "name", "hydrated_content_text",
        "selected_display_text", "file_name", "display_name", "conversation",
    ];
    let Some(obj) = v.as_object() else { return "-".into() };
    let mut parts = Vec::new();
    for (k, v) in obj {
        if v.is_null() || v.as_array().is_some_and(Vec::is_empty) || k == "message_context_info" {
            continue;
        }
        let inner = v.get("message").and_then(|m| m.as_object()).map(|m| {
            m.iter()
                .filter(|(k, v)| !v.is_null() && *k != "message_context_info")
                .map(|(k, _)| k.as_str())
                .collect::<Vec<_>>()
                .join("+")
        });
        let texts = v.as_object().map(|o| {
            o.iter()
                .filter(|(k, v)| TEXT.contains(&k.as_str()) && v.as_str().is_some_and(|s| !s.is_empty()))
                .map(|(k, _)| k.as_str())
                .collect::<Vec<_>>()
                .join(",")
        });
        match (inner, texts) {
            (Some(i), _) => parts.push(format!("{k}{{{i}}}")),
            (None, Some(t)) => parts.push(format!("{k}[{t}]")),
            _ => parts.push(k.clone()),
        }
    }
    parts.join(" ")
}

fn find_quoted(v: &serde_json::Value, out: &mut Vec<(String, serde_json::Value)>) {
    match v {
        serde_json::Value::Object(o) => {
            if let (Some(id), Some(q)) = (o.get("stanza_id").and_then(|s| s.as_str()), o.get("quoted_message"))
                && !q.is_null()
            {
                out.push((id.to_string(), q.clone()));
            }
            o.values().for_each(|v| find_quoted(v, out));
        }
        serde_json::Value::Array(a) => a.iter().for_each(|v| find_quoted(v, out)),
        _ => {}
    }
}

/// Quoted payloads the bridge maps to an empty snippet, grouped by shape.
/// `cargo test -- --ignored --nocapture real_capture_quotes`
#[test]
#[ignore]
fn real_capture_quotes() {
    let dir = std::env::var("WA_CAPTURE_DIR").unwrap_or_else(|_| {
        format!("{}/Library/Application Support/CmdFreak/capture", std::env::var("HOME").unwrap())
    });
    let mut files: Vec<_> = std::fs::read_dir(format!("{dir}/history"))
        .unwrap()
        .filter_map(Result::ok)
        .map(|e| e.path())
        .collect();
    files.sort();
    let canon = canon();
    let polls = PollCache::default();
    let (mut quotes, mut empty) = (0usize, 0usize);
    let mut shapes = std::collections::BTreeMap::<String, usize>::new();
    let mut kinds = std::collections::BTreeMap::<String, usize>::new();
    for f in files {
        let bytes = std::fs::read(&f).unwrap();
        let mut stream = HistorySyncStream::new(&bytes, MAX_DECOMPRESSED);
        let mut conv = wa::Conversation::default();
        loop {
            conv.clear();
            if !stream.next_conversation_into(&mut conv).unwrap() {
                break;
            }
            let Some(chat) = crate::canon::parse(&conv.id) else { continue };
            for hm in &conv.messages {
                let Some(wmi) = hm.message.as_option() else { continue };
                let Some(msg) = wmi.message.as_option() else { continue };
                let (mut ms, mut us) = (Vec::new(), Vec::new());
                map::map_web_message(wmi, &chat, &|j| canon.cached(j), &canon, &polls, &mut ms, &mut us);
                let Some(q) = ms.first().and_then(|m| m.quoted.clone()) else { continue };
                quotes += 1;
                let tag = if q.snippet.is_empty() { ":empty" } else { "" };
                *kinds.entry(format!("{:?}{tag}", q.kind)).or_default() += 1;
                if !q.snippet.is_empty() {
                    continue;
                }
                empty += 1;
                let json = serde_json::to_value(msg).unwrap();
                let mut found = Vec::new();
                find_quoted(&json, &mut found);
                let shape = found
                    .iter()
                    .find(|(id, _)| *id == q.id)
                    .map(|(_, v)| quote_shape(v))
                    .unwrap_or_else(|| "<none>".into());
                *shapes.entry(format!("{:?} {shape}", q.kind)).or_default() += 1;
            }
        }
    }
    println!("QUOTES total={quotes} empty_snippet={empty}");
    println!("kinds: {kinds:?}");
    let mut v: Vec<_> = shapes.into_iter().collect();
    v.sort_by_key(|e| std::cmp::Reverse(e.1));
    for (s, n) in v {
        println!("{n:6}  {s}");
    }
}

#[test]
fn group_create_and_own_add_are_joins() {
    use whatsapp_rust::NodeBuilder;
    use whatsapp_rust::wacore::stanza::groups::{GroupNotificationAction, GroupParticipantInfo};
    use whatsapp_rust::wacore::types::events::{Event, GroupUpdate};
    let canon = canon();
    let polls = PollCache::default();
    let ctx = crate::live::MapCtx { canon: &canon, polls: &polls, client: None };
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let member = |jid: Jid| GroupParticipantInfo {
        jid,
        phone_number: None,
        display_name: None,
        r#type: None,
        lid: None,
        username: None,
        join_time: None,
        group_history_sent_state: None,
    };
    let joined = |action: GroupNotificationAction| {
        let update = GroupUpdate::builder()
            .group_jid("120363000000000077@g.us".parse().unwrap())
            .timestamp(whatsapp_rust::chrono::DateTime::from_timestamp(1_700_000_500, 0).unwrap())
            .is_lid_addressing_mode(true)
            .action(Box::new(action))
            .build();
        let out = rt.block_on(crate::live::map_event(&ctx, &Event::GroupUpdate(update)));
        let [BridgeEvent::Group { group }] = out.as_slice() else { panic!("{out:?}") };
        assert!(group.membership_changed);
        group.joined_at
    };
    assert_eq!(joined(GroupNotificationAction::Create { raw: NodeBuilder::new("create").build() }), Some(1_700_000_500));
    let community = NodeBuilder::new("create")
        .children([NodeBuilder::new("group").children([NodeBuilder::new("parent").build()]).build()])
        .build();
    assert_eq!(joined(GroupNotificationAction::Create { raw: community }), None);
    let add = |who: Jid| GroupNotificationAction::Add { participants: vec![member(who)], reason: None };
    assert_eq!(joined(add(Jid::lid(ME_LID))), Some(1_700_000_500));
    assert_eq!(joined(add(Jid::lid("99999999999999"))), None);
}

mod ack_waiters {
    use std::time::Duration;

    use crate::acks::{AckClass, AckWaiters};
    use crate::types::BridgeError;

    const WAIT: Duration = Duration::from_secs(5);

    #[tokio::test]
    async fn ack_resolves_the_waiter_for_its_class_and_id() {
        let acks = AckWaiters::default();
        let pending = acks.expect(AckClass::Receipt, "R1", acks.epoch());
        // Another class with the same id, or another id, leaves it waiting.
        acks.resolve(AckClass::Message, "R1", None);
        acks.resolve(AckClass::Receipt, "R2", None);
        let waiter = tokio::spawn(pending.wait(WAIT));
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(!waiter.is_finished());
        acks.resolve(AckClass::Receipt, "R1", None);
        assert!(waiter.await.unwrap().is_ok());
    }

    #[tokio::test]
    async fn an_ack_that_beats_the_waiter_still_counts() {
        let acks = AckWaiters::default();
        let epoch = acks.epoch();
        acks.resolve(AckClass::Message, "M1", None);
        assert!(acks.expect(AckClass::Message, "M1", epoch).wait(WAIT).await.is_ok());
    }

    #[tokio::test]
    async fn no_ack_times_out() {
        let acks = AckWaiters::default();
        let result = acks.expect(AckClass::Message, "M1", acks.epoch()).wait(Duration::from_millis(30)).await;
        assert!(matches!(result, Err(BridgeError::Timeout(id)) if id == "M1"));
    }

    #[tokio::test]
    async fn a_nack_errors() {
        let acks = AckWaiters::default();
        let pending = acks.expect(AckClass::Message, "M1", acks.epoch());
        acks.resolve(AckClass::Message, "M1", Some("479".into()));
        let result = pending.wait(WAIT).await;
        assert!(matches!(result, Err(BridgeError::Protocol(msg)) if msg.contains("479")));
    }

    #[tokio::test]
    async fn a_delivery_receipts_ack_does_not_confirm_a_read_receipt_under_the_same_id() {
        let acks = AckWaiters::default();
        acks.delivery_receipts_owed(["X", "Y"]);
        // The delivery receipt for X is still unacked when the read receipt starting with X goes.
        let pending = acks.expect(AckClass::Receipt, "X", acks.epoch());
        acks.resolve(AckClass::Receipt, "X", None);
        let waiter = tokio::spawn(pending.wait(WAIT));
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(!waiter.is_finished());
        acks.resolve(AckClass::Receipt, "X", None);
        assert!(waiter.await.unwrap().is_ok());

        // A nack under such an id fails the read receipt rather than passing for the delivery ack.
        acks.delivery_receipts_owed(["Z"]);
        let pending = acks.expect(AckClass::Receipt, "Z", acks.epoch());
        acks.resolve(AckClass::Receipt, "Z", Some("400".into()));
        assert!(matches!(pending.wait(WAIT).await, Err(BridgeError::Protocol(_))));

        // Y's delivery ack came first: nobody waits for it, and it is not kept for a later read receipt.
        acks.resolve(AckClass::Receipt, "Y", None);
        let result = acks.expect(AckClass::Receipt, "Y", acks.epoch()).wait(Duration::from_millis(30)).await;
        assert!(matches!(result, Err(BridgeError::Timeout(_))));
    }

    #[tokio::test]
    async fn a_dropped_connection_fails_waits_in_flight_and_sends_from_before_it() {
        let acks = AckWaiters::default();
        let epoch = acks.epoch();
        let pending = acks.expect(AckClass::Receipt, "R1", epoch);
        acks.fail_all();
        assert!(matches!(pending.wait(WAIT).await, Err(BridgeError::NotConnected)));
        // Sent before the drop, registered after it: no ack will come.
        assert!(matches!(acks.expect(AckClass::Message, "M1", epoch).wait(WAIT).await, Err(BridgeError::NotConnected)));
        // Sent after it: waits as usual.
        let pending = acks.expect(AckClass::Message, "M2", acks.epoch());
        acks.resolve(AckClass::Message, "M2", None);
        assert!(pending.wait(WAIT).await.is_ok());
    }
}

#[test]
fn mentions_switch_to_their_lid_in_the_text() {
    use crate::bridge::replace_mentions;
    use std::collections::HashMap;
    let renamed = HashMap::from([("15551110000".to_string(), "99887766".to_string())]);
    assert_eq!(replace_mentions("@15551110000 hi @155511100001 @15551110000", &renamed),
               "@99887766 hi @155511100001 @99887766");
    assert_eq!(replace_mentions("no mention, a@ @", &renamed), "no mention, a@ @");
    // A new number that is also an old one is renamed once.
    let swapped = HashMap::from([("15551110000".to_string(), "919876543210".to_string()),
                                 ("919876543210".to_string(), "99887766".to_string())]);
    assert_eq!(replace_mentions("@15551110000 @919876543210", &swapped), "@919876543210 @99887766");
}
