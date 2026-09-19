import AppKit

// terminal grupları: her grup yan yana bölünmüş terminaller; başlıkta grup sekmeleri
final class TerminalPanel: FlippedView {
    var onClose: (() -> Void)?
    var onOpenPath: ((URL, Int?, Int?) -> Void)?
    var environment: () -> [String: String] = { [:] }
    private(set) var groups: [[TerminalView]] = []
    private(set) var active = 0
    private(set) var terminal: TerminalView?   // odaktaki
    private var tabButtons: [NSButton] = []
    private var splitHandles: [SplitHandle] = []
    private var ratios: [[CGFloat]] = []
    private lazy var newButton = iconButton("plus", tooltip: "New Terminal (⌃⇧`)", size: 13, target: self, action: #selector(newTerminal))
    private lazy var splitButton = iconButton("square.split.2x1", tooltip: "Split Terminal (⌘\\)", size: 12, target: self, action: #selector(splitTerminal))
    private lazy var killButton = iconButton("trash", tooltip: "Kill Terminal", size: 12, target: self, action: #selector(kill))
    private lazy var closeButton = iconButton("xmark", tooltip: "Hide Panel", size: 12, target: self, action: #selector(hide))
    private let header: CGFloat = 35
    var cwd = NSHomeDirectory()

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.chrome
        [newButton, splitButton, killButton, closeButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    var views: [TerminalView] { groups.flatMap { $0 } }

    override func layout() {
        super.layout()
        let w = bounds.width
        var x: CGFloat = 12
        for (i, b) in tabButtons.enumerated() {
            let tw = min(180, max(70, b.intrinsicContentSize.width + 16))
            b.frame = NSRect(x: x, y: 6, width: tw, height: 24)
            b.contentTintColor = i == active ? Palette.brightText : Palette.dimText
            x += tw + 2
        }
        newButton.frame = NSRect(x: w - 110, y: 7, width: 22, height: 22)
        splitButton.frame = NSRect(x: w - 84, y: 7, width: 22, height: 22)
        killButton.frame = NSRect(x: w - 58, y: 7, width: 22, height: 22)
        closeButton.frame = NSRect(x: w - 32, y: 7, width: 22, height: 22)
        splitHandles.forEach { $0.isHidden = true }
        for (g, group) in groups.enumerated() {
            group.forEach { $0.isHidden = g != active }
        }
        guard active < groups.count else { return }
        let group = groups[active]
        let h = max(0, bounds.height - header)
        var tx: CGFloat = 0
        for (i, v) in group.enumerated() {
            let vw = i == group.count - 1 ? w - tx : round(w * ratios[active][i])
            v.frame = NSRect(x: tx, y: header, width: vw, height: h)
            if i < group.count - 1, i < splitHandles.count {
                splitHandles[i].isHidden = false
                splitHandles[i].frame = NSRect(x: tx + vw - 2, y: header, width: 5, height: h)
            }
            tx += vw
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        if active < tabButtons.count {
            Palette.brightText.setFill()
            let f = tabButtons[active].frame
            NSRect(x: f.minX + 6, y: 29, width: f.width - 12, height: 1).fill()
        }
        // bölmeler arası çizgi
        if active < groups.count {
            Palette.border.setFill()
            for v in groups[active].dropLast() { NSRect(x: v.frame.maxX, y: header, width: 1, height: bounds.height - header).fill() }
        }
    }

    func focus() {
        if terminal == nil { newTerminal() }
        if let terminal { window?.makeFirstResponder(terminal) }
    }

    private func makeView() -> TerminalView? {
        guard let view = TerminalView(cwd: terminal?.currentDirectory ?? cwd, environment: environment()) else { return nil }
        view.onExit = { [weak self, weak view] in
            guard let self, let view else { return }
            self.remove(view)
        }
        view.onTitle = { [weak self] _ in self?.refreshTabs() }
        view.onFocus = { [weak self, weak view] in
            guard let self, let view else { return }
            self.terminal = view
            if let g = self.groups.firstIndex(where: { $0.contains { $0 === view } }), g != self.active {
                self.active = g
                self.needsLayout = true
            }
            self.refreshTabs()
        }
        view.onOpenPath = { [weak self] url, line, col in self?.onOpenPath?(url, line, col) }
        addSubview(view)
        return view
    }

    @objc func newTerminal() {
        guard let view = makeView() else { return }
        groups.append([view])
        ratios.append([1])
        active = groups.count - 1
        terminal = view
        refreshTabs()
        window?.makeFirstResponder(view)
    }

    @objc func splitTerminal() {
        guard !groups.isEmpty, active < groups.count else { return newTerminal() }
        guard let view = makeView() else { return }
        let at = (groups[active].firstIndex { $0 === terminal } ?? groups[active].count - 1) + 1
        groups[active].insert(view, at: at)
        ratios[active] = Array(repeating: 1 / CGFloat(groups[active].count), count: groups[active].count)
        terminal = view
        refreshTabs()
        window?.makeFirstResponder(view)
    }

    func focusNext(_ delta: Int) {
        let all = views
        guard let t = terminal, let i = all.firstIndex(where: { $0 === t }), !all.isEmpty else { return }
        window?.makeFirstResponder(all[(i + delta + all.count) % all.count])
    }

    private func remove(_ view: TerminalView) {
        view.removeFromSuperview()
        for g in groups.indices {
            if let i = groups[g].firstIndex(where: { $0 === view }) {
                groups[g].remove(at: i)
                ratios[g] = Array(repeating: 1 / CGFloat(max(1, groups[g].count)), count: groups[g].count)
            }
        }
        let emptied = groups.firstIndex { $0.isEmpty }
        if let e = emptied {
            groups.remove(at: e)
            ratios.remove(at: e)
        }
        active = min(active, max(0, groups.count - 1))
        terminal = groups.isEmpty ? nil : groups[active].last
        refreshTabs()
        if groups.isEmpty {
            onClose?()
        } else if let terminal {
            window?.makeFirstResponder(terminal)
        }
    }

    private func refreshTabs() {
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons = groups.enumerated().map { i, group in
            let names = group.map { $0.shortTitle }
            let title = names.count > 1 ? "\(names[0]), +\(names.count - 1)" : (names.first ?? "")
            let b = NSButton(title: title.isEmpty ? "TERMINAL" : title, target: self, action: #selector(tabClicked(_:)))
            b.isBordered = false
            b.font = .systemFont(ofSize: 11)
            b.tag = i
            b.lineBreakMode = .byTruncatingTail
            addSubview(b)
            return b
        }
        splitHandles.forEach { $0.removeFromSuperview() }
        let count = active < groups.count ? max(0, groups[active].count - 1) : 0
        splitHandles = (0..<count).map { i in
            let h = SplitHandle()
            h.onDrag = { [weak self] dx in self?.dragSplit(i, dx) }
            addSubview(h)
            return h
        }
        needsLayout = true
        needsDisplay = true
    }

    private func dragSplit(_ i: Int, _ dx: CGFloat) {
        let w = max(1, bounds.width), d = dx / w, minR = 80 / w
        guard active < ratios.count, ratios[active][i] + d >= minR, ratios[active][i + 1] - d >= minR else { return }
        ratios[active][i] += d
        ratios[active][i + 1] -= d
        needsLayout = true
    }

    @objc private func tabClicked(_ b: NSButton) {
        guard b.tag < groups.count else { return }
        active = b.tag
        terminal = groups[active].last
        refreshTabs()
        if let terminal { window?.makeFirstResponder(terminal) }
    }

    @objc func kill() {
        guard let terminal else { return }
        remove(terminal)
    }

    @objc private func hide() {
        onClose?()
    }
}
