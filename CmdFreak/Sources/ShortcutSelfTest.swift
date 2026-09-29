#if DEBUG
import AppKit
import WAKit
import WAMacUI

/// `CMDFREAK_SELFTEST=1` (with `CMDFREAK_SEED`): drives every shortcut through main-menu key
/// equivalent matching (`NSMenu.performKeyEquivalent`, so matching and validation are real), the
/// command bar's key handler, and the main window's first responder, then logs PASS/FAIL per
/// check to stdout. Command-bar snapshots land in `CMDFREAK_SNAPSHOT` if set.
@MainActor
enum ShortcutSelfTest {
    private static var failures = 0
    private static weak var main: MainWindowController?

    static func run(_ main: MainWindowController, client: WAClient, snapshotDir: String?) async {
        NSApp.activate()
        main.window?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(600))
        self.main = main
        log("key window: \(NSApp.keyWindow?.identifier?.rawValue ?? "nil"), active: \(NSApp.isActive)")
        log("split widths: \(main.debugSplitWidths)")
        // A locked or inactive session has no key window, so nil-targeted actions reach nothing.
        // Point window-level menu items at the controller and let validation assume key status.
        MainWindowController.debugAssumeKeyWindow = true
        retarget(NSApp.mainMenu, to: main)
        dumpMenu()

        // ⌘K → type → Enter opens the chat.
        main.selectChat(at: 0)
        check("⌘K is a menu key equivalent", await menu("k", 40, [.command]))
        check("⌘K shows the bar", main.debugCommandBar.visible)
        let target = main.visibleChatJids(limit: 40)[25]
        let targetTitle = main.chatTitle(target) ?? ""
        let typed = String(targetTitle.prefix(5))
        main.debugSetCommandBarQuery(typed)
        try? await Task.sleep(for: .milliseconds(300))
        log("query '\(main.debugCommandBar.query)' results: \(main.debugCommandBar.results.prefix(6))")
        if let dir = snapshotDir {
            save(main.debugRenderCommandBar(), dir, "commandbar-query")
            save(main.debugRenderCommandBar(dark: true), dir, "commandbar-query-dark")
        }
        await bar("j", 38, [.control])
        check("⌃J moves selection down", main.debugCommandBar.selectedIndex == 1)
        await bar("k", 40, [.control])
        check("⌃K moves selection up", main.debugCommandBar.selectedIndex == 0)
        await bar("n", 45, [.control])
        await bar("n", 45, [.control])
        await bar("p", 35, [.control])
        check("⌃N / ⌃P move selection", main.debugCommandBar.selectedIndex == 1)
        await bar(key(NSDownArrowFunctionKey), 125, [.numericPad, .function])
        await bar(key(NSUpArrowFunctionKey), 126, [.numericPad, .function])
        await bar(key(NSUpArrowFunctionKey), 126, [.numericPad, .function])
        check("↑ / ↓ move selection", main.debugCommandBar.selectedIndex == 0)
        let expectedTop = main.debugCommandBar.results.first ?? ""
        await bar("\r", 36, [])
        try? await Task.sleep(for: .milliseconds(300))
        check("Enter closes the bar", !main.debugCommandBar.visible)
        check("Enter opens the typed chat (\(targetTitle) → top result \(expectedTop))",
              main.selectedChatJid == target && expectedTop.hasPrefix(targetTitle))

        // Fast typing: Enter before the last keystroke's results arrive still opens the right chat.
        await menu("k", 40, [.command])
        let other = main.visibleChatJids(limit: 40)[30]
        let otherTitle = main.chatTitle(other) ?? ""
        main.debugSetCommandBarQuery(otherTitle)
        await bar("\r", 36, [], wait: 0)
        try? await Task.sleep(for: .milliseconds(400))
        check("Enter right after typing waits for results",
              main.selectedChatJid.flatMap(main.chatTitle) == otherTitle && !main.debugCommandBar.visible)

        // Empty-query snapshot and actions.
        await menu("k", 40, [.command])
        try? await Task.sleep(for: .milliseconds(300))
        log("recent: \(main.debugCommandBar.results.prefix(8))")
        if let dir = snapshotDir { save(main.debugRenderCommandBar(), dir, "commandbar-recent") }
        main.debugSetCommandBarQuery("mute")
        try? await Task.sleep(for: .milliseconds(300))
        log("results for 'mute': \(main.debugCommandBar.results.prefix(4))")
        check("actions match the query", main.debugCommandBar.results.first?.hasSuffix("[action]") == true)
        if let dir = snapshotDir { save(main.debugRenderCommandBar(), dir, "commandbar-actions") }
        let muteJid = main.selectedChatJid!
        let wasMuted = main.debugChat(muteJid)?.isMuted() ?? false
        await bar("\r", 36, [])
        try? await Task.sleep(for: .milliseconds(400))
        check("Enter runs the action on the current chat (mute toggled)", main.debugChat(muteJid)?.isMuted() == !wasMuted)
        await menu("k", 40, [.command])
        await menu("k", 40, [.command])
        check("⌘K toggles the bar closed", !main.debugCommandBar.visible)

