import AppKit

// yüklü eklentiler: paket içi (Resources/extensions) + kullanıcı (<ayar dizini>/extensions)
final class Extensions {
    static let shared = Extensions()
    static let changed = Notification.Name("KernExtensionsChanged")

    private let registry = KernExtensions()
    private(set) var installed: [[String: Any]] = []
    private(set) var errors: [[String: Any]] = []
    private(set) var contributions: [String: Any] = [:]

    static var userDir: URL { Settings.directory.appendingPathComponent("extensions", isDirectory: true) }
    static var bundledDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("extensions", isDirectory: true) }

    private func json(_ s: RustString) -> Any? { try? JSONSerialization.jsonObject(with: Data(s.toString().utf8)) }

    func reload() {
        let roots = [Self.bundledDir, Self.userDir].compactMap { $0?.path }.joined(separator: "\n")
        registry.load(roots)
        Theme.customCache = nil
        installed = json(registry.list()) as? [[String: Any]] ?? []
        errors = json(registry.errors()) as? [[String: Any]] ?? []
        contributions = json(registry.contributions()) as? [String: Any] ?? [:]
        errors.forEach { NSLog("Kern extension error: %@ — %@", "\($0["dir"] ?? "")", "\($0["error"] ?? "")") }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    var commands: [(ext: String, id: String, title: String)] {
        (contributions["commands"] as? [[String: Any]] ?? []).compactMap { c in
            guard let e = c["extension"] as? String, let id = c["id"] as? String else { return nil }
            return (e, id, c["title"] as? String ?? id)
        }
    }

    var themes: [[String: Any]] { contributions["themes"] as? [[String: Any]] ?? [] }
    var themeNames: [String] { themes.compactMap { $0["name"] as? String } }
    func theme(named name: String) -> [String: Any]? { themes.first { $0["name"] as? String == name } }

    var languageServers: [String: String] { contributions["languageServers"] as? [String: String] ?? [:] }
    var keybindings: [[String: Any]] { contributions["keybindings"] as? [[String: Any]] ?? [] }

    func snippets(for language: String) -> [[String: Any]] {
        (contributions["snippets"] as? [String: Any])?[language] as? [[String: Any]] ?? []
    }

    func isBundled(_ ext: [String: Any]) -> Bool {
        guard let dir = ext["dir"] as? String, let b = Self.bundledDir?.path else { return false }
        return dir.hasPrefix(b)
    }

    func run(_ ext: String, _ command: String, context: [String: Any], root: String) -> [String: Any] {
        let ctx = (try? JSONSerialization.data(withJSONObject: context)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return json(registry.run_command(ext, command, ctx, root)) as? [String: Any] ?? ["error": "invalid result"]
    }

    // kurmadan önce manifest (ya da hata)
    func inspect(_ dir: URL) -> [String: Any] {
        json(registry.inspect(dir.path)) as? [String: Any] ?? ["error": "unreadable manifest"]
    }

    func install(_ dir: URL, id: String) throws {
        let dest = Self.userDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: Self.userDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: dir, to: dest)
        reload()
    }

    func uninstall(_ ext: [String: Any]) throws {
        guard !isBundled(ext), let dir = ext["dir"] as? String else { return }
        try FileManager.default.removeItem(atPath: dir)
        reload()
    }
}
