import AppKit

final class EditorTab {
    let view: EditorView
    let untitled: Int
    var editor: KernEditor { view.editor }
    var path: String { editor.path().toString() }
    var url: URL? { path.isEmpty ? nil : URL(fileURLWithPath: path) }
    var title: String { url?.lastPathComponent ?? "Untitled-\(untitled)" }

    var isPristine: Bool {
        path.isEmpty && !editor.is_dirty() && editor.line_count() == 1 && editor.line(0).toString().isEmpty
    }

    init(view: EditorView, untitled: Int) {
        self.view = view
        self.untitled = untitled
    }
}

final class WorkbenchView: FlippedView {
    let activity = ActivityBar()
    let explorer = ExplorerView()
    let search = SearchPanel()
    let handle = SplitHandle()
    let tabBar = TabBarView()
    let breadcrumbs = BreadcrumbsView()
    let host = FlippedView()
    let welcome = WelcomeView()
    let findBar = FindBar()
    let status = StatusBarView()
    let terminal = TerminalPanel()
    let terminalHandle = SplitHandle()

    var sidebarWidth: CGFloat = 260
    var sidebarVisible = true
    var panel = 0
    var hasEditors = false
    var terminalVisible = false
    var terminalHeight: CGFloat = 280

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background = Palette.editor
        host.background = Palette.editor
        findBar.isHidden = true
        terminalHandle.vertical = true
        [activity, explorer, search, host, welcome, tabBar, breadcrumbs, findBar, terminal, terminalHandle, handle, status].forEach(addSubview)
        handle.onDrag = { [weak self] dx in
            guard let self else { return }
            self.sidebarWidth = min(max(170, self.sidebarWidth + dx), 640)
            self.needsLayout = true
        }
        terminalHandle.onDrag = { [weak self] dy in
            guard let self else { return }
            self.terminalHeight = min(max(100, self.terminalHeight - dy), self.bounds.height - 160)
            self.needsLayout = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let barH: CGFloat = 22, tabsH: CGFloat = 35, act: CGFloat = 48
        let side = sidebarVisible ? sidebarWidth : 0
        let body = h - barH

        activity.frame = NSRect(x: 0, y: 0, width: act, height: body)
        activity.selected = sidebarVisible ? panel : nil
        explorer.frame = NSRect(x: act, y: 0, width: side, height: body)
        search.frame = explorer.frame
        explorer.isHidden = !(sidebarVisible && panel == 0)
        search.isHidden = !(sidebarVisible && panel == 1)
        handle.frame = NSRect(x: act + side - 2, y: 0, width: 5, height: body)
        handle.isHidden = !sidebarVisible

        let x = act + side
        let termH = terminalVisible ? min(terminalHeight, body - 160) : 0
        let area = body - termH
        let crumbsH: CGFloat = 22
        tabBar.isHidden = !hasEditors
        tabBar.frame = NSRect(x: x, y: 0, width: w - x, height: tabsH)
        breadcrumbs.isHidden = !hasEditors
        breadcrumbs.frame = NSRect(x: x, y: tabsH, width: w - x, height: crumbsH)
        host.isHidden = !hasEditors
        host.frame = NSRect(x: x, y: tabsH + crumbsH, width: w - x, height: area - tabsH - crumbsH)
        host.subviews.forEach { $0.frame = host.bounds }
        welcome.isHidden = hasEditors
        welcome.frame = NSRect(x: x, y: 0, width: w - x, height: area)
        terminal.isHidden = !terminalVisible
        terminal.frame = NSRect(x: x, y: area, width: w - x, height: termH)
        terminalHandle.isHidden = !terminalVisible
        terminalHandle.frame = NSRect(x: x, y: area - 2, width: w - x, height: 5)

        let fw = min(460, max(300, (w - x) - 60))
        findBar.frame = NSRect(x: w - fw - 28, y: tabsH + crumbsH, width: fw, height: findBar.preferredHeight)
        status.frame = NSRect(x: 0, y: body, width: w, height: barH)
    }
}

final class WorkbenchWindowController: NSWindowController, NSWindowDelegate {
    let root = WorkbenchView()
    var onClose: ((WorkbenchWindowController) -> Void)?
    private(set) var folder: URL?
    private(set) var tabs: [EditorTab] = []
    private var active = -1
    private var untitledCounter = 0
    private var workspace: KernWorkspace?
    private let queue = DispatchQueue(label: "dev.kern.workspace")
    private var palette: PaletteView?