        // ⌘N scoped to contacts; start a DM with a contact that has no chat.
        check("⌘N is a menu key equivalent", await menu("n", 45, [.command]))
        check("⌘N opens the contacts scope", main.debugCommandBar.visible && main.debugCommandBar.contactsScope)
        main.debugSetCommandBarQuery("quinn")
        try? await Task.sleep(for: .milliseconds(300))
        log("contacts for 'quinn': \(main.debugCommandBar.results.prefix(4))")
        if let dir = snapshotDir { save(main.debugRenderCommandBar(), dir, "commandbar-contacts") }
        await bar("\r", 36, [])
        try? await Task.sleep(for: .milliseconds(800))
        check("Enter on a contact without a chat creates and opens it",
              main.selectedChatJid == Seed.newContactJid(0) && main.chatTitle(Seed.newContactJid(0)) == "Quinn Harper")
        await menu("k", 40, [.command])
        main.debugSetCommandBarQuery("new ch")
        try? await Task.sleep(for: .milliseconds(300))
        await bar("\r", 36, [])
        check("'New Chat' action switches the open bar to contacts", main.debugCommandBar.visible && main.debugCommandBar.contactsScope)
        await bar("\u{1b}", 53, [])
        check("Esc closes the bar", !main.debugCommandBar.visible)

        // Navigation.
        main.selectChat(at: 3)
        let jids = main.visibleChatJids(limit: 10)
        await menu("]", 30, [.command])
        check("⌘] next chat", main.selectedChatJid == jids[4])
        await menu("[", 33, [.command])
        check("⌘[ previous chat", main.selectedChatJid == jids[3])
        await menu("\t", 48, [.control])
        check("⌃Tab next chat", main.selectedChatJid == jids[4])
        await menu("\u{19}", 48, [.control, .shift])
        check("⌃⇧Tab previous chat", main.selectedChatJid == jids[3])
        await menu("}", 30, [.command, .shift])
        check("⇧⌘] next chat", main.selectedChatJid == jids[4])
        await menu("{", 33, [.command, .shift])
        check("⇧⌘[ previous chat", main.selectedChatJid == jids[3])
        await menu(key(NSDownArrowFunctionKey), 125, [.option, .numericPad, .function])
        let downUnread = main.selectedChatJid
        check("⌥↓ next unread chat", downUnread != jids[3] && downUnread.map(main.chatShowsUnread) == true)
        await menu(key(NSUpArrowFunctionKey), 126, [.option, .numericPad, .function])
        check("⌥↑ previous unread chat", main.selectedChatJid != downUnread && main.selectedChatJid.map(main.chatShowsUnread) == true)
        await menu("1", 18, [.command])
        check("⌘1 first pinned chat", main.selectedChatJid != nil && main.selectedChatJid == main.debugPinnedJids().first)
        await menu("2", 19, [.command])
        check("⌘2 second pinned chat", main.selectedChatJid != nil && main.selectedChatJid == main.debugPinnedJids().dropFirst().first)

        // Chat actions on the selected chat.
        main.selectChat(at: 8)
        let jid = main.selectedChatJid!
        let before = main.debugChat(jid)!
        await menu("p", 35, [.command, .shift], wait: 300)
        check("⇧⌘P pin", main.debugChat(jid)?.isPinned == !before.isPinned)
        await menu("m", 46, [.command, .shift], wait: 300)
        check("⇧⌘M mute", main.debugChat(jid)?.isMuted() == !before.isMuted())
        await menu("u", 32, [.command, .shift], wait: 300)
        let unreadNow = main.debugChat(jid).map { $0.unreadCount > 0 || $0.markedUnread }
        check("⇧⌘U toggle unread", unreadNow == !(before.unreadCount > 0 || before.markedUnread))
        await menu("a", 0, [.command, .shift], wait: 300)
        check("⇧⌘A archive", main.debugChat(jid) == nil)

