import AppKit

// aynı belgeyi gösteren sekmeler (bölünmüş gruplar) aynı token'ı paylaşır
final class DocToken {
    var keepMine = false
}

final class EditorTab {
    let view: EditorView
    let untitled: Int
    let doc: DocToken
    var keepMine: Bool {
        get { doc.keepMine }
        set { doc.keepMine = newValue }
    }
    var editor: KernEditor { view.editor }
    var path: String { editor.path().toString() }
    var url: URL? { path.isEmpty ? nil : URL(fileURLWithPath: path) }
    var title: String { url?.lastPathComponent ?? "Untitled-\(untitled)" }

    var isPristine: Bool {
        path.isEmpty && !editor.is_dirty() && editor.line_count() == 1 && editor.line(0).toString().isEmpty
    }

    init(view: EditorView, untitled: Int, doc: DocToken = DocToken()) {
        self.view = view
        self.untitled = untitled
        self.doc = doc
    }
}

final class GroupView: FlippedView {
    let tabBar = TabBarView()
    let breadcrumbs = BreadcrumbsView()
    let host = FlippedView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.editor
        host.background = Palette.editor
        [host, tabBar, breadcrumbs].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let w = bounds.width, tabsH: CGFloat = 35, crumbsH: CGFloat = 22
        tabBar.frame = NSRect(x: 0, y: 0, width: w, height: tabsH)
        breadcrumbs.frame = NSRect(x: 0, y: tabsH, width: w, height: crumbsH)
        host.frame = NSRect(x: 0, y: tabsH + crumbsH, width: w, height: max(0, bounds.height - tabsH - crumbsH))
        host.subviews.forEach { $0.frame = host.bounds }
        tabBar.revealActive()
    }
}

final class EditorGroup {
    let view = GroupView()
    var tabs: [EditorTab] = []
    var active = -1
    var activeTab: EditorTab? { active >= 0 && active < tabs.count ? tabs[active] : nil }
}

final class WorkbenchView: FlippedView {
    let activity = ActivityBar()
    let explorer = ExplorerView()
    let search = SearchPanel()
    let ai = ChatPanel()
    let scm = SourceControlPanel()
    let debug = DebugPanel()
    let console = DebugConsole()
    let handle = SplitHandle()
    let welcome = WelcomeView()
    let findBar = FindBar()
    let status = StatusBarView()
    let terminal = TerminalPanel()
    let terminalHandle = SplitHandle()

    var sidebarWidth: CGFloat = 260
    var sidebarVisible = true
    var zen = false
    var panelMaximized = false
    var panel = 0
    var hasEditors = false
    var terminalVisible = false
    var consoleVisible = false
    var terminalHeight: CGFloat = 280
    var groupViews: [GroupView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            groupHandles.forEach { $0.removeFromSuperview() }
            groupViews.forEach { addSubview($0, positioned: .below, relativeTo: findBar) }
            groupRatios = Array(repeating: 1 / CGFloat(max(1, groupViews.count)), count: groupViews.count)
            groupHandles = (0..<max(0, groupViews.count - 1)).map { i in
                let h = SplitHandle()
                h.onDrag = { [weak self] dx in self?.dragGroup(i, dx) }
                addSubview(h, positioned: .below, relativeTo: findBar)
                return h
            }
            needsLayout = true
        }
    }
    var focusedGroup = 0 { didSet { needsLayout = true } }
    private var groupHandles: [SplitHandle] = []
    private var groupRatios: [CGFloat] = []
    private var editorWidth: CGFloat = 1

    private func dragGroup(_ i: Int, _ dx: CGFloat) {
        let d = dx / max(1, editorWidth), minR = 120 / max(1, editorWidth)
        guard groupRatios[i] + d >= minR, groupRatios[i + 1] - d >= minR else { return }
        groupRatios[i] += d
        groupRatios[i + 1] -= d
        needsLayout = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background = Palette.editor
        findBar.isHidden = true
        terminalHandle.vertical = true
        [activity, explorer, search, ai, scm, debug, welcome, findBar, terminal, console, terminalHandle, handle, status].forEach(addSubview)
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
        let barH: CGFloat = zen ? 0 : 22, tabsH: CGFloat = 35, act: CGFloat = zen ? 0 : 48
        let side = sidebarVisible && !zen ? sidebarWidth : 0
        let body = h - barH

        activity.isHidden = zen
        status.isHidden = zen
        activity.frame = NSRect(x: 0, y: 0, width: act, height: body)
        activity.selected = sidebarVisible ? panel : nil
        explorer.frame = NSRect(x: act, y: 0, width: side, height: body)
        search.frame = explorer.frame
        ai.frame = explorer.frame
        explorer.isHidden = zen || !(sidebarVisible && panel == 0)
        search.isHidden = zen || !(sidebarVisible && panel == 1)
        ai.isHidden = zen || !(sidebarVisible && panel == 2)
        scm.frame = explorer.frame
        scm.isHidden = zen || !(sidebarVisible && panel == 3)
        debug.frame = explorer.frame
        debug.isHidden = zen || !(sidebarVisible && panel == 4)
        handle.frame = NSRect(x: act + side - 2, y: 0, width: 5, height: body)
        handle.isHidden = !sidebarVisible || zen

        let x = act + side
        let bottomVisible = terminalVisible || consoleVisible
        // panel büyütüldüyse editör alanı kalmaz
        let termH = bottomVisible ? (panelMaximized ? body : min(terminalHeight, body - 160)) : 0
        let area = body - termH
        let crumbsH: CGFloat = 22
        editorWidth = w - x
        var gx = x
        var focusFrame = NSRect(x: x, y: 0, width: w - x, height: area)
        for (i, g) in groupViews.enumerated() {
            let gw = i == groupViews.count - 1 ? w - gx : round(editorWidth * groupRatios[i])
            g.isHidden = !hasEditors
            g.frame = NSRect(x: gx, y: 0, width: gw, height: area)
            if i == focusedGroup { focusFrame = g.frame }
            if i < groupHandles.count {
                groupHandles[i].isHidden = !hasEditors
                groupHandles[i].frame = NSRect(x: gx + gw - 2, y: 0, width: 5, height: area)
            }
            gx += gw
        }
        welcome.isHidden = hasEditors
        welcome.frame = NSRect(x: x, y: 0, width: w - x, height: area)
        // alt panel: terminal ya da hata ayıklama konsolu
        terminal.isHidden = !terminalVisible
        terminal.frame = NSRect(x: x, y: area, width: w - x, height: termH)
        console.isHidden = terminalVisible || !consoleVisible
        console.frame = terminal.frame
        terminalHandle.isHidden = !bottomVisible
        terminalHandle.frame = NSRect(x: x, y: area - 2, width: w - x, height: 5)

        let fw = min(460, max(300, focusFrame.width - 60))
        findBar.frame = NSRect(x: focusFrame.maxX - fw - 28, y: tabsH + crumbsH, width: fw, height: findBar.preferredHeight)
        status.frame = NSRect(x: 0, y: body, width: w, height: barH)
    }
}

