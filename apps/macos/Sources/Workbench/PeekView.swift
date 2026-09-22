import AppKit

// peek: imlecin altında açılan küçük tanım/referans listesi (⌥F12 / ⇧F12)
final class PeekView: FlippedView {
    struct Row {
        var file: String
        var line: Int
        var text: String
        var open: () -> Void
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var rows: [Row] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.widget
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        border = Palette.inputBorder
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = Palette.dimText
        addSubview(titleLabel)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("peek"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 20
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(clicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title: String, rows: [Row], at p: NSPoint, in parent: NSView) {
        self.rows = rows
        titleLabel.stringValue = title
        table.reloadData()
        let w = min(640, max(320, parent.bounds.width - 40))
        let h = min(240, CGFloat(rows.count) * 20 + 26)
        var y = p.y + 4
        if y + h > parent.bounds.height { y = max(0, p.y - h - 20) }
        let x = min(max(4, p.x - 40), max(4, parent.bounds.width - w - 4))
        frame = NSRect(x: x, y: y, width: w, height: h)
        titleLabel.frame = NSRect(x: 8, y: 4, width: w - 16, height: 16)
        scroll.frame = NSRect(x: 0, y: 22, width: w, height: h - 22)
        if superview !== parent { parent.addSubview(self) }
        if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func hide() { removeFromSuperview() }

    @objc private func clicked() {
        let i = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard i >= 0, i < rows.count else { return }
        rows[i].open()
    }
}

extension PeekView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("peekCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let f = NSTextField(labelWithString: "")
            f.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            f.lineBreakMode = .byTruncatingTail
            c.textField = f
            c.addSubview(f)
            return c
        }()
        let r = rows[row]
        cell.textField?.stringValue = "\(r.file):\(r.line + 1)  \(r.text)"
        cell.textField?.textColor = Palette.text
        cell.textField?.frame = NSRect(x: 6, y: 1, width: tableView.bounds.width - 12, height: 17)
        return cell
    }
}
