import AppKit

// KERN_SELFTEST=<çıktı> ile açılır: geçici klasörde arayüz senaryolarını çalıştırır, sonucu yazar, çıkar
final class SelfTest {
    private let output: String
    private let makeWindow: (URL?) -> WorkbenchWindowController
    private var lines: [String] = []
    private var failures = 0
    private var steps: [(String, () -> Void)] = []
    private let dir: URL
    private var c: WorkbenchWindowController!
    private var wrapWas = false
    private var actionCount: Int?

    init(output: String, makeWindow: @escaping (URL?) -> WorkbenchWindowController) {
        self.output = output
        self.makeWindow = makeWindow
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kern-selftest-\(getpid())")
    }

    func check(_ name: String, _ ok: @autoclosure () -> Bool) {
        let pass = ok()
        if !pass { failures += 1 }
        lines.append("\(pass ? "PASS" : "FAIL") \(name)")
    }

    private func file(_ name: String) -> URL { dir.appendingPathComponent(name) }
    private func read(_ name: String) -> String { (try? String(contentsOf: file(name), encoding: .utf8)) ?? "<yok>" }
    private func step(_ name: String, _ f: @escaping () -> Void) { steps.append((name, f)) }

    // koşul sağlanana (ya da süre dolana) kadar adımı yeniden kuyruğa koyar; ana kuyruk bloklanmaz
    private func wait(_ name: String, timeout: TimeInterval = 10, _ cond: @escaping () -> Bool) {
        var deadline: Date?
        var poll: (() -> Void)!
        poll = {
            let d = deadline ?? Date().addingTimeInterval(timeout)
            deadline = d
            if cond() || Date() >= d { self.check(name, cond()) } else { self.steps.insert(("bekle: \(name)", poll), at: 0) }
        }
        step("bekle: \(name)", poll)
    }

    func start() {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "hello\nworld\n".write(to: file("a.txt"), atomically: true, encoding: .utf8)
        try? "fn main() {}\n".write(to: file("b.rs"), atomically: true, encoding: .utf8)
        try? SessionStore.file(for: dir).path.withCString { unlink($0) }
        c = makeWindow(dir)
        scenarios()
        next()
    }

