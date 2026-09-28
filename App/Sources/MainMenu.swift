import AppKit
import WAMacUI

/// The main menu, built in code. Every shell shortcut is an item here so it shows in the menu
/// bar and in Help search. Actions target nil and resolve through the responder chain to
/// `MainWindowController` (chat and navigation) or `AppDelegate` (log out).
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(app()))
        main.addItem(submenu(file()))
        main.addItem(submenu(edit()))
        main.addItem(submenu(view()))
        main.addItem(submenu(chat()))
        let window = window()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = help()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func app() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        menu.addItem(item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Log Out…", #selector(AppDelegate.logOut(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = item("Services", nil)
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func file() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Chat…", #selector(MainWindowController.newChat(_:)), "n"))
        menu.addItem(item("Attach File…", #selector(MainWindowController.attachFile(_:)), "o", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func edit() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        // Focuses the chat list's search field.
        menu.addItem(item("Find…", #selector(MainWindowController.focusSearch(_:)), "f"))
        menu.addItem(.separator())
        menu.addItem(item("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control]))
        return menu
    }

    private static func view() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Command Bar", #selector(MainWindowController.showCommandBar(_:)), "k"))
        menu.addItem(.separator())
        for (position, title) in ["Chats", "Unread", "Groups", "Archived"].enumerated() {
            let railItem = item(title, #selector(MainWindowController.selectRailItem(_:)), String(position + 1), [.command, .option])
            railItem.tag = position + 1
            menu.addItem(railItem)
        }
        menu.addItem(item("Previous Sidebar Item", #selector(MainWindowController.previousRailItem(_:)), key(NSUpArrowFunctionKey), [.command, .option]))
        menu.addItem(item("Next Sidebar Item", #selector(MainWindowController.nextRailItem(_:)), key(NSDownArrowFunctionKey), [.command, .option]))
        // ⌥⌘[ / ⌥⌘], alongside the chats' ⇧⌘[ / ⇧⌘]. Hidden: the arrows are the visible binding.
        menu.addItem(hidden(item("Show Previous Sidebar Item", #selector(MainWindowController.previousRailItem(_:)), "[", [.command, .option])))
        menu.addItem(hidden(item("Show Next Sidebar Item", #selector(MainWindowController.nextRailItem(_:)), "]", [.command, .option])))
        menu.addItem(.separator())
        menu.addItem(item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func chat() -> NSMenu {
        let menu = NSMenu(title: "Chat")
        menu.addItem(item("Next Chat", #selector(MainWindowController.nextChat(_:)), "]"))
        menu.addItem(item("Previous Chat", #selector(MainWindowController.previousChat(_:)), "["))
        menu.addItem(item("Next Unread Chat", #selector(MainWindowController.nextUnreadChat(_:)), key(NSDownArrowFunctionKey), [.option]))
        menu.addItem(item("Previous Unread Chat", #selector(MainWindowController.previousUnreadChat(_:)), key(NSUpArrowFunctionKey), [.option]))
        menu.addItem(.separator())
        menu.addItem(item("Mark as Unread", #selector(MainWindowController.toggleUnread(_:)), "u", [.command, .shift]))
        menu.addItem(item("Pin", #selector(MainWindowController.togglePin(_:)), "p", [.command, .shift]))
        menu.addItem(item("Mute", #selector(MainWindowController.toggleMute(_:)), "m", [.command, .shift]))
        menu.addItem(item("Archive", #selector(MainWindowController.toggleArchive(_:)), "a", [.command, .shift]))
        menu.addItem(.separator())
        // Esc and Space have no modifier, so they are armed only while live (see PlainKeyEquivalents).
        let escape = item("Cancel", #selector(MainWindowController.cancelTransientState(_:)), "\u{1b}", [])
        let quickLook = item("Quick Look", #selector(MainWindowController.quickLookSelection(_:)), " ", [])
        menu.addItem(escape)
        menu.addItem(quickLook)
        PlainKeyEquivalents.shared.manage([escape, quickLook], in: menu)
        menu.addItem(.separator())
        let pinned = NSMenu(title: "Pinned Chats")
        for n in 1...9 {
            let pinnedItem = item("Pinned Chat \(n)", #selector(MainWindowController.openPinnedChat(_:)), String(n))
            pinnedItem.tag = n
            pinned.addItem(pinnedItem)
        }
        let pinnedItem = item("Pinned Chats", nil)
        pinnedItem.submenu = pinned
        menu.addItem(pinnedItem)
        return menu
    }

    private static func window() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        // Tab-style chat switching, as Safari's Show Next/Previous Tab.
        menu.addItem(item("Show Next Chat", #selector(MainWindowController.nextChat(_:)), "\t", [.control]))
        menu.addItem(item("Show Previous Chat", #selector(MainWindowController.previousChat(_:)), "\t", [.control, .shift]))
        // Shift turns Tab into backtab (U+0019) in some event paths; catch that form too.
        let backtab = item("Show Previous Chat", #selector(MainWindowController.previousChat(_:)), "\u{19}", [.control, .shift])
        backtab.isHidden = true
        backtab.allowsKeyEquivalentWhenHidden = true
        menu.addItem(backtab)
        // ⇧⌘] / ⇧⌘[, as Safari's tab switching. Hidden, like Safari's: ⌃Tab is the visible binding.
        menu.addItem(hidden(item("Show Next Chat", #selector(MainWindowController.nextChat(_:)), "]", [.command, .shift])))
        menu.addItem(hidden(item("Show Previous Chat", #selector(MainWindowController.previousChat(_:)), "[", [.command, .shift])))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func help() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("CmdFreak Help", #selector(NSApplication.showHelp(_:)), "?"))
        return menu
    }

    // MARK: Helpers

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    private static func hidden(_ item: NSMenuItem) -> NSMenuItem {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    private static func key(_ functionKey: Int) -> String {
        String(Character(UnicodeScalar(functionKey)!))
    }
}
