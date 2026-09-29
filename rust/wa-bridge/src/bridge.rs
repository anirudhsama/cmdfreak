//! `WaBridge`: the object Swift holds. Owns the tokio runtime and the whatsapp-rust client.
//!
//! Event flow: the library's event bus calls [`BusHandler::handle_event`] inline, which only pushes
//! onto an unbounded channel. One pipeline task drains it in order, maps each event (async: LID
//! lookups, add-on decryption) and coalesces the results, flushing to the `EventSink` every ~16 ms
//! or 200 events. History-sync payloads are handed to a worker that decodes them on a blocking
//! thread and feeds chunks back into the same pipeline, one chunk in flight at a time.
//!
//! `EventSink::on_events` runs on a dedicated `wa-bridge-sink` OS thread, never on a tokio worker:
//! Swift's sink blocks until its database transaction for the batch has committed. A waiter (hook
//! batch, history chunk) fires only after `on_events` has returned, i.e. after the commit.
//!
//! Inbound user messages take the durability-hook path: the hook maps its batch, pushes it through
//! the pipeline and returns only after the sink has persisted it, so the library acks to the server
//! only once Swift has committed the message. The `Event::Messages` that follows carries
//! `hook_committed == true` and is skipped to avoid delivering it twice. When the sink reports a
//! failed save the hook returns `Err`: the library then neither acks nor dispatches
//! `Event::Messages` for the batch (it returns before dispatch), and the server redelivers it on
//! the next connect. History chunks use the same wait, so exactly one chunk is in flight against
//! Swift's commit.

use std::collections::HashMap;
use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock, Weak};
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
    /// has returned from the flush containing them, with the sink's result.
    Ready(Vec<BridgeEvent>, Option<oneshot::Sender<bool>>),
}

#[derive(Default)]
pub(crate) struct Counters {
    received: AtomicU64,
    dropped: AtomicU64,
    flushed: AtomicU64,
}

pub(crate) struct Shared {
    pub data_dir: String,
    pub canon: Canon,
    pub polls: PollCache,
    pub counters: Counters,
    pub tx: mpsc::UnboundedSender<Input>,
    history_tx: mpsc::UnboundedSender<Arc<Event>>,
    client: RwLock<Option<Arc<Client>>>,
    bot: tokio::sync::Mutex<Option<BotHandle>>,
    /// Bumped per client built and per reset; a `LoggedOut` from an older client never resets a
    /// newer one.
    generation: AtomicU64,
    rt: tokio::runtime::Handle,
}

impl Shared {
    pub fn client(&self) -> Option<Arc<Client>> {
        self.client.read().unwrap().clone()
    }

    fn require_client(&self) -> R<Arc<Client>> {
        self.client().ok_or(BridgeError::NotConnected)
    }

    /// Pushes mapped events and waits (async) until the sink has handled them. `Some(persisted)`
    /// is the sink's result; `None` means the sink is gone.
    pub async fn emit_and_wait(&self, events: Vec<BridgeEvent>) -> Option<bool> {
        let (done, rx) = oneshot::channel();
        if self.tx.send(Input::Ready(events, Some(done))).is_err() {
            return None;
        }
        rx.await.ok()
    }

    /// Blocking-thread variant of [`Shared::emit_and_wait`] for history chunks. Returns whether
    /// to go on: a chunk the app failed to save is logged and skipped; only a gone sink stops.
    pub fn emit_blocking(&self, events: Vec<BridgeEvent>) -> bool {
        let (done, rx) = oneshot::channel();
        if self.tx.send(Input::Ready(events, Some(done))).is_err() {
            return false;
        }
        match rx.blocking_recv() {
            Ok(true) => true,
            Ok(false) => {
                log::error!("history chunk not persisted by the app; continuing with the next");
                true
            }
            Err(_) => false,
        }
    }

    fn emit(&self, events: Vec<BridgeEvent>) {
        let _ = self.tx.send(Input::Ready(events, None));
    }

    fn map_ctx(&self) -> (Option<Arc<Client>>, &Canon, &PollCache) {
        (self.client(), &self.canon, &self.polls)
    }
}

// MARK: - Pipeline

type SinkJob = (Vec<BridgeEvent>, Vec<oneshot::Sender<bool>>);

