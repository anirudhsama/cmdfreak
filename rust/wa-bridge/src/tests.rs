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

    let dm = wa::Conversation {
        id: bob_chat.clone(),
        pn_jid: Some(format!("{BOB_PN}@s.whatsapp.net")),
        unread_count: Some(2),
        conversation_timestamp: Some(1_700_000_400),
        messages: vec![
            wmi(key(&bob_chat, false, "M1", None), 1_700_000_100, Some(text("hello"))),
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
            BridgeMessageUpdate::Edit { target, text, edited_at } => Some((target, text, edited_at)),
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

/// `WA_CAPTURE_DIR=… cargo test -- --ignored --nocapture real_capture`
#[test]
#[ignore]
fn real_capture_summary() {
    let dir = std::env::var("WA_CAPTURE_DIR").unwrap_or_else(|_| {
        format!("{}/Library/Application Support/BetterWA/capture", std::env::var("HOME").unwrap())
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
