//! `WaBridge`: the object Swift holds. Owns the tokio runtime and the whatsapp-rust client.
//!
//! Event flow: the library's event bus calls [`BusHandler::handle_event`] inline, which only pushes
//! onto an unbounded channel. One pipeline task drains it in order, maps each event (async: LID
//! lookups, add-on decryption) and coalesces the results, flushing to the `EventSink` every ~16 ms
//! or 200 events. History-sync payloads are handed to a worker that decodes them on a blocking
//! thread and feeds chunks back into the same pipeline, one chunk in flight at a time.
//!
//! Inbound user messages take the durability-hook path: the hook maps its batch, pushes it through
//! the pipeline and returns only after the sink has received it, so the library acks to the server
//! only once Swift has the message. The `Event::Messages` that follows carries
//! `hook_committed == true` and is skipped to avoid delivering it twice.

use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, RwLock, Weak};
use std::time::Duration;

use tokio::sync::{mpsc, oneshot};
use whatsapp_rust::{InboundDurabilityHook, RevokeType};
use whatsapp_rust::Jid;
use whatsapp_rust::pair_code::PairCodeOptions;
use whatsapp_rust::prelude::*;

use crate::canon::Canon;
use crate::history::{self, HistoryInput};
use crate::live::{self, MapCtx};
use crate::map::PollCache;
use crate::types::*;

type R<T> = Result<T, BridgeError>;

const FLUSH_INTERVAL: Duration = Duration::from_millis(16);
const FLUSH_EVENTS: usize = 200;
/// The raw bus handler never drops, so this only bounds the library's own closure mailbox
/// (unused by the bridge) should one ever be registered.
const ORDERED_CAPACITY: usize = 8192;

pub(crate) enum Input {
    Lib(Arc<Event>),
    /// Already-mapped events (hook batches, history chunks, import). `done` fires after the sink
    /// has received the flush containing them.
    Ready(Vec<BridgeEvent>, Option<oneshot::Sender<()>>),
}

#[derive(Default)]
pub(crate) struct Counters {
    received: AtomicU64,
    dropped: AtomicU64,
    flushed: AtomicU64,
}

pub(crate) struct Shared {
    pub data_dir: String,
    pub sink: Arc<dyn EventSink>,
    pub canon: Canon,
    pub polls: PollCache,
    pub counters: Counters,
    pub tx: mpsc::UnboundedSender<Input>,
    history_tx: mpsc::UnboundedSender<Arc<Event>>,
    client: RwLock<Option<Arc<Client>>>,
    bot: tokio::sync::Mutex<Option<BotHandle>>,
}

impl Shared {
    pub fn client(&self) -> Option<Arc<Client>> {
        self.client.read().unwrap().clone()
    }

    fn require_client(&self) -> R<Arc<Client>> {
        self.client().ok_or(BridgeError::NotConnected)
    }

    /// Pushes mapped events and waits (async) until the sink has received them.
    pub async fn emit_and_wait(&self, events: Vec<BridgeEvent>) -> bool {
        let (done, rx) = oneshot::channel();
        if self.tx.send(Input::Ready(events, Some(done))).is_err() {
            return false;
        }
        rx.await.is_ok()
    }

    /// Blocking-thread variant of [`Shared::emit_and_wait`].
    pub fn emit_blocking(&self, events: Vec<BridgeEvent>) -> bool {
        let (done, rx) = oneshot::channel();
        if self.tx.send(Input::Ready(events, Some(done))).is_err() {
            return false;
        }
        rx.blocking_recv().is_ok()
    }

    fn emit(&self, events: Vec<BridgeEvent>) {
        let _ = self.tx.send(Input::Ready(events, None));
    }

    fn map_ctx(&self) -> (Option<Arc<Client>>, &Canon, &PollCache) {
        (self.client(), &self.canon, &self.polls)
    }
}

// MARK: - Pipeline