final class WorkbenchWindowController: NSWindowController, NSWindowDelegate {
    let root = WorkbenchView()
    var onClose: ((WorkbenchWindowController) -> Void)?
    private(set) var folder: URL?
    private(set) var groups: [EditorGroup] = []
    var paletteView: PaletteView? { palette }
    private(set) var focused = 0
    private var group: EditorGroup { groups[focused] }
    private(set) var tabs: [EditorTab] {
        get { group.tabs }
        set { group.tabs = newValue }
    }
    private var active: Int {
        get { group.active }
        set { group.active = newValue }
    }
    var allTabs: [EditorTab] { groups.flatMap(\.tabs) }
    private var untitledCounter = 0
    private var workspace: KernWorkspace?
    private var extraFolders: [URL] = []
    private var extraWorkspaces: [KernWorkspace] = []
    private let queue = DispatchQueue(label: "dev.kern.workspace")
    private var palette: PaletteView?
    private let watcher = FileWatcher()
    var language: LanguageService?
    let hover = HoverView()
    let signature = HoverView()
    let completion = CompletionPopup()
    weak var completionView: EditorView?
    var completionRequest = 0
    var signatureRequest = 0
    var symbolCache: [PaletteItem]?
    var wsSymbolCache: (String, [PaletteItem])?
    var extrasWork: DispatchWorkItem?
    var occurrenceWork: DispatchWorkItem?
    // code lens komutları: yol → satır → [komut JSON]; lensVersion: en son istenen belge sürümü
    var lensCommands: [String: [Int: [String]]] = [:]
    var lensVersion: [String: UInt64] = [:]
    var autoSaveWork: DispatchWorkItem?
    let peek = PeekView()
    var tasksRunner: TaskRunner?
    var diagnosticCounts = (errors: 0, warnings: 0)
    var inlineRequest = 0
    var acceptingGhost = false
    private var fsRefresh: DispatchWorkItem?
    private var askingConflict = false
    let git = GitState()
    let debug = DebugState()

    var activeTab: EditorTab? { active >= 0 && active < tabs.count ? tabs[active] : nil }
    var isEmpty: Bool { folder == nil && allTabs.allSatisfy(\.isPristine) }

