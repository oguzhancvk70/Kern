import AppKit

// LSP özellikleri: senkron, tanılar, tamamlama, hover, gezinme, yeniden adlandırma, biçimlendirme
extension WorkbenchWindowController {
    func tab(for view: EditorView) -> EditorTab? { allTabs.first { $0.view === view } }

    @discardableResult
    func ensureLanguage() -> LanguageService? {
        guard LanguageService.enabled else { return nil }
        if language == nil {
            let root = folder?.path ?? activeTab?.url?.deletingLastPathComponent().path ?? NSHomeDirectory()
            let service = LanguageService(root: root)
            service.onDiagnostics = { [weak self] in self?.refreshDiagnostics() }
            language = service
        }
        return language
    }

    func restartLanguage() {
        language = nil
        var seen = Set<ObjectIdentifier>()
        for t in allTabs where seen.insert(ObjectIdentifier(t.doc)).inserted { languageOpened(t) }
        refreshDiagnostics()
    }

    func languageOpened(_ tab: EditorTab) {
        guard !tab.path.isEmpty, tab.editor.byte_len() < 8 * 1024 * 1024, let lang = ensureLanguage() else { return }
        lang.open(tab.path, text: tab.editor.text().toString())
        refreshLanguageExtras(tab, delay: 0.8)
    }

    func languageChanged(_ tab: EditorTab) {
        guard !tab.path.isEmpty, let lang = language else { return }
        lang.changed(tab.path) { [weak tab] in tab?.editor.text().toString() ?? "" }
        refreshLanguageExtras(tab)
    }

    func languageSaved(_ tab: EditorTab, reopened: Bool) {
        if reopened { return languageOpened(tab) }
        language?.saved(tab.path)
    }

    func refreshDiagnostics() {
        guard let lang = language else { return }
        for t in allTabs where !t.path.isEmpty { t.view.diagnostics = lang.diagnostics(t.path) }
        let all = lang.allDiagnostics().flatMap(\.1)
        diagnosticCounts = (all.filter { $0.severity == 1 }.count, all.filter { $0.severity == 2 }.count)
        refreshUI()
        // sunucu belgeyi işledi: renk/ipucu/katlama verisini tazele
        if let tab = activeTab { refreshLanguageExtras(tab, delay: 0.2) }
    }

    // anlamsal renkler, satır içi ipuçları ve LSP katlama aralıkları (yalnız etkin sekme)
    private static let extrasMaxLines = 20000

