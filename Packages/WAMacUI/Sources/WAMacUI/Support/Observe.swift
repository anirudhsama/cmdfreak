import Foundation
import Observation

/// Re-runs `apply` whenever any `@Observable` property read inside it changes. Main-actor only;
/// the first run is synchronous. Cancel by dropping the returned token.
@MainActor
public final class ObservationToken {
    private var active = true

    public init(_ apply: @escaping @MainActor () -> Void) {
        run(apply)
    }

    private func run(_ apply: @escaping @MainActor () -> Void) {
        guard active else { return }
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in self?.run(apply) }
        }
    }

    public func cancel() { active = false }

    isolated deinit { active = false }
}

@MainActor
public func observe(_ apply: @escaping @MainActor () -> Void) -> ObservationToken {
    ObservationToken(apply)
}
