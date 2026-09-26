import AppKit
import WAKit

/// Files from a paste or drop: file URLs as-is; bare image data (a copied screenshot, an image
/// dragged from a browser) is written to a PNG in the outgoing staging directory.
enum PasteboardAttachments {
    static let dragTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    static func canRead(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pb.availableType(from: [.png, .tiff]) != nil
    }

    static func urls(from pb: NSPasteboard) -> [URL] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.filter { !$0.hasDirectoryPath }
        }
        // Rich text copies carry images too; only take image data when there's no text to paste.
        guard pb.string(forType: .string) == nil, let type = pb.availableType(from: [.png, .tiff]),
              let data = pb.data(forType: type) else { return [] }
        let png = type == .png ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        guard let png else { return [] }
        let dir = OutgoingMediaPreparer.stagingDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Pasted Image \(UUID().uuidString.prefix(8)).png")
        do { try png.write(to: url) } catch { return [] }
        return [url]
    }
}
