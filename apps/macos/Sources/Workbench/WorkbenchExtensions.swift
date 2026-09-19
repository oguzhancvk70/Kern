import AppKit

// eklenti komutları ve yönetimi
extension WorkbenchWindowController {
    @objc func runExtensionCommand(_ sender: Any?) {
        guard let rep = (sender as? NSMenuItem)?.representedObject as? String else { return }
        let parts = rep.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return }
        runExtension(parts[1], parts[2])
    }

    @discardableResult
    func runExtension(_ ext: String, _ command: String) -> [String: Any] {
        let tab = activeTab
        let ctx: [String: Any] = [
            "text": tab?.editor.text().toString() ?? "", "selection": tab?.editor.selected_text().toString() ?? "",
            "path": tab?.path ?? "", "language": tab?.editor.language().toString() ?? "",
        ]
        let out = Extensions.shared.run(ext, command, context: ctx, root: folder?.path ?? NSHomeDirectory())
        for a in out["actions"] as? [[String: Any]] ?? [] {
            let value = a["value"] as? String ?? ""
            switch a["kind"] as? String {
            case "replace_selection", "insert":
                guard let view = tab?.view else { continue }
                view.editor.insert_text(value)
                view.changed(edited: true)
            case "status":
                root.status.left = root.status.left + [value]
            case "message":
                let alert = NSAlert()
                alert.messageText = value
                alert.runModal()
            default: break
            }
        }
        if let err = out["error"] as? String {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Extension “\(ext)” failed"
            alert.informativeText = err
            if NSApp.modalWindow == nil, ProcessInfo.processInfo.environment["KERN_SELFTEST"] == nil { alert.runModal() }
        }
        return out
    }

    private func describe(_ e: [String: Any]) -> String {
        let perms = (e["permissions"] as? [String] ?? []).joined(separator: ", ")
        return "v\(e["version"] as? String ?? "?")  ·  \(perms.isEmpty ? "no permissions" : perms)\(Extensions.shared.isBundled(e) ? "  ·  built-in" : "")"
    }

    @objc func showExtensions(_ sender: Any?) {
        let items = Extensions.shared.installed.map { e in
            PaletteItem(title: e["name"] as? String ?? "", detail: describe(e)) {}
        } + Extensions.shared.errors.map { e in
            PaletteItem(title: "⚠ \((e["dir"] as? String).map { ($0 as NSString).lastPathComponent } ?? "")", detail: e["error"] as? String ?? "") {}
        }
        showPalette("", provider: { q in q.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(q) } },
                    placeholder: "\(Extensions.shared.installed.count) extensions installed")
    }

    // izinleri gösterip onay al, sonra kullanıcı dizinine kopyala
    @objc func installExtension(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Install"
        panel.message = "Choose a folder containing kern-extension.json"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let m = Extensions.shared.inspect(dir)
        let alert = NSAlert()
        if let err = m["error"] as? String {
            alert.alertStyle = .warning
            alert.messageText = "Not a valid extension"
            alert.informativeText = err
            alert.runModal()
            return
        }
        let id = m["id"] as? String ?? dir.lastPathComponent
        let perms = m["permissions"] as? [String] ?? []
        alert.messageText = "Install “\(m["name"] as? String ?? id)”?"
        alert.informativeText = "Version \(m["version"] as? String ?? "?")\n\nPermissions:\n"
            + (perms.isEmpty ? "  none" : perms.map { "  • \($0)" }.joined(separator: "\n"))
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try Extensions.shared.install(dir, id: id) } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func uninstallExtension(_ sender: Any?) {
        let items = Extensions.shared.installed.filter { !Extensions.shared.isBundled($0) }.map { e in
            PaletteItem(title: e["name"] as? String ?? "", detail: describe(e)) {
                try? Extensions.shared.uninstall(e)
            }
        }
        showPalette("", provider: { _ in items }, placeholder: items.isEmpty ? "No user-installed extensions" : "Choose an extension to uninstall")
    }

    @objc func reloadExtensions(_ sender: Any?) { Extensions.shared.reload() }
}
