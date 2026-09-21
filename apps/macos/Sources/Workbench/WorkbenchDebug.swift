import AppKit

// hata ayıklama durumu; tüm DAP çağrıları tek seri kuyrukta (istek/yanıt sırası korunur)
final class DebugState {
    var session: KernDebug?
    let queue = DispatchQueue(label: "dev.kern.debug")
    var timer: Timer?
    var version: UInt64 = 0
    var generation = 0
    var busy = false
    var breakpoints: [String: Set<Int>] = [:]   // yol → 0 tabanlı satırlar
    var configs: [[String: Any]] = []
    var selected = 0
    var state = "none"
    var stopped: (path: String, line: Int)?     // 0 tabanlı
    var frame: Int64 = -1
    var statusText = ""

    static let defaultsKey = "breakpoints"
    // self-test kullanıcı tercihlerini kirletmesin
    private let persists = ProcessInfo.processInfo.environment["KERN_SELFTEST"] == nil

    init() {
        guard persists else { return }
        let saved = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: [Int]] ?? [:]
        breakpoints = saved.mapValues(Set.init)
    }

    func save() {
        guard persists else { return }
        UserDefaults.standard.set(breakpoints.filter { !$0.value.isEmpty }.mapValues { $0.sorted() }, forKey: Self.defaultsKey)
    }
}

private func jsonObject(_ raw: String) -> Any? {
    try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)
}

