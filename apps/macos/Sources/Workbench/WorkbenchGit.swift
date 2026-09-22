import AppKit

// git durumu; tüm depo işlemleri tek seri kuyrukta (index kilidi çakışmasın)
final class GitState {
    var repo: KernRepo?
    let queue = DispatchQueue(label: "dev.kern.git")
    var generation = 0
    var refreshWork: DispatchWorkItem?
    var markWork: [ObjectIdentifier: DispatchWorkItem] = [:]
    var blameWork: DispatchWorkItem?
    var blameKey = ""
    var blame = ""
    var branch = ""
}

extension WorkbenchWindowController {
    func wireGit() {
        let scm = root.scm
        scm.onRefresh = { [weak self] in self?.gitRefresh() }
        scm.onOpen = { [weak self] f in
            guard let self, let root = self.gitRoot, f.letter != "D" else { return }
            self.openFile(root.appendingPathComponent(f.path))
        }
        scm.onDiff = { [weak self] f in
            guard let self, let root = self.gitRoot else { return }
            self.showDiff(root.appendingPathComponent(f.path), rev: "HEAD", title: f.path)
        }
        scm.onHistory = { [weak self] f in
            guard let self, let root = self.gitRoot else { return }
            self.showLog(path: root.appendingPathComponent(f.path).path)
        }
        scm.onStage = { [weak self] p in self?.gitRun { $0.stage(p.joined(separator: "\n")) } }
        scm.onUnstage = { [weak self] p in self?.gitRun { $0.unstage(p.joined(separator: "\n")) } }
        scm.onDiscard = { [weak self] p in self?.gitDiscard(p) }
        scm.onCommit = { [weak self] msg in self?.gitCommit(msg) }
        scm.onPush = { [weak self] in self?.gitRun(progress: "Pushing…", done: "Pushed.") { $0.push() } }
        scm.onPull = { [weak self] in self?.gitRun(progress: "Pulling…", done: "Pulled.") { $0.pull() } }
        scm.onBranch = { [weak self] in self?.showBranchPicker() }
    }

    var gitRoot: URL? { git.repo.map { URL(fileURLWithPath: $0.root().toString()) } }

    func gitOpen(_ folder: URL?) {
        git.generation += 1
        git.repo = nil
        git.blame = ""
        let gen = git.generation
        guard let folder else { return root.scm.set(status: nil, branch: "") }
        git.queue.async { [weak self] in
            let repo = discover_repo(folder.path)
            DispatchQueue.main.async {
                guard let self, self.git.generation == gen else { return }
                self.git.repo = repo
                self.gitRefresh()
            }
        }
    }

    func scheduleGitRefresh() {
        git.refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.gitRefresh() }
        git.refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func gitRefresh() {
        guard let repo = git.repo else {
            root.scm.set(status: nil, branch: "")
            allTabs.forEach { $0.view.gitMarks = [:] }
            return
        }
        let gen = git.generation
        git.queue.async { [weak self] in
            let status = repo.status().toString(), branch = repo.branch().toString()
            DispatchQueue.main.async {
                guard let self, self.git.generation == gen else { return }
                self.git.branch = branch
                self.root.scm.set(status: status, branch: branch)
                self.refreshUI()
                var seen = Set<ObjectIdentifier>()
                for t in self.allTabs where seen.insert(ObjectIdentifier(t.doc)).inserted { self.gitMarks(t) }
                self.git.blameKey = ""
                if let view = self.activeTab?.view { self.gitCursorMoved(view) }
            }
        }
    }

