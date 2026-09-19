import AppKit

final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    private(set) var children: [FileNode]?

    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    func loadChildren() -> [FileNode] {
        if let children { return children }
        let list = FileNode.list(url, reuse: [])
        children = list
        return list
    }

    // yüklenmiş alt ağaçları yeniden okur, var olan düğümleri korur (açık klasörler kapanmasın)
    func reload() {
        guard let old = children else { return }
        children = FileNode.list(url, reuse: old)
        children?.forEach { $0.reload() }
    }

    private static func list(_ url: URL, reuse: [FileNode]) -> [FileNode] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        let existing = Dictionary(reuse.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        return urls
            .filter { ![".git", ".DS_Store"].contains($0.lastPathComponent) }
            .map { u in
                if let node = existing[u.path] { return node }
                let dir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileNode(url: u, isDirectory: dir == true)
            }
            .sorted { a, b in
                a.isDirectory != b.isDirectory
                    ? a.isDirectory
                    : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
}

private final class FileCell: NSTableCellView {
    let icon = NSImageView()
    let label = makeLabel("")

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        icon.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 21, y: (bounds.height - 17) / 2, width: bounds.width - 23, height: 17)
    }
}

final class ExplorerView: FlippedView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onOpen: ((URL) -> Void)?
    var onOpenFolder: (() -> Void)?
    var onFilesChanged: (() -> Void)?

    private(set) var root: FileNode?
    private let title = makeLabel("EXPLORER", size: 11, weight: .regular, color: Palette.dimText)
    private let section = makeLabel("", size: 11, weight: .bold, color: Palette.text)
    private let scroll = NSScrollView()
    private let outline = NSOutlineView()
    private let emptyLabel = makeLabel("You have not yet opened a folder.", size: 13, color: Palette.text)
    private let openButton = NSButton(title: "Open Folder", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.chrome

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        column.maxWidth = .greatestFiniteMagnitude
        outline.addTableColumn(column)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
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
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 0
        openButton.target = self
        openButton.action = #selector(openFolderTapped)
        openButton.bezelStyle = .rounded
        openButton.bezelColor = Palette.accent
        openButton.keyEquivalent = ""

        [title, section, scroll, emptyLabel, openButton].forEach(addSubview)
        setRoot(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = NSRect(x: 20, y: 11, width: w - 40, height: 15)
        section.frame = NSRect(x: 12, y: 38, width: w - 24, height: 15)
        scroll.frame = NSRect(x: 0, y: 60, width: w, height: max(0, bounds.height - 60))
        outline.sizeLastColumnToFit()
        emptyLabel.frame = NSRect(x: 20, y: 44, width: w - 40, height: 40)
        openButton.frame = NSRect(x: 20, y: 92, width: w - 40, height: 28)
    }

    func setRoot(_ url: URL?) {
        root = url.map { FileNode(url: $0, isDirectory: true) }
        section.stringValue = url?.lastPathComponent.uppercased() ?? ""
        section.isHidden = url == nil
        scroll.isHidden = url == nil
        emptyLabel.isHidden = url != nil
        openButton.isHidden = url != nil
        outline.reloadData()
    }

    func refresh() {
        guard let root else { return }
        root.reload()
        outline.reloadItem(nil, reloadChildren: true)
    }

    func reveal(_ url: URL?) {
        guard let url, let root else { return outline.deselectAll(nil) }
        // üst klasörleri aç
        let rootPath = root.url.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        if target.hasPrefix(rootPath + "/") {
            var node = root
            for part in target.dropFirst(rootPath.count + 1).split(separator: "/").dropLast() {
                guard let next = node.loadChildren().first(where: { $0.name == part && $0.isDirectory }) else { break }
                outline.expandItem(next)
                node = next
            }
        }
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, node.url.path == url.path {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                return
            }
        }
        outline.deselectAll(nil)
    }

    @objc private func openFolderTapped() {
        onOpenFolder?()
    }

    @objc private func clicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else {
            onOpen?(node.url)
        }
    }

    // veri kaynağı

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? FileNode) ?? root else { return 0 }
        return node.loadChildren().count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? root!).loadChildren()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("file")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? FileCell ?? {
            let c = FileCell()
            c.identifier = id
            return c
        }()
        cell.label.stringValue = node.name
        cell.icon.image = FileIcons.icon(for: node.name, directory: node.isDirectory, open: outlineView.isItemExpanded(node))
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] { outline.reloadItem(node, reloadChildren: false) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] { outline.reloadItem(node, reloadChildren: false) }
    }

    // sağ tık menüsü

    private var target: FileNode? {
        let row = outline.clickedRow
        return row >= 0 ? outline.item(atRow: row) as? FileNode : root
    }

    private var targetDirectory: URL? {
        guard let t = target else { return nil }
        return t.isDirectory ? t.url : t.url.deletingLastPathComponent()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard root != nil else { return }
        let add = { (title: String, action: Selector) in
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("New File…", #selector(newFile))
        add("New Folder…", #selector(newFolder))
        menu.addItem(.separator())
        add("Reveal in Finder", #selector(revealInFinder))
        add("Copy Path", #selector(copyPath))
        if outline.clickedRow >= 0 {
            menu.addItem(.separator())
            add("Rename…", #selector(rename))
            add("Move to Trash", #selector(trash))
        }
    }

    private func ask(_ message: String, value: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private func fail(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    private func changed(expand dir: URL?) {
        refresh()
        if let dir, let node = findNode(dir) { outline.expandItem(node) }
        onFilesChanged?()
    }

    private func findNode(_ url: URL) -> FileNode? {
        for row in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: row) as? FileNode, n.url.path == url.path { return n }
        }
        return nil
    }

    @objc private func newFile() {
        guard let dir = targetDirectory, let name = ask("New file name:") else { return }
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
            changed(expand: dir)
            onOpen?(url)
        } catch { fail(error) }
    }

    @objc private func newFolder() {
        guard let dir = targetDirectory, let name = ask("New folder name:") else { return }
        do {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
            changed(expand: dir)
        } catch { fail(error) }
    }

    @objc private func rename() {
        guard let node = target, node !== root, let name = ask("Rename to:", value: node.name) else { return }
        do {
            try FileManager.default.moveItem(at: node.url, to: node.url.deletingLastPathComponent().appendingPathComponent(name))
            changed(expand: nil)
        } catch { fail(error) }
    }

    @objc private func trash() {
        guard let node = target, node !== root else { return }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            changed(expand: nil)
        } catch { fail(error) }
    }

    @objc private func revealInFinder() {
        guard let url = target?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyPath() {
        guard let url = target?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}
