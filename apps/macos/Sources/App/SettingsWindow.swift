import AppKit

// ⌘, — sık kullanılan ayarlar için form; her değişiklik settings.json'a yazılır
final class SettingsWindowController: NSWindowController {
    private var controls: [(key: String, view: NSView)] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing

        func header(_ title: String) {
            let l = NSTextField(labelWithString: title)
            l.font = .boldSystemFont(ofSize: 13)
            grid.addRow(with: [l, NSGridCell.emptyContentView])
        }
        func row(_ label: String, _ key: String, _ view: NSView) {
            grid.addRow(with: [NSTextField(labelWithString: label), view])
            controls.append((key, view))
        }
        func number(_ key: String, _ range: ClosedRange<Double>) -> NSView {
            let field = NSTextField()
            field.formatter = {
                let f = NumberFormatter()
                f.minimum = NSNumber(value: range.lowerBound)
                f.maximum = NSNumber(value: range.upperBound)
                return f
            }()
            field.identifier = NSUserInterfaceItemIdentifier(key)
            field.target = self
            field.action = #selector(numberChanged(_:))
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            return field
        }
        func check(_ key: String, _ title: String) -> NSView {
            let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkChanged(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(key)
            return b
        }
        func popup(_ key: String, _ items: [(String, String)]) -> NSView {
            let p = NSPopUpButton()
            for (title, value) in items {
                p.addItem(withTitle: title)
                p.lastItem?.representedObject = value
            }
            p.identifier = NSUserInterfaceItemIdentifier(key)
            p.target = self
            p.action = #selector(popupChanged(_:))
            return p
        }

        header("Editor")
        row("Font size:", "editor.fontSize", number("editor.fontSize", 6...40))
        let family = NSTextField()
        family.placeholderString = "System monospace"
        family.identifier = NSUserInterfaceItemIdentifier("editor.fontFamily")
        family.target = self
        family.action = #selector(textChanged(_:))
        family.widthAnchor.constraint(equalToConstant: 220).isActive = true
        row("Font family:", "editor.fontFamily", family)
        row("Tab size:", "editor.tabSize", popup("editor.tabSize", [("2", "2"), ("4", "4"), ("8", "8")]))
        row("", "editor.insertSpaces", check("editor.insertSpaces", "Insert spaces"))
        row("", "editor.detectIndentation", check("editor.detectIndentation", "Detect indentation from file"))
        row("", "editor.wordWrap", check("editor.wordWrap", "Word wrap"))
        row("", "editor.minimap", check("editor.minimap", "Show minimap"))
        header("Files")
        row("", "files.trimTrailingWhitespace", check("files.trimTrailingWhitespace", "Trim trailing whitespace on save"))
        row("", "files.insertFinalNewline", check("files.insertFinalNewline", "Insert final newline on save"))
        header("Workbench")
        row("Color theme:", "workbench.colorTheme",
            popup("workbench.colorTheme", [("Follow System", "system"), ("Dark Modern", "dark"), ("Light Modern", "light")]
                  + Extensions.shared.themeNames.map { ($0, $0) }))
        header("AI")
        row("", "ai.inlineCompletion", check("ai.inlineCompletion", "Inline completions (Claude Haiku 4.5)"))
        row("", "lsp.enabled", check("lsp.enabled", "Language servers (LSP)"))
        row("", "editor.semanticHighlighting", check("editor.semanticHighlighting", "Semantic highlighting"))
        row("", "editor.inlayHints", check("editor.inlayHints", "Inlay hints"))
        header("Terminal")
        row("Font size:", "terminal.fontSize", number("terminal.fontSize", 6...40))
        row("Scrollback:", "terminal.scrollback", number("terminal.scrollback", 100...1_000_000))
        row("", "terminal.optionAsMeta", check("terminal.optionAsMeta", "Use Option as Meta key"))

        let json = NSButton(title: "Open settings.json", target: self, action: #selector(openJSON(_:)))
        let keys = NSButton(title: "Open keymap.json", target: self, action: #selector(openKeymap(_:)))
        let buttons = NSStackView(views: [json, keys])
        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        window?.contentView = stack
        refresh()
    }

    private func refresh() {
        let s = Settings.shared
        for (key, view) in controls {
            switch view {
            case let b as NSButton: b.state = s.bool(key) ? .on : .off
            case let p as NSPopUpButton:
                let v = key == "editor.tabSize" ? String(s.int(key)) : s.string(key)
                if let item = p.itemArray.first(where: { $0.representedObject as? String == v }) { p.select(item) }
            case let f as NSTextField:
                f.stringValue = key == "editor.fontFamily" ? s.string(key) : String(s.int(key))
            default: break
            }
        }
    }

    @objc private func checkChanged(_ b: NSButton) {
        Settings.shared.set(b.identifier!.rawValue, b.state == .on)
    }

    @objc private func popupChanged(_ p: NSPopUpButton) {
        guard let v = p.selectedItem?.representedObject as? String else { return }
        let key = p.identifier!.rawValue
        Settings.shared.set(key, key == "editor.tabSize" ? (Int(v) ?? 4) as Any : v)
    }

    @objc private func numberChanged(_ f: NSTextField) {
        Settings.shared.set(f.identifier!.rawValue, f.integerValue)
    }

    @objc private func textChanged(_ f: NSTextField) {
        Settings.shared.set(f.identifier!.rawValue, f.stringValue)
    }

    @objc private func openJSON(_ sender: Any?) {
        NSApp.sendAction(#selector(AppDelegate.openSettingsJSON(_:)), to: NSApp.delegate, from: self)
    }

    @objc private func openKeymap(_ sender: Any?) {
        NSApp.sendAction(#selector(AppDelegate.openKeymapJSON(_:)), to: NSApp.delegate, from: self)
    }
}