async fn pipeline(weak: Weak<Shared>, mut rx: mpsc::UnboundedReceiver<Input>) {
    let mut buf: Vec<BridgeEvent> = Vec::new();
    let mut waiters: Vec<oneshot::Sender<()>> = Vec::new();
    let mut deadline = tokio::time::Instant::now();

    let flush = |shared: &Shared, buf: &mut Vec<BridgeEvent>, waiters: &mut Vec<oneshot::Sender<()>>| {
        if !buf.is_empty() {
            shared.sink.on_events(std::mem::take(buf));
            shared.counters.flushed.fetch_add(1, Ordering::Relaxed);
        }
        for w in waiters.drain(..) {
            let _ = w.send(());
        }
    };

    loop {
        let next = if buf.is_empty() && waiters.is_empty() {
            rx.recv().await
        } else {
            match tokio::time::timeout_at(deadline, rx.recv()).await {
                Ok(item) => item,
                Err(_) => {
                    let Some(shared) = weak.upgrade() else { return };
                    flush(&shared, &mut buf, &mut waiters);
                    continue;
                }
            }
        };
        let Some(shared) = weak.upgrade() else { return };
        let Some(input) = next else {
            flush(&shared, &mut buf, &mut waiters);
            return;
        };
        let was_empty = buf.is_empty() && waiters.is_empty();
        match input {
            Input::Lib(event) => {
                if matches!(&*event, Event::HistorySync(_)) {
                    let _ = shared.history_tx.send(event);
                } else {
                    let (client, canon, polls) = shared.map_ctx();
                    let ctx = MapCtx { canon, polls, client: client.as_ref() };
                    buf.extend(live::map_event(&ctx, &event).await);
                }
            }
            Input::Ready(events, done) => {
                buf.extend(events);
                waiters.extend(done);
            }
        }
        if was_empty {
            deadline = tokio::time::Instant::now() + FLUSH_INTERVAL;
        }
        // A waiter is a durability-hook batch (the library's receive loop is blocked on it) or a
        // history chunk (one in flight by design): hand it over now rather than on the timer.
        if buf.len() >= FLUSH_EVENTS || !waiters.is_empty() {
            flush(&shared, &mut buf, &mut waiters);
        }
    }
}

async fn history_worker(weak: Weak<Shared>, mut rx: mpsc::UnboundedReceiver<Arc<Event>>) {
    while let Some(event) = rx.recv().await {
        let Some(shared) = weak.upgrade() else { return };
        let rt = tokio::runtime::Handle::current();
        let result = tokio::task::spawn_blocking(move || {
            let Event::HistorySync(h) = &*event else { return Ok(Default::default()) };
            let input = HistoryInput {
                stream: h.stream(),
                sync_type: history::sync_type(h.sync_type()),
                chunk_order: h.chunk_order().unwrap_or(0),
                progress: h.progress(),
            };
            log::info!(
                "history sync: type {:?} chunk {:?} ({} bytes inflated)",
                input.sync_type,
                h.chunk_order(),
                h.decompressed_size()
            );
            let client = shared.client();
            let resolve = |j: &Jid| shared.canon.resolve_blocking(client.as_deref(), &rt, j);
            history::process(input, &shared.canon, &shared.polls, &resolve, &mut |chunk| {
                shared.emit_blocking(vec![BridgeEvent::HistoryChunk { chunk }])
            })
        })
        .await;
        match result {
            Ok(Ok(s)) => log::info!(
                "history sync done: {} chats, {} messages, {} updates, {} contacts, {} aliases",
                s.chats,
                s.messages,
                s.updates,
                s.contacts,
                s.aliases
            ),
            Ok(Err(e)) => log::warn!("history sync failed: {e}"),
            Err(e) => log::error!("history sync task panicked: {e}"),
        }
    }
}

// MARK: - Library hooks

struct BusHandler {
    shared: Weak<Shared>,
}

impl EventHandler for BusHandler {
    fn handle_event(&self, event: Arc<Event>) {
        let Some(shared) = self.shared.upgrade() else { return };
        if let Event::Messages(batch) = &*event
            && batch.hook_committed
        {
            return;
        }
        shared.counters.received.fetch_add(1, Ordering::Relaxed);
        if shared.tx.send(Input::Lib(event)).is_err() {
            shared.counters.dropped.fetch_add(1, Ordering::Relaxed);
        }
    }