private func jsonString(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

extension WorkbenchWindowController {
    func wireDebug() {
        let panel = root.debug
        panel.onStart = { [weak self] in self?.startDebugging(nil) }
        panel.onStop = { [weak self] in self?.stopDebugging(nil) }
        panel.onRestart = { [weak self] in self?.restartDebugging(nil) }
        panel.onPauseOrContinue = { [weak self] in
            guard let self else { return }
            self.debug.state == "stopped" ? self.debugResume("continue") : self.debugPause()
        }
        panel.onStep = { [weak self] cmd in self?.debugResume(cmd) }
        panel.onSelectConfig = { [weak self] i in
            guard let self, i >= 0, i < self.debug.configs.count else { return }
            self.debug.selected = i
        }
        panel.onOpenLaunchJSON = { [weak self] in self?.openLaunchJSON() }
        panel.onSelectFrame = { [weak self] node in self?.debugSelectFrame(node) }
        panel.onExpand = { [weak self] node in self?.debugLoadChildren(node) }
        panel.onRemoveBreakpoint = { [weak self] node in
            guard node.line >= 0 else { return }
            self?.setBreakpoint(path: node.path, line: node.line, on: false)
        }
        panel.onOpen = { [weak self] node in
            guard !node.path.isEmpty else { return }
            self?.openFile(URL(fileURLWithPath: node.path))?.goTo(line: max(0, node.line), col: 0)
        }
        root.console.onClose = { [weak self] in self?.hideDebugConsole() }
        root.console.onEvaluate = { [weak self] expr in self?.debugEvaluate(expr) }
        refreshConfigs()
        refreshDebugTree()
    }

    // menü eylemleri

    @objc func showDebugPanel(_ sender: Any?) {
        root.sidebarVisible = true
        root.panel = 4
        root.needsLayout = true
        refreshConfigs()
        refreshDebugTree()
    }

    @objc func startDebugging(_ sender: Any?) {
        guard debug.session == nil else { return debugResume("continue") }
        showDebugPanel(nil)
        guard let config = pickDebugConfig() else { return }
        let kind = config["type"] as? String ?? ""
        let status = debug_adapter_status(kind).toString()
        guard status == "ok" else {
            root.debug.show(status.hasPrefix("missing") ? "Debug adapter \(status)" : status, error: true)
            return
        }
        let rootPath = (folder ?? activeTab?.url?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSHomeDirectory())).path
        let bps = jsonString(debug.breakpoints.filter { !$0.value.isEmpty }.mapValues { $0.map { $0 + 1 }.sorted() })
        let configJSON = jsonString(config)
        root.debug.show("Starting \(config["name"] as? String ?? kind)…")
        showDebugConsole()
        root.console.append("Starting: \(config["name"] as? String ?? kind)\n", category: "important")
        debug.generation += 1
        let gen = debug.generation
        debug.queue.async { [weak self] in
            let session = debug_start(rootPath, configJSON, bps)
            let error = session == nil ? debug_last_error().toString() : ""
            DispatchQueue.main.async {
                guard let self, self.debug.generation == gen else {
                    session?.terminate()
                    return
                }
                guard let session else {
                    self.root.debug.show(error, error: true)
                    self.root.console.append("\(error)\n", category: "stderr")
                    return
                }
                self.debug.session = session
                self.debug.version = 0
                self.debug.state = "starting"
                self.root.debug.setState(state: "starting", reason: "")
                self.root.debug.show("")
                self.startDebugTimer()
            }
        }
    }

    @objc func stopDebugging(_ sender: Any?) {
        guard let session = debug.session else { return }
        debug.generation += 1
        debug.session = nil
        stopDebugTimer()
        debug.state = "none"
        debug.stopped = nil
        debug.frame = -1
        debug.statusText = ""
        root.debug.setState(state: "none", reason: "")
        root.console.append("Debug session stopped.\n", category: "important")
        allTabs.forEach { $0.view.stoppedLine = nil }
        refreshDebugTree()
        refreshUI()
        debug.queue.async { session.terminate() }
    }

    @objc func restartDebugging(_ sender: Any?) {
        let again = debug.session != nil
        stopDebugging(nil)
        guard again else { return }
        // bağdaştırıcı kapanması için bir tur bekle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.startDebugging(nil) }
    }

    @objc func debugStepOver(_ sender: Any?) { debugResume("next") }
    @objc func debugStepInto(_ sender: Any?) { debugResume("stepIn") }
    @objc func debugStepOut(_ sender: Any?) { debugResume("stepOut") }
    @objc func debugContinue(_ sender: Any?) { debug.session == nil ? startDebugging(nil) : debugResume("continue") }
    @objc func debugPauseAction(_ sender: Any?) { debugPause() }

    @objc func toggleBreakpoint(_ sender: Any?) {
        guard let tab = activeTab, !tab.path.isEmpty else { return }
        let line = Int(tab.editor.cursor_line())
        setBreakpoint(path: tab.path, line: line, on: !(debug.breakpoints[tab.path]?.contains(line) ?? false))
    }

    @objc func removeAllBreakpoints(_ sender: Any?) {
        let paths = Array(debug.breakpoints.keys)
        debug.breakpoints.removeAll()
        debug.save()
        allTabs.forEach { $0.view.breakpointLines = [] }
        if let session = debug.session {
            debug.queue.async { paths.forEach { _ = session.set_breakpoints($0, "") } }
        }
        refreshDebugTree()
    }

    @objc func toggleDebugConsole(_ sender: Any?) {
        root.consoleVisible ? hideDebugConsole() : showDebugConsole()
    }

    @objc func openLaunchJSON(_ sender: Any? = nil) {
        guard let folder else {
            let alert = NSAlert()
            alert.messageText = "Open a folder first."
            alert.informativeText = "launch.json is stored in the project’s .kern folder."
            alert.runModal()
            return
        }
        let dir = folder.appendingPathComponent(".kern")
        let file = dir.appendingPathComponent("launch.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let suggestion = activeTab.flatMap { t -> [String: Any]? in
                guard !t.path.isEmpty else { return nil }
                return jsonObject(debug_suggest(t.path).toString()) as? [String: Any]
            }
            var entry: [String: Any] = suggestion ?? ["name": "Launch", "type": "lldb", "request": "launch", "program": "${workspaceFolder}/a.out"]
            entry.removeValue(forKey: "needsProgram")
            if entry["program"] as? String == "" { entry["program"] = "${workspaceFolder}/a.out" }
            let template: [String: Any] = ["version": "0.2.0", "configurations": [entry]]
            let data = try? JSONSerialization.data(withJSONObject: template, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: file)
        }
        openFile(file)
        refreshConfigs()
    }

    // konfigürasyonlar

    func refreshConfigs() {
        let rootPath = folder?.path ?? ""
        debug.configs = rootPath.isEmpty ? [] : (jsonObject(debug_configs(rootPath).toString()) as? [[String: Any]] ?? [])
        debug.selected = min(debug.selected, max(0, debug.configs.count - 1))
        root.debug.setConfigs(debug.configs.map { $0["name"] as? String ?? $0["type"] as? String ?? "debug" }, selected: debug.selected)
    }

    // launch.json yoksa açık dosyadan öneri
    private func pickDebugConfig() -> [String: Any]? {
        refreshConfigs()
        if debug.selected < debug.configs.count {
            return resolveVariables(debug.configs[debug.selected])
        }
        guard let tab = activeTab, !tab.path.isEmpty else {
            root.debug.show("Open a file or add a launch configuration.", error: true)
            return nil
        }
        guard let suggestion = jsonObject(debug_suggest(tab.path).toString()) as? [String: Any] else {
            root.debug.show("No debug configuration for this file type.", error: true)
            return nil
        }
        if suggestion["needsProgram"] as? Bool == true {
            root.debug.show("Compiled languages need a program path in launch.json.", error: true)
            root.console.append("Add .kern/launch.json with the built executable’s path.\n", category: "important")
            openLaunchJSON()
            return nil
        }
        return resolveVariables(suggestion)
    }

    // ${workspaceFolder} ve ${file} değişkenleri
    private func resolveVariables(_ config: [String: Any]) -> [String: Any] {
        let workspace = folder?.path ?? ""
        let file = activeTab?.path ?? ""
        func expand(_ value: Any) -> Any {
            if let s = value as? String {
                return s.replacingOccurrences(of: "${workspaceFolder}", with: workspace)
                    .replacingOccurrences(of: "${workspaceRoot}", with: workspace)
                    .replacingOccurrences(of: "${file}", with: file)
                    .replacingOccurrences(of: "${fileDirname}", with: (file as NSString).deletingLastPathComponent)
            }
            if let a = value as? [Any] { return a.map(expand) }
            if let d = value as? [String: Any] { return d.mapValues(expand) }
            return value
        }
        return config.mapValues(expand)
    }

    // kesme noktaları

    func setBreakpoint(path: String, line: Int, on: Bool) {
        guard !path.isEmpty else { return }
        var lines = debug.breakpoints[path] ?? []
        if on { lines.insert(line) } else { lines.remove(line) }
        debug.breakpoints[path] = lines.isEmpty ? nil : lines
        debug.save()
        for t in allTabs where t.path == path { t.view.breakpointLines = lines }
        if let session = debug.session {
            let csv = lines.map { String($0 + 1) }.sorted().joined(separator: ",")
            debug.queue.async { _ = session.set_breakpoints(path, csv) }
        }
        refreshDebugTree()
    }

    // sekme açıldığında/değiştiğinde işaretleri uygula
    func debugSync(_ tab: EditorTab) {
        guard !tab.path.isEmpty else { return }
        tab.view.breakpointLines = debug.breakpoints[tab.path] ?? []
        if let s = debug.stopped, s.path == tab.url?.resolvingSymlinksInPath().path || s.path == tab.path {
            tab.view.stoppedLine = s.line
        } else {
            tab.view.stoppedLine = nil
        }
    }

    // oturum döngüsü

    private func startDebugTimer() {
        stopDebugTimer()
        debug.timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.debugTick() }
    }

    private func stopDebugTimer() {
        debug.timer?.invalidate()
        debug.timer = nil
    }

    private func debugTick() {
        guard let session = debug.session, !debug.busy else { return }
        let last = debug.version, gen = debug.generation
        debug.busy = true
        debug.queue.async { [weak self] in
            let version = session.version()
            guard version != last else {
                DispatchQueue.main.async { self?.debug.busy = false }
                return
            }
            let status = jsonObject(session.status().toString()) as? [String: Any] ?? [:]
            let output = jsonObject(session.output().toString()) as? [[String: Any]] ?? []
            var frames: [[String: Any]] = []
            var scopes: [DebugNode] = []
            if status["state"] as? String == "stopped", let thread = status["thread"] as? Int {
                frames = jsonObject(session.stack_trace(Int64(thread)).toString()) as? [[String: Any]] ?? []
                if let frameId = frames.first?["id"] as? Int {
                    scopes = Self.scopeNodes(session, frame: Int64(frameId))
                }
            }
            DispatchQueue.main.async {
                guard let self, self.debug.generation == gen else { return }
                self.debug.busy = false
                self.debug.version = version
                self.applyDebug(status: status, output: output, frames: frames, scopes: scopes)
            }
        }
    }

    // kapsamlar ve ilk seviye değişkenler
    private static func scopeNodes(_ session: KernDebug, frame: Int64) -> [DebugNode] {
        let scopes = jsonObject(session.scopes(frame).toString()) as? [[String: Any]] ?? []
        return scopes.compactMap { scope in
            guard let ref = scope["variablesReference"] as? Int, ref > 0 else { return nil }
            let node = DebugNode(.variable, title: scope["name"] as? String ?? "Scope", reference: Int64(ref))
            node.expanded = scope["expensive"] as? Bool != true
            if node.expanded {
                node.children = variableNodes(session, reference: Int64(ref))
            }
            return node
        }
    }

    private static func variableNodes(_ session: KernDebug, reference: Int64) -> [DebugNode] {
        let vars = jsonObject(session.variables(reference).toString()) as? [[String: Any]] ?? []
        return vars.map { v in
            let ref = v["variablesReference"] as? Int ?? 0
            return DebugNode(.variable, title: v["name"] as? String ?? "?",
                             detail: v["value"] as? String ?? "", reference: Int64(ref))
        }
    }

    private func applyDebug(status: [String: Any], output: [[String: Any]], frames: [[String: Any]], scopes: [DebugNode]) {
        let state = status["state"] as? String ?? "none"
        let reason = status["reason"] as? String ?? ""
        debug.state = state
        for item in output {
            root.console.append(item["text"] as? String ?? "", category: item["category"] as? String ?? "console")
        }
        root.debug.setState(state: state, reason: reason)

        // duran satır
        debug.stopped = nil
        debug.frame = (frames.first?["id"] as? Int).map(Int64.init) ?? -1
        if state == "stopped", let top = frames.first(where: { ($0["path"] as? String)?.isEmpty == false }),
           let path = top["path"] as? String, let line = top["line"] as? Int, line > 0 {
            debug.stopped = (path, line - 1)
            if FileManager.default.fileExists(atPath: path) {
                openFile(URL(fileURLWithPath: path))?.goTo(line: line - 1, col: max(0, (top["column"] as? Int ?? 1) - 1))
            }
        }
        allTabs.forEach { debugSync($0) }

        let frameNodes = frames.map { f -> DebugNode in
            let line = f["line"] as? Int ?? 0
            let source = f["source"] as? String ?? (f["path"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
            let node = DebugNode(.frame, title: f["name"] as? String ?? "frame",
                                 detail: source.isEmpty ? "" : "\(source):\(line)",
                                 id: Int64(f["id"] as? Int ?? -1), path: f["path"] as? String ?? "", line: max(0, line - 1))
            node.active = Int64(f["id"] as? Int ?? -1) == debug.frame
            return node
        }
        refreshDebugTree(variables: scopes, frames: frameNodes)

        switch state {
        case "stopped":
            let where_ = debug.stopped.map { "\(($0.path as NSString).lastPathComponent):\($0.line + 1)" } ?? ""
            let label = reason.isEmpty ? "paused" : reason
            debug.statusText = "⏸ \(label)\(where_.isEmpty ? "" : " · \(where_)")"
            root.debug.show(status["description"] as? String ?? "")
        case "running", "starting":
            debug.statusText = "⏵ debugging"
            root.debug.show("")
        case "terminated":
            let code = status["exitCode"] as? Int
            root.console.append("Program exited\(code.map { " with code \($0)" } ?? "").\n", category: "important")
            stopDebugging(nil)
            return
        default:
            debug.statusText = ""
        }
        refreshUI()
    }

    func refreshDebugTree(variables: [DebugNode]? = nil, frames: [DebugNode]? = nil) {
        var roots: [DebugNode] = []
        if debug.session != nil {
            roots.append(DebugNode(.group, title: "Variables", children: variables ?? []))
            roots.append(DebugNode(.group, title: "Call Stack", children: frames ?? []))
        }
        let bps = debug.breakpoints.flatMap { path, lines in
            lines.map { line in
                DebugNode(.breakpoint, title: (path as NSString).lastPathComponent, detail: "\(line + 1)",
                          path: path, line: line)
            }
        }.sorted { ($0.title, $0.line) < ($1.title, $1.line) }
        roots.append(DebugNode(.group, title: "Breakpoints", children: bps))
        root.debug.setTree(roots)
    }

    private func debugLoadChildren(_ node: DebugNode) {
        guard let session = debug.session, node.reference > 0 else { return }
        let gen = debug.generation, ref = node.reference
        debug.queue.async { [weak self, weak node] in
            let children = Self.variableNodes(session, reference: ref)
            DispatchQueue.main.async {
                guard let self, let node, self.debug.generation == gen else { return }
                node.children = children
                self.root.debug.reload(node)
            }
        }
    }

    private func debugSelectFrame(_ node: DebugNode) {
        guard let session = debug.session, node.id >= 0 else { return }
        debug.frame = node.id
        if !node.path.isEmpty, FileManager.default.fileExists(atPath: node.path) {
            openFile(URL(fileURLWithPath: node.path))?.goTo(line: max(0, node.line), col: 0)
        }
        let gen = debug.generation, id = node.id
        debug.queue.async { [weak self] in
            session.select_frame(id)
            let scopes = Self.scopeNodes(session, frame: id)
            DispatchQueue.main.async {
                guard let self, self.debug.generation == gen else { return }
                let frames = self.root.debug.roots.first(where: { $0.title == "Call Stack" })?.children ?? []
                frames.forEach { $0.active = $0.id == id }
                self.refreshDebugTree(variables: scopes, frames: frames)
            }
        }
    }

    private func debugResume(_ command: String) {
        guard let session = debug.session else { return }
        guard debug.state == "stopped" || command == "continue" else { return }
        debug.state = "running"
        root.debug.setState(state: "running", reason: "")
        allTabs.forEach { $0.view.stoppedLine = nil }
        debug.stopped = nil
        let gen = debug.generation
        debug.queue.async { [weak self] in
            let raw = session.resume(command).toString()
            guard let error = (jsonObject(raw) as? [String: Any])?["error"] as? String else { return }
            DispatchQueue.main.async {
                guard let self, self.debug.generation == gen else { return }
                self.root.console.append("\(error)\n", category: "stderr")
            }
        }
    }

    private func debugPause() {
        guard let session = debug.session else { return }
        debug.queue.async { _ = session.pause() }
    }

    private func debugEvaluate(_ expr: String) {
        guard let session = debug.session else {
            return root.console.append("No active debug session.\n", category: "stderr")
        }
        let frame = debug.frame, gen = debug.generation
        debug.queue.async { [weak self] in
            let obj = jsonObject(session.evaluate(expr, frame, "repl").toString()) as? [String: Any] ?? [:]
            let text = (obj["error"] as? String).map { "\($0)\n" } ?? "\(obj["result"] as? String ?? "")\n"
            let category = obj["error"] == nil ? "result" : "stderr"
            DispatchQueue.main.async {
                guard let self, self.debug.generation == gen else { return }
                self.root.console.append(text, category: category)
            }
        }
    }

    // alt panel

    func showDebugConsole() {
        root.consoleVisible = true
        root.terminalVisible = false
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
    }

    func hideDebugConsole() {
        root.consoleVisible = false
        root.needsLayout = true
        if let view = activeTab?.view { window?.makeFirstResponder(view) }
    }
}