    private func next() {
        guard !steps.isEmpty else { return finish() }
        let (name, f) = steps.removeFirst()
        if lines.last != "# \(name)" { lines.append("# \(name)") }
        f()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.next() }
    }

    private func finish() {
        lines.append(failures == 0 ? "OK" : "FAILED \(failures)")
        try? lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: dir)
        exit(failures == 0 ? 0 : 1)
    }

    private var view: EditorView? { c.activeTab?.view }

    private func scenarios() {
        step("kaydetme") {
            self.c.openFile(self.file("a.txt"))
            self.view?.goTo(line: 0, col: 5)
            self.view?.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
            self.check("sekme kirli", self.c.activeTab?.editor.is_dirty() == true)
            NSApp.sendAction(#selector(WorkbenchWindowController.saveDocument(_:)), to: self.c, from: nil)
            self.check("diske yazıldı", self.read("a.txt") == "hello!\nworld\n")
            self.check("temiz", self.c.activeTab?.editor.is_dirty() == false)
        }
        step("bölme") {
            NSApp.sendAction(#selector(WorkbenchWindowController.splitEditor(_:)), to: self.c, from: nil)
            self.check("iki grup", self.c.groups.count == 2)
            self.check("sağ grup odakta", self.c.focused == 1)
            self.view?.goTo(line: 1, col: 0)
            self.view?.insertText(">", replacementRange: NSRange(location: NSNotFound, length: 0))
            let left = self.c.groups[0].activeTab?.editor
            self.check("sol görünüm aynı metni görüyor", left?.line(1).toString() == ">world")
            self.check("sol imleç yerinde", left?.cursor_line() == 0 && left?.cursor_col() == 6)
            self.check("sağ imleç", self.view?.editor.cursor_line() == 1 && self.view?.editor.cursor_col() == 1)
        }
        step("bölmeyi kapat") {
            NSApp.sendAction(#selector(WorkbenchWindowController.saveDocument(_:)), to: self.c, from: nil)
            NSApp.sendAction(#selector(WorkbenchWindowController.closeEditor(_:)), to: self.c, from: nil)
            self.check("tek grup", self.c.groups.count == 1)
            self.check("sol sekme temiz", self.c.activeTab?.editor.is_dirty() == false)
        }
        step("dışarıdan değişiklik") {
            Thread.sleep(forTimeInterval: 0.05)
            try? "external\n".write(to: self.file("a.txt"), atomically: true, encoding: .utf8)
        }
        step("yeniden yükleme") {
            self.c.checkDisk()
            self.check("yeniden yüklendi", self.c.activeTab?.editor.line(0).toString() == "external")
            self.check("temiz kaldı", self.c.activeTab?.editor.is_dirty() == false)
        }
        step("katlama") {
            let long = String(repeating: "word ", count: 80)
            try? "def f():\n    a = 1\n    b = 2\nx = 1\n\(long)\n".write(to: self.file("c.py"), atomically: true, encoding: .utf8)
            self.c.openFile(self.file("c.py"))
            guard let v = self.view else { return self.check("c.py açıldı", false) }
            v.goTo(line: 0, col: 0)
            v.rebuildMapIfNeeded()
            let rows = v.totalRows
            v.fold()
            v.rebuildMapIfNeeded()
            self.check("katlanınca 2 satır gizlendi", v.totalRows == rows - 2)
            v.doCommand(by: #selector(NSResponder.moveDown(_:)))
            self.check("aşağı ok katlamayı atlar", v.editor.cursor_line() == 3)
            self.check("katlama açık kalmadı", v.folds[0] != nil)
            v.unfoldAll()
            v.rebuildMapIfNeeded()
            self.check("açınca satır sayısı döner", v.totalRows == rows)
        }
        step("sarma") {
            guard let v = self.view else { return }
            self.wrapWas = EditorView.wordWrap
            EditorView.setWordWrap(true)
            v.rebuildMapIfNeeded()
            self.check("uzun satır sarıldı", v.totalRows > Int(v.editor.line_count()))
            v.goTo(line: 4, col: 0)
            v.doCommand(by: #selector(NSResponder.moveDown(_:)))
            self.check("aşağı ok aynı satırın sonraki parçasına", v.editor.cursor_line() == 4 && v.editor.cursor_col() > 0)
            EditorView.setWordWrap(false)
            v.rebuildMapIfNeeded()
            self.check("sarma kapanınca satır = görüntü satırı", v.totalRows == Int(v.editor.line_count()))
            EditorView.setWordWrap(self.wrapWas)
        }
        step("ayarlar") {
            let s = Settings.shared
            self.check("JSONC ayrıştırma", Settings.parse(Data("// yorum\n{ \"a\": 1, /* x */ \"b\": \"//\", }".utf8))?["b"] as? String == "//")
            s.set("editor.tabSize", 2)
            s.set("editor.detectIndentation", false)
            self.c.newUntitled()
            guard let v = self.view else { return self.check("yeni sekme", false) }
            v.doCommand(by: #selector(NSResponder.insertTab(_:)))
            self.check("tabSize 2 uygulandı", v.editor.line(0).toString() == "  ")
            s.set("workbench.colorTheme", "light")
            self.check("açık tema", self.c.window?.appearance?.name == .aqua)
            self.check("editör açık renk", Theme.for(v.effectiveAppearance).background == Theme.light.background)
            s.set("workbench.colorTheme", "dark")
            self.check("koyu tema", self.c.window?.appearance?.name == .darkAqua)
            try? "[ { \"key\": \"cmd+shift+d\", \"command\": \"copyLineDown\" } ]".write(to: Settings.keymapFile, atomically: true, encoding: .utf8)
            s.reload()
            let item = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }.first { $0.action == NSSelectorFromString("copyLineDown:") }
            self.check("keymap uygulandı", item?.keyEquivalent == "d" && item?.keyEquivalentModifierMask == [.command, .shift])
            s.set("files.trimTrailingWhitespace", true)
            v.insertText("x  ", replacementRange: NSRange(location: NSNotFound, length: 0))
            v.editor.prepare_save(true, false)
            self.check("sondaki boşluk silindi", v.editor.line(0).toString() == "  x")
            _ = v.editor.undo()
            _ = v.editor.undo()
        }
        step("arama") {
            try? "İstanbul istanbul\nfoo_bar foo\n".write(to: self.file("d.txt"), atomically: true, encoding: .utf8)
            self.c.openFile(self.file("d.txt"))
            guard let e = self.view?.editor else { return self.check("d.txt", false) }
            self.check("Türkçe büyük/küçük harf", Array(e.find_status("istanbul", 0)).first == 2)
            self.check("tam kelime", Array(e.find_status("foo", 2)).first == 1)
            self.check("regex", Array(e.find_status("fo+_\\w+", 4)).first == 1)
            self.check("geçersiz regex hatası", !find_error("(", 4).toString().isEmpty)
            let ws = KernWorkspace(self.dir.path)
            guard let job = ws.start_search("istanbul", 0, 100) else { return self.check("proje araması başladı", false) }
            var raw = ""
            let deadline = Date().addingTimeInterval(5)
            while !job.is_done() && Date() < deadline { raw += job.poll().toString(); usleep(2000) }
            raw += job.poll().toString()
            self.check("proje araması akışı", raw.split(separator: "\n").count == 2 && raw.contains("d.txt\t0\t"))
        }
        step("terminal") {
            NSApp.sendAction(#selector(WorkbenchWindowController.toggleTerminal(_:)), to: self.c, from: nil)
            self.check("terminal açıldı", self.c.root.terminal.terminal != nil)
            NSApp.sendAction(#selector(WorkbenchWindowController.splitTerminal(_:)), to: self.c, from: nil)
            self.check("terminal bölündü", self.c.root.terminal.groups.first?.count == 2)
            self.c.root.terminal.kill()
            self.check("bölme kapandı", self.c.root.terminal.groups.first?.count == 1)
            self.c.root.terminal.terminal?.terminal?.write_text("cd \(self.dir.path) && echo \(self.dir.path)/b.rs:1\r")
        }
        wait("OSC 7 çalışma dizini") { self.c.root.terminal.terminal?.currentDirectory.hasSuffix(self.dir.lastPathComponent) == true }
        wait("komut işareti") { (self.c.root.terminal.terminal?.terminal?.marks().len() ?? 0) > 0 }
        step("tıklanabilir yol") {
            guard let tv = self.c.root.terminal.terminal, let t = tv.terminal else { return self.check("terminal", false) }
            var opened = false
            for row in 0..<60 {
                let text = t.row_text(UInt(row)).toString()
                if text.hasPrefix("/"), text.hasSuffix("b.rs:1"), t.logical_offset(UInt(row)) == 0 { opened = tv.openLink(row: row, col: 3); break }
            }
            self.check("yol açıldı", opened && self.c.activeTab?.path.hasSuffix("b.rs") == true)
            let wrapped = (0..<60).first { t.logical_offset(UInt($0)) > 0 }
            self.check("sarılmış satır birleşti", wrapped.map { t.logical_line(UInt($0)).toString().contains("&& echo") } ?? true)
            if !opened { for row in 0..<8 { self.lines.append("  satır \(row): " + t.row_text(UInt(row)).toString()) } }
        }
        step("kern CLI URL") {
            let n = self.c.window?.windowNumber ?? 0
            let enc = self.file("c.py").path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            NSApp.delegate?.application?(NSApp, open: [URL(string: "kern://open?path=\(enc)&line=2&col=5&window=\(n)")!])
            self.check("CLI dosyayı pencerede açtı", self.c.activeTab?.path.hasSuffix("c.py") == true)
            self.check("CLI satır/sütun", self.c.activeTab?.editor.cursor_line() == 1 && self.c.activeTab?.editor.cursor_col() == 4)
        }
        step("lsp aç") {
            // son fonksiyon çok satırlı: clangd katlama aralığı ancak böyle döner
            let src = "int square(int x) { return x * x; }\nint main(void) { return undefined_name; }\n\n\nint helper(int a) {\n  int b = a + 1;\n  return b;\n}\n"
            try? src.write(to: self.file("e.c"), atomically: true, encoding: .utf8)
            self.c.openFile(self.file("e.c"))
        }
        wait("LSP tanıları", timeout: 20) { self.view?.diagnostics.contains { $0.message.contains("undefined_name") } == true }
        step("tamamlama yaz") {
            guard let v = self.view else { return }
            v.goTo(line: 2, col: 0)
            for ch in "int z = squ" { v.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
        wait("tamamlama listesi", timeout: 15) { self.c.completion.isShown && self.c.completion.items.contains { $0.label.contains("square") } }
        step("tamamlamayı kabul") {
            guard let v = self.view else { return }
            v.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            self.check("tamamlama eklendi", v.editor.line(2).toString().hasPrefix("int z = square"))
            self.check("liste kapandı", !self.c.completion.isShown)
            let l2 = v.editor.line(2).toString() as NSString
            v.goTo(line: 2, col: l2.length)
            v.editor.select_range(2, 8, UInt(l2.length - 8))
            v.insertText("square(2);", replacementRange: NSRange(location: NSNotFound, length: 0))
            self.c.hideCompletion()
            NSApp.sendAction(#selector(WorkbenchWindowController.saveDocument(_:)), to: self.c, from: nil)
            v.goTo(line: 2, col: 10)
            NSApp.sendAction(#selector(WorkbenchWindowController.goToDefinition(_:)), to: self.c, from: nil)
        }
        wait("tanıma git", timeout: 10) { self.view?.editor.cursor_line() == 0 }
        step("yeniden adlandır") {
            guard let lang = self.c.language, let path = self.c.activeTab?.path else { return self.check("lsp", false) }
            lang.request(path, { $0.rename(path, 0, 5, "area") }) { obj, err in
                if let err { self.lines.append("  rename hatası: \(err)") }
                self.c.applyWorkspaceEdit(obj, error: err)
            }
        }
        wait("yeniden adlandırıldı", timeout: 10) {
            self.view?.editor.line(0).toString().hasPrefix("int area(") == true && self.view?.editor.line(2).toString().contains("area") == true
        }
        step("biçimlendir") {
            guard let v = self.view else { return }
            v.goTo(line: 3, col: 0)
            v.insertText("int   w=1;", replacementRange: NSRange(location: NSNotFound, length: 0))
            NSApp.sendAction(#selector(WorkbenchWindowController.formatDocument(_:)), to: self.c, from: nil)
        }
        wait("biçimlendirildi", timeout: 10) { self.view?.editor.line(3).toString() == "int w = 1;" }
        step("anlamsal renk / katlama / ipucu iste") {
            guard let t = self.c.activeTab else { return self.check("sekme", false) }
            self.c.refreshLanguageExtras(t, delay: 0)
        }
        wait("anlamsal renkler", timeout: 15) { self.view?.semanticSpans.isEmpty == false }
        wait("LSP katlama aralıkları", timeout: 10) { self.view?.lspFolds.isEmpty == false }
        step("imza yardımı") {
            guard let v = self.view else { return }
            let line = v.editor.line(2).toString() as NSString
            let p = line.range(of: "(").location
            self.check("çağrı bulundu", p != NSNotFound)
            v.goTo(line: 2, col: p == NSNotFound ? 0 : p + 1)
            self.c.showSignature(v)
        }
        wait("imza kutusu açıldı", timeout: 10) { self.c.signature.superview != nil }
        step("düzeltme eylemleri") {
            guard let lang = self.c.language, let path = self.c.activeTab?.path else { return self.check("lsp", false) }
            self.actionCount = nil
            lang.request(path, { $0.code_actions(path, 1, 0, 1, 5) }) { obj, err in
                if let err { self.lines.append("  code action hatası: \(err)") }
                self.actionCount = (obj as? [Any])?.count ?? -1
            }
        }
        wait("düzeltme eylemi isteği", timeout: 10) { (self.actionCount ?? -1) >= 0 }
        step("proje sembolü ara") {
            self.c.signature.hide()
            NSApp.sendAction(#selector(WorkbenchWindowController.goToWorkspaceSymbol(_:)), to: self.c, from: nil)
            self.c.paletteView?.present(text: "#area")
        }
        wait("proje sembolü bulundu", timeout: 15) {
            self.c.paletteView?.items.contains { $0.title.contains("area") } == true
        }
        step("paleti kapat") { self.c.paletteView?.dismiss() }
        step("lsp temizle") {
            while self.view?.editor.is_dirty() == true, self.view?.editor.undo() == true {}
            self.c.hideCompletion()
            NSApp.sendAction(#selector(WorkbenchWindowController.saveDocument(_:)), to: self.c, from: nil)
        }
        // yeni editör/çalışma alanı özellikleri
        step("otomatik parantez") {
            Settings.shared.set("editor.autoClosingBrackets", true)
            Settings.shared.set("editor.autoSurround", true)
            try? "".write(to: self.file("pairs.txt"), atomically: true, encoding: .utf8)
            self.c.openFile(self.file("pairs.txt"))
            guard let v = self.view else { return self.check("sekme", false) }
            v.goTo(line: 0, col: 0)
            v.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
            self.check("çift kapandı", v.editor.line(0).toString().hasPrefix("()"))
            self.check("imleç içeride", v.editor.cursor_col() == 1)
            v.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
            self.check("kapanışın üstüne yazıldı", v.editor.line(0).toString().hasPrefix("()") && v.editor.cursor_col() == 2)
            v.insertText("ab", replacementRange: NSRange(location: NSNotFound, length: 0))
            v.editor.select_range(0, 2, 2)
            v.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))
            self.check("seçim sarıldı", v.editor.line(0).toString() == "()\"ab\"")
        }
        step("sütun seçimi") {
            guard let v = self.view else { return self.check("sekme", false) }
            v.editor.select_all()
            v.insertText("abcd\nefgh\nij", replacementRange: NSRange(location: NSNotFound, length: 0))
            v.editor.select_box(0, 1, 2, 3)
            self.check("üç seçim", v.editor.selections().count == 12)
            v.insertText("-", replacementRange: NSRange(location: NSNotFound, length: 0))
            self.check("kutu değişti", v.editor.text().toString() == "a-d\ne-h\ni-")
        }
        step(".editorconfig") {
            let (cfg, isRoot) = EditorConfig.parse("root = true\n[*.py]\nindent_style = space\nindent_size = 2\n", name: "a.py")
            self.check("root okundu", isRoot)
            self.check("girinti", cfg.indentSize == 2 && cfg.useSpaces == true)
            let (other, _) = EditorConfig.parse("[*.js]\nindent_size = 8\n", name: "a.py")
            self.check("eşleşmeyen bölüm atlandı", other.isEmpty)
        }
        step("görevler") {
            let dir = self.dir.appendingPathComponent(".kern")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "{ \"tasks\": [ { \"label\": \"build\", \"command\": \"echo\", \"args\": [\"hi\"] } ] }"
                .write(to: dir.appendingPathComponent("tasks.json"), atomically: true, encoding: .utf8)
            let runner = TaskRunner()
            runner.reload(self.dir)
            self.check("görev okundu", runner.tasks.count == 1 && runner.task(named: "build")?.command == "echo hi")
        }
        step("markdown önizleme") {
            let text = MarkdownPreviewController.render("# Başlık\n\n**kalın** ve `kod`\n").string
            self.check("başlık", text.hasPrefix("Başlık"))
            self.check("satır içi biçim", text.contains("kalın ve kod"))
        }
        step("AI (sahte akış)") {
            func sse(_ events: [[String: Any]]) -> [String] {
                events.map { "data: " + String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            }
            let toolTurn = sse([
                ["type": "message_start", "message": [:]],
                ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]],
                ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "plan"]],
                ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "SIG"]],
                ["type": "content_block_stop", "index": 0],
                ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "t1", "name": "read_file", "input": [:]]],
                ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"path\": \"a"]],
                ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": ".txt\"}"]],
                ["type": "content_block_stop", "index": 1],
                ["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "id": "t2", "name": "write_file", "input": [:]]],
                ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "{\"path\": \"x.txt\", \"content\": \"no\"}"]],
                ["type": "content_block_stop", "index": 2],
                ["type": "message_delta", "delta": ["stop_reason": "tool_use"]],
            ])
            let finalTurn = sse([
                ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
                ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hel"]],
                ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "lo"]],
                ["type": "content_block_stop", "index": 0],
                ["type": "message_delta", "delta": ["stop_reason": "end_turn"]],
            ])
            var turns = [toolTurn, finalTurn]
            var requests: [URLRequest] = []
            let client = AIClient()
            client.keyProvider = { "test-key" }
            client.transport = { req in
                requests.append(req)
                let lines = turns.isEmpty ? finalTurn : turns.removeFirst()
                return AsyncThrowingStream { c in lines.forEach { c.yield($0) }; c.finish() }
            }
            let agent = AIAgent(client: client, root: self.dir)
            agent.approve = { _, _ in false }
            let done = DispatchSemaphore(value: 0)
            var reply = ""
            Task.detached { reply = (try? await agent.run("read a.txt")) ?? "error"; done.signal() }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            self.check("ajan yanıtı", reply == "Hello")
            self.check("ajan geçmişi 4 mesaj", agent.messages.count == 4)
            let results = agent.messages.count > 2 ? agent.messages[2]["content"] as? [[String: Any]] ?? [] : []
            self.check("read_file sonucu", (results.first?["content"] as? String)?.contains("external") == true)
            self.check("reddedilen yazma hata döndü", results.count == 2 && results[1]["is_error"] as? Bool == true && !FileManager.default.fileExists(atPath: self.file("x.txt").path))
            let thinking = (agent.messages[1]["content"] as? [[String: Any]])?.first
            self.check("düşünme bloğu imzayla korundu", thinking?["signature"] as? String == "SIG")
            let first = requests.first.flatMap { $0.httpBody }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            self.check("ajan isteği: model/stream/fallback", first?["model"] as? String == "claude-opus-5" && first?["stream"] as? Bool == true
                       && first?["fallbacks"] as? String == "default" && requests.first?.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01"
                       && requests.first?.value(forHTTPHeaderField: "x-api-key") == "test-key")
            self.check("proje dışı yol reddi", agent.resolve("../../etc/passwd") == nil && agent.resolve("a.txt") != nil)
            self.check("kod bloğu ayıklama", ChatPanel.lastCodeBlock("x\n```swift\nlet a = 1\n```\n") == "let a = 1")
            // sohbet paneli
            let panel = self.c.root.ai
            panel.client.keyProvider = { "test-key" }
            panel.client.transport = { _ in AsyncThrowingStream { c in finalTurn.forEach { c.yield($0) }; c.finish() } }
            panel.isAgent = false
            panel.send("hi")
        }
        wait("sohbet yanıtı") { !self.c.root.ai.busy && self.c.root.ai.lastReply == "Hello" }
        step("hayalet metin") {
            guard let v = self.view else { return }
            v.editor.move_cursor(.LineEnd, false)
            let before = v.editor.line(v.editor.cursor_line()).toString()
            v.ghostText = "XYZ"
            v.doCommand(by: #selector(NSResponder.insertTab(_:)))
            self.check("Tab öneriyi kabul etti", v.editor.line(v.editor.cursor_line()).toString() == before + "XYZ" && v.ghostText == nil)
            _ = v.editor.undo()
            v.changed(edited: true)
        }
        step("eklentiler") {
            let ext = Extensions.shared
            self.check("paket içi eklentiler yüklendi", ext.installed.count >= 3 && ext.errors.isEmpty)
            let item = NSApp.mainMenu?.items.first { $0.title == "Extensions" }?.submenu?.items.first { $0.title == "Transform to Uppercase" }
            self.check("eklenti menüsü ve kısayolu", item?.keyEquivalent == "u" && item?.keyEquivalentModifierMask == [.command, .option])
            self.c.openFile(self.file("a.txt"))
            guard let v = self.view else { return }
            v.editor.select_all()
            let out = self.c.runExtension("kern.text-tools", "upper")
            self.check("wasm komutu seçimi dönüştürdü", v.editor.line(0).toString() == "EXTERNAL" && out["error"] == nil)
            _ = v.editor.undo()
            v.changed(edited: true)
            Settings.shared.set("workbench.colorTheme", "Solarized Dark")
            self.check("eklenti teması", Theme.for(v.effectiveAppearance).background == Theme.custom(ext.theme(named: "Solarized Dark")!).background
                       && Theme.for(v.effectiveAppearance).background != Theme.dark.background && self.c.window?.appearance?.name == .darkAqua)
            Settings.shared.set("workbench.colorTheme", "dark")
            self.c.openFile(self.file("b.rs"))
            if let rv = self.view { self.check("Rust snippet'leri", self.c.snippetItems(rv).contains { $0.label == "fnmain" }) }
            // kur / kaldır
            let src = self.dir.appendingPathComponent("my-ext")
            try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try? #"{"id":"test.mine","name":"Mine","version":"0.1.0","contributes":{"snippets":{"Rust":[{"prefix":"zz","body":"zz!"}]}}}"#
                .write(to: src.appendingPathComponent("kern-extension.json"), atomically: true, encoding: .utf8)
            self.check("kurulum öncesi doğrulama", ext.inspect(src)["id"] as? String == "test.mine")
            try? ext.install(src, id: "test.mine")
            let mine = ext.installed.first { $0["id"] as? String == "test.mine" }
            self.check("eklenti kuruldu", mine != nil)
            if let mine { try? ext.uninstall(mine) }
            self.check("eklenti kaldırıldı", !ext.installed.contains { $0["id"] as? String == "test.mine" })
        }
        step("oturum") {
            self.c.openFile(self.file("b.rs"))
            self.c.saveSession()
            let s = SessionStore.load(self.dir)
            self.check("oturum altı sekme", s?.tabs.count == 6)
            self.check("etkin sekme b.rs", s.map { $0.tabs[$0.active].path.hasSuffix("b.rs") } ?? false)
        }
        accessibilityScenarios()
        gitScenarios()
        debugScenarios()
    }

    // erişilebilirlik ve IME (işaretli metin)
    private func accessibilityScenarios() {
        step("erişilebilirlik") {
            self.c.openFile(self.file("a.txt"))
            guard let v = self.view else { return self.check("a.txt açıldı", false) }
            v.editor.select_all()
            v.editor.insert_text("bir\niki\nüç\n")
            v.changed(edited: true)
            v.goTo(line: 1, col: 1, length: 2)
            self.check("rol metin alanı", v.accessibilityRole() == .textArea && v.isAccessibilityElement())
            self.check("ad dosya adı", v.accessibilityLabel() == "a.txt")
            self.check("değer tüm metin", v.accessibilityValue() as? String == "bir\niki\nüç\n")
            self.check("karakter sayısı", v.accessibilityNumberOfCharacters() == 11)
            self.check("seçim aralığı", v.accessibilitySelectedTextRange() == NSRange(location: 5, length: 2))
            self.check("seçili metin", v.accessibilitySelectedText() == "ki")
            self.check("satır aralığı", v.accessibilityRange(forLine: 2) == NSRange(location: 8, length: 3))
            self.check("konumdan satır", v.accessibilityLine(for: 9) == 2)
            self.check("aralıktan metin", v.accessibilityString(for: NSRange(location: 0, length: 3)) == "bir")
            v.setAccessibilitySelectedTextRange(NSRange(location: 8, length: 2))
            self.check("VoiceOver seçim yaptı", v.editor.cursor_line() == 2 && v.editor.selected_text().toString() == "üç")
        }
        step("arayüz etiketleri") {
            let bar = self.c.root.status
            self.check("durum çubuğu okunuyor", bar.accessibilityRole() == .staticText
                && (bar.accessibilityValue() as? String)?.contains("Ln ") == true)
            let tabs = self.c.groups[0].view.tabBar
            let children = tabs.accessibilityChildren() as? [TabElement] ?? []
            self.check("sekmeler öğe", tabs.accessibilityRole() == .tabGroup && children.count == self.c.tabs.count)
            self.check("sekme adı", children.first?.accessibilityLabel()?.hasPrefix("a.txt") == true)
            let crumbs = self.c.groups[0].view.breadcrumbs
            self.check("breadcrumb okunuyor", (crumbs.accessibilityValue() as? String)?.hasSuffix("a.txt") == true)
            let button = self.c.root.activity.subviews.compactMap { $0 as? NSButton }.first
            self.check("aktivite düğmesi etiketli", button?.accessibilityLabel()?.hasPrefix("Explorer") == true)
        }
        step("IME işaretli metin") {
            guard let v = self.view else { return self.check("editör", false) }
            v.editor.select_all()
            v.editor.insert_text("")
            v.changed(edited: true)
            v.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            self.check("işaretli metin var", v.hasMarkedText() && v.markedRange().length == 2)
            self.check("tampona yazılmadı", v.editor.text().toString() == "")
            v.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
            self.check("dönüştürme yazıldı", v.editor.text().toString() == "日本" && !v.hasMarkedText())
            v.setMarkedText("ç", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            v.unmarkText()
            self.check("işaret kaldırılınca eklendi", v.editor.text().toString() == "日本ç" && !v.hasMarkedText())
            self.check("imleç UTF-16 sonunda", v.selectedRange().location == 3)
        }
    }

    @discardableResult
    private func git(_ args: String...) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func gitScenarios() {
        let scm = { self.c.root.scm }
        step("git kurulumu") {
            let g = parseGitStatus("M \ta\n M\tb\nMM\tc\n??\td\nUU\te\n")
            self.check("durum ayrıştırma", g.map(\.kind) == [.merge, .staged, .changes] && g.map(\.files.count) == [1, 2, 3])
            try? "one\ntwo\nthree\n".write(to: self.file("g.txt"), atomically: true, encoding: .utf8)
            self.git("init", "-q", "-b", "main")
            self.git("config", "user.email", "t@example.com")
            self.git("config", "user.name", "Tester")
            self.git("add", "-A")
            self.git("commit", "-q", "-m", "first")
            self.c.gitOpen(self.dir)
        }
        wait("depo bulundu, temiz") { self.c.git.repo != nil && scm().hasRepo && scm().groups.isEmpty && self.c.git.branch == "main" }
        step("gutter") {
            self.c.openFile(self.file("g.txt"))
            guard let v = self.view else { return self.check("g.txt", false) }
            v.editor.select_range(1, 0, 3)
            v.editor.insert_text("TWO")
            v.changed(edited: true)
        }
        wait("gutter M işareti") { self.view?.gitMarks == [1: "M"] }
        wait("blame durum çubuğunda") { self.c.git.blame == "✎ Uncommitted changes" && self.c.root.status.left.contains(self.c.git.blame) }
        step("kaydet") { self.c.saveDocument(nil) }
        wait("değişiklik listelendi") { scm().groups.first { $0.kind == .changes }?.files.map(\.path) == ["g.txt"] }
        step("commit") {
            scm().message.field.stringValue = "second"
            scm().onCommit?("second")
        }
        wait("commit edildi") { scm().groups.isEmpty && self.git("log", "--oneline").split(separator: "\n").count == 2 }
        wait("commit sonrası gutter temiz") { self.view?.gitMarks.isEmpty == true }
        step("dal") { self.c.gitRun { $0.checkout("feature", true) } }
        wait("dal değişti") { self.c.git.branch == "feature" && self.c.root.status.left.contains("⎇ feature") }
        step("çakışma") {
            guard let v = self.view, let tab = self.c.activeTab else { return self.check("g.txt", false) }
            v.editor.select_all()
            v.editor.insert_text("a\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> b\nz\n")
            v.changed(edited: true)
            self.c.gitMarks(tab)
            self.check("çakışma satırları", v.conflictLines == [1: 0, 2: 1, 3: 0, 4: 2, 5: 0])
            v.editor.click(2, 0, false)
            self.c.acceptBothChanges(nil)
            self.check("iki taraf kabul", v.editor.text().toString() == "a\nmine\ntheirs\nz\n")
            _ = v.editor.undo()
            v.editor.click(4, 0, false)
            self.c.acceptIncomingChange(nil)
            self.check("gelen kabul", v.editor.text().toString() == "a\ntheirs\nz\n")
            self.c.gitMarks(tab)
            self.check("çakışma vurgusu kalktı", v.conflictLines.isEmpty)
        }
    }

    // hata ayıklama: kesme noktaları, launch.json, canlı lldb-dap oturumu
    private func debugScenarios() {
        let panel = { self.c.root.debug }
        // kaynak senaryo kurulurken yazılır: canlı oturum kararı derlemeye bakar
        let source = "#include <stdio.h>\nint main(void) {\n  int total = 0;\n  for (int i = 1; i <= 3; i++) total += i;\n  printf(\"total=%d\\n\", total);\n  return 0;\n}\n"
        try? source.write(to: file("d.c"), atomically: true, encoding: .utf8)
        step("kesme noktası") {
            self.c.openFile(self.file("d.c"))
            guard let v = self.view else { return self.check("d.c açıldı", false) }
            v.goTo(line: 4, col: 0)
            self.c.toggleBreakpoint(nil)
            self.check("gutter işareti", v.breakpointLines == [4])
            self.check("durumda tutuldu", self.c.debug.breakpoints[self.file("d.c").path] == [4])
            let bps = panel().roots.first { $0.title == "Breakpoints" }?.children ?? []
            self.check("panelde listelendi", bps.count == 1 && bps[0].detail == "5")
            self.c.toggleBreakpoint(nil)
            self.check("kaldırıldı", v.breakpointLines.isEmpty && self.c.debug.breakpoints.isEmpty)
            v.onToggleBreakpoint?(4)
            self.check("gutter tıklaması ekledi", v.breakpointLines == [4])
        }
        step("launch.json") {
            self.c.openLaunchJSON(nil)
            self.check("dosya yazıldı", self.read(".kern/launch.json").contains("configurations"))
            self.c.refreshConfigs()
            self.check("konfigürasyon okundu", self.c.debug.configs.count == 1)
            self.check("desteklenmeyen tür", debug_adapter_status("ruby").toString().hasPrefix("unsupported"))
            self.c.toggleDebugConsole(nil)
            self.check("konsol göründü", self.c.root.consoleVisible && !self.c.root.console.isHidden)
            self.c.root.console.onEvaluate?("1 + 1")
            self.check("oturumsuz değerlendirme", self.c.root.console.contents.contains("No active debug session"))
        }
        guard debug_adapter_status("lldb").toString() == "ok", compile("d.c", "d") else {
            lines.append("# lldb-dap veya clang yok: canlı oturum atlandı")
            return
        }
        step("oturumu başlat") {
            let config: [String: Any] = ["version": "0.2.0", "configurations": [
                ["name": "d", "type": "lldb", "request": "launch", "program": self.file("d").path, "cwd": self.dir.path]]]
            try? JSONSerialization.data(withJSONObject: config).write(to: self.file(".kern/launch.json"))
            self.c.refreshConfigs()
            self.c.startDebugging(nil)
        }
        wait("kesme noktasında durdu", timeout: 40) { self.c.debug.state == "stopped" }
        step("durma durumu") {
            self.check("duran satır işaretlendi", self.view?.stoppedLine == 4)
            self.check("durum çubuğu", self.c.debug.statusText.hasPrefix("⏸") && self.c.root.status.left.contains(self.c.debug.statusText))
            let frames = panel().roots.first { $0.title == "Call Stack" }?.children ?? []
            self.check("çağrı yığını", frames.first?.title == "main" && frames.first?.detail == "d.c:5")
            let scopes = panel().roots.first { $0.title == "Variables" }?.children ?? []
            let locals = scopes.first?.children ?? []
            self.check("yerel değişkenler", locals.contains { $0.title == "total" && $0.detail == "6" })
        }
        step("ifade değerlendir") { self.c.root.console.onEvaluate?("total * 2") }
        wait("sonuç konsolda") { self.c.root.console.contents.contains("12") }
        step("devam et") { self.c.debugContinue(nil) }
        wait("oturum bitti", timeout: 40) { self.c.debug.session == nil }
        step("bitiş") {
            self.check("program çıktısı", self.c.root.console.contents.contains("total=6"))
            self.check("duran satır temizlendi", self.view?.stoppedLine == nil)
            self.check("durum çubuğu temiz", self.c.debug.statusText.isEmpty)
        }
    }

    // clang ile örnek programı derler
    private func compile(_ source: String, _ output: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        p.arguments = ["-g", "-O0", file(source).path, "-o", file(output).path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
