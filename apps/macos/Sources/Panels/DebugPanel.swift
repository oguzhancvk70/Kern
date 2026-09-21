import AppKit

enum DebugRow { case group, variable, frame, breakpoint, message }

// panelin ağaç düğümü: değişken, çerçeve, kesme noktası ya da bölüm başlığı
final class DebugNode: NSObject {
    let kind: DebugRow
    let title: String
    var detail: String
    let reference: Int64   // değişkenler: >0 ise genişletilebilir
    let id: Int64          // çerçeve id'si
    let path: String
    let line: Int          // 0 tabanlı
    var children: [DebugNode]?
    var expanded = false
    var active = false     // seçili çerçeve

    init(_ kind: DebugRow, title: String, detail: String = "", reference: Int64 = 0, id: Int64 = -1,
         path: String = "", line: Int = -1, children: [DebugNode]? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.reference = reference
        self.id = id
        self.path = path
        self.line = line
        self.children = children
    }
}

private final class DebugCell: NSTableCellView {
    let label = makeLabel("")
    let value = makeLabel("", size: 12, color: Palette.dimText)
    let dot = FlippedView()
    let remove = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        remove.isBordered = false
        remove.imagePosition = .imageOnly
        remove.image = symbol("xmark", size: 10)
        remove.toolTip = "Remove Breakpoint"
        [dot, label, value, remove].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        dot.frame = NSRect(x: 2, y: (h - 8) / 2, width: 8, height: 8)
        let x: CGFloat = dot.isHidden ? 2 : 14
        let right = remove.isHidden ? w - 6 : w - 24
        remove.frame = NSRect(x: w - 22, y: (h - 18) / 2, width: 18, height: 18)
        let labelWidth = min(label.attributedStringValue.size().width + 2, max(0, right - x))
        label.frame = NSRect(x: x, y: (h - 17) / 2, width: labelWidth, height: 17)
        value.frame = NSRect(x: x + labelWidth + 4, y: (h - 16) / 2, width: max(0, right - x - labelWidth - 4), height: 16)
    }
}

