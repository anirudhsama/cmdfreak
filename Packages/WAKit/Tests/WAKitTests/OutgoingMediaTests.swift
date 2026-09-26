import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WAKit

/// Metadata extraction and conversion on files generated in a temp dir.
@Suite struct OutgoingMediaTests {
    let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appending(path: "wa-outgoing-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func image(_ w: Int, _ h: Int, alpha: Bool = false, shade: Double = 0.3) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        ctx.setFillColor(CGColor(red: shade, green: 0.5, blue: 1 - shade, alpha: alpha ? 0.5 : 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        return ctx.makeImage()!
    }

    func write(_ images: [CGImage], type: UTType, name: String, props: [CFString: Any] = [:], frameProps: [CFString: Any] = [:]) -> URL {
        let url = dir.appending(path: name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil)!
        CGImageDestinationSetProperties(dest, props as CFDictionary)
        for img in images { CGImageDestinationAddImage(dest, img, frameProps as CFDictionary) }
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func pngPassesThroughWithDimensionsAndThumbnail() async throws {
        let url = write([image(800, 600, alpha: true)], type: .png, name: "shot.png")
        let p = try await OutgoingMediaPreparer.prepare(url)
        #expect(p.kind == .image)
        #expect(!p.isConverted)
        #expect(p.outgoing.mimetype == "image/png")
        #expect(p.outgoing.width == 800 && p.outgoing.height == 600)
        let thumb = try #require(p.outgoing.jpegThumbnail)
        let src = CGImageSourceCreateWithData(thumb as CFData, nil)!
        #expect(CGImageSourceGetType(src) as String? == UTType.jpeg.identifier)
        let tp = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        #expect(tp[kCGImagePropertyPixelWidth] as? Int == 100)
        #expect(p.preview != nil)
    }

    @Test func rotatedJPEGIsReencodedUpright() async throws {
        let url = write([image(400, 200)], type: .jpeg, name: "rotated.jpg", frameProps: [kCGImagePropertyOrientation: 6])
        let p = try await OutgoingMediaPreparer.prepare(url)
        #expect(p.isConverted)
        #expect(p.outgoing.mimetype == "image/jpeg")
        #expect(p.outgoing.width == 200 && p.outgoing.height == 400)
        try? FileManager.default.removeItem(at: p.fileURL)
    }

    @Test func heicIsTranscodedToJPEG() async throws {
        let url = write([image(640, 480)], type: .heic, name: "photo.heic")
        let p = try await OutgoingMediaPreparer.prepare(url)
        #expect(p.kind == .image && p.isConverted)
        #expect(p.fileURL.pathExtension == "jpg" && p.outgoing.fileName == "photo.jpg")
        #expect(p.outgoing.width == 640 && p.outgoing.height == 480)
        try? FileManager.default.removeItem(at: p.fileURL)
    }

    @Test func gifBecomesLoopingMP4() async throws {
        let frames = (0..<6).map { image(121, 81, shade: Double($0) / 6) }
        let url = write(frames, type: .gif, name: "anim.gif",
                        frameProps: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.25]])
        let p = try await OutgoingMediaPreparer.prepare(url)
        #expect(p.kind == .gif)
        #expect(p.outgoing.mimetype == "video/mp4")
        #expect(p.outgoing.fileName == "anim.mp4")
        #expect(p.outgoing.width == 120 && p.outgoing.height == 80)  // even dimensions for H.264
        #expect(p.outgoing.durationSecs == 2)  // 6 × 0.25s = 1.5s → rounds to 2
        let asset = AVURLAsset(url: p.fileURL)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let fmt = try await track.load(.formatDescriptions)
        #expect(fmt.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 })
        #expect(abs(try await asset.load(.duration).seconds - 1.5) < 0.05)

        // The same MP4 as a video: H.264 in MP4 passes through with duration, size and thumbnail.
        let video = try await OutgoingMediaPreparer.prepare(p.fileURL)
        #expect(video.kind == .video && !video.isConverted)
        #expect(video.outgoing.width == 120 && video.outgoing.height == 80)
        #expect(video.outgoing.durationSecs == 2)
        #expect(video.outgoing.jpegThumbnail != nil)

        // Not MP4 → transcoded to H.264 MP4.
        let mov = dir.appending(path: "clip.mov")
        try FileManager.default.copyItem(at: p.fileURL, to: mov)
        let converted = try await OutgoingMediaPreparer.prepare(mov)
        #expect(converted.kind == .video && converted.isConverted)
        #expect(converted.fileURL.pathExtension == "mp4")
        #expect(converted.outgoing.fileName == "clip.mp4")
        #expect(converted.outgoing.durationSecs == 2)
        try? FileManager.default.removeItem(at: p.fileURL)
        try? FileManager.default.removeItem(at: converted.fileURL)
    }

    @Test func pdfDocumentHasPageCountAndPreview() async throws {
        let url = dir.appending(path: "Report Q3.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for _ in 0..<3 {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 50, y: 50, width: 200, height: 200))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let p = try await OutgoingMediaPreparer.prepare(url)
        #expect(p.kind == .document && !p.isConverted)
        #expect(p.outgoing.mimetype == "application/pdf")
        #expect(p.outgoing.fileName == "Report Q3.pdf")
        #expect(p.outgoing.pageCount == 3)
        #expect(p.outgoing.jpegThumbnail != nil)
        #expect(p.outgoing.thumbnailHeight == 320)
        #expect(p.outgoing.thumbnailWidth == 247)
    }

    @Test func unknownFileIsAnOctetStreamDocument() async throws {
        let url = dir.appending(path: "notes.weirdext")
        try Data("hello".utf8).write(to: url)
        let p = try await OutgoingMediaPreparer.prepare(url)
        #expect(p.kind == .document)
        #expect(p.outgoing.mimetype == "application/octet-stream")
        #expect(p.outgoing.pageCount == nil)
    }

    @Test func imageCanBeForcedToDocument() async throws {
        let url = write([image(50, 50)], type: .png, name: "icon.png")
        let p = try await OutgoingMediaPreparer.prepare(url, asDocument: true)
        #expect(p.kind == .document)
        #expect(p.outgoing.mimetype == "image/png")
        #expect(p.preview != nil)
    }
}