    fn interest(&self) -> EventInterest {
        EventInterest::of(live::INTEREST)
    }
}

struct DurabilityHook {
    shared: Weak<Shared>,
}

#[whatsapp_rust::async_trait]
impl InboundDurabilityHook for DurabilityHook {
    async fn on_messages(&self, client: Arc<Client>, batch: &[InboundMessage]) -> anyhow::Result<()> {
        let shared = self.shared.upgrade().ok_or_else(|| anyhow::anyhow!("bridge dropped"))?;
        shared.counters.received.fetch_add(1, Ordering::Relaxed);
        let ctx = MapCtx { canon: &shared.canon, polls: &shared.polls, client: Some(&client) };
        let (messages, updates) = live::map_batch(&ctx, batch).await;
        let mut events = Vec::new();
        live::push_aliases(&shared.canon, &mut events);
        if !messages.is_empty() || !updates.is_empty() {
            events.push(BridgeEvent::Messages { messages, updates });
        }
        if events.is_empty() || shared.emit_and_wait(events).await {
            Ok(())
        } else {
            anyhow::bail!("event sink closed; leaving messages unacked for redelivery")
        }
    }
}

// MARK: - WaBridge

#[derive(uniffi::Object)]
pub struct WaBridge {
    runtime: Option<tokio::runtime::Runtime>,
    rt: tokio::runtime::Handle,
    shared: Arc<Shared>,
}

impl Drop for WaBridge {
    /// Call `disconnect()` first for a graceful flush; dropping only stops the runtime.
    fn drop(&mut self) {
        if let Some(rt) = self.runtime.take() {
            rt.shutdown_background();
        }
    }
}

impl WaBridge {
    /// Runs `fut` on the owned runtime; awaitable from any executor (Swift's included).
    async fn run<T: Send + 'static>(
        &self,
        fut: impl Future<Output = R<T>> + Send + 'static,
    ) -> R<T> {
        self.rt
            .spawn(fut)
            .await
            .map_err(|e| BridgeError::Other(format!("bridge task failed: {e}")))?
    }

    fn session_path(&self) -> std::path::PathBuf {
        std::path::Path::new(&self.shared.data_dir).join("wa-session.sqlite")
    }
}

fn parse_jid(s: &str) -> R<Jid> {
    s.parse::<Jid>().map_err(|_| BridgeError::InvalidJid(s.to_string()))
}

fn net<E: std::fmt::Display>(e: E) -> BridgeError {
    BridgeError::Network(e.to_string())
}

async fn connect_inner(shared: Arc<Shared>, session: std::path::PathBuf) -> R<()> {
    let mut guard = shared.bot.lock().await;
    if guard.is_some() {
        return Ok(());
    }
    shared.emit(vec![BridgeEvent::Connection { state: BridgeConnection::Connecting }]);
    if let Some(parent) = session.parent() {
        std::fs::create_dir_all(parent).map_err(|e| BridgeError::Io(e.to_string()))?;
    }
    let path = session.to_str().ok_or_else(|| BridgeError::Io("non-UTF-8 data dir".into()))?;
    let store = SqliteStore::new(path).await.map_err(|e| BridgeError::Store(e.to_string()))?;
    let bot = Bot::builder()
        .with_backend(store)
        .with_event_delivery(EventDelivery::Ordered { capacity: ORDERED_CAPACITY })
        .with_event_handler(BusHandler { shared: Arc::downgrade(&shared) })
        .with_inbound_durability_hook(DurabilityHook { shared: Arc::downgrade(&shared) })
        .build()
        .await
        .map_err(|e| BridgeError::Store(e.to_string()))?;
    let client = bot.client();
    shared.canon.set_own(client.pn(), client.lid());
    *shared.client.write().unwrap() = Some(client);
    // The library supervises and reconnects with its own backoff; this is the only spawn.
    *guard = Some(bot.spawn());
    Ok(())
}