    init(folder: URL?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
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
        groups = [makeGroup()]
        root.groupViews = groups.map(\.view)
        wire()
        applySettings()
        if let folder { setFolder(folder) }
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    private func wire() {
        root.activity.onSelect = { [weak self] i in self?.showPanel(i, toggle: true) }
        root.explorer.onOpen = { [weak self] url in self?.openFile(url) }
        root.explorer.onOpenFolder = { NSApp.sendAction(#selector(AppDelegate.openFolder(_:)), to: nil, from: nil) }
        root.explorer.onFilesChanged = { [weak self] in self?.refreshWorkspace() }
        root.search.startSearch = { [weak self] query, flags in
            guard let self, let ws = self.workspace, let main = ws.start_search(query, flags, UInt(SearchPanel.limit)) else { return [] }
            var out = [SearchPanel.SearchJobRef(job: main, prefix: "")]
            // ek klasörlerin sonuçları klasör adı ön ekiyle gelir
            for (i, extra) in self.extraWorkspaces.enumerated() where i < self.extraFolders.count {
                if let job = extra.start_search(query, flags, UInt(SearchPanel.limit)) {
                    out.append(SearchPanel.SearchJobRef(job: job, prefix: self.extraFolders[i].lastPathComponent + "/"))
                }
            }
            return out
        }
        root.search.onOpen = { [weak self] hit in
            guard let self, let url = self.resolveSearchPath(hit.path) else { return }
            self.openFile(url)?.goTo(line: hit.line, col: hit.col, length: hit.len)
        }
        root.search.onReplaceAll = { [weak self] query, repl, flags, targets in
            guard let self else { return }
            // açık ve kirli sekmeler diskteki değişimi ezmesin
            let dirty = self.allTabs.filter { $0.editor.is_dirty() && !$0.path.isEmpty }
            if !dirty.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Save changes before replacing?"
                alert.informativeText = dirty.map(\.title).joined(separator: ", ")
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                dirty.forEach { self.save($0) }
            }
            // hedefler kök başına ayrılır (ek klasörlerde yol ön ekli gelir)
            var files = 0, replaced = 0
            for (i, ws) in ([self.workspace].compactMap { $0 } + self.extraWorkspaces).enumerated() {
                let prefix = i == 0 ? "" : (i - 1 < self.extraFolders.count ? self.extraFolders[i - 1].lastPathComponent + "/" : "")
                let mine = targets.filter { i == 0 ? !self.isExtraPath($0) : $0.hasPrefix(prefix) }
                    .map { prefix.isEmpty ? $0 : String($0.dropFirst(prefix.count)) }
                guard !mine.isEmpty else { continue }
                let result = ws.replace_all(query, flags, repl, mine.joined(separator: "\n")).toString()
                let obj = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any]
                if let err = obj?["error"] as? String { return self.report(err) }
                let parts = (obj?["ok"] as? String ?? "").split(separator: "\t").map { Int($0) ?? 0 }
                files += parts.first ?? 0
                replaced += parts.last ?? 0
            }
            self.root.status.left = self.root.status.left + ["↻ \(replaced) replaced in \(files) files"]
            self.filesChanged(targets.compactMap { self.resolveSearchPath(String($0.split(separator: ":").first ?? ""))?.path })
        }

        let find = root.findBar
        find.onQuery = { [weak self] query, flags in
            guard let view = self?.activeTab?.view else { return }
            view.findQuery = query
            view.findFlags = flags
            if !query.isEmpty {
                if view.editor.has_selection() { view.editor.move_cursor(.Left, false) }
                if view.editor.find_next(query, flags, true) { view.revealCursor(center: true) }
            }
            self?.updateFindCount()
        }
        find.onNext = { [weak self] forward in self?.findStep(forward) }
        find.onReplace = { [weak self] replacement, all in
            guard let self, let view = self.activeTab?.view else { return }
            let q = find.query
            guard !q.isEmpty else { return }
            if all {
                _ = view.editor.replace_all(q, replacement, find.flags)
            } else {
                view.editor.replace_one(q, replacement, find.flags)
            }
            view.changed(edited: true)
            self.updateFindCount()
        }
        find.onClose = { [weak self] in self?.hideFind() }
        root.terminal.onClose = { [weak self] in self?.hideTerminal() }
        root.terminal.onOpenPath = { [weak self] url, line, col in
            let view = self?.openFile(url)
            if let line { view?.goTo(line: line - 1, col: max(0, (col ?? 1) - 1)) }
        }
        root.terminal.environment = { [weak self] in
            var env: [String: String] = [:]
            if let n = self?.window?.windowNumber { env["KERN_WINDOW"] = String(n) }
            if let bin = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
                env["PATH"] = bin + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            }
            return env
        }
        root.status.onClickItem = { [weak self] text in
            guard let self else { return }
            if text.hasPrefix("⚠ No Language Server") {
                self.installLanguageServer(nil)
            } else if text.hasPrefix("⚠ LSP Error"), let tab = self.activeTab, !tab.path.isEmpty {
                self.report(self.language?.status(tab.path) ?? "LSP error")
            }
        }
        watcher.onChange = { [weak self] paths in self?.filesChanged(paths) }
        wireAI()
        wireGit()
        wireDebug()
    }

    // ayarlar

    func applySettings() {
        let theme = Settings.shared.string("workbench.colorTheme")
        let custom = Extensions.shared.theme(named: theme)?["type"] as? String
        switch custom ?? theme {
        case "dark": window?.appearance = NSAppearance(named: .darkAqua)
        case "light": window?.appearance = NSAppearance(named: .aqua)
        default: window?.appearance = nil
        }
        allTabs.forEach { $0.view.needsDisplay = true }
        language?.configure()
        var seen = Set<ObjectIdentifier>()
        for t in allTabs where seen.insert(ObjectIdentifier(t.doc)).inserted { applyIndent(t.editor) }
        update(tabsOnly: true)
    }

