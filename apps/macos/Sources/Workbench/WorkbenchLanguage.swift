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
    }

    func languageChanged(_ tab: EditorTab) {
        guard !tab.path.isEmpty, let lang = language else { return }
        lang.changed(tab.path) { [weak tab] in tab?.editor.text().toString() ?? "" }
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
        } else if [".", ":", ">", "/", "\"", "<", "@", "#"].contains(text) {
            requestCompletion(view, trigger: text)
        } else {
            hideCompletion()
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

    private func report(_ err: String?) {
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
    func applyWorkspaceEdit(_ obj: Any?, error: String?) {
        guard let changes = obj as? [String: Any], !changes.isEmpty else { return report(error ?? "Nothing to rename") }
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
        guard let view = activeTab?.view, let tab = activeTab, !tab.path.isEmpty, let lang = ensureLanguage() else { return }
        let path = tab.path
        let size = UInt32(view.editor.tab_width()), spaces = view.editor.insert_spaces()
        lang.request(path, { $0.formatting(path, size, spaces) }) { [weak self, weak view] obj, err in
            guard let view, let edits = obj as? [Any], !edits.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: edits), let json = String(data: data, encoding: .utf8) else {
                return self?.report(err ?? "No formatting changes") ?? ()
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