#[uniffi::export]
impl WaBridge {
    /// `data_dir` holds `wa-session.sqlite`. Events are delivered in ordered batches to `sink`.
    #[uniffi::constructor]
    pub fn new(data_dir: String, sink: Arc<dyn EventSink>) -> R<Arc<Self>> {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("wa-bridge")
            .build()
            .map_err(|e| BridgeError::Other(format!("runtime: {e}")))?;
        let (tx, rx) = mpsc::unbounded_channel();
        let (history_tx, history_rx) = mpsc::unbounded_channel();
        let shared = Arc::new(Shared {
            data_dir,
            sink,
            canon: Canon::default(),
            polls: PollCache::default(),
            counters: Counters::default(),
            tx,
            history_tx,
            client: RwLock::new(None),
            bot: tokio::sync::Mutex::new(None),
        });
        rt.spawn(pipeline(Arc::downgrade(&shared), rx));
        rt.spawn(history_worker(Arc::downgrade(&shared), history_rx));
        Ok(Arc::new(Self { rt: rt.handle().clone(), runtime: Some(rt), shared }))
    }

    pub fn data_dir(&self) -> String {
        self.shared.data_dir.clone()
    }

    /// `events_dropped` is the library's ordered-mailbox drop count plus any event the bridge could
    /// not enqueue; it must stay 0.
    pub fn stats(&self) -> BridgeStats {
        let c = &self.shared.counters;
        let lib_dropped = self.shared.client().map_or(0, |cl| cl.stats().events_dropped);
        BridgeStats {
            events_received: c.received.load(Ordering::Relaxed),
            events_dropped: c.dropped.load(Ordering::Relaxed) + lib_dropped,
            batches_flushed: c.flushed.load(Ordering::Relaxed),
        }
    }

    // Session

    /// Opens the session store and starts the client (`Bot::spawn`, once). Idempotent. An unpaired
    /// store starts emitting `Pairing::Qr` events.
    pub async fn connect(&self) -> R<()> {
        let shared = self.shared.clone();
        let session = self.session_path();
        self.run(connect_inner(shared, session)).await
    }

    /// Graceful stop (flushes library state). `connect()` may be called again afterwards.
    pub async fn disconnect(&self) -> R<()> {
        let shared = self.shared.clone();
        self.run(async move {
            let handle = shared.bot.lock().await.take();
            if let Some(h) = handle {
                h.shutdown().await;
            }
            *shared.client.write().unwrap() = None;
            Ok(())
        })
        .await
    }

