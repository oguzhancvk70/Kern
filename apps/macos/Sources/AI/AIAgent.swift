import Foundation

// ajan modu: araç kullanan döngü; yazma ve komut çalıştırma onaya tabi
final class AIAgent {
    let client: AIClient
    let root: URL
    var approve: (_ title: String, _ detail: String) async -> Bool = { _, _ in false }
    var onEvent: (String) -> Void = { _ in }
    var onText: (String) -> Void = { _ in }
    private(set) var messages: [[String: Any]] = []
    static let maxTurns = 30

    init(client: AIClient, root: URL) {
        self.client = client
        self.root = root.standardizedFileURL
    }

    static let system = """
    You are Kern's coding agent, working inside the user's project folder. Use the tools to inspect files before \
    changing them. Keep edits minimal and focused on the task. Paths are relative to the project root. \
    write_file and run_command need the user's approval; if one is rejected, adjust your plan instead of retrying \
    the same call. When you finish, summarize what you changed in a few sentences.
    """

    static let tools: [[String: Any]] = [
        tool("list_files", "List files under a directory of the project (recursive, max 500 entries).",
             ["path": ["type": "string", "description": "Directory relative to project root; empty for root"]], []),
        tool("read_file", "Read a UTF-8 text file from the project.",
             ["path": ["type": "string", "description": "File path relative to project root"]], ["path"]),
        tool("search", "Search the project for a literal string; returns path:line: text matches (max 200).",
             ["query": ["type": "string"]], ["query"]),
        tool("write_file", "Create or overwrite a file with the full new content. Requires user approval.",
             ["path": ["type": "string"], "content": ["type": "string", "description": "Complete new file content"]], ["path", "content"]),
        tool("run_command", "Run a shell command in the project root (zsh, 120 s timeout). Requires user approval.",
             ["command": ["type": "string"]], ["command"]),
    ]

    private static func tool(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name, "description": desc, "eager_input_streaming": true,
         "input_schema": ["type": "object", "properties": props, "required": required]]
    }

    func run(_ task: String) async throws -> String {
        messages.append(["role": "user", "content": task])
        for _ in 0..<Self.maxTurns {
            let body: [String: Any] = [
                "model": AIModel.agent, "max_tokens": 64000, "system": Self.system, "tools": Self.tools,
                "messages": messages, "cache_control": ["type": "ephemeral"], "fallbacks": "default",
            ]
            let resp = try await client.stream(body, betas: ["server-side-fallback-2026-07-01"], onText: onText)
            // yanıt içeriği olduğu gibi (düşünme blokları dahil) geri gönderilir
            messages.append(["role": "assistant", "content": resp.content.map { $0.filter { $0.key != "_invalid" } }])
            if resp.stopReason == "max_tokens" { onEvent("⚠ Response hit the output limit.") }
            guard resp.stopReason == "tool_use" else { return resp.text }
            var results: [[String: Any]] = []
            for use in resp.toolUses {
                let id = use["id"] as? String ?? ""
                let name = use["name"] as? String ?? ""
                let input = use["input"] as? [String: Any] ?? [:]
                let (out, isError) = use["_invalid"] as? Bool == true
                    ? ("INVALID_JSON: tool input could not be parsed; send the call again.", true)
                    : await execute(name, input)
                var r: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": out]
                if isError { r["is_error"] = true }
                results.append(r)
            }
            messages.append(["role": "user", "content": results])
        }
        return "Stopped after \(Self.maxTurns) steps."
    }

    // proje dışına çıkan yolları reddet
    func resolve(_ path: String) -> URL? {
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
        let r = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(r) ? url : nil
    }

    func execute(_ name: String, _ input: [String: Any]) async -> (String, Bool) {
        let str = { (k: String) -> String? in input[k] as? String }
        switch name {
        case "list_files":
            guard let dir = resolve(str("path") ?? "") else { return ("Path is outside the project.", true) }
            onEvent("▸ list \(dir.path.replacingOccurrences(of: root.path, with: "."))")
            let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var out: [String] = []
            while let u = e?.nextObject() as? URL, out.count < 500 {
                let rel = String(u.path.dropFirst(root.path.count + 1))
                if rel.hasPrefix("target") || rel.contains("/node_modules/") || rel.hasPrefix("node_modules") { e?.skipDescendants(); continue }
                out.append(rel)
            }
            return (out.joined(separator: "\n") + (out.count >= 500 ? "\n… (listing stopped at 500 entries)" : ""), false)
        case "read_file":
            guard let p = str("path"), let url = resolve(p) else { return ("Missing or invalid path.", true) }
            onEvent("▸ read \(p)")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ("Cannot read \(p) as UTF-8 text.", true) }
            return (text, false)
        case "search":
            guard let q = str("query"), !q.isEmpty else { return ("Missing query.", true) }
            onEvent("▸ search “\(q)”")
            let ws = KernWorkspace(root.path)
            let hits = ws.start_search(q, 1, 200)
            var raw = ""
            while let h = hits, !h.is_done() { raw += h.poll().toString(); usleep(5000) }
            raw += hits?.poll().toString() ?? ""
            let lines = raw.split(separator: "\n").map { l -> String in
                let f = l.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
                return f.count == 6 ? "\(f[0]):\(Int(f[1]).map { $0 + 1 } ?? 0): \(f[5])" : String(l)
            }
            return (lines.isEmpty ? "No matches." : lines.joined(separator: "\n"), false)
        case "write_file":
            guard let p = str("path"), let content = str("content"), let url = resolve(p) else { return ("Missing or invalid path/content.", true) }
            let old = (try? String(contentsOf: url, encoding: .utf8))
            let summary = old == nil ? "New file (\(content.count) characters)" : "Overwrite (\(old!.count) → \(content.count) characters)"
            guard await approve("Write \(p)?", summary + "\n\n" + String(content.prefix(4000))) else {
                onEvent("✗ write \(p) rejected")
                return ("The user rejected this write.", true)
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
                onEvent("✓ wrote \(p)")
                return ("Wrote \(p).", false)
            } catch { return ("Write failed: \(error.localizedDescription)", true) }
        case "run_command":
            guard let cmd = str("command"), !cmd.isEmpty else { return ("Missing command.", true) }
            guard await approve("Run command?", cmd) else {
                onEvent("✗ command rejected")
                return ("The user rejected this command.", true)
            }
            onEvent("▸ $ \(cmd)")
            return await Self.shell(cmd, in: root)
        default:
            return ("Unknown tool \(name).", true)
        }
    }

    static func shell(_ cmd: String, in dir: URL) async -> (String, Bool) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", cmd]
                p.currentDirectoryURL = dir
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { return cont.resume(returning: ("Failed to start: \(error.localizedDescription)", true)) }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                var out = String(decoding: data, as: UTF8.self)
                // çok uzun çıktı: baş ve son kısım, arada kısaltıldığı belirtilir
                if out.count > 30_000 {
                    out = String(out.prefix(12_000)) + "\n… [\(out.count - 24_000) characters omitted] …\n" + String(out.suffix(12_000))
                }
                cont.resume(returning: ("exit code \(p.terminationStatus)\n\(out)", p.terminationStatus != 0))
            }
        }
    }
}
