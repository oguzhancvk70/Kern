import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [WorkbenchWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
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
        urls.forEach(open)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for c in controllers {
            c.window?.makeKeyAndOrderFront(nil)
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

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Open Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }
}
