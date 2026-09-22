import AppKit

// yan yana diff penceresi: solda eski (revizyon), sağda çalışma kopyası
final class DiffWindowController: NSWindowController {
    struct Row {
        var old: Int
        var new: Int
        var kind: Character  // ' ' eşit, '-' silinen, '+' eklenen, '~' değişen
    }

    private static var open: [DiffWindowController] = []

    private let table = NSTableView()
    private var rows: [Row] = []
    private var base: [String] = []
    private var current: [String] = []

    static func show(title: String, rows: [Row], base: [String], current: [String]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        let c = DiffWindowController(window: window)
        c.rows = rows
        c.base = base
        c.current = current
        c.build()
        window.center()
        c.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        open.append(c)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            open.removeAll { $0 === c }
        }
    }

    private func build() {
        guard let window else { return }
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        for (id, title, width) in [("oldNo", "", 50.0), ("old", "Revision", 430.0),
                                   ("newNo", "", 50.0), ("new", "Working copy", 430.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            table.addTableColumn(col)
        }
        table.rowHeight = 17
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        window.contentView = scroll
        // ilk farka kaydır
        if let i = rows.firstIndex(where: { $0.kind != " " }) {
            table.scrollRowToVisible(min(rows.count - 1, i + 12))
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
    }

    private func text(_ lines: [String], _ index: Int) -> String {
        index >= 0 && index < lines.count ? lines[index] : ""
    }
}

extension DiffWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let r = rows[row]
        let cellID = NSUserInterfaceItemIdentifier("diffCell")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = cellID
            let f = NSTextField(labelWithString: "")
            f.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            f.lineBreakMode = .byTruncatingTail
            f.drawsBackground = true
            c.textField = f
            c.addSubview(f)
            return c
        }()
        let isOld = id.hasPrefix("old")
        let index = isOld ? r.old : r.new
        let number = id.hasSuffix("No")
        let value = number ? (index >= 0 ? String(index + 1) : "") : text(isOld ? base : current, index)
        cell.textField?.stringValue = value
        cell.textField?.alignment = number ? .right : .left
        cell.textField?.textColor = number ? Palette.dimText : Palette.text
        var color = NSColor.clear
        if index < 0 {
            color = Palette.hover
        } else if r.kind == "~" {
            color = (isOld ? NSColor.systemRed : .systemGreen).withAlphaComponent(0.14)
        } else if r.kind == "-" {
            color = NSColor.systemRed.withAlphaComponent(0.14)
        } else if r.kind == "+" {
            color = NSColor.systemGreen.withAlphaComponent(0.14)
        }
        cell.textField?.backgroundColor = color
        cell.textField?.frame = NSRect(x: 2, y: 0, width: max(10, (tableColumn?.width ?? 100) - 4), height: 16)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
}
