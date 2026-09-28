import os

/// Points of interest for the open-chat, send and scroll paths. Visible in Instruments.
enum Signposts {
    static let poi = OSSignposter(subsystem: "net.anirudhs.CmdFreak", category: .pointsOfInterest)
    static let log = Logger(subsystem: "net.anirudhs.CmdFreak", category: "Chat")
}