        // Rail.
        await menu("5", 23, [.command, .option])
        check("⌥⌘5 archived filter", main.debugRailIsArchived)
        await menu("1", 18, [.command, .option])
        check("⌥⌘1 chats filter", !main.debugRailIsArchived)
        await menu(key(NSDownArrowFunctionKey), 125, [.command, .option, .numericPad, .function])
        check("⌥⌘↓ next sidebar item", main.debugRailTitle == "Unread")
        await menu(key(NSUpArrowFunctionKey), 126, [.command, .option, .numericPad, .function])
        check("⌥⌘↑ previous sidebar item", main.debugRailTitle == "Chats")
        check("⌥⌘↑ disabled on the first sidebar item", !isEnabled(key(NSUpArrowFunctionKey), [.command, .option]))
        await menu("]", 30, [.command, .option])
        check("⌥⌘] next sidebar item", main.debugRailTitle == "Unread")
        await menu("[", 33, [.command, .option])
        check("⌥⌘[ previous sidebar item", main.debugRailTitle == "Chats")
        let widthsBefore = main.debugSplitWidths
        main.debugToggleSidebar()
        try? await Task.sleep(for: .milliseconds(400))
        let widthsToggled = main.debugSplitWidths
        main.debugToggleSidebar()
        try? await Task.sleep(for: .milliseconds(400))
        check("toggling the sidebar keeps the chat list's width (\(widthsBefore) → \(widthsToggled) → \(main.debugSplitWidths))",
              widthsToggled[0] != widthsBefore[0] && abs(widthsToggled[1] - widthsBefore[1]) < 1 && main.debugSplitWidths == widthsBefore)

