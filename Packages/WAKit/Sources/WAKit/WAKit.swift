import Foundation
import os
@_exported import GRDB
@_exported import WACoreFFI

public enum WAKit {
    public static let appName = "CmdFreak"
    /// Matches the bundle ID; used as the os_log subsystem.
    public static let subsystem = "net.anirudhs.CmdFreak"
    /// Folder name under Application Support and Caches. The demo app sets `CmdFreakStorageName` in
    /// its Info.plist so it never touches a real account's data.
    public static let storageName = Bundle.main.object(forInfoDictionaryKey: "CmdFreakStorageName") as? String ?? appName
    /// WhatsApp session, app database and captures. Losing this means re-pairing.
    public static let dataDirectory = URL.applicationSupportDirectory.appending(path: storageName, directoryHint: .isDirectory)
    /// Re-downloadable media and avatars.
    public static let cacheDirectory = URL.cachesDirectory.appending(path: storageName, directoryHint: .isDirectory)

    public static let log = Logger(subsystem: subsystem, category: "WAKit")

    public static func bridgeVersion() -> String {
        bridgeHello()
    }
}
