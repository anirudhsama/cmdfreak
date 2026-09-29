import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WAKit

struct Person {
    let jid: String
    /// The saved contact name; nil for a number that is not in the address book.
    let name: String?
    let pushName: String

    init(_ number: String, _ name: String?, push: String? = nil) {
        jid = "\(number)@s.whatsapp.net"
        self.name = name
        pushName = push ?? name?.split(separator: " ").first.map(String.init) ?? number
    }

    var phone: String { String(jid.prefix { $0 != "@" }) }

    var contact: BridgeContact {
        BridgeContact(jid: jid, fullName: name, firstName: name?.split(separator: " ").first.map(String.init),
                      pushName: pushName, phone: phone)
    }
}

/// Timestamps relative to a fixed "now", so regenerating gives the same file. Times are written as
/// GMT; at launch the app moves everything by whole days and the local UTC offset, so each message
/// keeps its time of day on the viewer's clock and the newest lands today (or yesterday before 09:46).
enum Clock {
    static let zone = TimeZone(identifier: "GMT")!
    static let now: Int64 = at(0, "09:42")

    /// `daysAgo` days before the reference day, at `time` ("HH:mm").
    static func at(_ daysAgo: Int, _ time: String) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = time.split(separator: ":").compactMap { Int($0) }
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28 - daysAgo, hour: parts[0], minute: parts[1]))!
        return Int64(day.timeIntervalSince1970)
    }
}

/// A sent message, for replies, reactions added later and poll votes.
struct Ref {
    let id: String
    let chatJid: String
    let sender: Person
    let kind: MessageKind
    let text: String?
    let fromMe: Bool

    var key: BridgeMessageKey {
        BridgeMessageKey(chatJid: chatJid, id: id, fromMe: fromMe, participant: chatJid.hasSuffix("@g.us") ? sender.jid : nil)
    }

    var quote: BridgeQuoted {
        BridgeQuoted(id: id, senderJid: sender.jid, kind: kind, snippet: String((text ?? "").prefix(200)))
    }
}

/// One conversation, written top to bottom. `day` sets the clock, each message moves it on a
/// minute, `wait` adds more.
final class Chat {
    let jid: String
    let name: String?
    let members: [Person]
    let admins: Set<String>
    /// Pin position, 1 at the top.
    var pin: Int?
    var muted = false
    var archived = false
    var markedUnread = false
    /// The newest `unread` incoming messages count as unread.
    var unread: UInt32 = 0
    private(set) var messages: [BridgeMessage] = []
    private(set) var updates: [BridgeMessageUpdate] = []
    private var t: Int64 = 0

    var isGroup: Bool { jid.hasSuffix("@g.us") }

    /// A DM with `person`.
    init(_ person: Person) {
        jid = person.jid
        name = nil
        members = [person]
        admins = []
    }

    /// A group; `members` excludes you.
    init(group id: Int, _ name: String, _ members: [Person], admins: [Person] = []) {
        jid = String(format: "1203630411%08d@g.us", id)
        self.name = name
        self.members = members
        self.admins = Set(admins.map(\.jid))
    }

    func day(_ daysAgo: Int, _ time: String) { t = Clock.at(daysAgo, time) }
    func wait(_ minutes: Double) { t += Int64(minutes * 60) }

    @discardableResult
    func send(
        _ from: Person, _ text: String? = nil, kind: MessageKind = .text, media: BridgeMedia? = nil, reply: Ref? = nil,
        reactions: [(Person, String)] = [], edited: Bool = false, forwarded: Bool = false, location: BridgeLocation? = nil,
        poll: BridgePoll? = nil, status: MessageStatus? = nil, typeName: String? = nil
    ) -> Ref {
        let fromMe = from.jid == Cast.me.jid
        let id = Self.messageId(chat: jid, index: messages.count)
        messages.append(BridgeMessage(
            id: id, chatJid: jid, senderJid: from.jid, participant: isGroup ? from.jid : nil, fromMe: fromMe, timestamp: t,
            kind: kind, text: text, quoted: reply?.quote, media: media, location: location, contact: nil, poll: poll,
            reactions: reactions.map { BridgeReaction(senderJid: $0.0.jid, fromMe: $0.0.jid == Cast.me.jid, emoji: $0.1, timestamp: t + 60) },
            typeName: typeName, pushName: fromMe ? nil : from.pushName, status: fromMe ? status ?? .read : nil,
            isForwarded: forwarded, revoked: false, editedAt: edited ? t + 90 : nil))
        let ref = Ref(id: id, chatJid: jid, sender: from, kind: kind, text: text ?? poll?.question, fromMe: fromMe)
        t += 60
        return ref
    }

    func system(_ actor: Person, _ text: String, typeName: String) {
        send(actor, text, kind: .system, typeName: typeName)
    }

