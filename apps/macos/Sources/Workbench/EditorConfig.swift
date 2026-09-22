import AppKit
import Darwin

// .editorconfig: dosyanın klasöründen yukarı doğru, root=true'da durur
struct EditorConfig {
    var indentSize: Int?
    var useSpaces: Bool?
    var trimTrailingWhitespace: Bool?
    var insertFinalNewline: Bool?

    var isEmpty: Bool { indentSize == nil && useSpaces == nil && trimTrailingWhitespace == nil && insertFinalNewline == nil }

    static func load(for path: String) -> EditorConfig {
        var result = EditorConfig()
        guard Settings.shared.bool("files.useEditorConfig"), !path.isEmpty else { return result }
        let file = URL(fileURLWithPath: path)
        var dir = file.deletingLastPathComponent()
        var files: [URL] = []
        while true {
            files.append(dir.appendingPathComponent(".editorconfig"))
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        // yakından uzağa topla, root=true'da dur; sonra uzaktan yakına uygula (en yakın kazanır)
        var chain: [EditorConfig] = []
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let (cfg, isRoot) = parse(text, name: file.lastPathComponent)
            chain.append(cfg)
            if isRoot { break }
        }
        for cfg in chain.reversed() { result.merge(cfg) }
        return result
    }

    private mutating func merge(_ o: EditorConfig) {
        indentSize = o.indentSize ?? indentSize
        useSpaces = o.useSpaces ?? useSpaces
        trimTrailingWhitespace = o.trimTrailingWhitespace ?? trimTrailingWhitespace
        insertFinalNewline = o.insertFinalNewline ?? insertFinalNewline
    }

    // yalnız eşleşen bölümler; desteklenen anahtarlar: indent_style, indent_size/tab_width,
    // trim_trailing_whitespace, insert_final_newline
    static func parse(_ text: String, name: String) -> (EditorConfig, Bool) {
        var cfg = EditorConfig()
        var isRoot = false
        var applies = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                applies = matches(String(line.dropFirst().dropLast()), name)
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count == 2 else { continue }
            let (key, value) = (parts[0], parts[1])
            if key == "root", !applies { isRoot = value == "true" }
            guard applies else { continue }
            switch key {
            case "indent_style": cfg.useSpaces = value == "space" ? true : (value == "tab" ? false : nil)
            case "indent_size", "tab_width": if let n = Int(value) { cfg.indentSize = n }
            case "trim_trailing_whitespace": cfg.trimTrailingWhitespace = value == "true"
            case "insert_final_newline": cfg.insertFinalNewline = value == "true"
            default: break
            }
        }
        return (cfg, isRoot)
    }

    // glob: *, **, ?, {a,b}, [abc] — dosya adına göre
    static func matches(_ pattern: String, _ name: String) -> Bool {
        for alt in expand(pattern) {
            let p = alt.contains("/") ? String(alt.split(separator: "/").last ?? "") : alt
            if fnmatch(p, name, 0) == 0 { return true }
        }
        return false
    }

    // {a,b} açılımı
    private static func expand(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "{"), let close = pattern[open...].firstIndex(of: "}") else { return [pattern] }
        let head = String(pattern[pattern.startIndex..<open])
        let tail = String(pattern[pattern.index(after: close)...])
        return pattern[pattern.index(after: open)..<close].split(separator: ",", omittingEmptySubsequences: false)
            .flatMap { expand(head + $0 + tail) }
    }
}