    /// Unlinks this device. Irreversible: a new link needs the phone.
    pub async fn logout(&self) -> R<()> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            client.logout().await;
            Ok(())
        })
        .await
    }

    /// Drops the transport so the library's own supervision loop redials at once (e.g. after
    /// wake). No backoff of our own; `reconnect_immediately` skips the library's deliberate
    /// offline window that plain `reconnect` adds.
    pub fn nudge_reconnect(&self) {
        if let Some(client) = self.shared.client() {
            self.rt.spawn(async move { client.reconnect_immediately().await });
        }
    }

    /// QR pairing: connects; QR codes then arrive as `Pairing::Qr` events and rotate on their own.
    pub async fn start_pairing_qr(&self) -> R<()> {
        self.connect().await
    }

    /// Phone-number pairing; returns the 8-character code (also emitted as `Pairing::PairCode`).
    pub async fn pair_with_phone(&self, number: String) -> R<String> {
        self.connect().await?;
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            client.wait_for_socket(Duration::from_secs(30)).await.map_err(net)?;
            let digits: String = number.chars().filter(char::is_ascii_digit).collect();
            client
                .pair_with_code(PairCodeOptions { phone_number: digits, ..Default::default() })
                .await
                .map_err(|e| BridgeError::Protocol(e.to_string()))
        })
        .await
    }

    pub async fn cancel_pairing(&self) -> R<()> {
        let logged_in = self.shared.client().is_some_and(|c| c.is_logged_in());
        if let Some(client) = self.shared.client() {
            self.run(async move {
                client.cancel_pair_code().await;
                Ok(())
            })
            .await?;
        }
        if !logged_in {
            self.disconnect().await?;
        }
        Ok(())
    }

    // Sending

    pub async fn send_text(
        &self,
        chat: String,
        text: String,
        reply_to: Option<BridgeMessageKey>,
    ) -> R<BridgeSendResult> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            let to = parse_jid(&chat)?;
            let msg = match &reply_to {
                Some(key) => wa::Message::text_with_context(text.clone(), quote_context(&shared, key)),
                None => wa::Message::text(text.clone()),
            };
            let sent = client.send_message(to.clone(), msg).await.map_err(net)?;
            Ok(sent_result(&shared, &to, sent.message_id, MessageKind::Text, Some(text), None, reply_to))
        })
        .await
    }

    pub async fn send_media(
        &self,
        chat: String,
        media: BridgeOutgoingMedia,
        reply_to: Option<BridgeMessageKey>,
        progress: Option<Arc<dyn ProgressSink>>,
    ) -> R<BridgeSendResult> {
        let shared = self.shared.clone();
        self.run(async move { crate::media::send_media(shared, chat, media, reply_to, progress).await })
            .await
    }

    /// Empty `emoji` removes our reaction.
    pub async fn send_reaction(&self, target: BridgeMessageKey, emoji: String) -> R<()> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            let chat = parse_jid(&target.chat_jid)?;
            client.send_reaction(chat, wire_key(&target), &emoji).await.map_err(net)?;
            Ok(())
        })
        .await
    }

    pub async fn edit_message(&self, target: BridgeMessageKey, text: String) -> R<()> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            let chat = parse_jid(&target.chat_jid)?;
            client.edit_message(chat, target.id.clone(), wa::Message::text(text)).await.map_err(net)?;
            Ok(())
        })
        .await
    }

    /// Our own message → sender revoke; someone else's (group admin) → admin revoke.
    pub async fn revoke_message(&self, target: BridgeMessageKey) -> R<()> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            let chat = parse_jid(&target.chat_jid)?;
            let kind = if target.from_me {
                RevokeType::Sender
            } else {
                let sender = target
                    .participant
                    .as_deref()
                    .ok_or_else(|| BridgeError::InvalidJid("admin revoke needs participant".into()))?;
                RevokeType::Admin { original_sender: parse_jid(sender)? }
            };
            client.revoke_message(chat, target.id.clone(), kind).await.map_err(net)?;
            Ok(())
        })
        .await
    }

    // Receipts, presence

    /// Sends read receipts, one per sender (groups need the sender as the receipt participant).
    pub async fn mark_read(&self, chat: String, messages: Vec<BridgeMessageKey>) -> R<()> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            let chat = parse_jid(&chat)?;
            let mut groups: Vec<(Option<String>, Vec<String>)> = Vec::new();
            for m in messages.into_iter().filter(|m| !m.from_me) {
                match groups.iter_mut().find(|(p, _)| *p == m.participant) {
                    Some((_, ids)) => ids.push(m.id),
                    None => groups.push((m.participant, vec![m.id])),
                }
            }
            for (participant, ids) in groups {
                let sender = participant.as_deref().map(parse_jid).transpose()?;
                let refs: Vec<&str> = ids.iter().map(String::as_str).collect();
                client.mark_as_read(&chat, sender.as_ref(), &refs).await.map_err(net)?;
            }
            Ok(())
        })
        .await
    }

    pub async fn send_chat_state(&self, chat: String, state: ChatState) -> R<()> {
        use whatsapp_rust::features::ChatStateType;
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            let to = parse_jid(&chat)?;
            let state = match state {
                ChatState::Composing => ChatStateType::Composing,
                ChatState::Recording => ChatStateType::Recording,
                ChatState::Paused => ChatStateType::Paused,
            };
            client.chatstate().send(&to, state).await.map_err(net)?;
            Ok(())
        })
        .await
    }

    pub async fn subscribe_presence(&self, jid: String) -> R<()> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            client.presence().subscribe(parse_jid(&jid)?).await.map_err(net)?;
            Ok(())
        })
        .await
    }

    // Groups, contacts

    /// Batched subject + participant count. Groups we can't see are omitted.
    pub async fn fetch_group_overviews(&self, jids: Vec<String>) -> R<Vec<BridgeGroup>> {
        use whatsapp_rust::features::GroupOverviewResult;
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            let parsed: Vec<Jid> = jids.iter().map(|s| parse_jid(s)).collect::<R<_>>()?;
            let mut out = Vec::new();
            let limit = whatsapp_rust::wacore::iq::groups::BATCH_GROUP_INFO_LIMIT.max(1);
            for batch in parsed.chunks(limit) {
                for r in client.groups().fetch_overviews(batch).await.map_err(net)? {
                    match r {
                        GroupOverviewResult::Found(o) => out.push(BridgeGroup {
                            jid: o.id.to_string(),
                            subject: o.subject,
                            participant_count: o.participant_count.unwrap_or(0),
                            participants: vec![],
                        }),
                        GroupOverviewResult::Truncated { id, participant_count } => {
                            out.push(BridgeGroup {
                                jid: id.to_string(),
                                subject: None,
                                participant_count,
                                participants: vec![],
                            })
                        }
                        _ => {}
                    }
                }
            }
            Ok(out)
        })
        .await
    }

    pub async fn fetch_group_metadata(&self, jid: String) -> R<BridgeGroup> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            let md = client.groups().fetch_metadata(&parse_jid(&jid)?).await.map_err(net)?;
            let participants: Vec<BridgeGroupParticipant> = md
                .participants
                .iter()
                .map(|p| {
                    if let Some(pn) = &p.phone_number {
                        shared.canon.learn_pair(&p.jid, pn);
                    }
                    if let Some(lid) = &p.lid {
                        shared.canon.learn_pair(&p.jid, lid);
                    }
                    BridgeGroupParticipant {
                        jid: shared.canon.cached_str(&p.jid),
                        is_admin: p.is_admin(),
                        is_super_admin: p.is_super_admin(),
                    }
                })
                .collect();
            let aliases = shared.canon.take_pending();
            if !aliases.is_empty() {
                shared.emit(vec![BridgeEvent::JidAliases { aliases }]);
            }
            Ok(BridgeGroup {
                jid: md.id.to_string(),
                subject: md.subject,
                participant_count: participants.len() as u32,
                participants,
            })
        })
        .await
    }

    /// Downloads the picture to `dest_path`; returns false when the user has none.
    pub async fn profile_picture(&self, jid: String, preview: bool, dest_path: String) -> R<bool> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            let target = parse_jid(&jid)?;
            let Some(pic) =
                client.contacts().get_profile_picture(&target, preview).await.map_err(net)?
            else {
                return Ok(false);
            };
            crate::media::fetch_url_to(&pic.url, &dest_path).await?;
            Ok(true)
        })
        .await
    }

    // Media

    /// Streams, decrypts and verifies into `dest_path` (written via `<dest>.part`, then renamed).
    pub async fn download_media(
        &self,
        media: BridgeMedia,
        dest_path: String,
        progress: Option<Arc<dyn ProgressSink>>,
    ) -> R<()> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            crate::media::download(client, media, dest_path, progress).await
        })
        .await
    }

    // Development: replays a wa-link capture (`history/*.zlib` + `events.jsonl`) through the same
    // mapping and sink as live traffic, without connecting. Lets the app DB be built without re-pairing.
    pub async fn import_capture(&self, capture_dir: String) -> R<()> {
        let shared = self.shared.clone();
        self.run(async move {
            tokio::task::spawn_blocking(move || crate::import::import_capture(&shared, &capture_dir))
                .await
                .map_err(|e| BridgeError::Other(e.to_string()))?
        })
        .await
    }

    // Chat actions (synced to other devices via app state)

    pub async fn pin_chat(&self, chat: String, pinned: bool) -> R<()> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            let j = parse_jid(&chat)?;
            let actions = client.chat_actions();
            if pinned { actions.pin_chat(&j).await } else { actions.unpin_chat(&j).await }
                .map_err(net)
        })
        .await
    }

    pub async fn archive_chat(&self, chat: String, archived: bool) -> R<()> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            let j = parse_jid(&chat)?;
            let actions = client.chat_actions();
            if archived {
                actions.archive_chat(&j, None).await
            } else {
                actions.unarchive_chat(&j, None).await
            }
            .map_err(net)
        })
        .await
    }

    /// `None` unmutes; `Some(i64::MAX)` mutes forever; otherwise unix seconds.
    pub async fn mute_chat(&self, chat: String, until: Option<i64>) -> R<()> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            let j = parse_jid(&chat)?;
            let actions = client.chat_actions();
            match until {
                None => actions.unmute_chat(&j).await,
                Some(i64::MAX) => actions.mute_chat(&j).await,
                Some(secs) => actions.mute_chat_until(&j, secs.saturating_mul(1000)).await,
            }
            .map_err(net)
        })
        .await
    }

    pub async fn mark_chat_read(&self, chat: String, read: bool) -> R<()> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            client.chat_actions().mark_chat_as_read(&parse_jid(&chat)?, read, None).await.map_err(net)
        })
        .await
    }
}