    func vote(_ poll: Ref, _ voter: Person, _ options: String...) {
        updates.append(.pollVote(target: poll.key, voterJid: voter.jid, selected: options, timestamp: t))
    }

    var bridgeChat: BridgeChat {
        BridgeChat(jid: jid, kind: isGroup ? .group : .dm, name: name, lastActivityAt: messages.last?.timestamp, unreadCount: unread,
                   markedUnread: markedUnread, pinnedAt: pin.map { Clock.at(40, "12:00") - Int64($0) * 60 }, mutedUntil: muted ? Int64.max : nil,
                   archived: archived, readOnly: false)
    }

    var group: BridgeGroup? {
        guard isGroup else { return nil }
        let participants = ([Cast.me] + members).map {
            BridgeGroupParticipant(jid: $0.jid, isAdmin: admins.contains($0.jid), isSuperAdmin: false)
        }
        return BridgeGroup(jid: jid, subject: name, participantCount: UInt32(participants.count), participants: participants,
                           membershipChanged: false)
    }

    /// Shaped like the ids real clients send (`3EB0…`), stable across runs.
    private static func messageId(chat: String, index: Int) -> String {
        let digest = SHA256.hash(data: Data("\(chat)#\(index)".utf8))
        return "3EB0" + digest.prefix(9).map { String(format: "%02X", $0) }.joined()
    }
}

/// Files under `media/`. `directPath` carries the file name; the demo bridge "downloads" by copying it.
struct MediaLibrary {
    let dir: URL

    func photo(_ name: String) throws -> BridgeMedia {
        let data = try Data(contentsOf: dir.appending(path: name))
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        return media(name, data, type: .image, mime: "image/jpeg",
                     width: props[kCGImagePropertyPixelWidth] as? Int, height: props[kCGImagePropertyPixelHeight] as? Int,
                     thumbnail: Self.thumbnail(CGImageSourceCreateImageAtIndex(source, 0, nil)!))
    }

    func voice(_ name: String) throws -> BridgeMedia {
        let url = dir.appending(path: name)
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        return media(name, try Data(contentsOf: url), type: .audio, mime: "audio/mp4",
                     duration: Int(seconds.rounded()), waveform: try Self.waveform(file))
    }

    func pdf(_ name: String) throws -> BridgeMedia {
        let url = dir.appending(path: name)
        let doc = CGPDFDocument(url as CFURL)!
        return media(name, try Data(contentsOf: url), type: .document, mime: "application/pdf", fileName: name,
                     pages: doc.numberOfPages, thumbnail: Self.pageThumbnail(doc.page(at: 1)!))
    }

    private func media(_ name: String, _ data: Data, type: BridgeMediaType, mime: String, fileName: String? = nil,
                       width: Int? = nil, height: Int? = nil, duration: Int? = nil, pages: Int? = nil,
                       thumbnail: Data? = nil, waveform: Data? = nil) -> BridgeMedia {
        let sha = Data(SHA256.hash(data: data))
        return BridgeMedia(
            directPath: "demo/\(name)", mediaKey: Data(count: 32), fileSha256: sha, fileEncSha256: sha,
            fileLength: UInt64(data.count), mediaType: type, mimetype: mime, fileName: fileName,
            width: width.map(UInt32.init), height: height.map(UInt32.init), durationSecs: duration.map(UInt32.init),
            jpegThumbnail: thumbnail, waveform: waveform, pageCount: pages.map(UInt32.init), isAnimated: nil)
    }

    /// The small blurred-looking JPEG WhatsApp shows before a download.
    private static func thumbnail(_ image: CGImage, maxPixel: Int = 64) -> Data {
        let scale = CGFloat(maxPixel) / CGFloat(max(image.width, image.height))
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return jpeg(ctx.makeImage()!, quality: 0.6)
    }

    private static func pageThumbnail(_ page: CGPDFPage) -> Data {
        let box = page.getBoxRect(.mediaBox)
        let w = 240, h = Int(240 * box.height / box.width)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(w) / box.width, y: CGFloat(h) / box.height)
        ctx.drawPDFPage(page)
        return jpeg(ctx.makeImage()!, quality: 0.7)
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// 64 peaks scaled to 0…100, as WhatsApp stores them.
    private static func waveform(_ file: AVAudioFile) throws -> Data {
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let bucket = max(1, samples.count / 64)
        let peaks = (0..<64).map { i in
            samples[min(i * bucket, samples.count)..<min((i + 1) * bucket, samples.count)].reduce(Float(0)) { max($0, abs($1)) }
        }
        let top = peaks.max().flatMap { $0 > 0 ? $0 : nil } ?? 1
        return Data(peaks.map { UInt8(min(100, 8 + 92 * $0 / top)) })
    }
}
