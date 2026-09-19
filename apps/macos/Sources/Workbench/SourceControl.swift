import AppKit

enum SCMKind { case merge, staged, changes }

final class SCMFile: NSObject {
    let path: String
    let letter: String
    let kind: SCMKind
    init(path: String, letter: String, kind: SCMKind) {
        self.path = path
        self.letter = letter
        self.kind = kind
    }
}

final class SCMGroup: NSObject {
    let title: String
    let kind: SCMKind
    let files: [SCMFile]
    init(title: String, kind: SCMKind, files: [SCMFile]) {
        self.title = title
        self.kind = kind
        self.files = files
    }
}

// "XY\tyol" satırları → gruplar
func parseGitStatus(_ raw: String) -> [SCMGroup] {
    var merge: [SCMFile] = [], staged: [SCMFile] = [], changes: [SCMFile] = []
    let conflict: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
    for line in raw.split(separator: "\n") {
        let f = line.split(separator: "\t", maxSplits: 1)
        guard f.count == 2, f[0].count == 2 else { continue }
        let xy = String(f[0]), path = String(f[1])
        let x = xy.first!, y = xy.last!
        if conflict.contains(xy) {
            merge.append(SCMFile(path: path, letter: "!", kind: .merge))
            continue
        }
        if xy == "??" {
            changes.append(SCMFile(path: path, letter: "U", kind: .changes))
            continue
        }
        if x != " " { staged.append(SCMFile(path: path, letter: String(x), kind: .staged)) }
        if y != " " { changes.append(SCMFile(path: path, letter: String(y), kind: .changes)) }
    }
    return [SCMGroup(title: "Merge Changes", kind: .merge, files: merge),
            SCMGroup(title: "Staged Changes", kind: .staged, files: staged),
            SCMGroup(title: "Changes", kind: .changes, files: changes)].filter { !$0.files.isEmpty }
}

private final class SCMCell: NSTableCellView {
    let icon = NSImageView()
    let label = makeLabel("")
    let letter = makeLabel("", size: 12, weight: .semibold)
    let action = NSButton()
    let discard = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for b in [action, discard] {
            b.isBordered = false
            b.imagePosition = .imageOnly
        }
        letter.alignment = .center
        [icon, label, letter, action, discard].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        let hasIcon = icon.image != nil
        icon.frame = NSRect(x: 0, y: (h - 16) / 2, width: 16, height: 16)
        letter.frame = NSRect(x: w - 18, y: (h - 16) / 2, width: 14, height: 16)
        action.frame = NSRect(x: w - 40, y: (h - 18) / 2, width: 18, height: 18)
        discard.frame = NSRect(x: w - 60, y: (h - 18) / 2, width: 18, height: 18)
        let x: CGFloat = hasIcon ? 21 : 2
        let right = discard.isHidden ? (action.isHidden ? w - 20 : w - 42) : w - 62
        label.frame = NSRect(x: x, y: (h - 17) / 2, width: max(0, right - x), height: 17)
    }
}

