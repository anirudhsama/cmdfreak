import CoreGraphics
import Foundation
import ImageIO

/// Decoded images at display size, decoded off the main thread and kept in an `NSCache`.
public final class ThumbnailCache: @unchecked Sendable {
    public enum Source: Sendable {
        case data(Data)
        case file(URL)
    }

    public static let shared = ThumbnailCache()

    // NSCache is thread-safe.
    private let cache = NSCache<NSString, CGImage>()

    public init(countLimit: Int = 600) {
        cache.countLimit = countLimit
    }

    /// Synchronous lookup for the first frame. Never decodes.
    public func cached(key: String, maxPixelSize: Int) -> CGImage? {
        cache.object(forKey: Self.cacheKey(key, maxPixelSize))
    }

    /// Decodes `source` so its longest side is at most `maxPixelSize` pixels, off the main thread.
    public func image(key: String, source: Source, maxPixelSize: Int) async -> CGImage? {
        let ck = Self.cacheKey(key, maxPixelSize)
        if let hit = cache.object(forKey: ck) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            Self.decode(source, maxPixelSize: maxPixelSize)
        }.value
        if let image { cache.setObject(image, forKey: ck) }
        return image
    }

    /// Decodes on the calling thread and caches. For preloaders that already run off the main thread.
    @discardableResult
    public func decodeSync(key: String, source: Source, maxPixelSize: Int) -> CGImage? {
        let ck = Self.cacheKey(key, maxPixelSize)
        if let hit = cache.object(forKey: ck) { return hit }
        let image = Self.decode(source, maxPixelSize: maxPixelSize)
        if let image { cache.setObject(image, forKey: ck) }
        return image
    }

    public func removeAll() { cache.removeAllObjects() }

    static func cacheKey(_ key: String, _ size: Int) -> NSString { "\(key)@\(size)" as NSString }

    static func decode(_ source: Source, maxPixelSize: Int) -> CGImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        let src: CGImageSource? = switch source {
        case .data(let d): CGImageSourceCreateWithData(d as CFData, opts)
        case .file(let u): CGImageSourceCreateWithURL(u as CFURL, opts)
        }
        guard let src else { return nil }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts)
    }
}
