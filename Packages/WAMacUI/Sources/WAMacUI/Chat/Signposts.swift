import os
import WAKit

/// Points of interest for the open-chat, send and scroll paths. Visible in Instruments.
enum Signposts {
    static let poi = OSSignposter(subsystem: WAKit.subsystem, category: .pointsOfInterest)
    static let log = Logger(subsystem: WAKit.subsystem, category: "Chat")
}
