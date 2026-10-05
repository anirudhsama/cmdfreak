import Foundation
import PhoneNumberKit
import Synchronization

public enum PhoneFormat {
    private final class State {
        lazy var utility = PhoneNumberUtility()
        var cache: [String: String] = [:]
    }

    private static let state = Mutex(State())

    /// "+44 7700 900208": the digits grouped the way the number's country writes them.
    /// Falls back to "+" and the bare digits when the number can't be parsed.
    public static func display(_ digits: String) -> String {
        state.withLock { s in
            if let hit = s.cache[digits] { return hit }
            let plain = "+" + digits
            let formatted = (try? s.utility.parse(plain, ignoreType: true))
                .map { s.utility.format($0, toType: .international) } ?? plain
            s.cache[digits] = formatted
            return formatted
        }
    }
}