    func refreshLanguageExtras(_ tab: EditorTab, delay: Double = 0.4) {
        extrasWork?.cancel()
        guard !tab.path.isEmpty, let lang = ensureLanguage() else { return }
        let path = tab.path
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab, tab.view.window != nil else { return }
            let view = tab.view
            let lines = Int(view.editor.line_count())
            guard lines <= Self.extrasMaxLines else { return }
            let version = view.editor.version()
            let fresh = { [weak view] in view?.editor.version() == version }
            if Settings.shared.bool("editor.semanticHighlighting") {
                lang.request(path, { $0.semantic_tokens(path) }) { [weak view] obj, _ in
                    guard let view, fresh() else { return }
                    var spans: [Int: [(Int, Int, UInt32)]] = [:]
                    for t in obj as? [[String: Any]] ?? [] {
                        guard let line = t["line"] as? Int, let col = t["col"] as? Int,
                              let len = t["len"] as? Int, let kind = t["kind"] as? Int else { continue }
                        spans[line, default: []].append((col, col + len, UInt32(kind)))
                    }
                    view.semanticSpans = spans
                }
            }
            if Settings.shared.bool("editor.inlayHints") {
                lang.request(path, { $0.inlay_hints(path, 0, UInt32(lines)) }) { [weak view] obj, _ in
                    guard let view, fresh() else { return }
                    var hints: [Int: [(Int, String)]] = [:]
                    for h in obj as? [[String: Any]] ?? [] {
                        guard let line = h["line"] as? Int, let col = h["col"] as? Int, let text = h["text"] as? String else { continue }
                        hints[line, default: []].append((col, text))
                    }
                    view.inlayHints = hints
                }
            }
            // code lens pahalı: yalnız belge sürümü değiştiyse istenir
            if Settings.shared.bool("editor.codeLens"), self.lensVersion[path] != version {
                self.lensVersion[path] = version
                lang.request(path, { $0.code_lenses(path) }) { [weak self, weak view] obj, _ in
                    guard let self, let view, fresh() else { return }
                    var titles: [Int: [String]] = [:]
                    var cmds: [Int: [String]] = [:]
                    for l in obj as? [[String: Any]] ?? [] {
                        guard let line = l["line"] as? Int, let title = l["title"] as? String, let cmd = l["command"] else { continue }
                        guard let data = try? JSONSerialization.data(withJSONObject: ["title": title, "command": cmd]),
                              let json = String(data: data, encoding: .utf8) else { continue }
                        titles[line, default: []].append(title)
                        cmds[line, default: []].append(json)
                    }
                    self.lensCommands[path] = cmds
                    view.codeLenses = titles
                }
            }
            lang.request(path, { $0.folding_ranges(path) }) { [weak view] obj, _ in
                guard let view, fresh() else { return }
                var folds: [Int: Int] = [:]
                for f in obj as? [[String: Any]] ?? [] {
                    guard let s = f["start"] as? Int, let e = f["end"] as? Int else { continue }
                    folds[s] = max(folds[s] ?? 0, e)
                }
                view.lspFolds = folds
            }
        }
        extrasWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // editör kancaları

    func wireLanguage(_ view: EditorView) {
        view.onTyped = { [weak self, weak view] text in
            guard let self, let view else { return }
            self.typed(text, in: view)
            self.scheduleInline(view)
        }
        view.keyInterceptor = { [weak self, weak view] name in
            guard let self, let view else { return false }
            if view.ghostText != nil, !self.completion.isShown {
                if name == "insertTab:" { return self.acceptGhost(view) }
                view.ghostText = nil
            }
            if name == "cancelOperation:", self.signature.superview != nil, !self.completion.isShown {
                self.signature.hide()
                return true
            }
            guard self.completion.isShown, self.completionView === view else { return false }
            switch name {
            case "moveUp:": self.completion.move(-1)
            case "moveDown:": self.completion.move(1)
            case "insertNewline:", "insertTab:": self.completion.accept()
            case "cancelOperation:": self.hideCompletion()
            case "deleteBackward:":
                DispatchQueue.main.async { self.refilterCompletion() }
                return false
            default:
                self.hideCompletion()
                return false
            }
            return true
        }
        view.onHover = { [weak self, weak view] line, col, point in
            guard let self, let view else { return }
            self.showHover(view, line: line, col: col, point: point)
        }
        view.onHoverEnd = { [weak self] in self?.hover.hide() }
        view.onCommandClick = { [weak self, weak view] _, _ in
            guard let self, let view else { return }
            self.definition(in: view)
        }
    }

    // tamamlama

    private func wordPrefix(_ view: EditorView) -> String {
        let line = view.editor.line(view.editor.cursor_line()).toString() as NSString
        let col = min(Int(view.editor.cursor_col()), line.length)
        var i = col
        while i > 0, let u = UnicodeScalar(line.character(at: i - 1)),
              CharacterSet.alphanumerics.contains(u) || u == "_" || u == "$" { i -= 1 }
        return line.substring(with: NSRange(location: i, length: col - i))
    }

