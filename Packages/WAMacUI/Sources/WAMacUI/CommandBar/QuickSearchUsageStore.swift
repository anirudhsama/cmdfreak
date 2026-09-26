import Foundation
import WAKit

/// Persists `QuickSearchUsage` as a small JSON file next to the app database, saving shortly after
/// each change so a burst of chat switches is one write.
@MainActor
final class QuickSearchUsageStore {
    private(set) var usage: QuickSearchUsage
    private let url: URL
    private var saveTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        usage = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(QuickSearchUsage.self, from: $0) } ?? QuickSearchUsage()
    }

    func recordSelection(of jid: String, query: String) {
        usage.recordSelection(of: jid, query: query)
        scheduleSave()
    }

    func recordVisit(of jid: String) {
        usage.recordVisit(of: jid)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let url = url
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let usage = self?.usage else { return }
            Task.detached(priority: .utility) {
                do { try JSONEncoder().encode(usage).write(to: url, options: .atomic) } catch {
                    WAKit.log.error("quick search usage save failed: \(error)")
                }
            }
        }
    }
}
