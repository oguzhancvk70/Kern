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
    let previewCol: Int

    init(path: String, line: Int, col: Int, len: Int, text: String, previewCol: Int? = nil) {
        self.path = path
        self.line = line
        self.col = col
        self.len = len
        self.text = text
        self.previewCol = previewCol ?? col
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

// bul çubuğu ve arama paneli için seçenek düğmesi (Aa, ab, .*)
final class OptionToggle: NSButton {
    var isOn = false { didSet { refresh() } }
    var onToggle: (() -> Void)?

    init(_ title: String, tip: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        font = .systemFont(ofSize: 12, weight: .semibold)
        toolTip = tip
        wantsLayer = true
        layer?.cornerRadius = 3
        target = self
        action = #selector(toggle)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() {
        isOn.toggle()
        onToggle?()
    }

    private func refresh() {
        contentTintColor = isOn ? Palette.brightText : Palette.dimText
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = self.isOn ? Palette.accent.withAlphaComponent(0.4).cgColor : nil
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
}

final class SearchPanel: FlippedView, NSTextFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    // her kök için bir iş; prefix sonuç yollarının başına eklenir ("" = ana klasör)
    struct SearchJobRef {
        var job: KernSearch
        var prefix: String
    }

    var startSearch: ((String, UInt8) -> [SearchJobRef])?
    var onOpen: ((SearchHit) -> Void)?
    // sorgu, yerine konacak metin, bayraklar, hedefler ("yol" ya da "yol:satır")
    var onReplaceAll: ((String, String, UInt8, [String]) -> Void)?

    let input = InputBox(placeholder: "Search")
    let replaceInput = InputBox(placeholder: "Replace")
    private let replaceButton = NSButton(title: "Replace All", target: nil, action: nil)
    private let title = makeLabel("SEARCH", size: 11, color: Palette.dimText)
    private let caseButton = OptionToggle("Aa", tip: "Match Case")
    private let wordButton = OptionToggle("ab", tip: "Match Whole Word")
    private let regexButton = OptionToggle(".*", tip: "Use Regular Expression")
    private let summary = makeLabel("", size: 12, color: Palette.dimText)
    private let scroll = NSScrollView()
    private let outline = NSOutlineView()
    private var groups: [SearchGroup] = []
    private var byPath: [String: SearchGroup] = [:]
    private var count = 0
    private var pending: DispatchWorkItem?
    private var jobs: [SearchJobRef] = []
    private var timer: Timer?
    static let limit = 20_000

    var flags: UInt8 {
        (caseButton.isOn ? 1 : 0) | (wordButton.isOn ? 2 : 0) | (regexButton.isOn ? 4 : 0)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.chrome
        input.field.delegate = self
        input.trailingInset = 84
        [caseButton, wordButton, regexButton].forEach { $0.onToggle = { [weak self] in self?.schedule(delay: 0) } }

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

        replaceButton.bezelStyle = .rounded
        replaceButton.font = .systemFont(ofSize: 11)
        replaceButton.target = self
        replaceButton.action = #selector(replaceAll)
        [title, input, replaceInput, replaceButton, caseButton, wordButton, regexButton, summary, scroll].forEach(addSubview)
    }

    // görünen sonuçların hepsini değiştir (tek dosya seçiliyse yalnız o dosya)
    @objc private func replaceAll() {
        let query = input.field.stringValue
        guard !query.isEmpty, !groups.isEmpty, let run = onReplaceAll else { return NSSound.beep() }
        var targets: [String] = []
        if let g = outline.item(atRow: outline.selectedRow) as? SearchGroup {
            targets = [g.path]
        } else if let h = outline.item(atRow: outline.selectedRow) as? SearchHit {
            targets = ["\(h.path):\(h.line)"]
        } else {
            targets = groups.map(\.path)
        }
        let alert = NSAlert()
        alert.messageText = "Replace \(count) match\(count == 1 ? "" : "es")?"
        alert.informativeText = "\(targets.count) file\(targets.count == 1 ? "" : "s") will be changed on disk."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(query, replaceInput.field.stringValue, flags, targets)
        schedule(delay: 0.1)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = NSRect(x: 20, y: 11, width: w - 40, height: 15)
        input.frame = NSRect(x: 12, y: 36, width: w - 24, height: 26)
        for (i, b) in [caseButton, wordButton, regexButton].enumerated() {
            b.frame = NSRect(x: w - 12 - 82 + CGFloat(i) * 26, y: 39, width: 24, height: 20)
        }
        replaceInput.frame = NSRect(x: 12, y: 68, width: max(60, w - 24 - 92), height: 26)
        replaceButton.frame = NSRect(x: w - 12 - 88, y: 69, width: 88, height: 24)
        summary.frame = NSRect(x: 20, y: 102, width: w - 40, height: 16)
        scroll.frame = NSRect(x: 0, y: 124, width: w, height: max(0, bounds.height - 124))
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
        jobs.forEach { $0.job.cancel() }
        jobs = []
        timer?.invalidate()
        groups = []
        byPath = [:]
        count = 0
        summary.textColor = Palette.dimText
        defer { outline.reloadData() }
        guard !query.isEmpty, let startSearch else {
            summary.stringValue = ""
            return
        }
        let err = find_error(query, flags).toString()
        let started = startSearch(query, flags)
        guard err.isEmpty, !started.isEmpty else {
            summary.stringValue = err.isEmpty ? "" : err
            summary.textColor = .systemRed
            return
        }
        jobs = started
        summary.stringValue = "Searching…"
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.poll() }
    }

    // sonuçlar geldikçe ekle (çoklu kökte her klasör ayrı iş)
    private func poll() {
        guard !jobs.isEmpty else { return timer?.invalidate() ?? () }
        let done = jobs.allSatisfy { $0.job.is_done() }
        var raw = ""
        for j in jobs {
            for line in j.job.poll().toString().split(separator: "\n", omittingEmptySubsequences: true) {
                // yolu köke göre mutlak yap (birden çok kökte çakışmasın)
                raw += j.prefix + line + "\n"
            }
        }
        var added: [SearchGroup] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            guard f.count == 6, let l = Int(f[1]), let c = Int(f[2]), let n = Int(f[3]), let pc = Int(f[4]) else { continue }
            let path = String(f[0])
            let group = byPath[path] ?? {
                let g = SearchGroup(path: path)
                byPath[path] = g
                groups.append(g)
                added.append(g)
                return g
            }()
            group.hits.append(SearchHit(path: path, line: l, col: c, len: n, text: String(f[5]), previewCol: pc))
            count += 1
        }
        if !raw.isEmpty {
            groups.forEach { $0.hits.sort { ($0.line, $0.col) < ($1.line, $1.col) } }
            outline.reloadData()
            groups.forEach { outline.expandItem($0) }
        }
        if done {
            timer?.invalidate()
            self.jobs = []
            summary.stringValue = count == 0
                ? "No results found."
                : "\(count)\(count >= Self.limit ? "+" : "") results in \(groups.count) files"
        } else if count > 0 {
            summary.stringValue = "\(count) results in \(groups.count) files…"
        }
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
        if h.previewCol - start > 36 {
            start = h.previewCol - 24
            prefix = "…"
        }
        start = min(start, ns.length)
        let body = ns.substring(from: start)
        let s = NSMutableAttributedString(string: prefix + body, attributes: [
            .foregroundColor: Palette.text, .font: NSFont.systemFont(ofSize: 13),
        ])
        let loc = h.previewCol - start + (prefix as NSString).length
        let range = NSIntersectionRange(NSRange(location: loc, length: h.len), NSRange(location: 0, length: s.length))
        if range.length > 0 {
            s.addAttributes([.backgroundColor: NSColor(hex: 0xEA5C00, alpha: 0.33)], range: range)
        }
        return s
    }
}