    private func applyIndent(_ e: KernEditor) {
        let s = Settings.shared
        // .editorconfig ayarların üstüne biner, dosya sezgisini kapatır
        let cfg = EditorConfig.load(for: e.path().toString())
        let size = cfg.indentSize ?? max(1, s.int("editor.tabSize"))
        let spaces = cfg.useSpaces ?? s.bool("editor.insertSpaces")
        let detect = cfg.isEmpty && s.bool("editor.detectIndentation")
        e.set_indent(UInt(max(1, size)), spaces, detect)
    }

    // editör grupları

    private func makeGroup() -> EditorGroup {
        let g = EditorGroup()
        g.view.tabBar.onSelect = { [weak self, weak g] i in
            guard let self, let g else { return }
            self.focus(g)
            self.select(i)
        }
        g.view.tabBar.onClose = { [weak self, weak g] i in
            guard let self, let g else { return }
            self.focus(g)
            _ = self.closeTab(i)
        }
        g.view.tabBar.onDropTab = { [weak self, weak g] bar, from, to in
            guard let self, let g, let source = self.groups.first(where: { $0.view.tabBar === bar }) else { return }
            self.moveTab(from: source, index: from, to: g, at: to)
        }
        return g
    }

    // sekmeyi gruplar arasında (ya da aynı grupta) taşı
    private func moveTab(from source: EditorGroup, index: Int, to target: EditorGroup, at position: Int) {
        guard index >= 0, index < source.tabs.count else { return }
        let tab = source.tabs.remove(at: index)
        source.active = min(source.active, source.tabs.count - 1)
        var at = position
        if source === target, index < position { at -= 1 }
        target.tabs.insert(tab, at: min(max(0, at), target.tabs.count))
        tab.view.removeFromSuperview()
        // boşalan grup kapanır (tek grup kalmadıysa)
        if source !== target, source.tabs.isEmpty, groups.count > 1, let i = groups.firstIndex(where: { $0 === source }) {
            groups.remove(at: i)
            root.groupViews = groups.map(\.view)
        }
        focused = groups.firstIndex { $0 === target } ?? 0
        root.focusedGroup = focused
        select(target.tabs.firstIndex { $0 === tab } ?? 0)
        if source !== target { source.view.tabBar.needsDisplay = true }
        update()
        window?.makeFirstResponder(tab.view)
    }

    private func focus(_ g: EditorGroup) {
        guard let i = groups.firstIndex(where: { $0 === g }), i != focused else { return }
        focused = i
        root.focusedGroup = i
        if let view = activeTab?.view {
            view.findQuery = root.findBar.isHidden ? "" : root.findBar.query
            view.findFlags = root.findBar.flags
        }
        update()
    }

    @objc func splitEditor(_ sender: Any?) {
        guard let tab = activeTab else { return }
        let g = makeGroup()
        groups.insert(g, at: focused + 1)
        root.groupViews = groups.map(\.view)
        focused += 1
        root.focusedGroup = focused
        let copy = addTab(tab.editor.split_view(), untitled: tab.untitled, doc: tab.doc)
        copy.view.goTo(line: Int(tab.editor.cursor_line()), col: Int(tab.editor.cursor_col()))
        copy.view.topLine = tab.view.topLine
    }

    @objc func focusNextGroup(_ sender: Any?) {
        guard groups.count > 1 else { return }
        let g = groups[(focused + 1) % groups.count]
        focus(g)
        if let view = g.activeTab?.view { window?.makeFirstResponder(view) }
    }

    func siblings(_ tab: EditorTab) -> [EditorTab] {
        allTabs.filter { $0.doc === tab.doc && $0 !== tab }
    }

    // dosya izleme

    private func updateWatch() {
        var paths = Set(allTabs.compactMap { $0.url?.deletingLastPathComponent().path }.filter { p in
            folder.map { !(p + "/").hasPrefix($0.path + "/") } ?? true
        })
        if let folder { paths.insert(folder.path) }
        watcher.watch(paths)
    }

