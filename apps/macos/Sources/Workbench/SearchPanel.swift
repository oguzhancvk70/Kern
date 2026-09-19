import AppKit

final class SearchGroup: NSObject {
    let path: String
    var hits: [SearchHit] = []
    init(path: String) { self.path = path }
}

final class SearchHit: NSObject {
    let path: String
    let line: Int
    let col: Int
    let len: Int
    let text: String

    init(path: String, line: Int, col: Int, len: Int, text: String) {
        self.path = path
        self.line = line
        self.col = col
        self.len = len
        self.text = text
    }
}

private final class ResultCell: NSTableCellView {
    let icon = NSImageView()
    let label = makeLabel("")

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let hasIcon = icon.image != nil
        icon.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let x: CGFloat = hasIcon ? 21 : 2
        label.frame = NSRect(x: x, y: (bounds.height - 17) / 2, width: bounds.width - x - 4, height: 17)
    }
}

final class SearchPanel: FlippedView, NSTextFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSearch: ((String, Bool, @escaping (String) -> Void) -> Void)?
    var onOpen: ((SearchHit) -> Void)?

    let input = InputBox(placeholder: "Search")
    private let title = makeLabel("SEARCH", size: 11, color: Palette.dimText)
    private let caseButton = NSButton(title: "Aa", target: nil, action: nil)
    private let summary = makeLabel("", size: 12, color: Palette.dimText)
    private let scroll = NSScrollView()
    private let outline = NSOutlineView()
    private var groups: [SearchGroup] = []
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var caseSensitive = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.chrome
        input.field.delegate = self
        input.trailingInset = 32

        caseButton.isBordered = false
        caseButton.font = .systemFont(ofSize: 12, weight: .semibold)
        caseButton.contentTintColor = Palette.dimText
        caseButton.toolTip = "Match Case"
        caseButton.target = self
        caseButton.action = #selector(toggleCase)

        let column = NSTableColumn(identifier: .init("result"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = Palette.chrome
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.focusRingType = .none
        outline.style = .plain
        outline.intercellSpacing = .zero
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        [title, input, caseButton, summary, scroll].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = NSRect(x: 20, y: 11, width: w - 40, height: 15)
        input.frame = NSRect(x: 12, y: 36, width: w - 24, height: 26)
        caseButton.frame = NSRect(x: w - 12 - 30, y: 39, width: 26, height: 20)
        summary.frame = NSRect(x: 20, y: 70, width: w - 40, height: 16)
        scroll.frame = NSRect(x: 0, y: 92, width: w, height: max(0, bounds.height - 92))
        outline.tableColumns.first?.width = w - 4
    }

    func focus(query: String? = nil) {
        if let query, !query.isEmpty {
            input.field.stringValue = query
            schedule(delay: 0)
        }
        window?.makeFirstResponder(input.field)
        input.field.currentEditor()?.selectAll(nil)
    }

    @objc private func toggleCase() {
        caseSensitive.toggle()
        caseButton.contentTintColor = caseSensitive ? Palette.brightText : Palette.dimText
        caseButton.layer?.backgroundColor = caseSensitive ? Palette.accent.withAlphaComponent(0.4).cgColor : nil
        caseButton.wantsLayer = true
        schedule(delay: 0)
    }

    func controlTextDidChange(_ obj: Notification) {
        schedule(delay: 0.25)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        input.setFocused(true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        input.setFocused(false)
    }

    private func schedule(delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.run() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func run() {
        let query = input.field.stringValue
        generation += 1
        let gen = generation
        guard !query.isEmpty, let onSearch else {
            groups = []
            summary.stringValue = ""
            outline.reloadData()
            return
        }
        summary.stringValue = "Searching…"
        onSearch(query, caseSensitive) { [weak self] raw in
            guard let self, gen == self.generation else { return }
            self.show(raw)
        }
    }

    private func show(_ raw: String) {
        var order: [SearchGroup] = []
        var byPath: [String: SearchGroup] = [:]
        var count = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard f.count == 5, let l = Int(f[1]), let c = Int(f[2]), let n = Int(f[3]) else { continue }
            let path = String(f[0])
            let group = byPath[path] ?? {
                let g = SearchGroup(path: path)
                byPath[path] = g
                order.append(g)
                return g
            }()
            group.hits.append(SearchHit(path: path, line: l, col: c, len: n, text: String(f[4])))
            count += 1
        }
        groups = order
        summary.stringValue = count == 0
            ? "No results found."
            : "\(count)\(count >= 2000 ? "+" : "") results in \(order.count) files"
        outline.reloadData()
        groups.forEach { outline.expandItem($0) }
    }

    @objc private func clicked() {
        let item = outline.item(atRow: outline.clickedRow)
        if let hit = item as? SearchHit {
            onOpen?(hit)
        } else if let group = item as? SearchGroup {
            outline.isItemExpanded(group) ? outline.collapseItem(group) : outline.expandItem(group)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let g = item as? SearchGroup { return g.hits.count }
        return item == nil ? groups.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let g = item as? SearchGroup { return g.hits[index] }
        return groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SearchGroup
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("result")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? ResultCell ?? {
            let c = ResultCell()
            c.identifier = id
            return c
        }()
        if let g = item as? SearchGroup {
            let name = (g.path as NSString).lastPathComponent
            let dir = (g.path as NSString).deletingLastPathComponent
            let s = NSMutableAttributedString(string: name, attributes: [.foregroundColor: Palette.text, .font: NSFont.systemFont(ofSize: 13)])
            s.append(NSAttributedString(string: "  \(dir)  \(g.hits.count)", attributes: [
                .foregroundColor: Palette.dimText, .font: NSFont.systemFont(ofSize: 11),
            ]))
            cell.icon.image = FileIcons.icon(for: name, directory: false)
            cell.label.attributedStringValue = s
        } else if let h = item as? SearchHit {
            cell.icon.image = nil
            cell.label.attributedStringValue = preview(h)
        }
        cell.needsLayout = true
        return cell
    }

    private func preview(_ h: SearchHit) -> NSAttributedString {
        let ns = h.text as NSString
        var start = 0
        while start < ns.length, let u = UnicodeScalar(ns.character(at: start)), CharacterSet.whitespaces.contains(u) {
            start += 1
        }
        var prefix = ""
        if h.col - start > 36 {
            start = h.col - 24
            prefix = "…"
        }
        start = min(start, ns.length)
        let body = ns.substring(from: start)
        let s = NSMutableAttributedString(string: prefix + body, attributes: [
            .foregroundColor: Palette.text, .font: NSFont.systemFont(ofSize: 13),
        ])
        let loc = h.col - start + (prefix as NSString).length
        let range = NSIntersectionRange(NSRange(location: loc, length: h.len), NSRange(location: 0, length: s.length))
        if range.length > 0 {
            s.addAttributes([.backgroundColor: NSColor(hex: 0xEA5C00, alpha: 0.33)], range: range)
        }
        return s
    }
}