final class DebugPanel: FlippedView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onRestart: (() -> Void)?
    var onPauseOrContinue: (() -> Void)?
    var onStep: ((String) -> Void)?
    var onSelectConfig: ((Int) -> Void)?
    var onOpenLaunchJSON: (() -> Void)?
    var onSelectFrame: ((DebugNode) -> Void)?
    var onExpand: ((DebugNode) -> Void)?
    var onRemoveBreakpoint: ((DebugNode) -> Void)?
    var onOpen: ((DebugNode) -> Void)?

    private let title = makeLabel("RUN AND DEBUG", size: 11, color: Palette.dimText)
    private let configButton = NSPopUpButton()
    private let startButton = NSButton(title: "  Start Debugging", target: nil, action: nil)
    private let summary = makeLabel("", size: 12, color: Palette.dimText)
    private var tools: [NSButton] = []
    private let scroll = NSScrollView()
    private let outline = NSOutlineView()
    private(set) var roots: [DebugNode] = []
    private var running = false
    private var stopped = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.chrome
        configButton.target = self
        configButton.action = #selector(pickConfig)
        configButton.font = .systemFont(ofSize: 12)
        startButton.bezelStyle = .rounded
        startButton.image = symbol("play.fill", size: 11, color: Palette.text)
        startButton.imagePosition = .imageLeading
        startButton.target = self
        startButton.action = #selector(start)
        tools = [("play.fill", "Continue (F5)", #selector(pauseOrContinue)),
                 ("arrow.turn.down.right", "Step Over (F10)", #selector(stepOver)),
                 ("arrow.down.to.line", "Step Into (F11)", #selector(stepIn)),
                 ("arrow.up.to.line", "Step Out (⇧F11)", #selector(stepOut)),
                 ("arrow.clockwise", "Restart (⇧⌘F5)", #selector(restart)),
                 ("stop.fill", "Stop (⇧F5)", #selector(stop))].map {
            iconButton($0.0, tooltip: $0.1, size: 12, target: self, action: $0.2)
        }

        let column = NSTableColumn(identifier: .init("debug"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = Palette.chrome
        outline.rowHeight = 22
        outline.indentationPerLevel = 10
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
        ([title, configButton, startButton, summary, scroll] + tools).forEach(addSubview)
        setState(state: "none", reason: "")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = NSRect(x: 20, y: 11, width: w - 40, height: 15)
        for (i, b) in tools.enumerated() {
            b.frame = NSRect(x: 12 + CGFloat(i) * 26, y: 32, width: 22, height: 22)
            b.isHidden = !running
        }
        configButton.frame = NSRect(x: 10, y: 32, width: w - 20, height: 24)
        configButton.isHidden = running
        startButton.frame = NSRect(x: 10, y: 62, width: w - 20, height: 28)
        startButton.isHidden = running
        let top: CGFloat = running ? 62 : 96
        summary.frame = NSRect(x: 20, y: top, width: w - 40, height: 16)
        let listTop = summary.stringValue.isEmpty ? top : top + 22
        scroll.frame = NSRect(x: 0, y: listTop, width: w, height: max(0, bounds.height - listTop))
        outline.tableColumns.first?.width = w - 4
    }

    // konfigürasyon listesi; son öğe launch.json açar
    func setConfigs(_ names: [String], selected: Int) {
        configButton.removeAllItems()
        if names.isEmpty {
            configButton.addItem(withTitle: "No Configurations")
        } else {
            names.forEach(configButton.addItem)
            configButton.selectItem(at: min(max(0, selected), names.count - 1))
        }
        configButton.menu?.addItem(.separator())
        configButton.menu?.addItem(NSMenuItem(title: "Add Configuration…", action: #selector(addConfig), keyEquivalent: ""))
        configButton.menu?.items.last?.target = self
        startButton.title = names.isEmpty ? "  Run and Debug" : "  Start Debugging"
    }

    // state: none/starting/running/stopped/terminated
    func setState(state: String, reason: String) {
        running = state == "starting" || state == "running" || state == "stopped"
        stopped = state == "stopped"
        if let b = tools.first {
            b.image = symbol(stopped ? "play.fill" : "pause.fill", size: 12)
            b.toolTip = stopped ? "Continue (F5)" : "Pause"
        }
        for b in tools.dropFirst().prefix(3) { b.isEnabled = stopped }
        needsLayout = true
    }

    func show(_ text: String, error: Bool = false) {
        summary.stringValue = text
        summary.textColor = error ? .systemRed : Palette.dimText
        summary.toolTip = text
        needsLayout = true
    }

    func setTree(_ roots: [DebugNode]) {
        let expandedTitles = Set(self.roots.filter { outline.isItemExpanded($0) }.map(\.title))
        self.roots = roots
        outline.reloadData()
        for r in roots where expandedTitles.contains(r.title) || expandedTitles.isEmpty {
            outline.expandItem(r)
        }
        // duran çerçevede açık olan değişken düğümleri geri açılır
        func restore(_ nodes: [DebugNode]) {
            for n in nodes {
                if n.expanded { outline.expandItem(n) }
                if let c = n.children { restore(c) }
            }
        }
        restore(roots)
    }

    func reload(_ node: DebugNode) {
        outline.reloadItem(node, reloadChildren: true)
        outline.expandItem(node)
    }

    @objc private func start() { onStart?() }
    @objc private func stop() { onStop?() }
    @objc private func restart() { onRestart?() }
    @objc private func pauseOrContinue() { onPauseOrContinue?() }
    @objc private func stepOver() { onStep?("next") }
    @objc private func stepIn() { onStep?("stepIn") }
    @objc private func stepOut() { onStep?("stepOut") }
    @objc private func addConfig() { onOpenLaunchJSON?() }
    @objc private func pickConfig() { onSelectConfig?(configButton.indexOfSelectedItem) }

    @objc private func clicked() {
        let item = outline.item(atRow: outline.clickedRow)
        guard let node = item as? DebugNode else { return }
        switch node.kind {
        case .group: outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        case .frame: onSelectFrame?(node)
        case .breakpoint: onOpen?(node)
        default: break
        }
    }

    @objc private func removeRow(_ sender: NSButton) {
        guard let node = outline.item(atRow: outline.row(for: sender)) as? DebugNode else { return }
        onRemoveBreakpoint?(node)
    }

    // outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? DebugNode else { return roots.count }
        return node.children?.count ?? (node.reference > 0 ? 1 : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? DebugNode else { return roots[index] }
        if let c = node.children, index < c.count { return c[index] }
        return DebugNode(.message, title: "loading…")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? DebugNode else { return false }
        return node.kind == .group || node.reference > 0 || !(node.children?.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? DebugNode else { return true }
        node.expanded = true
        if node.children == nil, node.reference > 0 { onExpand?(node) }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        (item as? DebugNode)?.expanded = false
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DebugNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("debug")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? DebugCell ?? {
            let c = DebugCell()
            c.identifier = id
            c.remove.target = self
            c.remove.action = #selector(removeRow(_:))
            return c
        }()
        cell.dot.isHidden = node.kind != .breakpoint
        cell.dot.background = NSColor(hex: 0xE51400)
        cell.remove.isHidden = node.kind != .breakpoint
        let bold = node.kind == .group || node.active
        let color = node.kind == .message ? Palette.dimText : (node.active ? Palette.brightText : Palette.text)
        cell.label.attributedStringValue = NSAttributedString(string: node.kind == .group ? node.title.uppercased() : node.title, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: node.kind == .group ? 11 : 13, weight: bold ? .semibold : .regular)])
        cell.value.stringValue = node.detail
        cell.value.textColor = node.kind == .variable ? Palette.match : Palette.dimText
        cell.toolTip = node.detail.isEmpty ? node.title : "\(node.title) \(node.detail)"
        cell.needsLayout = true
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? DebugNode)?.kind != .group
    }
}
