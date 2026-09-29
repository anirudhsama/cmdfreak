import Foundation
import GRDB

/// Marks the contacts of DM chats that are WhatsApp Business accounts, with batched usync lookups.
/// Each is checked once, then again after `recheckInterval` (an account can switch to or from Business).
public actor BusinessService {
    public static let batchSize = 50

    private let bridge: any WaBridgeProtocol
    private let ingest: IngestActor
    private let batchInterval: Duration
    private let recheckInterval: Int64
    private var filling = false
    private var rerun = false
    /// Asked this session; a user the server did not answer for is not asked again until relaunch.
    private var attempted: Set<String> = []

    public init(bridge: any WaBridgeProtocol, ingest: IngestActor, batchInterval: Duration = .seconds(2),
                recheckInterval: Int64 = 14 * 86_400) {
        self.bridge = bridge
        self.ingest = ingest
        self.batchInterval = batchInterval
        self.recheckInterval = recheckInterval
    }

    /// Safe to call repeatedly: a call during a run schedules one more pass.
    public func checkPending() async {
        guard !filling else { rerun = true; return }
        filling = true
        defer { filling = false }
        repeat {
            rerun = false
            await checkPass()
        } while rerun
    }

    private func checkPass() async {
        let now = Int64(Date().timeIntervalSince1970)
        do {
            let jids = try await ingest.database.reader.read { db in
                try String.fetchAll(db, sql: """
                    SELECT c.jid FROM chat c LEFT JOIN contact ct ON ct.jid = c.jid
                    WHERE c.kind = 'dm'
                      AND (c.jid LIKE '%@s.whatsapp.net' OR c.jid LIKE '%@lid')
                      AND (ct.businessCheckedAt IS NULL OR ct.businessCheckedAt < ?)
                      AND (c.lastActivityAt IS NOT NULL OR c.pinnedAt IS NOT NULL)
                    ORDER BY c.lastActivityAt DESC
                    """, arguments: [now - recheckInterval])
            }.filter { !attempted.contains($0) }
            for start in stride(from: 0, to: jids.count, by: Self.batchSize) {
                if start > 0 { try await Task.sleep(for: batchInterval) }
                let batch = Array(jids[start..<min(start + Self.batchSize, jids.count)])
                let checks = try await bridge.checkBusiness(jids: batch)
                try await ingest.setBusiness(checks, checkedAt: now)
                attempted.formUnion(batch)
            }
        } catch {
            WAKit.log.error("business check failed: \(error)")
        }
    }
}
