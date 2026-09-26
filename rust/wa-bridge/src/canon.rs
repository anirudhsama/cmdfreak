//! LID → phone-number canonicalisation with a bridge-side cache.
//!
//! Every JID crossing the FFI is device-stripped and, when a LID↔PN mapping is known, rewritten to
//! its `@s.whatsapp.net` form. Mappings come from message envelopes (`sender_alt`/`recipient_alt`),
//! history-sync remainders, contact actions, and (on a miss) `Client::get_lid_pn_entry`. Each newly
//! learned mapping is queued once as a `BridgeJidAlias` so Swift can merge chats split across both.

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, RwLock};

use whatsapp_rust::Jid;
use whatsapp_rust::prelude::Client;

use crate::types::BridgeJidAlias;

#[derive(Default)]
pub struct Canon {
    lid_to_pn: RwLock<HashMap<String, String>>,
    pn_to_lid: RwLock<HashMap<String, String>>,
    /// LID users the library had no mapping for; not re-queried until something teaches us one.
    misses: RwLock<HashSet<String>>,
    pending: Mutex<Vec<BridgeJidAlias>>,
    own: RwLock<(Option<Jid>, Option<Jid>)>,
}

impl Canon {
    pub fn set_own(&self, pn: Option<Jid>, lid: Option<Jid>) {
        if let (Some(p), Some(l)) = (&pn, &lid) {
            self.learn(&l.user, &p.user);
        }
        *self.own.write().unwrap() = (pn.map(|j| j.to_non_ad()), lid.map(|j| j.to_non_ad()));
    }

    pub fn own_pn(&self) -> Option<Jid> {
        self.own.read().unwrap().0.clone()
    }

    pub fn own_lid(&self) -> Option<Jid> {
        self.own.read().unwrap().1.clone()
    }

    pub fn is_own(&self, jid: &Jid) -> bool {
        let own = self.own.read().unwrap();
        own.0.as_ref().is_some_and(|p| p.user == jid.user && jid.is_pn())
            || own.1.as_ref().is_some_and(|l| l.user == jid.user && jid.is_lid())
    }

    /// Records `lid_user` ↔ `pn_user`; queues an alias when the mapping is new or changed.
    pub fn learn(&self, lid_user: &str, pn_user: &str) {
        if lid_user.is_empty() || pn_user.is_empty() {
            return;
        }
        {
            let map = self.lid_to_pn.read().unwrap();
            if map.get(lid_user).is_some_and(|p| p == pn_user) {
                return;
            }
        }
        self.lid_to_pn.write().unwrap().insert(lid_user.to_string(), pn_user.to_string());
        self.pn_to_lid.write().unwrap().insert(pn_user.to_string(), lid_user.to_string());
        self.misses.write().unwrap().remove(lid_user);
        self.pending.lock().unwrap().push(BridgeJidAlias {
            lid: Jid::lid(lid_user).to_string(),
            pn: Jid::pn(pn_user).to_string(),
        });
    }

    /// Learns from any pair where one side is a LID and the other a PN (order-insensitive).
    pub fn learn_pair(&self, a: &Jid, b: &Jid) {
        match (a.is_lid(), b.is_lid(), a.is_pn(), b.is_pn()) {
            (true, _, _, true) => self.learn(&a.user, &b.user),
            (_, true, true, _) => self.learn(&b.user, &a.user),
            _ => {}
        }
    }

    pub fn learn_strs(&self, a: Option<&str>, b: Option<&str>) {
        if let (Some(a), Some(b)) = (a.and_then(parse), b.and_then(parse)) {
            self.learn_pair(&a, &b);
        }
    }

    pub fn take_pending(&self) -> Vec<BridgeJidAlias> {
        std::mem::take(&mut *self.pending.lock().unwrap())
    }

    /// Canonical form using only the cache: device stripped, LID → PN when known.
    pub fn cached(&self, jid: &Jid) -> Jid {
        let base = jid.to_non_ad();
        if base.is_lid()
            && let Some(pn) = self.lid_to_pn.read().unwrap().get(base.user.as_str())
        {
            return Jid::pn(pn.as_str());
        }
        base
    }

    pub fn cached_str(&self, jid: &Jid) -> String {
        self.cached(jid).to_string()
    }

    /// The other namespace's form of a user JID (PN ↔ LID), if known. Used for secret lookups.
    pub fn alternate(&self, jid: &Jid) -> Option<Jid> {
        let base = jid.to_non_ad();
        if base.is_lid() {
            self.lid_to_pn.read().unwrap().get(base.user.as_str()).map(|p| Jid::pn(p.as_str()))
        } else if base.is_pn() {
            self.pn_to_lid.read().unwrap().get(base.user.as_str()).map(|l| Jid::lid(l.as_str()))
        } else {
            None
        }
    }

    fn needs_lookup(&self, jid: &Jid) -> bool {
        jid.is_lid()
            && !self.lid_to_pn.read().unwrap().contains_key(jid.user.as_str())
            && !self.misses.read().unwrap().contains(jid.user.as_str())
    }

    fn record_lookup(&self, jid: &Jid, found: Option<String>) {
        match found {
            Some(pn) => self.learn(&jid.user, &pn),
            None => {
                self.misses.write().unwrap().insert(jid.user.to_string());
            }
        }
    }

    /// Canonical form, asking the library's LID/PN store on a cache miss.
    pub async fn resolve(&self, client: Option<&Client>, jid: &Jid) -> Jid {
        let base = jid.to_non_ad();
        if let Some(client) = client
            && self.needs_lookup(&base)
        {
            let found = client
                .get_lid_pn_entry(&base)
                .await
                .ok()
                .flatten()
                .map(|e| e.phone_number.to_string());
            self.record_lookup(&base, found);
        }
        self.cached(&base)
    }

    /// Blocking-thread variant of [`Canon::resolve`] (history sync runs on `spawn_blocking`).
    pub fn resolve_blocking(
        &self,
        client: Option<&Client>,
        rt: &tokio::runtime::Handle,
        jid: &Jid,
    ) -> Jid {
        let base = jid.to_non_ad();
        if let Some(client) = client
            && self.needs_lookup(&base)
        {
            let found = rt
                .block_on(client.get_lid_pn_entry(&base))
                .ok()
                .flatten()
                .map(|e| e.phone_number.to_string());
            self.record_lookup(&base, found);
        }
        self.cached(&base)
    }
}

pub fn parse(s: &str) -> Option<Jid> {
    s.parse::<Jid>().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn learns_once_and_rewrites() {
        let c = Canon::default();
        let lid: Jid = "100000000000001:5@lid".parse().unwrap();
        assert_eq!(c.cached_str(&lid), "100000000000001@lid");
        c.learn("100000000000001", "15550001111");
        c.learn("100000000000001", "15550001111");
        assert_eq!(c.cached_str(&lid), "15550001111@s.whatsapp.net");
        let pending = c.take_pending();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].lid, "100000000000001@lid");
        assert_eq!(pending[0].pn, "15550001111@s.whatsapp.net");
        let pn: Jid = "15550001111@s.whatsapp.net".parse().unwrap();
        assert_eq!(c.alternate(&pn).unwrap().to_string(), "100000000000001@lid");
        let group: Jid = "120363000000000001@g.us".parse().unwrap();
        assert_eq!(c.cached_str(&group), "120363000000000001@g.us");
    }
}
