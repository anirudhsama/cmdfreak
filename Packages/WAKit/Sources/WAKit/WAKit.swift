import Foundation
import os
@_exported import GRDB
@_exported import WACoreFFI

public enum WAKit {
    public static let log = Logger(subsystem: "live.gosupernova.BetterWA", category: "WAKit")

    public static func bridgeVersion() -> String {
        bridgeHello()
    }
}
