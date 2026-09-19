import AppKit

// AI paneli ve satır içi (hayalet) tamamlama
extension WorkbenchWindowController {
    func wireAI() {
        root.ai.context = { [weak self] in
            guard let tab = self?.activeTab else { return nil }
            return (tab.path.isEmpty ? tab.title : tab.path, tab.editor.text().toString(), tab.editor.selected_text().toString())
        }
        root.ai.root = { [weak self] in self?.folder }
        root.ai.onApply = { [weak self] code in
            guard let view = self?.activeTab?.view else { return }
            view.editor.insert_text(code)
            view.changed(edited: true)
            self?.window?.makeFirstResponder(view)
        }
    }

    @objc func showAI(_ sender: Any?) {
        root.sidebarVisible = true
        root.panel = 2
        root.needsLayout = true
        root.ai.focus()
    }

    @objc func showAgent(_ sender: Any?) {
        root.ai.isAgent = true
        showAI(sender)
    }

    @objc func setAPIKey(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "Anthropic API Key"
        a.informativeText = "Stored in your macOS Keychain. Leave empty to remove it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if !AIKey.save(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) { NSSound.beep() }
    }

    @objc func toggleInlineCompletion(_ sender: Any?) {
        Settings.shared.set("ai.inlineCompletion", !Settings.shared.bool("ai.inlineCompletion"))
    }

    // yazmayı bırakınca 0.7 sn sonra Haiku'dan öneri
    func scheduleInline(_ view: EditorView) {
        guard Settings.shared.bool("ai.inlineCompletion"), AIKey.load() != nil else { return }
        view.ghostText = nil
        inlineRequest += 1
        let req = inlineRequest
        let version = view.editor.version()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self, weak view] in
            guard let self, let view, req == self.inlineRequest, view.editor.version() == version,
                  !view.editor.has_selection(), !self.completion.isShown else { return }
            self.requestInline(view, req: req)
        }
    }

    private func requestInline(_ view: EditorView, req: Int) {
        let text = view.editor.text().toString() as NSString
        let line = Int(view.editor.cursor_line()), col = Int(view.editor.cursor_col())
        // imlecin UTF-16 ofseti
        var offset = 0
        var l = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, _, enclosing, stop in
            if l == line { offset = enclosing.location + col; stop.pointee = true } else { l += 1 }
        }
        offset = min(offset, text.length)
        let start = max(0, offset - 6000), end = min(text.length, offset + 2000)
        let prefix = text.substring(with: NSRange(location: start, length: offset - start))
        let suffix = text.substring(with: NSRange(location: offset, length: end - offset))
        let name = activeTab?.title ?? "file"
        let body: [String: Any] = [
            "model": AIModel.inline, "max_tokens": 256,
            "system": "You complete code at the cursor. Reply with only the text to insert at <CURSOR> — no explanations, no code fences. Reply with nothing if no completion is useful.",
            "messages": [["role": "user", "content": "File: \(name)\n\(prefix)<CURSOR>\(suffix)"]],
        ]
        let client = root.ai.client
        let version = view.editor.version()
        Task { [weak self, weak view] in
            let resp = try? await client.stream(body, onText: { _ in })
            await MainActor.run {
                guard let self, let view, req == self.inlineRequest, view.editor.version() == version else { return }
                var s = resp?.text ?? ""
                if s.hasPrefix("```") { s = ChatPanel.lastCodeBlock(s + "\n```") ?? s }
                view.ghostText = s.trimmingCharacters(in: .newlines).isEmpty ? nil : s
            }
        }
    }

    func inlineCursorMoved(_ view: EditorView) {
        if view.ghostText != nil, !acceptingGhost { view.ghostText = nil }
    }

    // Tab: öneriyi kabul et
    func acceptGhost(_ view: EditorView) -> Bool {
        guard let g = view.ghostText else { return false }
        acceptingGhost = true
        view.ghostText = nil
        view.editor.insert_text(g)
        view.changed(edited: true)
        acceptingGhost = false
        return true
    }
}
