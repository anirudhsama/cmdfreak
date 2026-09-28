import Foundation
import WAKit

/// Process-wide plan cache keyed by message id + content hash + row context (which includes width).
/// `NSCache` is thread-safe, so the preloader and the list share it.
final class LayoutPlanCache: @unchecked Sendable {
    static let shared = LayoutPlanCache()

    private final class Box: @unchecked Sendable {
        let plan: LayoutPlan
        init(_ plan: LayoutPlan) { self.plan = plan }
    }

    private let cache = NSCache<NSString, Box>()

    init(countLimit: Int = 4000) {
        cache.countLimit = countLimit
    }

    func plan(for item: MessageItem, context: RowContext) -> LayoutPlan {
        let key = LayoutPlan.cacheKey(item, context) as NSString
        if let hit = cache.object(forKey: key) { return hit.plan }
        let plan = LayoutPlanner.plan(item, context)
        cache.setObject(Box(plan), forKey: key)
        return plan
    }
}
