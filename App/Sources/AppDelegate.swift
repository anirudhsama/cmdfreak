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
        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindow = controller
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