    var activeTab: EditorTab? { active >= 0 && active < tabs.count ? tabs[active] : nil }
    var isEmpty: Bool { folder == nil && tabs.allSatisfy(\.isPristine) }

    init(folder: URL?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Palette.chrome
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 640, height: 400)
        window.contentView = root
        // ekrana sığdır
        if let area = NSScreen.main?.visibleFrame {
            let size = NSSize(width: min(1280, area.width - 40), height: min(852, area.height - 40))
            window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                   width: size.width, height: size.height), display: false)
        }
        window.setFrameAutosaveName("KernWorkbench")
        super.init(window: window)
        window.delegate = self
        wire()
        if let folder { setFolder(folder) }
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    private func wire() {
        root.activity.onSelect = { [weak self] i in self?.showPanel(i, toggle: true) }
        root.explorer.onOpen = { [weak self] url in self?.openFile(url) }
        root.explorer.onOpenFolder = { NSApp.sendAction(#selector(AppDelegate.openFolder(_:)), to: nil, from: nil) }
        root.explorer.onFilesChanged = { [weak self] in self?.refreshWorkspace() }
        root.search.onSearch = { [weak self] query, caseSensitive, done in
            guard let self, let ws = self.workspace else { return done("") }
            self.queue.async {
                let raw = ws.search(query, caseSensitive, 2000).toString()
                DispatchQueue.main.async { done(raw) }
            }
        }
        root.search.onOpen = { [weak self] hit in
            guard let self, let folder = self.folder else { return }
            self.openFile(folder.appendingPathComponent(hit.path))?.goTo(line: hit.line, col: hit.col, length: hit.len)
        }
        root.tabBar.onSelect = { [weak self] i in self?.select(i) }
        root.tabBar.onClose = { [weak self] i in _ = self?.closeTab(i) }

        let find = root.findBar
        find.onQuery = { [weak self] query, caseSensitive in
            guard let view = self?.activeTab?.view else { return }
            view.findQuery = query
            view.findCaseSensitive = caseSensitive
            if !query.isEmpty {
                if view.editor.has_selection() { view.editor.move_cursor(.Left, false) }
                if view.editor.find_next(query, caseSensitive, true) { view.revealCursor(center: true) }
            }
            self?.updateFindCount()
        }
        find.onNext = { [weak self] forward in self?.findStep(forward) }
        find.onReplace = { [weak self] replacement, all in
            guard let self, let view = self.activeTab?.view else { return }
            let q = find.query
            guard !q.isEmpty else { return }
            if all {
                _ = view.editor.replace_all(q, replacement, find.caseSensitive)
            } else {
                view.editor.replace_one(q, replacement, find.caseSensitive)
            }
            view.changed(edited: true)
            self.updateFindCount()
        }
        find.onClose = { [weak self] in self?.hideFind() }
        root.terminal.onClose = { [weak self] in self?.hideTerminal() }
    }

    // terminal

    private func showTerminal() {
        root.terminalVisible = true
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        root.terminal.focus()
    }

    private func hideTerminal() {
        root.terminalVisible = false
        root.needsLayout = true
        if let view = activeTab?.view { window?.makeFirstResponder(view) }
    }

    @objc func toggleTerminal(_ sender: Any?) {
        let focused = root.terminal.terminal != nil && window?.firstResponder === root.terminal.terminal
        if !root.terminalVisible {
            showTerminal()
        } else if focused {
            hideTerminal()
        } else {
            root.terminal.focus()
        }
    }

    @objc func newTerminal(_ sender: Any?) {
        root.terminalVisible = true
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        root.terminal.newTerminal()
    }

    // klasör ve dosyalar

    func setFolder(_ url: URL) {
        folder = url
        workspace = nil
        root.explorer.setRoot(url)
        root.terminal.cwd = url.path
        readBranch()
        UserDefaults.standard.set(url.path, forKey: "lastFolder")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        queue.async { [weak self] in
            let ws = KernWorkspace(url.path)
            DispatchQueue.main.async { self?.workspace = ws }
        }
        update()
    }

    private func refreshWorkspace() {
        readBranch()
        guard let ws = workspace else { return }
        queue.async { ws.refresh() }
    }

    private var branch: String?

    // .git/HEAD → dal adı ya da kısa commit
    private func readBranch() {
        guard let folder, let head = try? String(contentsOf: folder.appendingPathComponent(".git/HEAD"), encoding: .utf8) else {
            branch = nil
            return
        }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        branch = line.hasPrefix("ref: refs/heads/") ? String(line.dropFirst(16)) : String(line.prefix(7))
    }

    // yazı boyutu

    @objc func zoomIn(_ sender: Any?) { EditorView.setFontSize(EditorView.fontSize + 1) }
    @objc func zoomOut(_ sender: Any?) { EditorView.setFontSize(EditorView.fontSize - 1) }
    @objc func resetZoom(_ sender: Any?) { EditorView.setFontSize(13) }

    func contains(_ url: URL) -> Bool {
        guard let folder else { return false }
        return url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    @discardableResult
    func openFile(_ url: URL) -> EditorView? {
        if let i = tabs.firstIndex(where: { $0.path == url.path }) {
            select(i)
            return tabs[i].view
        }
        guard let editor = open_editor(url.path) else {
            let alert = NSAlert()
            alert.messageText = "The file “\(url.lastPathComponent)” couldn’t be opened."
            alert.informativeText = url.path
            alert.runModal()
            return nil
        }
        let replacing = tabs.count == 1 && tabs[0].isPristine ? 0 : nil
        let tab = addTab(editor, untitled: 0)
        if let replacing { removeTab(replacing) }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return tab.view
    }

    func newUntitled() {
        untitledCounter += 1
        addTab(KernEditor(), untitled: untitledCounter)
    }

    @discardableResult
    private func addTab(_ editor: KernEditor, untitled: Int) -> EditorTab {
        guard let view = EditorView(editor: editor) else { fatalError("Metal kullanılamıyor") }
        let tab = EditorTab(view: view, untitled: untitled)
        view.onChange = { [weak self, weak view] edited in
            guard let self, let view, view === self.activeTab?.view else { return }
            self.update(tabsOnly: !edited)
            if edited && !self.root.findBar.isHidden { self.updateFindCount() }
        }
        let at = active >= 0 ? active + 1 : tabs.count
        tabs.insert(tab, at: at)
        select(at)
        return tab
    }

    private func removeTab(_ i: Int) {
        let tab = tabs.remove(at: i)
        tab.view.removeFromSuperview()
        if active >= tabs.count || i < active { active -= 1 }
        if active < 0 && !tabs.isEmpty { active = 0 }
        select(active)
    }

    func select(_ i: Int) {
        root.host.subviews.forEach { $0.removeFromSuperview() }
        active = tabs.isEmpty ? -1 : min(max(0, i), tabs.count - 1)
        if let tab = activeTab {
            tab.view.frame = root.host.bounds
            root.host.addSubview(tab.view)
            tab.view.findQuery = root.findBar.isHidden ? "" : root.findBar.query
            tab.view.findCaseSensitive = root.findBar.caseSensitive
            window?.makeFirstResponder(tab.view)
            tab.view.needsDisplay = true
        }
        update()
        root.tabBar.revealActive()
    }

    func closeTab(_ i: Int) -> Bool {
        guard i >= 0, i < tabs.count else { return false }
        let tab = tabs[i]
        if tab.editor.is_dirty() {
            select(i)
            switch confirmSave(tab.title) {
            case .alertFirstButtonReturn: guard save(tab) else { return false }
            case .alertThirdButtonReturn: break
            default: return false
            }
        }
        removeTab(i)
        return true
    }

    private func confirmSave(_ name: String) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \(name)?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        return alert.runModal()
    }

    func confirmCloseAll() -> Bool {
        for i in tabs.indices.reversed() where tabs[i].editor.is_dirty() {
            guard closeTab(i) else { return false }
        }
        return true
    }

    @discardableResult
    private func save(_ tab: EditorTab, forceAs: Bool = false) -> Bool {
        var ok: Bool
        if tab.path.isEmpty || forceAs {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = tab.title
            if let dir = tab.url?.deletingLastPathComponent() ?? folder { panel.directoryURL = dir }
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            ok = tab.editor.save_as(url.path)
            if ok { root.explorer.refresh(); refreshWorkspace() }
        } else {
            ok = tab.editor.save()
        }
        if !ok {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Failed to save “\(tab.title)”."
            alert.runModal()
        }
        tab.view.needsDisplay = true
        update()
        return ok
    }

    // görünüm durumu

    private func update(tabsOnly: Bool = false) {
        let names = Dictionary(grouping: tabs, by: \.title)
        root.tabBar.items = tabs.map { t in
            let dup = (names[t.title]?.count ?? 0) > 1
            let detail = dup ? t.url?.deletingLastPathComponent().lastPathComponent : nil
            return TabItem(title: t.title, detail: detail, dirty: t.editor.is_dirty(), path: t.path)
        }
        root.tabBar.active = active
        root.hasEditors = !tabs.isEmpty
        root.needsLayout = true

        let tab = activeTab
        var right: [String] = []
        if let e = tab?.editor {
            right = ["Ln \(e.cursor_line() + 1), Col \(e.cursor_col() + 1)", "Spaces: 4", "UTF-8",
                     e.line_ending_name().toString(), e.language().toString()]
        }
        root.status.right = right
        root.status.left = [folder.map { "⌂ \($0.lastPathComponent)" } ?? "No Folder"] + (branch.map { ["⎇ \($0)"] } ?? [])

        if let tab {
            if let url = tab.url, let folder, contains(url) {
                root.breadcrumbs.parts = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
                    .split(separator: "/").map(String.init)
            } else {
                root.breadcrumbs.parts = tab.url.map { Array($0.pathComponents.suffix(3)) } ?? [tab.title]
            }
        }

        guard let window else { return }
        let base = tab?.title ?? "Kern"
        window.title = folder.map { "\(base) — \($0.lastPathComponent)" } ?? base
        window.representedURL = tab?.url
        window.isDocumentEdited = tabs.contains { $0.editor.is_dirty() }
        if !tabsOnly { root.explorer.reveal(tab?.url) }
    }

    private func showPanel(_ i: Int, toggle: Bool) {
        if toggle && root.sidebarVisible && root.panel == i {
            root.sidebarVisible = false
        } else {
            root.sidebarVisible = true
            root.panel = i
        }
        root.needsLayout = true
    }

    // bul

    private func updateFindCount() {
        guard let view = activeTab?.view else { return }
        let q = root.findBar.query
        guard !q.isEmpty else { return root.findBar.setCount("", empty: false) }
        let s = Array(view.editor.find_status(q, root.findBar.caseSensitive))
        let total = Int(s.first ?? 0), current = Int(s.count > 1 ? s[1] : 0)
        root.findBar.setCount(total == 0 ? "No results" : "\(current == 0 ? "?" : String(current)) of \(total)", empty: total == 0)
    }

    private func findStep(_ forward: Bool) {
        guard let view = activeTab?.view else { return }
        let q = root.findBar.query
        guard !q.isEmpty else { return }
        if view.editor.find_next(q, root.findBar.caseSensitive, forward) {
            view.revealCursor(center: true)
            view.needsDisplay = true
            update(tabsOnly: true)
        }
        updateFindCount()
    }

    func hideFind() {
        root.findBar.isHidden = true
        tabs.forEach { $0.view.findQuery = "" }
        if let view = activeTab?.view { window?.makeFirstResponder(view) }
    }

    private func showFind(replace: Bool) {
        guard let view = activeTab?.view else { return }
        let selected = view.editor.selected_text().toString()
        let query = !selected.isEmpty && !selected.contains("\n") ? selected : nil
        root.findBar.isHidden = false
        root.needsLayout = true
        root.findBar.present(replace: replace, query: query)
    }

    // palet

    private func showPalette(_ text: String) {
        palette?.dismiss()
        let p = PaletteView()
        let w = min(620, root.bounds.width - 40)
        p.frame = NSRect(x: (root.bounds.width - w) / 2, y: 6, width: w, height: 40)
        p.provider = { [weak self] q in self?.paletteItems(q) ?? [] }
        p.onDismiss = { [weak self] in
            guard let self else { return }
            self.palette = nil
            if let view = self.activeTab?.view, self.window?.firstResponder === self.window { self.window?.makeFirstResponder(view) }
        }
        root.addSubview(p)
        palette = p
        p.present(text: text)
    }

    private func paletteItems(_ raw: String) -> [PaletteItem] {
        if raw.hasPrefix(">") {
            let q = raw.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
            return MainMenu.commands().filter { q.isEmpty || fuzzy($0.title.lowercased(), q) }
        }
        if raw.hasPrefix(":") {
            guard let view = activeTab?.view else { return [] }
            let total = Int(view.editor.line_count())
            guard let n = Int(raw.dropFirst().trimmingCharacters(in: .whitespaces)) else {
                return [PaletteItem(title: "Type a line number between 1 and \(total) to navigate to", run: {})]
            }
            let line = min(max(1, n), total)
            return [PaletteItem(title: "Go to line \(line)", run: { [weak view] in view?.goTo(line: line - 1, col: 0) })]
        }
        guard let ws = workspace, let folder else {
            return tabs.filter { raw.isEmpty || fuzzy($0.title.lowercased(), raw.lowercased()) }.map { t in
                PaletteItem(title: t.title, detail: t.url?.deletingLastPathComponent().path ?? "", icon: FileIcons.icon(for: t.title, directory: false)) { [weak self] in
                    if let i = self?.tabs.firstIndex(where: { $0 === t }) { self?.select(i) }
                }
            }
        }
        var paths = queue.sync { ws.quick_open(raw, 60).toString() }.split(separator: "\n").map(String.init)
        // boş sorguda önce açık sekmeler
        if raw.isEmpty {
            let open = tabs.reversed().compactMap { t -> String? in
                guard let p = t.url?.standardizedFileURL.path, p.hasPrefix(folder.standardizedFileURL.path + "/") else { return nil }
                return String(p.dropFirst(folder.standardizedFileURL.path.count + 1))
            }
            paths = open + paths.filter { !open.contains($0) }
        }
        return paths.map { path in
            let name = (path as NSString).lastPathComponent
            let dir = (path as NSString).deletingLastPathComponent
            return PaletteItem(title: name, detail: dir, icon: FileIcons.icon(for: name, directory: false)) { [weak self] in
                self?.openFile(folder.appendingPathComponent(path))
            }
        }
    }

    private func fuzzy(_ text: String, _ q: String) -> Bool {
        var it = q.makeIterator()
        var c = it.next()
        for ch in text where ch == c { c = it.next() }
        return c == nil
    }

    // menü eylemleri

    @objc func newDocument(_ sender: Any?) { newUntitled() }

    @objc func saveDocument(_ sender: Any?) {
        if let tab = activeTab { save(tab) }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        if let tab = activeTab { save(tab, forceAs: true) }
    }

    @objc func saveAllDocuments(_ sender: Any?) {
        tabs.filter { $0.editor.is_dirty() }.forEach { save($0) }
    }

    @objc func closeEditor(_ sender: Any?) {
        if tabs.isEmpty { window?.performClose(sender) } else { _ = closeTab(active) }
    }

    @objc func toggleSidebarVisibility(_ sender: Any?) {
        root.sidebarVisible.toggle()
        root.needsLayout = true
    }

    @objc func showExplorer(_ sender: Any?) { showPanel(0, toggle: false) }

    @objc func showSearch(_ sender: Any?) {
        showPanel(1, toggle: false)
        let selected = activeTab?.editor.selected_text().toString() ?? ""
        root.search.focus(query: selected.contains("\n") ? nil : selected)
    }

    @objc func showFind(_ sender: Any?) { showFind(replace: false) }
    @objc func showReplace(_ sender: Any?) { showFind(replace: true) }
    @objc func findNextMatch(_ sender: Any?) { findStep(true) }
    @objc func findPreviousMatch(_ sender: Any?) { findStep(false) }
    @objc func quickOpen(_ sender: Any?) { showPalette("") }
    @objc func showCommands(_ sender: Any?) { showPalette(">") }
    @objc func goToLine(_ sender: Any?) { showPalette(":") }

    @objc func nextEditor(_ sender: Any?) {
        if !tabs.isEmpty { select((active + 1) % tabs.count) }
    }

    @objc func previousEditor(_ sender: Any?) {
        if !tabs.isEmpty { select((active - 1 + tabs.count) % tabs.count) }
    }

    // pencere

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmCloseAll()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        root.explorer.refresh()
        refreshWorkspace()
    }
}