        // Focus lives in the open chat: switching chats lands in its composer, the list never
        // takes focus, and Esc never leaves the chat.
        let listJids = main.visibleChatJids(limit: 5)
        main.selectChat(at: 1)
        check("opening a chat focuses its composer", main.debugFirstResponder.contains("ComposeTextView"))
        await menu("]", 30, [.command])
        check("⌘] keeps focus in the composer", main.selectedChatJid == listJids[2] && main.debugFirstResponder.contains("ComposeTextView"))
        check("the chat list refuses focus", main.debugListRefusesFocus())
        check("Esc in the composer with nothing to cancel is not claimed", !(await menu("\u{1b}", 53, [])))
        await command(#selector(NSResponder.cancelOperation(_:)))
        check("Esc in the composer keeps the chat and its focus",
              main.selectedChatJid == listJids[2] && main.debugFirstResponder.contains("ComposeTextView"))
        check("Space is not claimed by Quick Look without a media selection", !(await menu(" ", 49, [])))
        main.debugClickRow(at: 3)
        try? await Task.sleep(for: .milliseconds(150))
        check("a click on a row opens it and focuses its composer",
              main.selectedChatJid == listJids[3] && main.debugFirstResponder.contains("ComposeTextView"))
        main.debugCommandClickSelectedRow()
        try? await Task.sleep(for: .milliseconds(150))
        check("⌘-click does not deselect the open chat", main.selectedChatJid == listJids[3] && main.chatContainer.chatJid == listJids[3])

        // Search: ⌘F focuses it, ↑/↓ move the open chat while it keeps focus, Return and Esc hand off.
        check("⌘F focuses search", await menu("f", 3, [.command]) && main.debugSearchIsEditing)
        let searchJids = main.visibleChatJids(limit: 60)
        let start = main.selectedChatJid.flatMap { searchJids.firstIndex(of: $0) } ?? 0
        await command(#selector(NSResponder.moveDown(_:)))
        check("↓ in search opens the next chat", main.selectedChatJid == searchJids[start + 1])
        await command(#selector(NSResponder.moveUp(_:)))
        check("↑ in search opens the previous chat", main.selectedChatJid == searchJids[start])
        check("search keeps focus while ↑/↓ move", main.debugSearchIsEditing)
        await command(#selector(NSResponder.insertNewline(_:)))
        check("Return in search focuses the composer", main.debugFirstResponder.contains("ComposeTextView"))
        await menu("f", 3, [.command])
        await command(#selector(NSResponder.cancelOperation(_:)))
        check("Esc in search focuses the composer", main.debugFirstResponder.contains("ComposeTextView"))

        // Disabled items.
        check("⌘F present and enabled", menuItem("f", [.command]) != nil && isEnabled("f", [.command]))
        check("⇧⌘O present and enabled with a chat open",
              menuItem("o", [.command, .shift]) != nil && isEnabled("o", [.command, .shift]) == (main.chatContainer.chatJid != nil))
        let quickLook = NSApp.mainMenu?.item(withTitle: "Chat")?.submenu?.item(withTitle: "Quick Look")
        quickLook.map { $0.menu?.delegate?.menuWillOpen?($0.menu!) }
        check("Space Quick Look listed with its shortcut when the menu opens", quickLook?.keyEquivalent == " ")
        quickLook.map { $0.menu?.delegate?.menuDidClose?($0.menu!) }

        retarget(NSApp.mainMenu, to: nil)
        MainWindowController.debugAssumeKeyWindow = false
        log(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    }

    // MARK: Event paths

    /// A keyboard-layout-backed event (via CGEvent), as the hardware would produce; `chars` is only
    /// used if CGEvent translation yields nothing.
    private static func event(_ chars: String, _ keyCode: UInt16, _ mods: NSEvent.ModifierFlags) -> NSEvent {
        if let cg = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            var flags: CGEventFlags = []
            if mods.contains(.command) { flags.insert(.maskCommand) }
            if mods.contains(.shift) { flags.insert(.maskShift) }
            if mods.contains(.control) { flags.insert(.maskControl) }
            if mods.contains(.option) { flags.insert(.maskAlternate) }
            if mods.contains(.function) { flags.insert(.maskSecondaryFn) }
            if mods.contains(.numericPad) { flags.insert(.maskNumericPad) }
            cg.flags = flags
            if let e = NSEvent(cgEvent: cg), e.characters?.isEmpty == false { return e }
        }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: main?.window?.windowNumber ?? 0, context: nil, characters: chars,
                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    }

    /// Main-menu key-equivalent matching, validation and dispatch (after the plain-key monitor's refresh).
    @discardableResult
    private static func menu(_ chars: String, _ keyCode: UInt16, _ mods: NSEvent.ModifierFlags, wait: Int = 150) async -> Bool {
        if mods.isDisjoint(with: [.command, .control, .option]) { PlainKeyEquivalents.shared.refresh() }
        let handled = NSApp.mainMenu?.performKeyEquivalent(with: event(chars, keyCode, mods)) ?? false
        try? await Task.sleep(for: .milliseconds(wait))
        return handled
    }

    /// A key binding's command on the main window's first responder, as the text input system would
    /// send it (synthetic keys do not reach text views without an active input context).
    private static func command(_ selector: Selector) async {
        main?.window?.firstResponder?.doCommand(by: selector)
        try? await Task.sleep(for: .milliseconds(80))
    }

    /// The command bar's key-monitor handler.
    private static func bar(_ chars: String, _ keyCode: UInt16, _ mods: NSEvent.ModifierFlags, wait: Int = 120) async {
        main?.debugCommandBarKey(event(chars, keyCode, mods))
        if wait > 0 { try? await Task.sleep(for: .milliseconds(wait)) }
    }

    /// Plain key delivery to the main window's first responder.
    private static func view(_ chars: String, _ keyCode: UInt16, _ mods: NSEvent.ModifierFlags) async {
        main?.window?.sendEvent(event(chars, keyCode, mods))
        try? await Task.sleep(for: .milliseconds(80))
    }

    private static func retarget(_ menu: NSMenu?, to target: MainWindowController?) {
        for item in menu?.items ?? [] {
            if let action = item.action, MainWindowController.instancesRespond(to: action) { item.target = target }
            retarget(item.submenu, to: target)
        }
    }

    // MARK: Helpers

    private static func log(_ s: String) {
        print("[selftest] \(s)")
        fflush(stdout)
    }

    private static func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        log("\(ok ? "PASS" : "FAIL") \(name)")
    }

    private static func key(_ functionKey: Int) -> String {
        String(Character(UnicodeScalar(functionKey)!))
    }

    private static func menuItem(_ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem? {
        func search(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.keyEquivalent == key, item.keyEquivalentModifierMask == mods { return item }
                if let sub = item.submenu, let hit = search(sub) { return hit }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }

    private static func isEnabled(_ key: String, _ mods: NSEvent.ModifierFlags) -> Bool {
        guard let item = menuItem(key, mods) else { return false }
        item.menu?.update()
        return item.isEnabled
    }

    private static func dumpMenu() {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let sub = top.submenu else { continue }
            sub.update()
            for item in sub.items where !item.keyEquivalent.isEmpty || item.submenu != nil {
                if let s2 = item.submenu {
                    s2.update()
                    for i in s2.items { log("menu \(top.title) › \(item.title) › \(i.title) \(describe(i))") }
                } else {
                    log("menu \(top.title) › \(item.title) \(describe(item))")
                }
            }
        }
    }

    private static func describe(_ item: NSMenuItem) -> String {
        let m = item.keyEquivalentModifierMask
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        let k: String = switch item.keyEquivalent {
        case "\t": "Tab"
        case "\u{1b}": "Esc"
        case " ": "Space"
        case key(NSUpArrowFunctionKey): "↑"
        case key(NSDownArrowFunctionKey): "↓"
        default: item.keyEquivalent.uppercased()
        }
        return "[\(s)\(k)]\(item.isEnabled ? "" : " (disabled)")"
    }

    private static func save(_ image: CGImage?, _ dir: String, _ name: String) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(filePath: dir).appending(path: "\(name).png"))
    }
}
#endif
