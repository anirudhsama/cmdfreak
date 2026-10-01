//! Waits for the server's `<ack>` of a stanza we sent. The library's send calls return once the
//! stanza is written to the socket, and a connection that dies right after loses it silently; calls
//! that must land wait here for the ack carrying the stanza's id. `BusHandler` resolves waiters from
//! the event bus as acks arrive and fails them all when the connection drops.
//!
//! A `<receipt>` is acked under its first message id, and the library's delivery receipt for an
//! incoming message is acked under that message's id: the same id a read receipt starting with it
//! is acked under, and the ack event doesn't say which receipt it was for. So the bridge records
//! the incoming messages a delivery receipt is owed for, and the first receipt ack under such an
//! id counts as the delivery receipt's. When that guess is wrong (the library sent the delivery
//! receipt later, or folded it into another id's), a read receipt goes unconfirmed and is sent
//! again; it is never confirmed by another receipt's ack.

use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use tokio::sync::oneshot;

use crate::types::BridgeError;

/// How long a sent stanza may go without its ack before the call fails.
pub const ACK_TIMEOUT: Duration = Duration::from_secs(30);
/// An ack can beat the send call that learns the stanza's id; one nobody waits for is kept this long.
const EARLY_TTL: Duration = Duration::from_secs(60);
const EARLY_MAX: usize = 4096;
/// A delivery receipt is acked within a round trip of the message's commit; past this its ack is
/// not coming.
const DELIVERY_TTL: Duration = Duration::from_secs(60);
const DELIVERY_MAX: usize = 8192;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AckClass {
    Message,
    Receipt,
}

impl AckClass {
    pub fn parse(class: Option<&str>) -> Option<Self> {
        match class {
            Some("message") => Some(Self::Message),
            Some("receipt") => Some(Self::Receipt),
            _ => None,
        }
    }
}

type Key = (AckClass, String);
type Outcome = Result<(), BridgeError>;

#[derive(Default)]
pub struct AckWaiters {
    state: Mutex<State>,
    /// Bumped per dropped connection: a stanza sent before a drop gets no ack after it.
    epoch: AtomicU64,
    /// Between connecting and the end of the offline drain, when the library aggregates delivery
    /// receipts.
    draining: AtomicBool,
}

#[derive(Default)]
struct State {
    waiting: HashMap<Key, Vec<oneshot::Sender<Outcome>>>,
    /// Message acks (with their nack code) that arrived before anyone waited for them. Receipt
    /// waiters register before sending, so a receipt ack nobody waits for is someone else's.
    early: HashMap<Key, (Instant, Option<String>)>,
    /// Incoming message ids whose delivery receipt's ack is still to come.
    delivery: HashMap<String, Instant>,
}

/// One registered wait; [`Pending::wait`] resolves it.
pub struct Pending {
    id: String,
    rx: oneshot::Receiver<Outcome>,
}

fn outcome(id: &str, error: Option<String>) -> Outcome {
    match error {
        None => Ok(()),
        Some(code) => Err(BridgeError::Protocol(format!("server rejected {id}: {code}"))),
    }
}

/// The connection went before the ack came: it may or may not have landed. `NotConnected`, so
/// callers can tell it from a failure on a live connection.
fn dropped() -> BridgeError {
    BridgeError::NotConnected
}

impl AckWaiters {
    /// Take before sending; pass to [`AckWaiters::expect`] once the stanza id is known.
    pub fn epoch(&self) -> u64 {
        self.epoch.load(Ordering::SeqCst)
    }

    /// Waits for the ack of stanza `id`, sent at `epoch`. Register before sending when the id is
    /// known up front; an ack that already arrived resolves it at once.
    pub fn expect(&self, class: AckClass, id: &str, epoch: u64) -> Pending {
        let (tx, rx) = oneshot::channel();
        let key = (class, id.to_string());
        let mut s = self.state.lock().unwrap();
        if let Some((at, error)) = s.early.remove(&key)
            && at.elapsed() < EARLY_TTL
        {
            let _ = tx.send(outcome(id, error));
        } else if epoch != self.epoch() {
            let _ = tx.send(Err(dropped()));
        } else {
            // Waits that timed out are dropped here, so a never-acked id doesn't pile up.
            s.waiting.retain(|_, ws| {
                ws.retain(|w| !w.is_closed());
                !ws.is_empty()
            });
            s.waiting.entry(key).or_default().push(tx);
        }
        Pending { id: id.to_string(), rx }
    }

    pub fn set_draining(&self, draining: bool) {
        self.draining.store(draining, Ordering::SeqCst);
    }

    pub fn draining(&self) -> bool {
        self.draining.load(Ordering::SeqCst)
    }

    /// The library owes the server a delivery receipt for these incoming messages, acked under
    /// these ids.
    pub fn delivery_receipts_owed<'a>(&self, ids: impl IntoIterator<Item = &'a str>) {
        let now = Instant::now();
        let mut s = self.state.lock().unwrap();
        if s.delivery.len() >= DELIVERY_MAX {
            s.delivery.retain(|_, at| now.duration_since(*at) < DELIVERY_TTL);
            if s.delivery.len() >= DELIVERY_MAX {
                s.delivery.clear();
            }
        }
        for id in ids {
            s.delivery.insert(id.to_string(), now);
        }
    }

    /// The server acked (`error == None`) or nacked stanza `id`.
    pub fn resolve(&self, class: AckClass, id: &str, error: Option<String>) {
        let key = (class, id.to_string());
        let mut s = self.state.lock().unwrap();
        // Only a plain ack is taken for the delivery receipt's: a nack fails a read receipt waiting
        // under the id (at worst it goes again), never confirming one by mistake later.
        if class == AckClass::Receipt
            && error.is_none()
            && s.delivery.remove(id).is_some_and(|at| at.elapsed() < DELIVERY_TTL)
        {
            return;
        }
        if let Some(waiters) = s.waiting.remove(&key) {
            for w in waiters {
                let _ = w.send(outcome(id, error.clone()));
            }
            return;
        }
        if class != AckClass::Message {
            return;
        }
        let now = Instant::now();
        if s.early.len() >= EARLY_MAX {
            s.early.retain(|_, (at, _)| now.duration_since(*at) < EARLY_TTL);
            if s.early.len() >= EARLY_MAX {
                s.early.clear();
            }
        }
        s.early.insert(key, (now, error));
    }

    /// The connection dropped or was replaced: nothing in flight will be acked.
    pub fn fail_all(&self) {
        self.epoch.fetch_add(1, Ordering::SeqCst);
        let waiting = {
            let mut s = self.state.lock().unwrap();
            s.delivery.clear();
            std::mem::take(&mut s.waiting)
        };
        for w in waiting.into_values().flatten() {
            let _ = w.send(Err(dropped()));
        }
    }
}

impl Pending {
    pub async fn wait(self, timeout: Duration) -> Outcome {
        match tokio::time::timeout(timeout, self.rx).await {
            Ok(Ok(outcome)) => outcome,
            Ok(Err(_)) => Err(dropped()),
            Err(_) => Err(BridgeError::Timeout(self.id)),
        }
    }
}
