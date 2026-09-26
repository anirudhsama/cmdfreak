import AppKit
import WAKit
import WAMacUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var client: WAClient!
    private var mainWindow: MainWindowController?
    private var onboarding: OnboardingWindowController?
    private var onboardingModel: OnboardingModel?
    private var sessionToken: ObservationToken?
    private var liveSeedTask: Task<Void, Never>?
    /// Debug: onboarding forced by `BETTERWA_ONBOARDING`, so no bridge calls are made.
    private var inertOnboarding: OnboardingModel.Method?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        WAKit.log.info("\(WAKit.bridgeVersion(), privacy: .public)")
        do {
            client = try makeClient()
        } catch {
            presentFatal("BetterWA could not open its database.", error)
            return
        }
        NSApp.mainMenu = MainMenu.build()

        #if DEBUG
        if let forced = DevSupport.forcedOnboarding {
            inertOnboarding = DevSupport.applyForcedOnboarding(forced, to: client.session)
        }
        #endif

        sessionToken = WAMacUI.observe { [weak self] in self?.updateWindows() }

        #if DEBUG
        if let count = DevSupport.seedCount {
            Task { await self.runSeed(count: count) }
            return
        }
        Task { await DevSupport.runSnapshots(main: nil) }
        #endif
        if inertOnboarding == nil, client.session.state == .ready {
            Task { [client] in
                do { try await client!.connect() } catch { WAKit.log.error("connect failed: \(error)") }
            }
        }
        NSApp.activate()
    }

    private func makeClient() throws -> WAClient {
        #if DEBUG
        if DevSupport.seedCount != nil {
            let dir = try DevSupport.seedDirectory()
            return try WAClient(database: AppDatabase(url: dir.appending(path: "app.sqlite")), dataDir: dir)
        }
        #endif
        return try WAClient(database: AppDatabase.openDefault())
    }

    /// Onboarding until the first history chunk lands (or when logged out); the main window otherwise.
    private func updateWindows() {
        let session = client.session
        if session.canShowMainWindow {
            onboarding?.close()
            onboarding = nil
            onboardingModel = nil
            let window = mainWindow ?? MainWindowController(client: client)
            mainWindow = window
            window.showWindow(nil)
        } else {
            mainWindow?.window?.orderOut(nil)
            if onboarding == nil {
                let model = OnboardingModel(client: client, initialMethod: inertOnboarding ?? .qr)
                model.isInert = inertOnboarding != nil
                onboardingModel = model
                onboarding = OnboardingWindowController(model: model)
                if case .unpaired = session.state { model.start() }
            }
            onboarding?.showWindow(nil)
        }
    }

    // MARK: Actions

    @objc func logOut(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Log out of WhatsApp on this Mac?"
        alert.informativeText = "Your chats stay on your phone. You will need to scan the QR code again to link this Mac."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Log Out")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { [client] in
            do {
                try await client!.logout()
            } catch {
                WAKit.log.error("logout failed: \(error)")
                let failure = NSAlert()
                failure.messageText = "Could not log out"
                failure.informativeText = error.localizedDescription
                failure.runModal()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { updateWindows() }
        return true
    }

    private func presentFatal(_ message: String, _ error: any Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: Debug seed

    #if DEBUG
    private func runSeed(count: Int) async {
        do {
            let started = Date()
            try await Seed.populate(client, count: count)
            WAKit.log.info("seeded \(count) chats in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        } catch {
            presentFatal("Seeding failed.", error)
            return
        }
        NSApp.activate()
        if DevSupport.seedLive, let window = mainWindow {
            liveSeedTask = Task { await Seed.runLiveTraffic(client, window: window, count: count) }
        }
        await DevSupport.runSnapshots(main: mainWindow)
    }
    #endif
}
