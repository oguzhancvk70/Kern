import AppKit

// ~/Library/Application Support/Kern/settings.json + <proje>/.kern/settings.json (JSONC)
final class Settings {
    static let shared = Settings()
    static let changed = Notification.Name("KernSettingsChanged")

    static let defaults: [String: Any] = [
        "editor.fontSize": 13,
        "editor.fontFamily": "",
        "editor.tabSize": 4,
        "editor.insertSpaces": true,
        "editor.detectIndentation": true,
        "editor.wordWrap": false,
        "editor.minimap": true,
        "workbench.colorTheme": "system",
        "update.automatic": true,
        "terminal.optionAsMeta": true,
        "terminal.scrollback": 10000,
        "terminal.fontSize": 12,
        "files.trimTrailingWhitespace": false,
        "files.insertFinalNewline": false,
        "ai.inlineCompletion": false,
        "lsp.enabled": true,
    ]

    private(set) var values: [String: Any] = Settings.defaults
    private(set) var projectRoot: URL?
    private(set) var error: String?

    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["KERN_CONFIG_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kern", isDirectory: true)
    }
    static var userFile: URL { directory.appendingPathComponent("settings.json") }
    static var keymapFile: URL { directory.appendingPathComponent("keymap.json") }
    var projectFile: URL? { projectRoot?.appendingPathComponent(".kern/settings.json") }

    func bool(_ key: String) -> Bool { values[key] as? Bool ?? Settings.defaults[key] as? Bool ?? false }
    func int(_ key: String) -> Int { (values[key] as? NSNumber)?.intValue ?? (Settings.defaults[key] as? Int ?? 0) }
    func double(_ key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
    func string(_ key: String) -> String { values[key] as? String ?? Settings.defaults[key] as? String ?? "" }

    func setProject(_ root: URL?) {
        guard root?.standardizedFileURL != projectRoot?.standardizedFileURL else { return }
        projectRoot = root
        reload()
    }

    func isSettingsFile(_ path: String) -> Bool {
        [Settings.userFile.path, Settings.keymapFile.path, projectFile?.path].contains(path)
    }

    func reload() {
        var merged = Settings.defaults
        var problems: [String] = []
        for url in [Settings.userFile, projectFile].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let dict = Settings.parse(data) { merged.merge(dict) { $1 } } else { problems.append(url.lastPathComponent) }
        }
        values = merged
        error = problems.isEmpty ? nil : "Could not parse \(problems.joined(separator: ", "))"
        NotificationCenter.default.post(name: Settings.changed, object: nil)
    }

    // kullanıcı dosyasında tek anahtarı değiştir (yorumlar korunmaz)
    func set(_ key: String, _ value: Any) {
        var user = (try? Data(contentsOf: Settings.userFile)).flatMap(Settings.parse) ?? [:]
        user[key] = value
        write(user, to: Settings.userFile)
        reload()
    }

    func ensureUserFile() -> URL {
        let url = Settings.userFile
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
            let body = Settings.defaults.keys.sorted().map { key -> String in
                let v = Settings.defaults[key]!
                let json = (try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                return "    // \"\(key)\": \(json)"
            }.joined(separator: ",\n")
            try? "// Kern kullanıcı ayarları — varsayılanları değiştirmek için satırın yorumunu kaldır\n{\n\(body)\n}\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    func ensureKeymapFile() -> URL {
        let url = Settings.keymapFile
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
            try? """
            // Kısayollar: menü eyleminin adı ve tuş. Örnek:
            // [ { "key": "cmd+shift+d", "command": "copyLineDown:" } ]
            []

            """.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    private func write(_ dict: [String: Any], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // JSONC: // ve /* */ yorumları ile sondaki virgüller
    static func parse(_ data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let clean = stripComments(text)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(clean.utf8)) else { return nil }
        return obj as? [String: Any]
    }

    static func parseArray(_ data: Data) -> [[String: Any]]? {
        guard let text = String(data: data, encoding: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: Data(stripComments(text).utf8)) else { return nil }
        return obj as? [[String: Any]]
    }

    static func stripComments(_ text: String) -> String {
        var out = ""
        var chars = Array(text), i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\" && i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        // sondaki virgüller: ",  }" / ",  ]"
        chars = Array(out)
        var result = ""
        i = 0
        inString = false
        while i < chars.count {
            let c = chars[i]
            if c == "\"" && (i == 0 || chars[i - 1] != "\\") { inString.toggle() }
            if !inString && c == "," {
                var j = i + 1
                while j < chars.count && chars[j].isWhitespace { j += 1 }
                if j < chars.count && (chars[j] == "}" || chars[j] == "]") { i += 1; continue }
            }
            result.append(c)
            i += 1
        }
        return result
    }

    // keymap.json'u menü kısayollarına uygula
    func applyKeymap(to menu: NSMenu?) {
        guard let menu else { return }
        // önce eklenti kısayolları, sonra kullanıcınınki (kullanıcı kazanır)
        let user = (try? Data(contentsOf: Settings.keymapFile)).flatMap(Settings.parseArray) ?? []
        let entries = Extensions.shared.keybindings + user
        var items: [String: NSMenuItem] = [:]
        func walk(_ m: NSMenu) {
            for it in m.items {
                if let rep = it.representedObject as? String, rep.hasPrefix("ext:") {
                    items[rep] = it
                } else if let a = it.action { items[NSStringFromSelector(a)] = it }
                if let sub = it.submenu { walk(sub) }
            }
        }
        walk(menu)
        for e in entries {
            guard let cmd = e["command"] as? String, let key = e["key"] as? String else { continue }
            let name = cmd.hasPrefix("ext:") || cmd.hasSuffix(":") ? cmd : cmd + ":"
            guard let item = items[name], let (k, mods) = Settings.parseKey(key) else { continue }
            // aynı kısayol başka öğedeyse onu boşalt
            for other in items.values where other !== item && other.keyEquivalent == k && other.keyEquivalentModifierMask == mods {
                other.keyEquivalent = ""
            }
            item.keyEquivalent = k
            item.keyEquivalentModifierMask = mods
        }
    }

    static func parseKey(_ spec: String) -> (String, NSEvent.ModifierFlags)? {
        var mods: NSEvent.ModifierFlags = []
        var key: String?
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command", "meta": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "alt", "option", "opt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            case "up": key = String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case "down": key = String(UnicodeScalar(NSDownArrowFunctionKey)!)
            case "left": key = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case "right": key = String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case "enter", "return": key = "\r"
            case "tab": key = "\t"
            case "space": key = " "
            case "backspace": key = String(UnicodeScalar(8))
            case "escape", "esc": key = String(UnicodeScalar(27))
            default:
                if part.count == 1 { key = part }
                else if part.hasPrefix("f"), let n = Int(part.dropFirst()), (1...20).contains(n) {
                    key = String(UnicodeScalar(NSF1FunctionKey + n - 1)!)
                } else { return nil }
            }
        }
        return key.map { ($0, mods) }
    }
}
