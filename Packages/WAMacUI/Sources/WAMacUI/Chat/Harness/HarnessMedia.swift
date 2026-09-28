#if DEBUG
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Generates throwaway media files so every message kind can be exercised without a network.
enum HarnessMedia {
    static func image(size: CGSize, hue: CGFloat, label: String) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        for i in 0..<6 {
            let r = size.width * CGFloat(0.12 + Double(i) * 0.05)
            ctx.setFillColor(NSColor(hue: (hue + CGFloat(i) * 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.75, alpha: 0.7).cgColor)
            ctx.fillEllipse(in: CGRect(x: size.width * CGFloat(0.1 + Double(i) * 0.13), y: size.height * CGFloat(0.2 + Double(i % 3) * 0.2), width: r, height: r))
        }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: size.height / 8), .foregroundColor: NSColor.white])
            .draw(at: NSPoint(x: 16, y: 16))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    static func encode(_ img: CGImage, type: UTType, quality: Double = 0.85) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func thumbnail(_ img: CGImage, maxPixel: Int = 48) -> Data {
        let scale = CGFloat(maxPixel) / CGFloat(max(img.width, img.height))
        let w = max(1, Int(CGFloat(img.width) * scale)), h = max(1, Int(CGFloat(img.height) * scale))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return encode(ctx.makeImage()!, type: .jpeg, quality: 0.5)
    }

    /// WebP when ImageIO can encode it, otherwise PNG bytes (ImageIO sniffs content on decode).
    static func sticker(hue: CGFloat) -> Data {
        let size = CGSize(width: 512, height: 512)
        let ctx = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 40, dy: 40))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.8).cgColor)
        ctx.fillEllipse(in: CGRect(x: 150, y: 300, width: 60, height: 80))
        ctx.fillEllipse(in: CGRect(x: 300, y: 300, width: 60, height: 80))
        ctx.setLineWidth(22)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor)
        ctx.addArc(center: CGPoint(x: 256, y: 230), radius: 110, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
        ctx.strokePath()
        let img = ctx.makeImage()!
        if let webp = UTType("org.webmproject.webp"), CGImageDestinationCreateWithData(NSMutableData(), webp.identifier as CFString, 1, nil) != nil {
            return encode(img, type: webp)
        }
        return encode(img, type: .png)
    }

    static func pdf(to url: URL, pages: Int) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for p in 1...pages {
            ctx.beginPDFPage(nil)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            NSAttributedString(string: "CmdFreak harness document — page \(p) of \(pages)", attributes: [.font: NSFont.systemFont(ofSize: 20)])
                .draw(at: NSPoint(x: 60, y: 700))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Three seconds of a sine sweep as PCM in a CAF container (what a remuxed voice note is).
    static func audio(to url: URL, seconds: Double = 3) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let p = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / 44_100
            let f = 220 + 440 * t / seconds
            p[i] = Float(sin(2 * .pi * f * t) * 0.3 * (0.5 + 0.5 * sin(t * 6)))
        }
        try file.write(from: buf)
    }

    static func waveform() -> Data {
        Data((0..<64).map { UInt8(20 + 70 * abs(sin(Double($0) * 0.4)) ) })
    }

    /// A short H.264 MP4 with a moving square, encoded synchronously.
    static func video(to url: URL, seconds: Double = 2, fps: Int32 = 12) throws {
        let w = 480, h = 360
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let total = Int(Double(fps) * seconds)
        for i in 0..<total {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let pb else { break }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(NSColor(hue: 0.6, saturation: 0.5, brightness: 0.35, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let x = CGFloat(i) / CGFloat(total) * CGFloat(w - 80)
            ctx.setFillColor(NSColor(hue: 0.1, saturation: 0.8, brightness: 1, alpha: 1).cgColor)
            ctx.fill(CGRect(x: x, y: 140, width: 80, height: 80))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }
}
#endif