    private func filesChanged(_ paths: [String]) {
        let tree = paths.contains { p in
            guard let folder, p.hasPrefix(folder.path + "/") else { return false }
            return !p.contains("/.git/") || p.hasSuffix("/.git/HEAD")
        }
        if tree {
            fsRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.root.explorer.refresh()
                self?.refreshWorkspace()
                self?.update(tabsOnly: true)
            }
            fsRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
        // FSEvents /private/var bildirir, klasör /var olabilir
        let bare = { (p: String) in p.hasPrefix("/private/") ? String(p.dropFirst(8)) : p }
        if let folder, paths.contains(where: { bare($0).hasPrefix(bare(folder.path) + "/") }) { scheduleGitRefresh() }
        let touched = Set(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        checkDisk(only: touched)
    }

    // diskte değişen sekmeler: temizse sessizce yükle, kirliyse sor
    func checkDisk(only: Set<String>? = nil) {
        guard !askingConflict else { return }
        var seen = Set<ObjectIdentifier>()
        for tab in allTabs where tab.url != nil && seen.insert(ObjectIdentifier(tab.doc)).inserted && tab.editor.disk_changed() {
            if let only, let url = tab.url, !only.contains(url.resolvingSymlinksInPath().path) { continue }
            if !tab.editor.is_dirty() {
                reload(tab)
            } else if !tab.keepMine {
                askingConflict = true
                let alert = NSAlert()
                alert.messageText = "“\(tab.title)” has changed on disk."
                alert.informativeText = "You have unsaved changes. Reload the file from disk and discard them, or keep your version?"
                alert.addButton(withTitle: "Keep My Version")
                alert.addButton(withTitle: "Reload from Disk")
                if alert.runModal() == .alertSecondButtonReturn { reload(tab) } else { tab.keepMine = true }
                askingConflict = false
            }
        }
    }

    private func reload(_ tab: EditorTab) {
        guard tab.editor.reload() else { return }
        tab.keepMine = false
        for t in [tab] + siblings(tab) {
            t.view.changed(edited: true)
            t.view.needsDisplay = true
        }
        update(tabsOnly: true)
    }

    // terminal

    func showTerminal() {
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

    // zen modu: kenar çubuğu, etkinlik çubuğu ve durum çubuğu gizlenir, tam ekrana geçilir
    @objc func toggleZenMode(_ sender: Any?) {
        root.zen.toggle()
        root.needsLayout = true
        let isFull = window?.styleMask.contains(.fullScreen) ?? false
        if root.zen != isFull { window?.toggleFullScreen(nil) }
        if let view = activeTab?.view { window?.makeFirstResponder(view) }
    }

    @objc func togglePanelMaximized(_ sender: Any?) {
        guard root.terminalVisible || root.consoleVisible else { return showTerminal() }
        root.panelMaximized.toggle()
        root.needsLayout = true
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

    @objc func splitTerminal(_ sender: Any?) {
        showTerminal()
        root.terminal.splitTerminal()
    }

    @objc func killTerminal(_ sender: Any?) { root.terminal.kill() }

    @objc func newTerminal(_ sender: Any?) {
        root.terminalVisible = true
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        root.terminal.newTerminal()
    }

    // klasör ve dosyalar

    func setFolder(_ url: URL) {
        saveSession()
        folder = url
        workspace = nil
        root.explorer.setRoot(url)
        root.terminal.cwd = url.path
        readBranch()
        gitOpen(url)
        updateWatch()
        Settings.shared.setProject(url)
        restartLanguage()
        refreshConfigs()
        // self-test geçici klasörü kullanıcının son klasör/son açılanlar listesini kirletmesin
        if ProcessInfo.processInfo.environment["KERN_SELFTEST"] == nil {
            UserDefaults.standard.set(url.path, forKey: "lastFolder")
            RecentFolders.add(url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        extraFolders = []
        extraWorkspaces = []
        queue.async { [weak self] in
            let ws = KernWorkspace(url.path)
            DispatchQueue.main.async { self?.workspace = ws }
        }
        update()
        if allTabs.allSatisfy(\.isPristine) { restoreSession() }
    }

    // çoklu kök: ek klasörler arama, hızlı açma ve gezginde görünür (LSP/git ana klasöre bağlı)
    var allFolders: [URL] { (folder.map { [$0] } ?? []) + extraFolders }

    private func isExtraPath(_ rel: String) -> Bool {
        extraFolders.contains { rel.hasPrefix($0.lastPathComponent + "/") }
    }

    // arama/hızlı açma yolunu (ön ekli olabilir) gerçek dosyaya çevir
    func resolveSearchPath(_ rel: String) -> URL? {
        for f in extraFolders where rel.hasPrefix(f.lastPathComponent + "/") {
            return f.appendingPathComponent(String(rel.dropFirst(f.lastPathComponent.count + 1)))
        }
        return folder?.appendingPathComponent(rel)
    }

    @objc func addFolderToWorkspace(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard folder != nil else { return setFolder(url) }
        guard !allFolders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        extraFolders.append(url)
        root.explorer.setRoots(allFolders)
        updateWatch()
        queue.async { [weak self] in
            let ws = KernWorkspace(url.path)
            DispatchQueue.main.async { self?.extraWorkspaces.append(ws) }
        }
        update()
    }

    @objc func removeFolderFromWorkspace(_ sender: Any?) {
        guard !extraFolders.isEmpty else { return report("No extra folders in this workspace") }
        let items = extraFolders.enumerated().map { i, url in
            PaletteItem(title: url.lastPathComponent, detail: url.path) { [weak self] in
                guard let self, i < self.extraFolders.count else { return }
                self.extraFolders.remove(at: i)
                if i < self.extraWorkspaces.count { self.extraWorkspaces.remove(at: i) }
                self.root.explorer.setRoots(self.allFolders)
                self.updateWatch()
            }
        }
        showPalette("", provider: { _ in items }, placeholder: "Remove folder from workspace")
    }

    // oturum

    func saveSession() {
        guard let folder else { return }
        var seenPaths = Set<String>()
        let entries = allTabs.compactMap { t -> Session.Entry? in
            guard !t.path.isEmpty, seenPaths.insert(t.path).inserted else { return nil }
            return Session.Entry(path: t.path, line: Int(t.editor.cursor_line()), col: Int(t.editor.cursor_col()), top: t.view.topLine)
        }
        let saved = entries.firstIndex { $0.path == activeTab?.path } ?? 0
        SessionStore.save(Session(folder: folder.path, tabs: entries, active: max(0, saved)), for: folder)
    }

    private func restoreSession() {
        guard let folder, let session = SessionStore.load(folder) else { return }
        var views: [(EditorView, Session.Entry)] = []
        for e in session.tabs where FileManager.default.fileExists(atPath: e.path) {
            if let view = openFile(URL(fileURLWithPath: e.path)) { views.append((view, e)) }
        }
        guard !views.isEmpty else { return }
        for (view, e) in views {
            view.goTo(line: e.line, col: e.col)
            view.topLine = e.top
        }
        let target = views[min(session.active, views.count - 1)].0
        if let i = tabs.firstIndex(where: { $0.view === target }) { select(i) }
    }

    private func refreshWorkspace() {
        readBranch()
        scheduleGitRefresh()
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
        // symlink'ler (/var → /private/var) aynı dosya sayılır
        let real = url.standardizedFileURL.resolvingSymlinksInPath().path
        let same: (EditorTab) -> Bool = { $0.path == url.path || (!$0.path.isEmpty && $0.url?.resolvingSymlinksInPath().path == real) }
        if let i = tabs.firstIndex(where: same) {
            select(i)
            return tabs[i].view
        }
        if let other = allTabs.first(where: same) {
            return addTab(other.editor.split_view(), untitled: 0, doc: other.doc).view
        }
        guard let editor = open_editor(url.path) else {
            let alert = NSAlert()
            alert.messageText = "The file “\(url.lastPathComponent)” couldn’t be opened."
            alert.informativeText = url.path
            alert.runModal()
            return nil
        }
        let replacing = tabs.count == 1 && tabs[0].isPristine ? 0 : nil
        applyIndent(editor)
        let tab = addTab(editor, untitled: 0)
        if let replacing { removeTab(replacing) }
        languageOpened(tab)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return tab.view
    }

    func newUntitled() {
        untitledCounter += 1
        let e = KernEditor()
        applyIndent(e)
        addTab(e, untitled: untitledCounter)
    }

    @discardableResult
    private func addTab(_ editor: KernEditor, untitled: Int, doc: DocToken = DocToken()) -> EditorTab {
        guard let view = EditorView(editor: editor) else { fatalError("Metal kullanılamıyor") }
        let tab = EditorTab(view: view, untitled: untitled, doc: doc)
        let owner = group
        wireLanguage(view)
        view.onFocus = { [weak self, weak owner] in
            guard let self, let owner else { return }
            self.focus(owner)
        }
        view.onChange = { [weak self, weak view, weak tab] edited in
            guard let self, let view, let tab else { return }
            if edited {
                self.siblings(tab).forEach { $0.view.needsDisplay = true }
                self.languageChanged(tab)
                self.gitEdited(tab)
            }
            self.inlineCursorMoved(view)
            self.gitCursorMoved(view)
            self.scheduleOccurrences(view)
            self.scheduleAutoSave(tab, edited: edited)
            guard view === self.activeTab?.view else { return }
            self.update(tabsOnly: !edited)
            if edited && !self.root.findBar.isHidden { self.updateFindCount() }
        }
        view.onCodeLens = { [weak self, weak tab] line, index in
            guard let self, let tab else { return }
            self.runCodeLens(tab, line: line, index: index)
        }
        view.onToggleBreakpoint = { [weak self, weak tab] line in
            guard let self, let tab, !tab.path.isEmpty else { return }
            self.setBreakpoint(path: tab.path, line: line, on: !(self.debug.breakpoints[tab.path]?.contains(line) ?? false))
        }
        let at = active >= 0 ? active + 1 : tabs.count
        tabs.insert(tab, at: at)
        select(at)
        updateWatch()
        gitMarks(tab)
        debugSync(tab)
        return tab
    }

    private func removeTab(_ i: Int) {
        let tab = tabs.remove(at: i)
        tab.view.removeFromSuperview()
        if siblings(tab).isEmpty, !tab.path.isEmpty { language?.closed(tab.path) }
        if completionView === tab.view { hideCompletion() }
        if tabs.isEmpty && groups.count > 1 {
            groups.remove(at: focused)
            focused = min(focused, groups.count - 1)
            root.groupViews = groups.map(\.view)
            root.focusedGroup = focused
            updateWatch()
            select(active)
            return
        }
        updateWatch()
        if active >= tabs.count || i < active { active -= 1 }
        if active < 0 && !tabs.isEmpty { active = 0 }
        select(active)
    }

    func select(_ i: Int) {
        if Settings.shared.string("files.autoSave") == "onFocusChange" { autoSaveOnFocusChange() }
        let host = group.view.host
        host.subviews.forEach { $0.removeFromSuperview() }
        active = tabs.isEmpty ? -1 : min(max(0, i), tabs.count - 1)
        if let tab = activeTab {
            tab.view.frame = host.bounds
            host.addSubview(tab.view)
            tab.view.findQuery = root.findBar.isHidden ? "" : root.findBar.query
            tab.view.findFlags = root.findBar.flags
            window?.makeFirstResponder(tab.view)
            tab.view.needsDisplay = true
        }
        update()
        group.view.tabBar.revealActive()
    }

    func closeTab(_ i: Int) -> Bool {
        guard i >= 0, i < tabs.count else { return false }
        let tab = tabs[i]
        if tab.editor.is_dirty() && siblings(tab).isEmpty {
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
        for g in groups.reversed() {
            focus(g)
            for i in tabs.indices.reversed() where tabs[i].editor.is_dirty() {
                guard closeTab(i) else { return false }
            }
        }
        return true
    }

    @discardableResult
    private func save(_ tab: EditorTab, forceAs: Bool = false) -> Bool {
        var error: String
        if tab.path.isEmpty || forceAs {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = tab.title
            if let dir = tab.url?.deletingLastPathComponent() ?? folder { panel.directoryURL = dir }
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            error = tab.editor.save_as(url.path).toString()
            if error.isEmpty { root.explorer.refresh(); refreshWorkspace() }
        } else {
            if tab.editor.disk_changed() && !tab.keepMine {
                let alert = NSAlert()
                alert.messageText = "“\(tab.title)” has been modified on disk since you opened it."
                alert.informativeText = "Saving will overwrite those changes."
                alert.addButton(withTitle: "Overwrite")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return false }
            }
            let s = Settings.shared
            let cfg = EditorConfig.load(for: tab.path)
            let trim = cfg.trimTrailingWhitespace ?? s.bool("files.trimTrailingWhitespace")
            let finalNewline = cfg.insertFinalNewline ?? s.bool("files.insertFinalNewline")
            if trim || finalNewline {
                tab.editor.prepare_save(trim, finalNewline)
                tab.view.changed(edited: true)
            }
            error = tab.editor.save().toString()
        }
        let ok = error.isEmpty
        if ok { tab.keepMine = false; updateWatch() }
        if ok && Settings.shared.isSettingsFile(tab.path) { Settings.shared.reload() }
        if ok { languageSaved(tab, reopened: tab.path.isEmpty || forceAs) }
        siblings(tab).forEach { $0.view.needsDisplay = true }
        if !ok {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Failed to save “\(tab.title)”."
            alert.informativeText = error
            alert.runModal()
        }
        tab.view.needsDisplay = true
        update()
        return ok
    }

    // görünüm durumu

    func refreshUI() { update(tabsOnly: true) }

    private func update(tabsOnly: Bool = false) {
        for g in groups {
            let names = Dictionary(grouping: g.tabs, by: \.title)
            g.view.tabBar.items = g.tabs.map { t in
                let dup = (names[t.title]?.count ?? 0) > 1
                let detail = dup ? t.url?.deletingLastPathComponent().lastPathComponent : nil
                return TabItem(title: t.title, detail: detail, dirty: t.editor.is_dirty(), path: t.path)
            }
            g.view.tabBar.active = g.active
            if let tab = g.activeTab { g.view.breadcrumbs.parts = crumbs(tab) }
        }
        root.hasEditors = !allTabs.isEmpty
        root.needsLayout = true

        let tab = activeTab
        var right: [String] = []
        if let e = tab?.editor {
            right = ["Ln \(e.cursor_line() + 1), Col \(e.cursor_col() + 1)",
                     e.insert_spaces() ? "Spaces: \(e.tab_width())" : "Tab Size: \(e.tab_width())", e.encoding_name().toString(),
                     e.line_ending_name().toString(), e.language().toString()]
        }
        root.status.right = right
        root.status.left = [folder.map { "⌂ \($0.lastPathComponent)" } ?? "No Folder"] + ((git.branch.isEmpty ? branch : git.branch).map { ["⎇ \($0)"] } ?? [])
            + ["⊗ \(diagnosticCounts.errors)  ⚠ \(diagnosticCounts.warnings)"] + (debug.statusText.isEmpty ? [] : [debug.statusText])
            + (git.blame.isEmpty ? [] : [git.blame])
        if let tab, !tab.path.isEmpty, let s = language?.status(tab.path), !s.isEmpty {
            // dil sunucusu yoksa tanı da gelmez: durum çubuğundaki uyarı tıklanınca kurulum komutu terminale yazılır
            right.append(s == "ok" ? "{ } LSP"
                : s.hasPrefix("missing") ? "⚠ No Language Server — click to install"
                : s == "starting" ? "LSP…" : "⚠ LSP Error — click for details")
        }
        root.status.right = right


        guard let window else { return }
        let base = tab?.title ?? "Kern"
        window.title = folder.map { "\(base) — \($0.lastPathComponent)" } ?? base
        window.representedURL = tab?.url
        window.isDocumentEdited = allTabs.contains { $0.editor.is_dirty() }
        if !tabsOnly { root.explorer.reveal(tab?.url) }
    }

    private func crumbs(_ tab: EditorTab) -> [String] {
        if let url = tab.url, let folder, contains(url) {
            return String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
                .split(separator: "/").map(String.init)
        }
        return tab.url.map { Array($0.pathComponents.suffix(3)) } ?? [tab.title]
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
        let err = find_error(q, root.findBar.flags).toString()
        guard err.isEmpty else { return root.findBar.setCount("Invalid regex", empty: true) }
        let s = Array(view.editor.find_status(q, root.findBar.flags))
        let total = Int(s.first ?? 0), current = Int(s.count > 1 ? s[1] : 0)
        root.findBar.setCount(total == 0 ? "No results" : "\(current == 0 ? "?" : String(current)) of \(total)", empty: total == 0)
    }

    private func findStep(_ forward: Bool) {
        guard let view = activeTab?.view else { return }
        let q = root.findBar.query
        guard !q.isEmpty else { return }
        if view.editor.find_next(q, root.findBar.flags, forward) {
            view.revealCursor(center: true)
            view.needsDisplay = true
            update(tabsOnly: true)
        }
        updateFindCount()
    }

    func hideFind() {
        root.findBar.isHidden = true
        allTabs.forEach { $0.view.findQuery = "" }
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

    func showPalette(_ text: String, provider custom: ((String) -> [PaletteItem])? = nil, placeholder: String? = nil) {
        showPaletteInternal(text)
        if let custom { palette?.provider = custom; palette?.present(text: text) }
        if let placeholder { palette?.input.field.placeholderString = placeholder }
    }

    private func showPaletteInternal(_ text: String) {
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
        if raw.hasPrefix("@") { return symbolItems(String(raw.dropFirst())) }
        if raw.hasPrefix("#") { return workspaceSymbolItems(String(raw.dropFirst())) }
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
        // ek klasörler: yollar klasör adı ön ekiyle listelenir
        for (i, extra) in extraWorkspaces.enumerated() where i < extraFolders.count {
            let prefix = extraFolders[i].lastPathComponent + "/"
            paths += queue.sync { extra.quick_open(raw, 30).toString() }.split(separator: "\n").map { prefix + $0 }
        }
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
                guard let url = self?.resolveSearchPath(path) else { return }
                self?.openFile(url)
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
        guard let tab = activeTab else { return }
        // formatOnSave: biçimlendirme düzenlemeleri uygulandıktan sonra kaydet
        guard Settings.shared.bool("editor.formatOnSave"), !tab.path.isEmpty, ensureLanguage() != nil else {
            save(tab)
            return
        }
        formatDocument(nil, then: { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.save(tab)
        })
    }

    // otomatik kaydetme (files.autoSave)
    func scheduleAutoSave(_ tab: EditorTab, edited: Bool) {
        guard edited, Settings.shared.string("files.autoSave") == "afterDelay", !tab.path.isEmpty else { return }
        autoSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab, !tab.path.isEmpty, tab.editor.is_dirty() else { return }
            self.save(tab)
        }
        autoSaveWork = work
        let delay = max(200, Settings.shared.int("files.autoSaveDelay"))
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
    }

    // odak değişince kaydet
    func autoSaveOnFocusChange() {
        guard ["afterDelay", "onFocusChange"].contains(Settings.shared.string("files.autoSave")) else { return }
        var seen = Set<ObjectIdentifier>()
        for t in allTabs where !t.path.isEmpty && t.editor.is_dirty() && seen.insert(ObjectIdentifier(t.doc)).inserted {
            save(t)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        if let tab = activeTab { save(tab, forceAs: true) }
    }

    @objc func saveAllDocuments(_ sender: Any?) {
        var seen = Set<ObjectIdentifier>()
        allTabs.filter { $0.editor.is_dirty() && seen.insert(ObjectIdentifier($0.doc)).inserted }.forEach { save($0) }
    }

    @objc func closeEditor(_ sender: Any?) {
        if allTabs.isEmpty { window?.performClose(sender) } else if tabs.isEmpty { focusNextGroup(sender) } else { _ = closeTab(active) }
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
    @objc func goToSymbol(_ sender: Any?) { symbolCache = nil; showPalette("@") }
    @objc func goToWorkspaceSymbol(_ sender: Any?) { wsSymbolCache = nil; showPalette("#") }
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
        saveSession()
        return confirmCloseAll()
    }

    func windowWillClose(_ notification: Notification) {
        watcher.stop()
        stopDebugging(nil)
        onClose?(self)
    }

    @objc func openSettingsJSON(_ sender: Any?) { openFile(Settings.shared.ensureUserFile()) }
    @objc func openKeymapJSON(_ sender: Any?) { openFile(Settings.shared.ensureKeymapFile()) }

    func windowDidResignKey(_ notification: Notification) {
        autoSaveOnFocusChange()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        Settings.shared.setProject(folder)
        root.explorer.refresh()
        refreshWorkspace()
        checkDisk()
    }
}
