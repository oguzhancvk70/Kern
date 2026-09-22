import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [WorkbenchWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.shared.reload()
        Extensions.shared.reload()
        Updater.shared.start()
        NSApp.mainMenu = MainMenu.make()
        Settings.shared.applyKeymap(to: NSApp.mainMenu)
        for name in [Settings.changed, Extensions.changed] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                NSApp.mainMenu = MainMenu.make()
                Settings.shared.applyKeymap(to: NSApp.mainMenu)
                self?.controllers.forEach { $0.applySettings() }
                if let err = Settings.shared.error { NSLog("Kern settings: %@", err) }
            }
        }
        if let out = ProcessInfo.processInfo.environment["KERN_SELFTEST"] {
            SelfTest(output: out) { self.newWindow(folder: $0) }.start()
            return
        }
        DispatchQueue.main.async {
            if self.controllers.isEmpty { self.newWindow(folder: self.lastFolder) }
        }
        NSApp.activate()
    }

    private var lastFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: "lastFolder"),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "kern" { handleKernURL(url) } else { open(url) }
        }
    }

    // kern://open?path=..&line=..&col=..&window=..&new=1&reuse=1 (kern CLI)
    private func handleKernURL(_ url: URL) {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        var targets: [(url: URL, line: Int?, col: Int?)] = []
        var windowNumber: Int?
        var forceNew = false, reuse = false
        for q in items {
            switch q.name {
            case "path": if let v = q.value { targets.append((URL(fileURLWithPath: v), nil, nil)) }
            case "line": if !targets.isEmpty { targets[targets.count - 1].line = q.value.flatMap(Int.init) }
            case "col": if !targets.isEmpty { targets[targets.count - 1].col = q.value.flatMap(Int.init) }
            case "window": windowNumber = q.value.flatMap(Int.init)
            case "new": forceNew = true
            case "reuse": reuse = true
            default: break
            }
        }
        NSApp.activate()
        let caller = windowNumber.flatMap { n in controllers.first { $0.window?.windowNumber == n } }
        if targets.isEmpty {
            (forceNew ? newWindow(folder: nil) : (caller ?? current ?? newWindow(folder: nil))).window?.makeKeyAndOrderFront(nil)
            return
        }
        for t in targets {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: t.url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let c = controllers.first(where: { $0.folder?.standardizedFileURL == t.url.standardizedFileURL }), !forceNew {
                    c.window?.makeKeyAndOrderFront(nil)
                } else if !forceNew, let c = reuse ? (caller ?? current) : (caller.flatMap { $0.isEmpty ? $0 : nil } ?? current.flatMap { $0.isEmpty ? $0 : nil }) {
                    c.setFolder(t.url)
                    c.window?.makeKeyAndOrderFront(nil)
                } else {
                    newWindow(folder: t.url)
                }
                continue
            }
            let c = forceNew ? newWindow(folder: nil) : (caller ?? controllers.first { $0.contains(t.url) } ?? current ?? newWindow(folder: nil))
            c.window?.makeKeyAndOrderFront(nil)
            let view = c.openFile(t.url)
            if let line = t.line { view?.goTo(line: line - 1, col: max(0, (t.col ?? 1) - 1)) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for c in controllers {
            c.window?.makeKeyAndOrderFront(nil)
            c.saveSession()
            if !c.confirmCloseAll() { return .terminateCancel }
        }
        return .terminateNow
    }

    private var current: WorkbenchWindowController? {
        (NSApp.keyWindow?.windowController as? WorkbenchWindowController) ?? controllers.last
    }

    @discardableResult
    private func newWindow(folder: URL?) -> WorkbenchWindowController {
        let c = WorkbenchWindowController(folder: folder)
        c.onClose = { [weak self] closed in self?.controllers.removeAll { $0 === closed } }
        if let last = controllers.last?.window, let window = c.window {
            window.setFrameTopLeftPoint(last.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            c.window?.center()
        }
        controllers.append(c)
        c.showWindow(nil)
        return c
    }

    // menüden/son klasörlerden açma
    func openURL(_ url: URL) { open(url) }

    private func open(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            if let c = controllers.first(where: { $0.folder?.path == url.path }) {
                c.window?.makeKeyAndOrderFront(nil)
            } else if let c = current, c.isEmpty {
                c.setFolder(url)
                c.window?.makeKeyAndOrderFront(nil)
            } else {
                newWindow(folder: url)
            }
            return
        }
        // ilk pencere: dosya son klasörün içindeyse klasörle birlikte aç
        let folder = lastFolder.flatMap { url.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") ? $0 : nil }
        let target = controllers.first { $0.contains(url) } ?? current ?? newWindow(folder: folder)
        target.window?.makeKeyAndOrderFront(nil)
        target.openFile(url)
    }

    private var settingsWindow: SettingsWindowController?

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openSettingsJSON(_ sender: Any?) {
        let c = current ?? newWindow(folder: nil)
        c.window?.makeKeyAndOrderFront(nil)
        c.openSettingsJSON(sender)
    }

    @objc func openKeymapJSON(_ sender: Any?) {
        let c = current ?? newWindow(folder: nil)
        c.window?.makeKeyAndOrderFront(nil)
        c.openKeymapJSON(sender)
    }

    @objc func newDocument(_ sender: Any?) {
        (current ?? newWindow(folder: nil)).newUntitled()
    }

    @objc func newWindowAction(_ sender: Any?) {
        newWindow(folder: nil)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(open)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Updater.shared.checkForUpdates()
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Open Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }
}