    private func typed(_ text: String, in view: EditorView) {
        guard text.count == 1, let c = text.unicodeScalars.first else { return hideCompletion() }
        let ident = CharacterSet.alphanumerics.contains(c) || c == "_" || c == "$"
        if ident {
            if completion.isShown && completionView === view { return refilterCompletion() }
            let req = completionRequest + 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak view] in
                guard let self, let view, self.completionRequest < req, view.window?.firstResponder === view else { return }
                if self.wordPrefix(view).count >= 1 { self.requestCompletion(view, trigger: nil) }
            }
        } else if ["(", ","].contains(text) {
            hideCompletion()
            showSignature(view)
        } else if [")"].contains(text) {
            hideCompletion()
            signature.hide()
        } else if [".", ":", ">", "/", "\"", "<", "@", "#"].contains(text) {
            requestCompletion(view, trigger: text)
        } else {
            hideCompletion()
        }
    }

    // imza yardımı (parametre ipuçları)

    @objc func showParameterHints(_ sender: Any?) {
        if let view = activeTab?.view { showSignature(view) }
    }

    func showSignature(_ view: EditorView) {
        guard let tab = tab(for: view), !tab.path.isEmpty, let lang = ensureLanguage() else { return }
        signatureRequest += 1
        let req = signatureRequest
        let path = tab.path
        let line = UInt32(view.editor.cursor_line()), col = UInt32(view.editor.cursor_col())
        lang.request(path, { $0.signature_help(path, line, col) }) { [weak self, weak view] obj, _ in
            guard let self, let view, req == self.signatureRequest else { return }
            let text = signatureText(obj)
            guard !text.isEmpty, view.window != nil else { return self.signature.hide() }
            self.signature.show(text, at: view.convert(view.caretPoint(), to: self.root), in: self.root)
        }
    }

    // düzeltme eylemleri (quick fix / refactor)

    @objc func showCodeActions(_ sender: Any?) {
        guard let view = activeTab?.view, let tab = activeTab, !tab.path.isEmpty, let lang = ensureLanguage() else { return }
        let path = tab.path
        var start = (Int(view.editor.cursor_line()), Int(view.editor.cursor_col()))
        var end = start
        let sel = Array(view.editor.selections())
        if view.editor.has_selection(), sel.count >= 4 {
            var a = (Int(sel[0]), Int(sel[1])), b = (Int(sel[2]), Int(sel[3]))
            if a > b { swap(&a, &b) }
            (start, end) = (a, b)
        }
        let (sl, sc, el, ec) = (UInt32(start.0), UInt32(start.1), UInt32(end.0), UInt32(end.1))
        lang.request(path, { $0.code_actions(path, sl, sc, el, ec) }) { [weak self] obj, err in
            guard let self else { return }
            let list = obj as? [[String: Any]] ?? []
            guard !list.isEmpty else { return self.report(err ?? "No code actions available") }
            let items = list.map { a in
                PaletteItem(title: a["title"] as? String ?? "", detail: a["kind"] as? String ?? "") { [weak self] in
                    guard let action = a["action"], let data = try? JSONSerialization.data(withJSONObject: action),
                          let json = String(data: data, encoding: .utf8) else { return }
                    lang.request(path, { $0.apply_code_action(path, json) }) { [weak self] obj, err in
                        self?.applyWorkspaceEdit(obj, error: err, empty: "Code action made no changes")
                    }
                }
            }
            self.showPalette("", provider: { q in
                q.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(q) }
            }, placeholder: "\(items.count) code actions")
        }
    }

    @objc func triggerSuggest(_ sender: Any?) {
        guard let view = activeTab?.view else { return }
        requestCompletion(view, trigger: nil)
    }

    func requestCompletion(_ view: EditorView, trigger: String?) {
        guard let tab = tab(for: view) else { return }
        guard !tab.path.isEmpty, let lang = ensureLanguage() else {
            // dil sunucusu yoksa yalnız snippet'ler
            let snippets = snippetItems(view)
            guard trigger == nil, !snippets.isEmpty else { return }
            completion.setItems(snippets)
            completionView = view
            completion.onAccept = { [weak self, weak view] item in if let view { self?.accept(item, in: view) } }
            return refilterCompletion()
        }
        completionRequest += 1
        let req = completionRequest
        let path = tab.path
        let line = UInt32(view.editor.cursor_line()), col = UInt32(view.editor.cursor_col())
        lang.request(path, { $0.completion(path, line, col, trigger ?? "") }) { [weak self, weak view] obj, _ in
            guard let self, let view, req == self.completionRequest, view.editor.cursor_line() == line else { return }
            let items = CompletionItem.parse(obj) + self.snippetItems(view)
            guard !items.isEmpty else { return self.hideCompletion() }
            self.completion.setItems(items)
            self.completionView = view
            self.completion.onAccept = { [weak self, weak view] item in
                guard let self, let view else { return }
                self.accept(item, in: view)
            }
            self.refilterCompletion()
        }
    }

    // eklenti snippet'leri tamamlama listesinde (tür 15)
    func snippetItems(_ view: EditorView) -> [CompletionItem] {
        Extensions.shared.snippets(for: view.editor.language().toString()).compactMap { s in
            guard let prefix = s["prefix"] as? String, let body = s["body"] as? String else { return nil }
            return CompletionItem(label: prefix, detail: s["description"] as? String ?? "snippet", kind: 15,
                                  insertText: CompletionItem.stripSnippet(body), filterText: prefix, sortText: "~" + prefix, edit: nil, additional: nil)
        }
    }

    func refilterCompletion() {
        guard let view = completionView else { return hideCompletion() }
        completion.filter(wordPrefix(view))
        guard !completion.items.isEmpty else { return hideCompletion() }
        let p = view.convert(view.caretPoint(), to: root)
        var f = completion.frame
        f.origin = NSPoint(x: min(p.x, root.bounds.width - f.width - 8), y: p.y + 2)
        if f.maxY > root.bounds.height - 30 { f.origin.y = p.y - f.height - view.fontLineHeight - 4 }
        completion.frame = f
        if completion.superview !== root { root.addSubview(completion) }
    }

    func hideCompletion() {
        completionRequest += 1
        completion.removeFromSuperview()
    }

    private func accept(_ item: CompletionItem, in view: EditorView) {
        let line = Int(view.editor.cursor_line()), col = Int(view.editor.cursor_col())
        let prefix16 = (wordPrefix(view) as NSString).length
        var start = (line, col - prefix16)
        if let e = item.edit, e.line == line, e.col <= col { start = (e.line, e.col) }
        var edits: [[String: Any]] = [[
            "range": ["start": ["line": start.0, "character": start.1], "end": ["line": line, "character": col]],
            "newText": item.insertText,
        ]]
        if let extra = item.additional as? [[String: Any]] { edits += extra }
        if let data = try? JSONSerialization.data(withJSONObject: edits), let json = String(data: data, encoding: .utf8) {
            _ = view.editor.apply_edits(json)
            view.changed(edited: true)
        }
        hideCompletion()
    }

    // hover

    private func showHover(_ view: EditorView, line: Int, col: Int, point: NSPoint) {
        guard let tab = tab(for: view) else { return }
        let local = view.diagnostics.filter { d in
            (line > d.line || (line == d.line && col >= d.col)) && (line < d.endLine || (line == d.endLine && col <= max(d.endCol, d.col + 1)))
        }.map { "\($0.severity == 1 ? "⊗" : "⚠") \($0.message)\($0.source.isEmpty ? "" : "  (\($0.source))")" }
        let anchor = view.convert(point, to: root)
        if !local.isEmpty { hover.show(local.joined(separator: "\n"), at: anchor, in: root) }
        guard !tab.path.isEmpty, let lang = ensureLanguage() else { return }
        let path = tab.path
        lang.request(path, { $0.hover(path, UInt32(line), UInt32(col)) }) { [weak self] obj, _ in
            guard let self else { return }
            let info = hoverText(obj)
            let text = (local + (info.isEmpty ? [] : [info])).joined(separator: "\n\n")
            guard !text.isEmpty, view.window != nil else { return }
            self.hover.show(text, at: anchor, in: self.root)
        }
    }

    // gezinme

    func open(_ loc: Location) {
        openFile(loc.url)?.goTo(line: loc.line, col: loc.col)
    }

    private func locationItems(_ locs: [Location]) -> [PaletteItem] {
        locs.map { l in
            let text = (try? String(contentsOf: l.url, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: false).dropFirst(l.line).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            var rel = l.url.path
            if let f = folder?.path, rel.hasPrefix(f + "/") { rel = String(rel.dropFirst(f.count + 1)) }
            return PaletteItem(title: text.isEmpty ? l.url.lastPathComponent : text, detail: "\(rel):\(l.line + 1)",
                               icon: FileIcons.icon(for: l.url.lastPathComponent, directory: false)) { [weak self] in self?.open(l) }
        }
    }

    private func position(_ view: EditorView) -> (String, UInt32, UInt32)? {
        guard let tab = tab(for: view), !tab.path.isEmpty else { return nil }
        return (tab.path, UInt32(view.editor.cursor_line()), UInt32(view.editor.cursor_col()))
    }

    func report(_ err: String?) {
        guard let err else { return }
        NSSound.beep()
        root.status.left = root.status.left + ["⚠ \(err)"]
    }

    func definition(in view: EditorView) {
        guard let (path, line, col) = position(view), let lang = ensureLanguage() else { return }
        lang.request(path, { $0.definition(path, line, col) }) { [weak self] obj, err in
            guard let self else { return }
            let locs = Location.parse(obj)
            if locs.count == 1 { self.open(locs[0]) } else if locs.count > 1 {
                self.showPalette("", provider: { [items = self.locationItems(locs)] _ in items }, placeholder: "Definitions")
            } else { self.report(err ?? "No definition found") }
        }
    }

    @objc func goToDefinition(_ sender: Any?) {
        if let view = activeTab?.view { definition(in: view) }
    }

    // tanım/uygulama/tür: tek sonuç açılır, çok sonuç palette listelenir
    private func locations(_ name: String, _ call: @escaping (KernLsp, String, UInt32, UInt32) -> RustString) {
        guard let view = activeTab?.view, let (path, line, col) = position(view), let lang = ensureLanguage() else { return }
        lang.request(path, { call($0, path, line, col) }) { [weak self] obj, err in
            guard let self else { return }
            let locs = Location.parse(obj)
            if locs.count == 1 { self.open(locs[0]) } else if locs.count > 1 {
                self.showPalette("", provider: { [items = self.locationItems(locs)] _ in items }, placeholder: name)
            } else { self.report(err ?? "No \(name.lowercased()) found") }
        }
    }

    @objc func goToTypeDefinition(_ sender: Any?) {
        locations("Type Definitions") { lsp, path, line, col in lsp.type_definition(path, line, col) }
    }

    @objc func goToImplementation(_ sender: Any?) {
        locations("Implementations") { lsp, path, line, col in lsp.implementation(path, line, col) }
    }

    // peek: imlecin altında küçük liste + kaynak satırı önizlemesi
    @objc func peekDefinition(_ sender: Any?) {
        peekLocations("Definition") { lsp, path, line, col in lsp.definition(path, line, col) }
    }

    @objc func peekReferences(_ sender: Any?) {
        peekLocations("References") { lsp, path, line, col in lsp.references(path, line, col) }
    }

    private func peekLocations(_ title: String, _ call: @escaping (KernLsp, String, UInt32, UInt32) -> RustString) {
        guard let view = activeTab?.view, let (path, line, col) = position(view), let lang = ensureLanguage() else { return }
        lang.request(path, { call($0, path, line, col) }) { [weak self, weak view] obj, err in
            guard let self, let view else { return }
            let locs = Location.parse(obj)
            guard !locs.isEmpty else { return self.report(err ?? "No \(title.lowercased()) found") }
            let rows = locs.prefix(40).map { loc in
                PeekView.Row(file: loc.url.lastPathComponent, line: loc.line, text: Self.sourceLine(loc), open: { [weak self] in
                    self?.peek.hide()
                    self?.open(loc)
                })
            }
            self.peek.show(title: "\(title) (\(locs.count))", rows: Array(rows), at: view.caretPoint(), in: view)
        }
    }

    // peek satırı için dosyadan tek satır oku
    private static func sourceLine(_ loc: Location) -> String {
        (try? String(contentsOf: loc.url, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false).dropFirst(loc.line).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    // çağrı hiyerarşisi
    @objc func showIncomingCalls(_ sender: Any?) { callHierarchy(incoming: true) }
    @objc func showOutgoingCalls(_ sender: Any?) { callHierarchy(incoming: false) }

    private func callHierarchy(incoming: Bool) {
        guard let view = activeTab?.view, let (path, line, col) = position(view), let lang = ensureLanguage() else { return }
        let name = incoming ? "Callers" : "Calls"
        lang.request(path, { $0.call_hierarchy(path, line, col, incoming) }) { [weak self] obj, err in
            guard let self else { return }
            let items = (obj as? [[String: Any]] ?? []).compactMap { c -> PaletteItem? in
                guard let uri = c["uri"] as? String, let url = URL(string: uri), url.isFileURL else { return nil }
                let range = c["range"] as? [String: Any]
                let start = range?["start"] as? [String: Any]
                let l = start?["line"] as? Int ?? 0, ch = start?["character"] as? Int ?? 0
                let detail = (c["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
                return PaletteItem(title: c["name"] as? String ?? "?", detail: "\(detail):\(l + 1)") { [weak self] in
                    self?.openFile(url)?.goTo(line: l, col: ch)
                }
            }
            guard !items.isEmpty else { return self.report(err ?? "No \(name.lowercased()) found") }
            self.showPalette("", provider: { q in
                q.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(q) }
            }, placeholder: name)
        }
    }

    // imleçteki sembolün geçişlerini vurgula
    func scheduleOccurrences(_ view: EditorView) {
        occurrenceWork?.cancel()
        guard Settings.shared.bool("editor.occurrencesHighlight"), let tab = tab(for: view), !tab.path.isEmpty,
              Int(view.editor.line_count()) <= Self.extrasMaxLines, !view.editor.has_selection() else {
            if !view.occurrences.isEmpty { view.occurrences = [:] }
            return
        }
        let path = tab.path
        let line = UInt32(view.editor.cursor_line()), col = UInt32(view.editor.cursor_col())
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, let lang = self.ensureLanguage() else { return }
            lang.request(path, { $0.document_highlights(path, line, col) }) { [weak view] obj, _ in
                guard let view else { return }
                var out: [Int: [(Int, Int)]] = [:]
                for h in obj as? [[String: Any]] ?? [] {
                    guard let r = h["range"] as? [String: Any],
                          let s = r["start"] as? [String: Any], let e = r["end"] as? [String: Any],
                          let sl = s["line"] as? Int, let sc = s["character"] as? Int,
                          let el = e["line"] as? Int, let ec = e["character"] as? Int, sl == el else { continue }
                    out[sl, default: []].append((sc, ec))
                }
                view.occurrences = out
            }
        }
        occurrenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // code lens: satır sonundaki başlığa tıklanınca komutu çalıştır
    func runCodeLens(_ tab: EditorTab, line: Int, index: Int) {
        guard let list = lensCommands[tab.path]?[line], index < list.count, let lang = ensureLanguage() else { return }
        let cmd = list[index]
        let path = tab.path
        lang.request(path, { $0.apply_code_action(path, cmd) }) { [weak self] obj, err in
            self?.applyWorkspaceEdit(obj, error: err, empty: "Code lens made no changes")
        }
    }

    @objc func goToReferences(_ sender: Any?) {
        guard let view = activeTab?.view, let (path, line, col) = position(view), let lang = ensureLanguage() else { return }
        lang.request(path, { $0.references(path, line, col) }) { [weak self] obj, err in
            guard let self else { return }
            let locs = Location.parse(obj)
            guard !locs.isEmpty else { return self.report(err ?? "No references found") }
            let items = self.locationItems(locs)
            self.showPalette("", provider: { q in
                q.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.detail.localizedCaseInsensitiveContains(q) }
            }, placeholder: "\(locs.count) references")
        }
    }

    @objc func renameSymbol(_ sender: Any?) {
        guard let view = activeTab?.view, let (path, line, col) = position(view), let lang = ensureLanguage() else { return }
        let word = wordAtCursor(view)
        showPalette(word, provider: { [weak self] q in
            let name = q.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return [] }
            return [PaletteItem(title: "Rename '\(word)' to '\(name)'", detail: "⏎") {
                lang.request(path, { $0.rename(path, line, col, name) }) { obj, err in self?.applyWorkspaceEdit(obj, error: err) }
            }]
        }, placeholder: "New name")
    }

    private func wordAtCursor(_ view: EditorView) -> String {
        let line = view.editor.line(view.editor.cursor_line()).toString() as NSString
        var a = min(Int(view.editor.cursor_col()), line.length), b = a
        let isWord: (unichar) -> Bool = { c in UnicodeScalar(c).map { CharacterSet.alphanumerics.contains($0) || $0 == "_" } ?? false }
        while a > 0, isWord(line.character(at: a - 1)) { a -= 1 }
        while b < line.length, isWord(line.character(at: b)) { b += 1 }
        return line.substring(with: NSRange(location: a, length: b - a))
    }

    // {uri: [TextEdit]} → dosyaları aç, düzenle (kaydetmek kullanıcıya kalır)
    func applyWorkspaceEdit(_ obj: Any?, error: String?, empty: String = "Nothing to rename") {
        guard let changes = obj as? [String: Any], !changes.isEmpty else { return report(error ?? empty) }
        // aynı dosya farklı URI'lerle gelebilir (symlink): gerçek yola göre bir kez uygula
        var seen = Set<String>()
        for (uri, edits) in changes.sorted(by: { $0.key < $1.key }) {
            guard let url = URL(string: uri), url.isFileURL, seen.insert(url.resolvingSymlinksInPath().path).inserted,
                  let view = openFile(url),
                  let data = try? JSONSerialization.data(withJSONObject: edits), let json = String(data: data, encoding: .utf8) else { continue }
            if view.editor.apply_edits(json) { view.changed(edited: true) }
        }
    }

    @objc func formatDocument(_ sender: Any?) {
        formatDocument(sender, then: nil)
    }

    // then: biçimlendirme bitince (hata olsa da) çalışır — formatOnSave için
    func formatDocument(_ sender: Any?, then done: (() -> Void)?) {
        guard let view = activeTab?.view, let tab = activeTab, !tab.path.isEmpty, let lang = ensureLanguage() else { return done?() ?? () }
        let path = tab.path
        let size = UInt32(view.editor.tab_width()), spaces = view.editor.insert_spaces()
        lang.request(path, { $0.formatting(path, size, spaces) }) { [weak self, weak view] obj, err in
            defer { done?() }
            guard let view, let edits = obj as? [Any], !edits.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: edits), let json = String(data: data, encoding: .utf8) else {
                if done == nil { self?.report(err ?? "No formatting changes") }
                return
            }
            if view.editor.apply_edits(json) { view.changed(edited: true) }
        }
    }

    // semboller (@) ve sorunlar

    private static let symbolKinds: [Int: String] = [2: "module", 5: "class", 6: "method", 8: "field", 9: "constructor", 10: "enum",
                                                     11: "interface", 12: "function", 13: "variable", 14: "constant", 22: "enum member", 23: "struct"]

    func symbolItems(_ query: String) -> [PaletteItem] {
        if let cache = symbolCache {
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            return q.isEmpty ? cache : cache.filter { $0.title.lowercased().contains(q) }
        }
        guard let view = activeTab?.view, let tab = activeTab, !tab.path.isEmpty, let lang = ensureLanguage() else { return [] }
        let path = tab.path
        symbolCache = []
        lang.request(path, { $0.document_symbols(path) }) { [weak self, weak view] obj, _ in
            guard let self else { return }
            self.symbolCache = (obj as? [[String: Any]] ?? []).map { s in
                let depth = s["depth"] as? Int ?? 0
                let line = s["line"] as? Int ?? 0, col = s["col"] as? Int ?? 0
                return PaletteItem(title: String(repeating: "  ", count: depth) + (s["name"] as? String ?? ""),
                                   detail: Self.symbolKinds[s["kind"] as? Int ?? 0] ?? "") { view?.goTo(line: line, col: col) }
            }
            if let p = self.paletteView, p.input.field.stringValue.hasPrefix("@") { p.present(text: p.input.field.stringValue) }
        }
        return [PaletteItem(title: "Loading symbols…", run: {})]
    }

    // proje geneli semboller (#): çalışan tüm sunucularda ara
    func workspaceSymbolItems(_ query: String) -> [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let cache = wsSymbolCache, cache.0 == q { return cache.1 }
        guard let lang = ensureLanguage() else { return [] }
        guard !q.isEmpty else { return [PaletteItem(title: "Type to search symbols across the project", run: {})] }
        wsSymbolCache = (q, [PaletteItem(title: "Searching…", run: {})])
        lang.request("", { $0.workspace_symbols(q) }) { [weak self] obj, err in
            guard let self else { return }
            let items = (obj as? [[String: Any]] ?? []).compactMap { s -> PaletteItem? in
                guard let uri = s["uri"] as? String, let url = URL(string: uri), url.isFileURL else { return nil }
                let line = s["line"] as? Int ?? 0, col = s["col"] as? Int ?? 0
                var rel = url.path
                if let f = self.folder?.path, rel.hasPrefix(f + "/") { rel = String(rel.dropFirst(f.count + 1)) }
                let container = s["container"] as? String ?? ""
                let kind = Self.symbolKinds[s["kind"] as? Int ?? 0] ?? ""
                return PaletteItem(title: (container.isEmpty ? "" : container + ".") + (s["name"] as? String ?? ""),
                                   detail: "\(kind.isEmpty ? "" : kind + "  ")\(rel):\(line + 1)",
                                   icon: FileIcons.icon(for: url.lastPathComponent, directory: false)) { [weak self] in
                    self?.open(Location(url: url, line: line, col: col))
                }
            }
            let empty = PaletteItem(title: err ?? "No symbols found", run: {})
            self.wsSymbolCache = (q, items.isEmpty ? [empty] : items)
            if let p = self.paletteView, p.input.field.stringValue.hasPrefix("#") { p.present(text: p.input.field.stringValue) }
        }
        return wsSymbolCache?.1 ?? []
    }

    @objc func showProblems(_ sender: Any?) {
        guard let lang = ensureLanguage() else { return }
        var items: [PaletteItem] = []
        for (path, diags) in lang.allDiagnostics() {
            let url = URL(fileURLWithPath: path)
            for d in diags.sorted(by: { ($0.severity, $0.line) < ($1.severity, $1.line) }) {
                items.append(PaletteItem(title: "\(d.severity == 1 ? "⊗" : "⚠") \(d.message)", detail: "\(url.lastPathComponent):\(d.line + 1)") {
                    [weak self] in self?.open(Location(url: url, line: d.line, col: d.col))
                })
            }
        }
        showPalette("", provider: { q in
            q.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.detail.localizedCaseInsensitiveContains(q) }
        }, placeholder: items.isEmpty ? "No problems have been detected" : "\(items.count) problems")
    }

    // kurulum komutunu terminale yaz (çalıştırmak kullanıcıya kalır)
    @objc func installLanguageServer(_ sender: Any?) {
        guard let tab = activeTab, !tab.path.isEmpty, let s = ensureLanguage()?.status(tab.path), s.hasPrefix("missing:") else {
            return report("Language server already available (or unsupported file)")
        }
        let cmd = s.dropFirst("missing:".count).trimmingCharacters(in: .whitespaces)
        NSApp.sendAction(#selector(WorkbenchWindowController.toggleTerminal(_:)), to: self, from: nil)
        if root.terminal.terminal == nil { root.terminal.newTerminal() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.root.terminal.terminal?.terminal?.write_text(cmd)
        }
    }
}
