import os

/// Points of interest for the open-chat, send and scroll paths. Visible in Instruments.
enum Signposts {
    static let poi = OSSignposter(subsystem: "live.gosupernova.BetterWA", category: .pointsOfInterest)
    static let log = Logger(subsystem: "live.gosupernova.BetterWA", category: "Chat")
}
