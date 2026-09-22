import AppKit

// .kern/tasks.json (VS Code biçimi): { "tasks": [{ "label", "command", "args", "cwd", "env" }] }
struct TaskDefinition {
    var label: String
    var command: String
    var cwd: String?
    var env: [String: String]

    // kabuk satırı
    var shellLine: String {
        let prefix = env.sorted { $0.key < $1.key }.map { "\($0.key)=\(shellQuote($0.value))" }.joined(separator: " ")
        return (prefix.isEmpty ? "" : prefix + " ") + command
    }

    private func shellQuote(_ s: String) -> String {
        s.contains(where: { $0 == " " || $0 == "\"" }) ? "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" : s
    }
}

final class TaskRunner {
    private(set) var tasks: [TaskDefinition] = []
    private(set) var lastLabel: String?

    // .kern/tasks.json, yoksa .vscode/tasks.json
    static func file(in folder: URL) -> URL {
        let kern = folder.appendingPathComponent(".kern/tasks.json")
        if FileManager.default.fileExists(atPath: kern.path) { return kern }
        let code = folder.appendingPathComponent(".vscode/tasks.json")
        return FileManager.default.fileExists(atPath: code.path) ? code : kern
    }

    func reload(_ folder: URL?) {
        tasks = []
        guard let folder, let data = try? Data(contentsOf: Self.file(in: folder)), let obj = Settings.parse(data) else { return }
        for raw in obj["tasks"] as? [[String: Any]] ?? [] {
            guard let label = raw["label"] as? String ?? raw["taskName"] as? String else { continue }
            var command = raw["command"] as? String ?? ""
            if let args = raw["args"] as? [String], !args.isEmpty {
                command += " " + args.joined(separator: " ")
            }
            guard !command.isEmpty else { continue }
            let options = raw["options"] as? [String: Any]
            tasks.append(TaskDefinition(label: label, command: command,
                                        cwd: options?["cwd"] as? String,
                                        env: options?["env"] as? [String: String] ?? [:]))
        }
    }

    func task(named: String) -> TaskDefinition? { tasks.first { $0.label == named } }

    func remember(_ label: String) { lastLabel = label }

    static let sample = """
    // Kern görevleri — terminalde çalışır
    {
        "tasks": [
            { "label": "build", "command": "make", "args": ["all"] },
            { "label": "test", "command": "npm", "args": ["test"] }
        ]
    }

    """
}

extension WorkbenchWindowController {
    private var runner: TaskRunner {
        if let r = tasksRunner { return r }
        let r = TaskRunner()
        tasksRunner = r
        return r
    }

    @objc func runTask(_ sender: Any?) {
        let r = runner
        r.reload(folder)
        guard !r.tasks.isEmpty else {
            return report(folder == nil ? "Open a folder first" : "No tasks in \(TaskRunner.file(in: folder!).lastPathComponent)")
        }
        let items = r.tasks.map { t in
            PaletteItem(title: t.label, detail: t.command) { [weak self] in self?.start(t) }
        }
        showPalette("", provider: { q in
            q.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.detail.localizedCaseInsensitiveContains(q) }
        }, placeholder: "Run Task")
    }

    @objc func rerunLastTask(_ sender: Any?) {
        let r = runner
        r.reload(folder)
        guard let label = r.lastLabel, let t = r.task(named: label) else { return runTask(sender) }
        start(t)
    }

    private func start(_ task: TaskDefinition) {
        runner.remember(task.label)
        showTerminal()
        root.terminal.newTerminal()
        let line = task.cwd.map { "cd \($0) && " } ?? ""
        // terminal hazır olsun diye bir tur bekle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.root.terminal.terminal?.run(line + task.shellLine)
        }
    }

    @objc func openTasksFile(_ sender: Any?) {
        guard let folder else { return report("Open a folder first") }
        let url = TaskRunner.file(in: folder)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? TaskRunner.sample.write(to: url, atomically: true, encoding: .utf8)
        }
        openFile(url)
    }
}