    // komut → {"ok"} / {"error"}; bitince durum yenilenir
    func gitRun(progress: String? = nil, done: String? = nil, clear: Bool = false, _ op: @escaping (KernRepo) -> RustString) {
        guard let repo = git.repo else { return }
        let scm = root.scm
        scm.setBusy(true)
        if let progress { scm.show(progress) }
        git.queue.async { [weak self] in
            let raw = op(repo).toString()
            DispatchQueue.main.async {
                scm.setBusy(false)
                let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: String] ?? [:]
                if let err = obj["error"] {
                    scm.show(err, error: true)
                } else {
                    scm.show(done ?? "")
                    if clear { scm.clearMessage() }
                }
                self?.gitRefresh()
            }
        }
    }

    // hiçbir şey stage edilmemişse tüm değişiklikler eklenir
    private func gitCommit(_ message: String) {
        let groups = root.scm.groups
        guard !groups.contains(where: { $0.kind == .merge }) else {
            return root.scm.show("Resolve merge conflicts before committing.", error: true)
        }
        let stageAll = !groups.contains { $0.kind == .staged }
        let changed = groups.first { $0.kind == .changes }?.files.map(\.path) ?? []
        guard !stageAll || !changed.isEmpty else { return root.scm.show("There are no changes to commit.", error: true) }
        gitRun(done: "Committed.", clear: true) { repo in
            if stageAll {
                let r = repo.stage(changed.joined(separator: "\n"))
                if r.toString().contains("\"error\"") { return r }
            }
            return repo.commit(message, false)
        }
    }

    // izlenmeyen dosyalar çöpe, diğerleri HEAD'e döner
    private func gitDiscard(_ paths: [String]) {
        guard let base = gitRoot else { return }
        let untracked = Set(root.scm.groups.flatMap(\.files).filter { $0.letter == "U" }.map(\.path))
        for p in paths where untracked.contains(p) {
            try? FileManager.default.trashItem(at: base.appendingPathComponent(p), resultingItemURL: nil)
        }
        let tracked = paths.filter { !untracked.contains($0) }
        if tracked.isEmpty { return gitRefresh() }
        gitRun { $0.discard(tracked.joined(separator: "\n")) }
    }

    // gutter

    func gitEdited(_ tab: EditorTab) {
        let key = ObjectIdentifier(tab.doc)
        git.markWork[key]?.cancel()
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.git.markWork[key] = nil
            self.gitMarks(tab)
        }
        git.markWork[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func gitMarks(_ tab: EditorTab) {
        let views = [tab] + siblings(tab)
        let text = tab.editor.text().toString()
        let conflicts = conflictLines(text)
        views.forEach { $0.view.conflictLines = conflicts }
        guard let repo = git.repo, !tab.path.isEmpty, let base = gitRoot,
              tab.url!.resolvingSymlinksInPath().path.hasPrefix(base.resolvingSymlinksInPath().path + "/") else {
            views.forEach { $0.view.gitMarks = [:] }
            return
        }
        let path = tab.path, version = tab.editor.version()
        git.queue.async { [weak self, weak tab] in
            let raw = repo.line_changes(path, text).toString()
            var marks: [Int: Character] = [:]
            for line in raw.split(separator: "\n") {
                let f = line.split(separator: "\t")
                guard f.count == 3, let l = Int(f[0]), let n = Int(f[1]), let k = f[2].first else { continue }
                if k == "D" { marks[l] = "D" } else { for i in l..<(l + n) { marks[i] = k } }
            }
            DispatchQueue.main.async {
                guard let self, let tab, tab.editor.version() == version else { return }
                ([tab] + self.siblings(tab)).forEach { $0.view.gitMarks = marks }
            }
        }
    }

    private func conflictLines(_ text: String) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for b in parseConflicts(text) {
            for i in b.start...b.end { out[i] = i == b.start || i == b.mid || i == b.end ? 0 : (i < b.mid ? 1 : 2) }
        }
        return out
    }

    private func parseConflicts(_ text: String) -> [(start: Int, mid: Int, end: Int)] {
        vcs_conflicts(text).toString().split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t").compactMap { Int($0) }
            return f.count == 3 ? (f[0], f[1], f[2]) : nil
        }
    }

    // durum çubuğunda satır blame'i

    func gitCursorMoved(_ view: EditorView) {
        guard view === activeTab?.view, let tab = activeTab, let repo = git.repo, !tab.path.isEmpty else {
            if !git.blame.isEmpty { git.blame = ""; refreshUI() }
            return
        }
        let line = Int(tab.editor.cursor_line()), version = tab.editor.version()
        let key = "\(tab.path):\(line):\(version)"
        guard key != git.blameKey else { return }
        git.blameKey = key
        git.blameWork?.cancel()
        let path = tab.path
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab else { return }
            let contents = tab.editor.is_dirty() ? tab.editor.text().toString() : ""
            self.git.queue.async {
                let raw = repo.blame(path, UInt(line), contents).toString()
                DispatchQueue.main.async {
                    guard self.git.blameKey == key else { return }
                    self.git.blame = Self.formatBlame(raw)
                    self.refreshUI()
                }
            }
        }
        git.blameWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    static func formatBlame(_ raw: String) -> String {
        let f = raw.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 3, let t = TimeInterval(f[1]) else { return "" }
        if t == 0 { return "✎ \(f[2])" }
        let ago = RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
        return "✎ \(f[0]), \(ago)"
    }

    // dal değiştirici

    @objc func showBranchPicker(_ sender: Any? = nil) {
        guard let repo = git.repo else { return }
        git.queue.async { [weak self] in
            let branches = repo.branches().toString().split(separator: "\n").map(String.init)
            DispatchQueue.main.async {
                guard let self else { return }
                let current = self.git.branch
                self.showPalette("", provider: { [weak self] q in
                    let query = q.trimmingCharacters(in: .whitespaces)
                    var items = branches.filter { query.isEmpty || $0.lowercased().contains(query.lowercased()) }.map { b in
                        PaletteItem(title: b, detail: b == current ? "current" : "") { [weak self] in
                            self?.gitRun(done: "Switched to \(b).") { $0.checkout(b, false) }
                        }
                    }
                    if !query.isEmpty, !branches.contains(query) {
                        let name = query.replacingOccurrences(of: " ", with: "-")
                        items.insert(PaletteItem(title: "Create new branch “\(name)”") { [weak self] in
                            self?.gitRun(done: "Switched to a new branch \(name).") { $0.checkout(name, true) }
                        }, at: 0)
                    }
                    return items
                }, placeholder: "Select a branch or type a new branch name")
            }
        }
    }

    @objc func showSourceControl(_ sender: Any?) {
        root.sidebarVisible = true
        root.panel = 3
        root.needsLayout = true
        gitRefresh()
        root.scm.focusMessage()
    }

    @objc func gitPush(_ sender: Any?) { root.scm.onPush?() }
    @objc func gitPull(_ sender: Any?) { root.scm.onPull?() }
    @objc func gitFetch(_ sender: Any?) { gitRun(progress: "Fetching…", done: "Fetched.") { $0.fetch(true) } }
    @objc func gitPushTags(_ sender: Any?) { gitRun(progress: "Pushing tags…", done: "Tags pushed.") { $0.push_tags() } }

    // son commit'i yeniden yaz (mesaj kutusu boşsa eski mesaj korunur)
    @objc func gitAmend(_ sender: Any?) {
        guard let repo = git.repo else { return }
        git.queue.async { [weak self] in
            let old = repo.head_message().toString()
            DispatchQueue.main.async {
                guard let self else { return }
                self.showPalette(old.components(separatedBy: "\n").first ?? "", provider: { [weak self] q in
                    let msg = q.trimmingCharacters(in: .whitespaces)
                    return [PaletteItem(title: msg.isEmpty ? "Amend without changing the message" : "Amend: \(msg)", detail: "⏎") {
                        self?.gitRun(done: "Amended.", clear: true) { $0.amend(msg, false) }
                    }]
                }, placeholder: "Amend last commit")
            }
        }
    }

    @objc func gitStash(_ sender: Any?) {
        showPalette("", provider: { [weak self] q in
            let msg = q.trimmingCharacters(in: .whitespaces)
            return [PaletteItem(title: msg.isEmpty ? "Stash all changes" : "Stash: \(msg)", detail: "⏎") {
                self?.gitRun(progress: "Stashing…", done: "Stashed.") { $0.stash_push(msg, false) }
            }]
        }, placeholder: "Stash message (optional)")
    }

    @objc func gitStashPop(_ sender: Any?) {
        guard let repo = git.repo else { return }
        git.queue.async { [weak self] in
            let list = repo.stash_list().toString().split(separator: "\n").map(String.init)
            DispatchQueue.main.async {
                guard let self else { return }
                guard !list.isEmpty else { return self.root.scm.show("No stash entries.", error: true) }
                let items = list.map { row -> PaletteItem in
                    let parts = row.components(separatedBy: "\t")
                    let name = parts.first ?? ""
                    return PaletteItem(title: parts.count > 1 ? parts[1] : name, detail: name) { [weak self] in
                        self?.gitRun(progress: "Applying…", done: "Stash applied.") { $0.stash_apply(name, true) }
                    }
                }
                self.showPalette("", provider: { _ in items }, placeholder: "Pop a stash")
            }
        }
    }

    // commit geçmişi; seçilen commit'te dosya listesi ve diff
    @objc func showGitLog(_ sender: Any?) {
        showLog(path: nil)
    }

    @objc func showFileHistory(_ sender: Any?) {
        showLog(path: activeTab?.path)
    }

    func showLog(path: String?) {
        guard let repo = git.repo else { return }
        git.queue.async { [weak self] in
            let rows = repo.log(200, path ?? "").toString().split(separator: "\n").map(String.init)
            DispatchQueue.main.async {
                guard let self else { return }
                guard !rows.isEmpty else { return self.root.scm.show("No commits.", error: true) }
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd HH:mm"
                let items = rows.compactMap { row -> PaletteItem? in
                    let p = row.components(separatedBy: "\t")
                    guard p.count >= 5 else { return nil }
                    let when = Date(timeIntervalSince1970: Double(p[3]) ?? 0)
                    return PaletteItem(title: p[4], detail: "\(p[1])  \(p[2])  \(fmt.string(from: when))") { [weak self] in
                        self?.showCommit(p[0], subject: p[4])
                    }
                }
                let title = path.map { "History of \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Commits"
                self.showPalette("", provider: { q in
                    q.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.detail.localizedCaseInsensitiveContains(q) }
                }, placeholder: title)
            }
        }
    }

    // bir commit'in dosyaları: seç → o commit'e göre diff
    private func showCommit(_ hash: String, subject: String) {
        guard let repo = git.repo, let base = gitRoot else { return }
        git.queue.async { [weak self] in
            let files = repo.commit_files(hash).toString().split(separator: "\n").map(String.init)
            DispatchQueue.main.async {
                guard let self else { return }
                let items = files.compactMap { row -> PaletteItem? in
                    let p = row.components(separatedBy: "\t")
                    guard p.count >= 2 else { return nil }
                    let url = base.appendingPathComponent(p[1])
                    return PaletteItem(title: p[1], detail: p[0]) { [weak self] in
                        self?.showDiff(url, rev: "\(hash)^", title: "\(p[1]) @ \(subject)")
                    }
                }
                guard !items.isEmpty else { return self.root.scm.show("Commit has no files.", error: true) }
                self.showPalette("", provider: { _ in items }, placeholder: subject)
            }
        }
    }

    // dosyayı bir revizyondaki haline döndür
    @objc func revertFile(_ sender: Any?) {
        guard let tab = activeTab, !tab.path.isEmpty, git.repo != nil else { return }
        let path = tab.path
        let alert = NSAlert()
        alert.messageText = "Revert “\(tab.title)” to HEAD?"
        alert.informativeText = "Changes in the working copy will be lost."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        gitRun(done: "Reverted.") { $0.revert_file("HEAD", path) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let tab = self.allTabs.first(where: { $0.path == path }) else { return }
            _ = tab.editor.reload()
            tab.view.changed(edited: true)
        }
    }

    @objc func showTags(_ sender: Any?) {
        guard let repo = git.repo else { return }
        git.queue.async { [weak self] in
            let tags = repo.tags().toString().split(separator: "\n").map(String.init)
            DispatchQueue.main.async {
                guard let self else { return }
                self.showPalette("", provider: { [weak self] q in
                    let name = q.trimmingCharacters(in: .whitespaces)
                    var items = tags.filter { name.isEmpty || $0.localizedCaseInsensitiveContains(name) }.map { t in
                        PaletteItem(title: t, detail: "checkout") { [weak self] in
                            self?.gitRun(done: "Switched to \(t).") { $0.checkout(t, false) }
                        }
                    }
                    if !name.isEmpty, !tags.contains(name) {
                        items.insert(PaletteItem(title: "Create tag “\(name)”") { [weak self] in
                            self?.gitRun(done: "Tag \(name) created.") { $0.tag_create(name, "") }
                        }, at: 0)
                    }
                    return items
                }, placeholder: "Tags")
            }
        }
    }

    @objc func showRemotes(_ sender: Any?) {
        guard let repo = git.repo else { return }
        git.queue.async { [weak self] in
            let rows = repo.remotes().toString().split(separator: "\n").map(String.init)
            DispatchQueue.main.async {
                guard let self else { return }
                let items = rows.map { row -> PaletteItem in
                    let p = row.components(separatedBy: "\t")
                    return PaletteItem(title: p.first ?? "", detail: p.count > 1 ? p[1] : "") { [weak self] in
                        guard let name = p.first else { return }
                        self?.gitRun(done: "Removed \(name).") { $0.remote_remove(name) }
                    }
                }
                self.showPalette("", provider: { q in
                    let text = q.trimmingCharacters(in: .whitespaces)
                    // "isim url" yazılırsa yeni remote ekle
                    let parts = text.split(separator: " ").map(String.init)
                    if parts.count == 2 {
                        return [PaletteItem(title: "Add remote “\(parts[0])”", detail: parts[1]) { [weak self] in
                            self?.gitRun(done: "Remote added.") { $0.remote_add(parts[0], parts[1]) }
                        }]
                    }
                    return items
                }, placeholder: "Remotes (type “name url” to add, ⏎ on a row removes it)")
            }
        }
    }

    // diff görünümü
    @objc func compareWithHead(_ sender: Any?) {
        guard let tab = activeTab, let url = tab.url else { return NSSound.beep() }
        showDiff(url, rev: "HEAD", title: tab.title)
    }

    func showDiff(_ url: URL, rev: String, title: String) {
        guard let repo = git.repo else { return }
        let current = allTabs.first { $0.path == url.path }?.editor.text().toString()
        git.queue.async { [weak self] in
            let raw = repo.diff_rows(rev, url.path, current ?? "").toString()
            let baseJSON = repo.show(rev, url.path).toString()
            DispatchQueue.main.async {
                guard let self else { return }
                let obj = (try? JSONSerialization.jsonObject(with: Data(baseJSON.utf8))) as? [String: String] ?? [:]
                let base = obj["ok"] ?? ""
                let now = current ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let rows: [DiffWindowController.Row] = raw.split(separator: "\n").compactMap { line in
                    let p = line.components(separatedBy: "\t")
                    guard p.count == 3, let o = Int(p[0]), let n = Int(p[1]), let kind = p[2].first else { return nil }
                    return DiffWindowController.Row(old: o, new: n, kind: kind)
                }
                guard !rows.isEmpty else { return self.root.scm.show("No differences.", error: false) }
                DiffWindowController.show(title: "\(title) ↔ \(rev)", rows: rows,
                                          base: base.components(separatedBy: "\n"), current: now.components(separatedBy: "\n"))
            }
        }
    }

    // çakışma çözümü: imlecin içinde olduğu blok

    @objc func acceptCurrentChange(_ sender: Any?) { resolveConflict(current: true, incoming: false) }
    @objc func acceptIncomingChange(_ sender: Any?) { resolveConflict(current: false, incoming: true) }
    @objc func acceptBothChanges(_ sender: Any?) { resolveConflict(current: true, incoming: true) }

    private func resolveConflict(current: Bool, incoming: Bool) {
        guard let view = activeTab?.view else { return }
        let e = view.editor
        let line = Int(e.cursor_line())
        let blocks = parseConflicts(e.text().toString())
        guard let b = blocks.first(where: { line >= $0.start && line <= $0.end }) ?? blocks.first(where: { $0.start > line }) ?? blocks.first else {
            NSSound.beep()
            return
        }
        var keep: [String] = []
        if current { keep += (b.start + 1..<b.mid).map { e.line(UInt($0)).toString() } }
        if incoming { keep += (b.mid + 1..<b.end).map { e.line(UInt($0)).toString() } }
        let atEnd = b.end + 1 >= Int(e.line_count())
        let endLine = atEnd ? b.end : b.end + 1
        let endCol = atEnd ? (e.line(UInt(b.end)).toString() as NSString).length : 0
        var text = keep.joined(separator: "\n")
        if !atEnd && !keep.isEmpty { text += "\n" }
        let edit: [[String: Any]] = [["range": ["start": ["line": b.start, "character": 0], "end": ["line": endLine, "character": endCol]],
                                      "newText": text]]
        guard let data = try? JSONSerialization.data(withJSONObject: edit), e.apply_edits(String(decoding: data, as: UTF8.self)) else { return }
        view.goTo(line: b.start, col: 0)
        view.changed(edited: true)
    }
}
