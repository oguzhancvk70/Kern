import AppKit

// son açılan klasörler (File ▸ Open Recent)
enum RecentFolders {
    private static let key = "recentFolders"
    private static let limit = 12

    static var urls: [URL] {
        (UserDefaults.standard.array(forKey: key) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var list = urls.map(\.standardizedFileURL.path).filter { $0 != url.standardizedFileURL.path }
        list.insert(url.standardizedFileURL.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// File ▸ Open Recent menüsü açılırken doldurulur
final class RecentFoldersMenu: NSObject, NSMenuDelegate {
    static let shared = RecentFoldersMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let list = RecentFolders.urls
        for url in list {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.toolTip = url.path
            item.representedObject = url
            menu.addItem(item)
        }
        if list.isEmpty {
            menu.addItem(NSMenuItem(title: "No Recent Folders", action: nil, keyEquivalent: ""))
            return
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clear), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        (NSApp.delegate as? AppDelegate)?.openURL(url)
    }

    @objc private func clear() {
        RecentFolders.clear()
    }
}
