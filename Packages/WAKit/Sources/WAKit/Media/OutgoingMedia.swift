import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A file staged for sending, with the metadata WhatsApp expects already computed.
public struct PreparedAttachment: Sendable, Identifiable {
    public let id = UUID()
    /// The file the user picked.
    public let source: URL
    /// What goes to the bridge (`caption` left nil; the sender fills it in).
    public var outgoing: BridgeOutgoingMedia
    /// ~240px JPEG for the staging tray.
    public let preview: Data?

    public var kind: SendMediaKind { outgoing.kind }
    public var fileURL: URL { URL(filePath: outgoing.filePath) }
    /// True when `fileURL` is a converted copy we own (GIF→MP4, HEIC→JPEG, video transcode).
    public var isConverted: Bool { fileURL.standardizedFileURL != source.standardizedFileURL }
}

/// Computes send metadata off the main thread and converts files into formats every WhatsApp
/// client plays:
/// - Images: JPEG and PNG go as-is. Anything else (HEIC, TIFF, WebP…), EXIF-rotated images and
///   images over 16 MB are re-encoded as JPEG. Android clients cannot decode HEIC and WhatsApp's own
///   apps convert before sending, so we do too.
/// - GIFs: WhatsApp has no GIF image message; a GIF is an H.264 MP4 with `gifPlayback`. Frames are
///   decoded with ImageIO (which composites disposal) and written with AVAssetWriter.
/// - Videos: H.264 in an MP4 container goes as-is; anything else (HEVC, .mov, ProRes…) is exported
///   to H.264 MP4 at up to 1080p, which is what WhatsApp clients send anyway.
/// - Everything else is a document: mimetype from UTType, page count and first-page preview for PDFs.
public enum OutgoingMediaPreparer {
    public enum Failure: Error, LocalizedError {
        case unreadable(String)
        case conversion(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let s): "Can't read \(s)"
            case .conversion(let s): "Can't convert \(s)"
            }
        }
    }

    static let thumbnailMaxPixels = 100
    static let previewMaxPixels = 240
    static let documentThumbnailMaxPixels = 320
    static let maxImageBytes: Int64 = 16 * 1024 * 1024

    /// Converted files live here until sent; `WAClient` removes them after a successful send.
    public static var stagingDirectory: URL {
        URL.cachesDirectory.appending(path: "CmdFreak/outgoing", directoryHint: .isDirectory)
    }

    /// `asDocument` sends media files as-is, as documents.
    public static func prepare(_ url: URL, asDocument: Bool = false) async throws -> PreparedAttachment {
        let type = UTType(filenameExtension: url.pathExtension.lowercased()) ?? .data
        if !asDocument {
            if type.conforms(to: .gif) { return try await prepareGIF(url) }
            if type.conforms(to: .image), let p = try prepareImage(url, type: type) { return p }
            if type.conforms(to: .movie), let p = try await prepareVideo(url, type: type) { return p }
        }
        return try prepareDocument(url, type: type)
    }

    // MARK: - Image

    static func prepareImage(_ url: URL, type: UTType) throws -> PreparedAttachment? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? Int, var h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let size = fileSize(url)
        let passthrough = (type.conforms(to: .jpeg) || type.conforms(to: .png)) && orientation == 1 && size <= maxImageBytes
        var file = url
        var mime = type.conforms(to: .png) ? "image/png" : "image/jpeg"
        if !passthrough {
            // Bake orientation; cap huge images so the JPEG stays under the image limit.
            let maxSide = size > maxImageBytes ? min(max(w, h), 4096) : max(w, h)
            guard let image = thumbnail(src, maxPixels: maxSide) else { throw Failure.conversion(url.lastPathComponent) }
            file = stagingURL(ext: "jpg")
            try writeJPEG(image, to: file, quality: 0.9)
            w = image.width
            h = image.height
            mime = "image/jpeg"
        }
        let thumb = thumbnail(src, maxPixels: thumbnailMaxPixels).flatMap { jpegData($0, quality: 0.6) }
        let preview = thumbnail(src, maxPixels: previewMaxPixels).flatMap { jpegData($0, quality: 0.8) }
        return PreparedAttachment(
            source: url,
            outgoing: media(.image, file: file, mime: mime, name: file == url ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent + ".jpg", w: w, h: h, thumb: thumb),
            preview: preview)
    }

    // MARK: - GIF → MP4

    static func prepareGIF(_ url: URL) async throws -> PreparedAttachment {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        let out = stagingURL(ext: "mp4")
        let (w, h, duration) = try await gifToMP4(src, to: out)
        let first = CGImageSourceCreateImageAtIndex(src, 0, nil)
        let thumb = first.flatMap { scaled($0, maxPixels: thumbnailMaxPixels) }.flatMap { jpegData($0, quality: 0.6) }
        let preview = first.flatMap { scaled($0, maxPixels: previewMaxPixels) }.flatMap { jpegData($0, quality: 0.8) }
        var m = media(.gif, file: out, mime: "video/mp4", name: url.deletingPathExtension().lastPathComponent + ".mp4",
                      w: w, h: h, thumb: thumb)
        m.durationSecs = UInt32(max(1, duration.rounded()))
        return PreparedAttachment(source: url, outgoing: m, preview: preview)
    }

    /// Writes the GIF's frames as H.264. Returns the output size and duration in seconds.
    static func gifToMP4(_ src: CGImageSource, to out: URL, maxSide: Int = 1280) async throws -> (Int, Int, Double) {
        let count = CGImageSourceGetCount(src)
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int
        else { throw Failure.unreadable("GIF") }
        let scale = min(1, Double(maxSide) / Double(max(pw, ph)))
        // H.264 wants even dimensions.
        let w = max(2, Int(Double(pw) * scale) & ~1)
        let h = max(2, Int(Double(ph) * scale) & ~1)

        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw Failure.conversion(writer.error?.localizedDescription ?? "GIF") }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        var t = 0.0
        for i in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.conversion("GIF (no pixel buffer pool)") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure.conversion("GIF (pixel buffer)") }
            draw(frame, into: buffer, width: w, height: h)
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: timescale))
            t += gifDelay(src, i)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: t, preferredTimescale: timescale))
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.conversion(writer.error?.localizedDescription ?? "GIF") }
        return (w, h, t)
    }

    /// Browsers clamp tiny delays to 100ms; do the same so "0" GIFs don't play at 50fps+.
    static func gifDelay(_ src: CGImageSource, _ i: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return d < 0.011 ? 0.1 : d
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        // Transparent GIF pixels become white, as on WhatsApp's own GIF conversions.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    // MARK: - Video

    static func prepareVideo(_ url: URL, type: UTType) async throws -> PreparedAttachment? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let formats = try await track.load(.formatDescriptions)
        let isH264 = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }
        var file = url
        var info = try await videoInfo(asset)
        if !(type.conforms(to: .mpeg4Movie) && isH264) {
            file = stagingURL(ext: "mp4")
            try await transcode(asset, to: file)
            info = try await videoInfo(AVURLAsset(url: file))
        }
        var m = media(.video, file: file, mime: "video/mp4", name: url.deletingPathExtension().lastPathComponent + ".mp4",
                      w: info.width, h: info.height, thumb: info.thumb)
        m.durationSecs = UInt32(max(1, info.duration.rounded()))
        return PreparedAttachment(source: url, outgoing: m, preview: info.preview)
    }

    struct VideoInfo {
        var width: Int, height: Int, duration: Double, thumb: Data?, preview: Data?
    }

    static func videoInfo(_ asset: AVURLAsset) async throws -> VideoInfo {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.unreadable(asset.url.lastPathComponent)
        }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = CGRect(origin: .zero, size: natural).applying(transform).size
        let duration = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: previewMaxPixels, height: previewMaxPixels)
        let at = CMTime(seconds: min(0.5, duration / 2), preferredTimescale: 600)
        let frame = try? await gen.image(at: at).image
        return VideoInfo(
            width: Int(abs(size.width).rounded()), height: Int(abs(size.height).rounded()), duration: duration,
            thumb: frame.flatMap { scaled($0, maxPixels: thumbnailMaxPixels) }.flatMap { jpegData($0, quality: 0.6) },
            preview: frame.flatMap { jpegData($0, quality: 0.8) })
    }

    static func transcode(_ asset: AVURLAsset, to out: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            throw Failure.conversion(asset.url.lastPathComponent)
        }
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: out)
        try await session.export(to: out, as: .mp4)
    }

    // MARK: - Document

    static func prepareDocument(_ url: URL, type: UTType) throws -> PreparedAttachment {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw Failure.unreadable(url.lastPathComponent) }
        let mime = type.preferredMIMEType ?? "application/octet-stream"
        var m = media(.document, file: url, mime: mime, name: url.lastPathComponent, w: nil, h: nil, thumb: nil)
        var preview: Data?
        if type.conforms(to: .pdf), let doc = PDFDocument(url: url) {
            m.pageCount = UInt32(doc.pageCount)
            if let page = doc.page(at: 0)?.pageRef, let image = render(page, maxPixels: documentThumbnailMaxPixels) {
                m.jpegThumbnail = jpegData(image, quality: 0.5)
                m.thumbnailWidth = UInt32(image.width)
                m.thumbnailHeight = UInt32(image.height)
                preview = scaled(image, maxPixels: previewMaxPixels).flatMap { jpegData($0, quality: 0.8) }
            }
        } else if type.conforms(to: .image), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = thumbnail(src, maxPixels: previewMaxPixels) {
            preview = jpegData(image, quality: 0.8)
        }
        return PreparedAttachment(source: url, outgoing: m, preview: preview)
    }

    static func render(_ page: CGPDFPage, maxPixels: Int) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let pageSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let scale = Double(maxPixels) / max(pageSize.width, pageSize.height)
        let w = Int(pageSize.width * scale), h = Int(pageSize.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    // MARK: - Helpers

    static func media(_ kind: SendMediaKind, file: URL, mime: String, name: String, w: Int?, h: Int?, thumb: Data?) -> BridgeOutgoingMedia {
        BridgeOutgoingMedia(
            kind: kind, filePath: file.path, mimetype: mime, fileName: name, caption: nil,
            width: w.map { UInt32($0) }, height: h.map { UInt32($0) }, durationSecs: nil, jpegThumbnail: thumb,
            thumbnailWidth: nil, thumbnailHeight: nil, pageCount: nil)
    }

    static func stagingURL(ext: String) -> URL {
        let dir = stagingDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(UUID().uuidString).\(ext)")
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    /// Downsampled, orientation-corrected image straight from the source.
    static func thumbnail(_ src: CGImageSource, maxPixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    static func scaled(_ image: CGImage, maxPixels: Int) -> CGImage? {
        let s = min(1, Double(maxPixels) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * s)), h = max(1, Int(Double(image.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flattened(image), [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let data = jpegData(image, quality: quality) else { throw Failure.conversion(url.lastPathComponent) }
        try data.write(to: url)
    }

    /// JPEG has no alpha: composite onto white so transparent areas don't turn black.
    static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: return scaled(image, maxPixels: max(image.width, image.height)) ?? image
        }
    }
}
