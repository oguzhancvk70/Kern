import AppKit

enum MainMenu {
    private static let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    private static let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    private static let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)

    static func make() -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu("Kern", [
            item("About Kern", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Kern", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Kern", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("File", [
            item("New File", "newDocument:", "n"),
            item("New Window", "newWindowAction:", "n", [.command, .shift]),
            .separator(),
            item("Open…", "openDocument:", "o"),
            item("Open Folder…", "openFolder:", "o", [.command, .shift]),
            .separator(),
            item("Save", "saveDocument:", "s"),
            item("Save As…", "saveDocumentAs:", "s", [.command, .shift]),
            item("Save All", "saveAllDocuments:", "s", [.command, .option]),
            .separator(),
            item("Close Editor", "closeEditor:", "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", "undo:", "z"),
            item("Redo", "redo:", "z", [.command, .shift]),
            .separator(),
            item("Cut", "cut:", "x"),
            item("Copy", "copy:", "c"),
            item("Paste", "paste:", "v"),
            .separator(),
            item("Find", "showFind:", "f"),
            item("Replace", "showReplace:", "f", [.command, .option]),
            item("Find Next", "findNextMatch:", "g"),
            item("Find Previous", "findPreviousMatch:", "g", [.command, .shift]),
            .separator(),
            item("Toggle Line Comment", "toggleLineComment:", "/"),
        ]))

        main.addItem(submenu("Selection", [
            item("Select All", "selectAll:", "a"),
            .separator(),
            item("Add Cursor Above", "addCursorAbove:", up, [.command, .option]),
            item("Add Cursor Below", "addCursorBelow:", down, [.command, .option]),
            item("Add Next Occurrence", "addNextOccurrence:", "d"),
            item("Select All Occurrences", "selectAllOccurrences:", "l", [.command, .shift]),
            .separator(),
            item("Copy Line Up", "copyLineUp:", up, [.option, .shift]),
            item("Copy Line Down", "copyLineDown:", down, [.option, .shift]),
            item("Move Line Up", "moveLineUp:", up, [.option]),
            item("Move Line Down", "moveLineDown:", down, [.option]),
            item("Delete Line", "deleteLine:", "k", [.command, .shift]),
            .separator(),
            item("Indent Line", "indentLines:", "]"),
            item("Outdent Line", "outdentLines:", "["),
        ]))

        main.addItem(submenu("View", [
            item("Command Palette…", "showCommands:", "p", [.command, .shift]),
            .separator(),
            item("Explorer", "showExplorer:", "e", [.command, .shift]),
            item("Search", "showSearch:", "f", [.command, .shift]),
            item("Toggle Sidebar", "toggleSidebarVisibility:", "b"),
            item("Terminal", "toggleTerminal:", "`", [.control]),
            .separator(),
            item("Zoom In", "zoomIn:", "="),
            item("Zoom Out", "zoomOut:", "-"),
            item("Reset Zoom", "resetZoom:", "0"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        main.addItem(submenu("Go", [
            item("Go to File…", "quickOpen:", "p"),
            item("Go to Line…", "goToLine:", "g", [.control]),
            .separator(),
            item("Next Editor", "nextEditor:", right, [.command, .option]),
            item("Previous Editor", "previousEditor:", left, [.command, .option]),
        ]))

        main.addItem(submenu("Terminal", [
            item("New Terminal", "newTerminal:", "`", [.control, .shift]),
            item("Toggle Terminal", "toggleTerminal:"),
            .separator(),
            item("Clear", "clearTerminal:", "k"),
        ]))

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        return main
    }

    // komut paleti: menüdeki tüm eylemler
    static func commands() -> [PaletteItem] {
        guard let main = NSApp.mainMenu else { return [] }
        var out: [PaletteItem] = []
        for top in main.items where top.title != "Kern" && top.title != "Window" {
            for item in top.submenu?.items ?? [] where !item.isSeparatorItem && item.action != nil {
                guard let action = item.action, action != #selector(NSApplication.terminate(_:)) else { continue }
                out.append(PaletteItem(title: "\(top.title): \(item.title)", key: shortcut(item)) {
                    NSApp.sendAction(action, to: item.target, from: item)
                })
            }
        }
        return out
    }

    private static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let m = item.keyEquivalentModifierMask
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        let key: String
        switch item.keyEquivalent {
        case up: key = "↑"
        case down: key = "↓"
        case left: key = "←"
        case right: key = "→"
        default: key = item.keyEquivalent.uppercased()
        }
        return s + key
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func item(_ title: String, _ action: String, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        item(title, Selector(action), key, modifiers)
    }
}
