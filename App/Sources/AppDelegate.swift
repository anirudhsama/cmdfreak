import AppKit
import WAKit
import WAMacUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        WAKit.log.info("\(WAKit.bridgeVersion(), privacy: .public)")
        #if DEBUG
        if ChatHarness.launchIfRequested() { return }  // BETTERWA_CHAT_HARNESS=1: stand-alone chat view
        #endif
        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindow = controller
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