final class SourceControlPanel: FlippedView, NSTextFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onCommit: ((String) -> Void)?
    var onOpen: ((SCMFile) -> Void)?
    var onStage: (([String]) -> Void)?
    var onUnstage: (([String]) -> Void)?
    var onDiscard: (([String]) -> Void)?
    var onPush: (() -> Void)?
    var onPull: (() -> Void)?
    var onBranch: (() -> Void)?
    var onRefresh: (() -> Void)?

    let message = InputBox(placeholder: "Message (↩ to commit)")
    private let title = makeLabel("SOURCE CONTROL", size: 11, color: Palette.dimText)
    private let commitButton = NSButton(title: "✓ Commit", target: nil, action: nil)
    private let branchButton = NSButton(title: "", target: nil, action: nil)
    private let summary = makeLabel("", size: 12, color: Palette.dimText)
    private var tools: [NSButton] = []
    private let scroll = NSScrollView()
    private let outline = NSOutlineView()
    private(set) var groups: [SCMGroup] = []
    private(set) var hasRepo = false
    private var showingError = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.chrome
        message.field.delegate = self
        commitButton.bezelStyle = .rounded
        commitButton.target = self
        commitButton.action = #selector(commit)
        branchButton.isBordered = false
        branchButton.alignment = .left
        branchButton.contentTintColor = Palette.text
        branchButton.target = self
        branchButton.action = #selector(branch)
        tools = [("arrow.clockwise", "Refresh", #selector(refresh)), ("arrow.down", "Pull", #selector(pull)),
                 ("arrow.up", "Push", #selector(push))].map { iconButton($0.0, tooltip: $0.1, target: self, action: $0.2) }

        let column = NSTableColumn(identifier: .init("scm"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = Palette.chrome
        outline.rowHeight = 22
        outline.indentationPerLevel = 8
        outline.focusRingType = .none
        outline.style = .plain
        outline.intercellSpacing = .zero
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.menu = NSMenu()
        outline.menu?.delegate = self

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        ([title, branchButton, message, commitButton, summary, scroll] + tools).forEach(addSubview)
        set(status: nil, branch: "")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = NSRect(x: 20, y: 11, width: w - 110, height: 15)
        for (i, b) in tools.enumerated() {
            b.frame = NSRect(x: w - 12 - CGFloat(tools.count - i) * 24, y: 8, width: 22, height: 20)
        }
        branchButton.frame = NSRect(x: 14, y: 32, width: w - 28, height: 20)
        message.frame = NSRect(x: 12, y: 56, width: w - 24, height: 26)
        commitButton.frame = NSRect(x: 10, y: 86, width: w - 20, height: 28)
        summary.frame = NSRect(x: 20, y: 118, width: w - 40, height: 16)
        let top: CGFloat = summary.stringValue.isEmpty ? 118 : 140
        scroll.frame = NSRect(x: 0, y: top, width: w, height: max(0, bounds.height - top))
        outline.tableColumns.first?.width = w - 4
    }

    // status nil → depo yok
    func set(status: String?, branch: String) {
        hasRepo = status != nil
        groups = parseGitStatus(status ?? "")
        branchButton.title = hasRepo ? "⎇ \(branch)" : ""
        [message, commitButton, branchButton].forEach { $0.isHidden = !hasRepo }
        tools.forEach { $0.isHidden = !hasRepo }
        if !hasRepo {
            show("The folder currently open doesn’t have a git repository.")
        } else if !showingError {
            show(groups.isEmpty ? "No changes." : "")
        }
        outline.reloadData()
        groups.forEach { outline.expandItem($0) }
    }

    func show(_ text: String, error: Bool = false) {
        summary.stringValue = text
        showingError = error
        summary.textColor = error ? .systemRed : Palette.dimText
        summary.toolTip = text
        needsLayout = true
    }

    func setBusy(_ busy: Bool) {
        commitButton.isEnabled = !busy
        tools.forEach { $0.isEnabled = !busy }
    }

    func focusMessage() {
        window?.makeFirstResponder(message.field)
    }

    @objc private func commit() {
        let text = message.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return show("Enter a commit message.", error: true) }
        onCommit?(text)
    }

    func clearMessage() { message.field.stringValue = "" }

    @objc private func refresh() { show(""); onRefresh?() }
    @objc private func pull() { onPull?() }
    @objc private func push() { onPush?() }
    @objc private func branch() { onBranch?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        commit()
        return true
    }

    func controlTextDidBeginEditing(_ obj: Notification) { message.setFocused(true) }
    func controlTextDidEndEditing(_ obj: Notification) { message.setFocused(false) }

    @objc private func clicked() {
        let item = outline.item(atRow: outline.clickedRow)
        if let f = item as? SCMFile {
            onOpen?(f)
        } else if let g = item as? SCMGroup {
            outline.isItemExpanded(g) ? outline.collapseItem(g) : outline.expandItem(g)
        }
    }

    private func paths(_ item: Any?) -> [String] {
        if let f = item as? SCMFile { return [f.path] }
        return (item as? SCMGroup)?.files.map(\.path) ?? []
    }

    private func kind(_ item: Any?) -> SCMKind? {
        (item as? SCMFile)?.kind ?? (item as? SCMGroup)?.kind
    }

    @objc private func rowAction(_ sender: NSButton) {
        let item = outline.item(atRow: outline.row(for: sender))
        if kind(item) == .staged { onUnstage?(paths(item)) } else { onStage?(paths(item)) }
    }

    @objc private func rowDiscard(_ sender: NSButton) {
        confirmDiscard(outline.item(atRow: outline.row(for: sender)))
    }

    private func confirmDiscard(_ item: Any?) {
        let p = paths(item)
        guard !p.isEmpty else { return }
        let untracked = (item as? SCMFile)?.letter == "U" || (item as? SCMGroup)?.files.allSatisfy { $0.letter == "U" } == true
        let alert = NSAlert()
        alert.messageText = p.count == 1 ? "Discard changes in “\((p[0] as NSString).lastPathComponent)”?"
                                         : "Discard changes in \(p.count) files?"
        alert.informativeText = untracked ? "Untracked files will be moved to the Trash." : "This can’t be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { onDiscard?(p) }
    }

    // outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let g = item as? SCMGroup { return g.files.count }
        return item == nil ? groups.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let g = item as? SCMGroup { return g.files[index] }
        return groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SCMGroup
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("scm")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? SCMCell ?? {
            let c = SCMCell()
            c.identifier = id
            c.action.target = self
            c.action.action = #selector(rowAction(_:))
            c.discard.target = self
            c.discard.action = #selector(rowDiscard(_:))
            return c
        }()
        let k = kind(item)
        cell.action.image = symbol(k == .staged ? "minus" : "plus", size: 12)
        cell.action.toolTip = k == .staged ? "Unstage Changes" : "Stage Changes"
        cell.discard.image = symbol("arrow.uturn.backward", size: 12)
        cell.discard.toolTip = "Discard Changes"
        cell.discard.isHidden = k != .changes
        if let g = item as? SCMGroup {
            cell.icon.image = nil
            cell.label.attributedStringValue = NSAttributedString(string: g.title.uppercased(), attributes: [
                .foregroundColor: Palette.text, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
            cell.letter.stringValue = String(g.files.count)
            cell.letter.textColor = Palette.dimText
        } else if let f = item as? SCMFile {
            let name = (f.path as NSString).lastPathComponent
            let dir = (f.path as NSString).deletingLastPathComponent
            let s = NSMutableAttributedString(string: name, attributes: [
                .foregroundColor: Palette.text, .font: NSFont.systemFont(ofSize: 13),
                .strikethroughStyle: f.letter == "D" ? NSUnderlineStyle.single.rawValue : 0])
            s.append(NSAttributedString(string: "  \(dir)", attributes: [.foregroundColor: Palette.dimText, .font: NSFont.systemFont(ofSize: 11)]))
            cell.icon.image = FileIcons.icon(for: name, directory: false)
            cell.label.attributedStringValue = s
            cell.letter.stringValue = f.letter
            cell.letter.textColor = Self.color(f.letter)
        }
        cell.needsLayout = true
        return cell
    }

    static func color(_ letter: String) -> NSColor {
        switch letter {
        case "A", "U": return NSColor(hex: 0x73C991)
        case "D", "!": return NSColor(hex: 0xE5534B)
        case "R", "C": return NSColor(hex: 0x4FC1FF)
        default: return NSColor(hex: 0xE2C08D)
        }
    }
}

// sağ tık menüsü
extension SourceControlPanel: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let item = outline.item(atRow: outline.clickedRow)
        guard item != nil else { return }
        func add(_ title: String, _ run: @escaping () -> Void) {
            let i = NSMenuItem(title: title, action: #selector(runMenu(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = run
            menu.addItem(i)
        }
        if let f = item as? SCMFile, f.letter != "D" { add("Open File") { [weak self] in self?.onOpen?(f) } }
        let p = paths(item)
        switch kind(item) {
        case .staged: add("Unstage Changes") { [weak self] in self?.onUnstage?(p) }
        case .merge: add("Mark as Resolved (Stage)") { [weak self] in self?.onStage?(p) }
        default:
            add("Stage Changes") { [weak self] in self?.onStage?(p) }
            add("Discard Changes") { [weak self] in self?.confirmDiscard(item) }
        }
    }

    @objc private func runMenu(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }
}