/// Calls the sink in order on its own thread (the sink may block until Swift has committed), then
/// releases the batch's waiters. Exits when the pipeline drops its sender.
fn spawn_sink_thread(sink: Arc<dyn EventSink>) -> std::io::Result<std::sync::mpsc::Sender<SinkJob>> {
    let (tx, rx) = std::sync::mpsc::channel::<SinkJob>();
    std::thread::Builder::new().name("wa-bridge-sink".into()).spawn(move || {
        for (events, waiters) in rx {
            let ok = events.is_empty() || sink.on_events(events);
            for w in waiters {
                let _ = w.send(ok);
            }
        }
    })?;
    Ok(tx)
}

async fn pipeline(
    weak: Weak<Shared>,
    mut rx: mpsc::UnboundedReceiver<Input>,
    sink_tx: std::sync::mpsc::Sender<SinkJob>,
) {
    let mut buf: Vec<BridgeEvent> = Vec::new();
    let mut waiters: Vec<oneshot::Sender<bool>> = Vec::new();
    let mut deadline = tokio::time::Instant::now();

    // Never blocks: hands the batch to the sink thread. A dead sink thread drops the waiters, which
    // the durability hook reports as a failure (messages stay unacked).
    let flush = |shared: &Shared, buf: &mut Vec<BridgeEvent>, waiters: &mut Vec<oneshot::Sender<bool>>| {
        if buf.is_empty() && waiters.is_empty() {
            return;
        }
        if !buf.is_empty() {
            shared.counters.flushed.fetch_add(1, Ordering::Relaxed);
        }
        let _ = sink_tx.send((std::mem::take(buf), std::mem::take(waiters)));
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
                // A waiter's batch is one sink call (one Swift transaction) of its own: events
                // already buffered go first, so a failure in them is never charged to the hook's
                // messages (which would count towards giving up on them).
                if done.is_some() && !buf.is_empty() {
                    flush(&shared, &mut buf, &mut waiters);
                }
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
    /// `Shared::generation` of the client this handler was built for.
    generation: u64,
}

impl EventHandler for BusHandler {
    fn handle_event(&self, event: Arc<Event>) {
        let Some(shared) = self.shared.upgrade() else { return };
        if let Event::Messages(batch) = &*event
            && batch.hook_committed
        {
            return;
        }
        if matches!(&*event, Event::LoggedOut(_)) {
            spawn_logout_reset(&shared, self.generation);
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

/// Unlinked (from the phone, or our own `logout()`): the session is dead, so do the same full reset
/// `logout()` does and let a later connect start unpaired. The event itself still reaches Swift,
/// which forgets its own identity.
fn spawn_logout_reset(shared: &Arc<Shared>, generation: u64) {
    let weak = Arc::downgrade(shared);
    shared.rt.spawn(async move {
        let Some(shared) = weak.upgrade() else { return };
        let session = session_path(&shared.data_dir);
        match reset_session(&shared, &session, Some(generation)).await {
            Ok(()) => log::info!("logged out; session store reset"),
            Err(e) => log::error!("session reset after logout failed: {e}"),
        }
    });
}

/// Failed saves a message gets before the hook gives up and acks it anyway (logged). The library
/// redelivers an unacked batch on the next connect; a batch the app can never save would otherwise
/// come back forever.
const MAX_HOOK_ATTEMPTS: u32 = 3;

type HookKey = (String, String, String);

struct DurabilityHook {
    shared: Weak<Shared>,
    /// Failed save attempts per `(chat, sender, id)` (this process only).
    failures: Mutex<HashMap<HookKey, u32>>,
}

impl DurabilityHook {
    fn new(shared: Weak<Shared>) -> Self {
        Self { shared, failures: Mutex::new(HashMap::new()) }
    }

    /// Hands the mapped batch to the sink and turns its answer into the hook's: `Ok` acks, `Err`
    /// leaves the batch unacked for redelivery, until every message in it has failed
    /// `MAX_HOOK_ATTEMPTS` times.
    async fn commit(&self, shared: &Shared, keys: Vec<HookKey>, events: Vec<BridgeEvent>) -> anyhow::Result<()> {
        if events.is_empty() {
            return Ok(());
        }
        match shared.emit_and_wait(events).await {
            None => anyhow::bail!("event sink closed; leaving messages unacked for redelivery"),
            Some(true) => {
                let mut failures = self.failures.lock().unwrap();
                if !failures.is_empty() {
                    keys.iter().for_each(|k| _ = failures.remove(k));
                }
                Ok(())
            }
            Some(false) => {
                let mut failures = self.failures.lock().unwrap();
                if failures.len() > 10_000 {
                    failures.clear();
                }
                let mut exhausted = true;
                for k in &keys {
                    let n = failures.entry(k.clone()).or_default();
                    *n += 1;
                    exhausted &= *n >= MAX_HOOK_ATTEMPTS;
                }
                if exhausted {
                    keys.iter().for_each(|k| _ = failures.remove(k));
                    log::error!(
                        "app failed to save {} inbound message(s) {MAX_HOOK_ATTEMPTS} times; acking them anyway",
                        keys.len()
                    );
                    Ok(())
                } else {
                    anyhow::bail!("app failed to save the batch; leaving it unacked for redelivery")
                }
            }
        }
    }
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
        let keys = batch
            .iter()
            .map(|m| (m.info.source.chat.to_string(), m.info.source.sender.to_string(), m.info.id.to_string()))
            .collect();
        self.commit(&shared, keys, events).await
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
        session_path(&self.shared.data_dir)
    }
}

fn session_path(data_dir: &str) -> std::path::PathBuf {
    std::path::Path::new(data_dir).join("wa-session.sqlite")
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
    let generation = shared.generation.fetch_add(1, Ordering::SeqCst) + 1;
    let builder = Bot::builder()
        .with_backend(store)
        .with_event_delivery(EventDelivery::Ordered { capacity: ORDERED_CAPACITY })
        .with_event_handler(BusHandler { shared: Arc::downgrade(&shared), generation })
        .with_inbound_durability_hook(DurabilityHook::new(Arc::downgrade(&shared)));
    #[cfg(test)]
    let builder = builder
        .with_transport_factory(sink_tests::NoNetwork)
        .with_http_client(sink_tests::NoNetwork)
        .with_version((2, 3000, 1));
    let bot = builder.build().await.map_err(|e| BridgeError::Store(e.to_string()))?;
    let client = bot.client();
    shared.canon.set_own(client.pn(), client.lid());
    *shared.client.write().unwrap() = Some(client);
    // The library supervises and reconnects with its own backoff; this is the only spawn.
    *guard = Some(bot.spawn());
    Ok(())
}

/// Stops the bot, forgets the client and our identity, and removes the session store files.
/// With `only_generation`, does nothing unless that client is still the current one.
///
/// Holds the bot lock throughout: a `connect()` arriving meanwhile (e.g. "Link again" right after
/// the phone unlinked us) waits and then builds a fresh client and store, instead of having them
/// torn down and unlinked under it.
async fn reset_session(shared: &Shared, session: &std::path::Path, only_generation: Option<u64>) -> R<()> {
    let mut guard = shared.bot.lock().await;
    if only_generation.is_some_and(|g| g != shared.generation.load(Ordering::SeqCst)) {
        return Ok(());
    }
    // This client is finished; a later connect() builds the next generation.
    shared.generation.fetch_add(1, Ordering::SeqCst);
    if let Some(h) = guard.take() {
        h.shutdown().await;
        // Widens the shutdown window so the race test reliably lands a connect() inside it.
        #[cfg(test)]
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    *shared.client.write().unwrap() = None;
    shared.canon.set_own(None, None);
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let mut p = session.as_os_str().to_owned();
        p.push(suffix);
        match std::fs::remove_file(&p) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(BridgeError::Io(e.to_string())),
        }
    }
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
        let sink_tx = spawn_sink_thread(sink)
            .map_err(|e| BridgeError::Other(format!("sink thread: {e}")))?;
        let shared = Arc::new(Shared {
            data_dir,
            canon: Canon::default(),
            polls: PollCache::default(),
            counters: Counters::default(),
            tx,
            history_tx,
            client: RwLock::new(None),
            bot: tokio::sync::Mutex::new(None),
            generation: AtomicU64::new(0),
            rt: rt.handle().clone(),
        });
        rt.spawn(pipeline(Arc::downgrade(&shared), rx, sink_tx));
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

    /// Unlinks this device. Irreversible: a new link needs the phone. Tears the client down and
    /// deletes the session store, so a later `connect()`/`start_pairing_qr()` builds a fresh,
    /// unpaired client that emits QR codes.
    pub async fn logout(&self) -> R<()> {
        let shared = self.shared.clone();
        let session = self.session_path();
        self.run(async move {
            let client = shared.require_client()?;
            client.logout().await;
            drop(client);
            reset_session(&shared, &session, None).await
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
            let mut result = sent_result(&shared, &to, sent.message_id, MessageKind::Text, Some(text), None, reply_to);
            result.message.participant = own_participant(&shared, &client, &to).await;
            Ok(result)
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
                            membership_changed: false,
                        }),
                        GroupOverviewResult::Truncated { id, participant_count } => {
                            out.push(BridgeGroup {
                                jid: id.to_string(),
                                subject: None,
                                participant_count,
                                participants: vec![],
                                membership_changed: false,
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
                membership_changed: false,
            })
        })
        .await
    }

    /// Batched usync business lookup for PN or LID user JIDs. Users the server did not answer
    /// for (or answered with a business error) are omitted.
    pub async fn check_business(&self, jids: Vec<String>) -> R<Vec<BridgeBusinessCheck>> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            let parsed: Vec<Jid> = jids.iter().map(|s| parse_jid(s)).collect::<R<_>>()?;
            let asked: HashMap<String, &String> =
                parsed.iter().map(|j| j.to_non_ad_string()).zip(&jids).collect();
            let results = client.contacts().is_on_whatsapp(&parsed).await.map_err(net)?;
            Ok(results
                .into_iter()
                .filter(|r| r.business_error.is_none())
                .filter_map(|r| {
                    // The server may answer a PN query LID-primary (or the reverse).
                    let jid = [Some(&r.jid), r.pn_jid.as_ref(), r.lid.as_ref()]
                        .into_iter()
                        .flatten()
                        .find_map(|j| asked.get(&j.to_non_ad_string()))?;
                    let verified_name = r
                        .verified_name
                        .as_ref()
                        .and_then(|v| v.name.clone())
                        .filter(|n| !n.is_empty());
                    Some(BridgeBusinessCheck {
                        jid: (*jid).clone(),
                        is_business: r.is_business,
                        verified_name,
                    })
                })
                .collect())
        })
        .await
    }

    /// Downloads the picture to `dest_path`; returns false when the user has none or hides it.
    /// `common_gid` is a group shared with the user; the server answers with it when we hold no
    /// privacy token for them (people known only from groups).
    pub async fn profile_picture(
        &self,
        jid: String,
        common_gid: Option<String>,
        preview: bool,
        dest_path: String,
    ) -> R<bool> {
        let shared = self.shared.clone();
        self.run(async move {
            let client = shared.require_client()?;
            let target = parse_jid(&jid)?;
            let group = common_gid.as_deref().map(parse_jid).transpose()?;
            let options = whatsapp_rust::ProfilePictureLookupOptions::new(&target)
                .preview(preview)
                .common_gid(group.as_ref());
            let contacts = client.contacts();
            let pic = match contacts.lookup_profile_picture_with_options(options).await.map_err(net)? {
                whatsapp_rust::ProfilePictureLookup::Found(pic) => pic,
                whatsapp_rust::ProfilePictureLookup::RateOverlimit => {
                    return Err(BridgeError::Network("profile picture rate-overlimit".into()));
                }
                _ => return Ok(false),
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

    /// Retries `BridgeMessageUpdate::Encrypted` envelopes once their target is stored. One entry
    /// per envelope, in order: the decrypted `Edit`/`PollVote`, or `None` (still no secret, not
    /// connected, or undecryptable).
    pub async fn decrypt_parked(&self, envelopes: Vec<Vec<u8>>) -> Vec<Option<BridgeMessageUpdate>> {
        let shared = self.shared.clone();
        let count = envelopes.len();
        self.run(async move {
            let client = shared.client();
            let ctx = MapCtx { canon: &shared.canon, polls: &shared.polls, client: client.as_ref() };
            let mut out = Vec::with_capacity(envelopes.len());
            for e in &envelopes {
                out.push(live::decrypt_parked(&ctx, e).await);
            }
            let aliases = shared.canon.take_pending();
            if !aliases.is_empty() {
                shared.emit(vec![BridgeEvent::JidAliases { aliases }]);
            }
            Ok(out)
        })
        .await
        .unwrap_or_else(|_| vec![None; count])
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

/// Our own JID as the key `participant` of a message we sent to `chat`: `None` outside groups; in a
/// group, the LID when the group is LID-addressed (as the server and our other devices key it),
/// else the phone-number JID. The routing info is cached by the send that just ran.
pub(crate) async fn own_participant(shared: &Shared, client: &Client, chat: &Jid) -> Option<String> {
    use whatsapp_rust::wacore::types::message::AddressingMode;
    use whatsapp_rust::wacore_binary::JidExt;
    if !chat.is_group() {
        return None;
    }
    // Unknown addressing: leave it unset rather than guess (the app then fills it from the
    // group's other messages).
    let lid_addressed = match client.groups().routing_info(chat).await {
        Ok(info) => info.addressing_mode == AddressingMode::Lid,
        Err(e) => {
            log::warn!("group addressing mode unknown for own participant: {e}");
            return None;
        }
    };
    own_participant_for(shared, lid_addressed).or_else(|| {
        let own = if lid_addressed { client.lid() } else { client.pn() };
        own.map(|j| j.to_non_ad().to_string())
    })
}

pub(crate) fn own_participant_for(shared: &Shared, lid_addressed: bool) -> Option<String> {
    let own = if lid_addressed { shared.canon.own_lid() } else { shared.canon.own_pn() };
    own.map(|j| j.to_non_ad().to_string())
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
            verified_name: None,
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

#[cfg(test)]
mod sink_tests {
    use super::*;
    use std::sync::Mutex;
    use std::sync::atomic::AtomicBool;

    /// Stands in for Swift: blocks like the real sink does until its commit.
    struct SlowSink {
        committed: AtomicBool,
        batches: Mutex<Vec<usize>>,
    }

    impl EventSink for SlowSink {
        fn on_events(&self, events: Vec<BridgeEvent>) -> bool {
            std::thread::sleep(Duration::from_millis(80));
            self.batches.lock().unwrap().push(events.len());
            self.committed.store(true, Ordering::SeqCst);
            true
        }
    }

    /// Transport and HTTP stand-ins for bots built in tests: every dial and request fails, so
    /// nothing ever reaches the network.
    pub(crate) struct NoNetwork;

    #[whatsapp_rust::async_trait]
    impl whatsapp_rust::transport::TransportFactory for NoNetwork {
        async fn create_transport(
            &self,
        ) -> Result<
            (
                Arc<dyn whatsapp_rust::transport::Transport>,
                whatsapp_rust::async_channel::Receiver<whatsapp_rust::transport::TransportEvent>,
            ),
            anyhow::Error,
        > {
            anyhow::bail!("no network in tests")
        }
    }

    #[whatsapp_rust::async_trait]
    impl whatsapp_rust::http::HttpClient for NoNetwork {
        async fn execute(
            &self,
            _request: whatsapp_rust::http::HttpRequest,
        ) -> anyhow::Result<whatsapp_rust::http::HttpResponse> {
            anyhow::bail!("no network in tests")
        }
    }

    /// Stands in for a Swift sink whose ingest transaction fails.
    struct FailingSink(AtomicBool);

    impl EventSink for FailingSink {
        fn on_events(&self, _events: Vec<BridgeEvent>) -> bool {
            !self.0.load(Ordering::SeqCst)
        }
    }

    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("wa-bridge-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn waiters_release_only_after_sink_returns_and_off_the_runtime() {
        let sink = Arc::new(SlowSink { committed: AtomicBool::new(false), batches: Mutex::new(vec![]) });
        let dir = temp_dir("sink");
        let bridge = WaBridge::new(dir.to_string_lossy().into(), sink.clone()).unwrap();
        let shared = bridge.shared.clone();
        let ok = bridge.rt.block_on(async move {
            // A blocked sink must not stall the runtime: this timer still fires meanwhile.
            let ticker = tokio::spawn(async { tokio::time::sleep(Duration::from_millis(10)).await });
            let ok = shared
                .emit_and_wait(vec![BridgeEvent::OfflineSyncCompleted { count: 1 }])
                .await;
            ticker.await.unwrap();
            ok
        });
        assert_eq!(ok, Some(true));
        assert!(sink.committed.load(Ordering::SeqCst), "hook resolved before the sink returned");
        assert_eq!(*sink.batches.lock().unwrap(), vec![1]);
    }

    #[test]
    fn reset_session_tears_down_and_removes_store() {
        let sink = Arc::new(SlowSink { committed: AtomicBool::new(false), batches: Mutex::new(vec![]) });
        let dir = temp_dir("reset");
        let bridge = WaBridge::new(dir.to_string_lossy().into(), sink).unwrap();
        let session = bridge.session_path();
        for suffix in ["", "-wal", "-shm"] {
            std::fs::write(format!("{}{suffix}", session.display()), b"x").unwrap();
        }
        bridge.shared.canon.set_own(
            Some("15550000000@s.whatsapp.net".parse().unwrap()),
            Some("123@lid".parse().unwrap()),
        );
        let shared = bridge.shared.clone();
        bridge.rt.block_on(async move { reset_session(&shared, &session, None).await }).unwrap();
        for suffix in ["", "-wal", "-shm"] {
            assert!(!std::path::Path::new(&format!("{}{suffix}", bridge.session_path().display())).exists());
        }
        assert!(bridge.shared.client().is_none());
        assert!(bridge.rt.block_on(bridge.shared.bot.lock()).is_none());
        assert!(bridge.shared.canon.own_pn().is_none());
    }

    fn write_session(bridge: &WaBridge) {
        for suffix in ["", "-wal"] {
            std::fs::write(format!("{}{suffix}", bridge.session_path().display()), b"x").unwrap();
        }
    }

    fn logged_out() -> Arc<Event> {
        use whatsapp_rust::types::events::{ConnectFailureReason, LoggedOut};
        Arc::new(Event::LoggedOut(Box::new(
            LoggedOut::builder().on_connect(false).reason(ConnectFailureReason::LoggedOut).build(),
        )))
    }

    #[test]
    fn server_logout_resets_the_session_like_logout() {
        let sink = Arc::new(SlowSink { committed: AtomicBool::new(false), batches: Mutex::new(vec![]) });
        let dir = temp_dir("server-logout");
        let bridge = WaBridge::new(dir.to_string_lossy().into(), sink).unwrap();
        bridge.shared.canon.set_own(Some("15550000000@s.whatsapp.net".parse().unwrap()), None);

        // A LoggedOut from a client that is no longer current changes nothing.
        bridge.shared.generation.store(2, Ordering::SeqCst);
        write_session(&bridge);
        BusHandler { shared: Arc::downgrade(&bridge.shared), generation: 1 }.handle_event(logged_out());
        std::thread::sleep(Duration::from_millis(200));
        assert!(bridge.session_path().exists());
        assert!(bridge.shared.canon.own_pn().is_some());

        BusHandler { shared: Arc::downgrade(&bridge.shared), generation: 2 }.handle_event(logged_out());
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while bridge.session_path().exists() && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(!bridge.session_path().exists());
        assert!(!std::path::Path::new(&format!("{}-wal", bridge.session_path().display())).exists());
        assert!(bridge.shared.canon.own_pn().is_none());
        assert!(bridge.shared.client().is_none());
    }

    #[test]
    fn reset_with_a_running_bot_does_not_tear_down_a_connect_that_follows_it() {
        let sink = Arc::new(SlowSink { committed: AtomicBool::new(false), batches: Mutex::new(vec![]) });
        let dir = temp_dir("reset-race");
        let bridge = WaBridge::new(dir.to_string_lossy().into(), sink).unwrap();
        let session = bridge.session_path();
        let shared = bridge.shared.clone();
        bridge.rt.block_on(async move {
            connect_inner(shared.clone(), session.clone()).await.unwrap();
            assert!(shared.bot.lock().await.is_some());
            let first = shared.generation.load(Ordering::SeqCst);
            // The server logs us out; the user relinks at once while the old bot shuts down.
            let reset = tokio::spawn({
                let (shared, session) = (shared.clone(), session.clone());
                async move { reset_session(&shared, &session, Some(first)).await }
            });
            tokio::time::sleep(Duration::from_millis(10)).await;
            connect_inner(shared.clone(), session.clone()).await.unwrap();
            reset.await.unwrap().unwrap();
            // The new client, its store and the bot survive the old reset.
            assert!(shared.client().is_some());
            assert!(shared.bot.lock().await.is_some());
            assert!(session.exists());
            assert!(shared.generation.load(Ordering::SeqCst) > first);
            // A late LoggedOut from the old client changes nothing.
            reset_session(&shared, &session, Some(first)).await.unwrap();
            assert!(shared.client().is_some() && session.exists());
            // The current one resets fully.
            let current = shared.generation.load(Ordering::SeqCst);
            reset_session(&shared, &session, Some(current)).await.unwrap();
            assert!(shared.client().is_none() && shared.bot.lock().await.is_none() && !session.exists());
        });
    }

    /// Records batches; fails any batch that contains `OfflineSyncCompleted { count: 666 }`.
    struct PickySink(Mutex<Vec<usize>>);

    impl EventSink for PickySink {
        fn on_events(&self, events: Vec<BridgeEvent>) -> bool {
            self.0.lock().unwrap().push(events.len());
            !events.iter().any(|e| matches!(e, BridgeEvent::OfflineSyncCompleted { count: 666 }))
        }
    }

    #[test]
    fn a_hook_batch_is_its_own_sink_call() {
        let sink = Arc::new(PickySink(Mutex::new(vec![])));
        let bridge = WaBridge::new(temp_dir("hook-alone").to_string_lossy().into(), sink.clone()).unwrap();
        let shared = bridge.shared.clone();
        let ok = bridge.rt.block_on(async move {
            // A buffered non-hook event the app fails on, then a hook batch right behind it.
            shared.emit(vec![BridgeEvent::OfflineSyncCompleted { count: 666 }]);
            shared.emit_and_wait(vec![BridgeEvent::OfflineSyncCompleted { count: 1 }]).await
        });
        assert_eq!(ok, Some(true));
        assert_eq!(*sink.0.lock().unwrap(), vec![1, 1]);
    }

    #[test]
    fn own_group_participant_follows_the_addressing_mode() {
        let sink = Arc::new(SlowSink { committed: AtomicBool::new(false), batches: Mutex::new(vec![]) });
        let bridge = WaBridge::new(temp_dir("own-participant").to_string_lossy().into(), sink).unwrap();
        bridge.shared.canon.set_own(
            Some("15550000000:3@s.whatsapp.net".parse().unwrap()),
            Some("123:3@lid".parse().unwrap()),
        );
        assert_eq!(own_participant_for(&bridge.shared, true).as_deref(), Some("123@lid"));
        assert_eq!(own_participant_for(&bridge.shared, false).as_deref(), Some("15550000000@s.whatsapp.net"));
    }

    #[test]
    fn hook_fails_while_the_app_cannot_save_then_gives_up() {
        let sink = Arc::new(FailingSink(AtomicBool::new(true)));
        let dir = temp_dir("hook-fail");
        let bridge = WaBridge::new(dir.to_string_lossy().into(), sink.clone()).unwrap();
        let hook = DurabilityHook::new(Arc::downgrade(&bridge.shared));
        let shared = bridge.shared.clone();
        let key = |id: &str| ("c@s.whatsapp.net".to_string(), "s@s.whatsapp.net".to_string(), id.to_string());
        let events = || vec![BridgeEvent::OfflineSyncCompleted { count: 1 }];
        bridge.rt.block_on(async {
            // Failing sink: unacked (Err) until the bound, then acked with an error log.
            for _ in 1..MAX_HOOK_ATTEMPTS {
                assert!(hook.commit(&shared, vec![key("A")], events()).await.is_err());
            }
            assert!(hook.commit(&shared, vec![key("A")], events()).await.is_ok());
            // A fresh message batched with it resets nothing: its own count starts over.
            assert!(hook.commit(&shared, vec![key("A"), key("B")], events()).await.is_err());
            // Once the app saves again, the batch is acked and its counts are forgotten.
            sink.0.store(false, Ordering::SeqCst);
            assert!(hook.commit(&shared, vec![key("A"), key("B")], events()).await.is_ok());
            assert!(hook.failures.lock().unwrap().is_empty());
        });
    }
}