/// Rebuilds the wire key from our-frame fields.
fn wire_key(k: &BridgeMessageKey) -> wa::MessageKey {
    wa::MessageKey {
        remote_jid: Some(k.chat_jid.clone()),
        from_me: Some(k.from_me),
        id: Some(k.id.clone()),
        participant: k.participant.clone(),
    }
}

/// Quote context for a reply. Only the key is known here, so the quoted body is left empty; the
/// phone resolves the quote by id when it has the message.
fn quote_context(shared: &Shared, key: &BridgeMessageKey) -> wa::ContextInfo {
    let participant = if key.from_me {
        shared.canon.own_pn().map(|j| j.to_string())
    } else {
        key.participant.clone().or_else(|| Some(key.chat_jid.clone()))
    };
    wa::ContextInfo {
        stanza_id: Some(key.id.clone()),
        participant,
        quoted_message: MessageField::some(wa::Message {
            conversation: Some(String::new()),
            ..Default::default()
        }),
        ..Default::default()
    }
}

pub(crate) fn sent_result(
    shared: &Shared,
    to: &Jid,
    message_id: String,
    kind: MessageKind,
    text: Option<String>,
    media: Option<BridgeMedia>,
    reply_to: Option<BridgeMessageKey>,
) -> BridgeSendResult {
    let now = whatsapp_rust::wacore::time::now_secs();
    let chat = shared.canon.cached(to);
    let own = shared.canon.own_pn().map(|j| j.to_string()).unwrap_or_default();
    BridgeSendResult {
        message_id: message_id.clone(),
        timestamp: now,
        message: BridgeMessage {
            id: message_id,
            chat_jid: chat.to_string(),
            sender_jid: own,
            participant: None,
            from_me: true,
            timestamp: now,
            kind,
            text,
            quoted: reply_to.map(|k| BridgeQuoted {
                id: k.id,
                sender_jid: k.participant,
                kind: MessageKind::Unsupported,
                snippet: String::new(),
            }),
            media,
            location: None,
            contact: None,
            poll: None,
            reactions: vec![],
            type_name: None,
            push_name: None,
            status: Some(MessageStatus::Sent),
            is_forwarded: false,
            revoked: false,
            edited_at: None,
        },
    }
}

pub(crate) fn quote_ctx_for(shared: &Shared, key: &BridgeMessageKey) -> wa::ContextInfo {
    quote_context(shared, key)
}

pub(crate) fn require_client(shared: &Shared) -> R<Arc<Client>> {
    shared.require_client()
}

/// Remuxes an Ogg/Opus voice note into CAF so Core Audio can play it.
#[uniffi::export]
pub fn remux_ogg_to_caf(src: String, dst: String) -> R<()> {
    let stats = crate::remux::remux_file(std::path::Path::new(&src), std::path::Path::new(&dst))?;
    log::debug!("remuxed {src}: {stats:?}");
    Ok(())
}

/// Routes the `log` facade and `tracing` output to `sink`. Call once, before `WaBridge::new`.
/// Release builds never go below `Info`.
#[uniffi::export]
pub fn install_logger(sink: Arc<dyn LogSink>, max_level: LogLevel) {
    crate::logging::install(sink, max_level);
}
