import AppKit

struct Diagnostic {
    var line: Int, col: Int, endLine: Int, endCol: Int
    var severity: Int  // 1 hata, 2 uyarı, 3 bilgi, 4 ipucu
    var message: String
    var source: String

    static func parse(_ v: Any?) -> [Diagnostic] {
        (v as? [[String: Any]] ?? []).compactMap { d in
            guard let r = d["range"] as? [String: Any], let s = r["start"] as? [String: Any], let e = r["end"] as? [String: Any] else { return nil }
            return Diagnostic(line: s["line"] as? Int ?? 0, col: s["character"] as? Int ?? 0,
                              endLine: e["line"] as? Int ?? 0, endCol: e["character"] as? Int ?? 0,
                              severity: d["severity"] as? Int ?? 1, message: d["message"] as? String ?? "",
                              source: d["source"] as? String ?? "")
        }
    }
}

struct Location {
    var url: URL
    var line: Int
    var col: Int

    static func parse(_ v: Any?) -> [Location] {
        (v as? [[String: Any]] ?? []).compactMap { l in
            guard let uri = l["uri"] as? String, let url = URL(string: uri), url.isFileURL,
                  let s = (l["range"] as? [String: Any])?["start"] as? [String: Any] else { return nil }
            return Location(url: url, line: s["line"] as? Int ?? 0, col: s["character"] as? Int ?? 0)
        }
    }
}

// pencere başına dil sunucuları; istekler arka planda, sonuç ana iş parçacığında
final class LanguageService {
    let lsp: KernLsp
    private let sync = DispatchQueue(label: "dev.kern.lsp.sync")
    private let work = DispatchQueue(label: "dev.kern.lsp.work", attributes: .concurrent)
    private var pending: [String: DispatchWorkItem] = [:]
    private var timer: Timer?
    private var lastVersion: UInt64 = 0
    var onDiagnostics: (() -> Void)?

    init(root: String) {
        lsp = KernLsp(root)
        configure()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
    }

    deinit {
        timer?.invalidate()
        let l = lsp
        DispatchQueue.global().async { l.shutdown() }
    }

    static var enabled: Bool { Settings.shared.values["lsp.enabled"] as? Bool ?? true }

    func configure() {
        for (key, cmd) in Extensions.shared.languageServers { lsp.configure(key, cmd) }
        for (key, cmd) in Settings.shared.values["lsp.servers"] as? [String: String] ?? [:] {
            lsp.configure(key, cmd)
        }
    }

    private func poll() {
        let v = lsp.diagnostics_version()
        guard v != lastVersion else { return }
        lastVersion = v
        onDiagnostics?()
    }

    func open(_ path: String, text: String) {
        guard Self.enabled else { return }
        sync.async { [lsp] in _ = lsp.open(path, text) }
    }

    // yazarken her tuşta değil, 250 ms durunca
    func changed(_ path: String, text: @escaping () -> String) {
        guard Self.enabled else { return }
        pending[path]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending[path] = nil
            let t = text()
            self.sync.async { [lsp = self.lsp] in _ = lsp.change(path, t) }
        }
        pending[path] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    // bekleyen değişikliği hemen gönder (istekten önce)
    func flush(_ path: String) {
        if let item = pending[path] {
            item.perform()
            item.cancel()
        }
    }

    func saved(_ path: String) { sync.async { [lsp] in lsp.save(path) } }
    func closed(_ path: String) {
        pending[path]?.cancel()
        pending[path] = nil
        sync.async { [lsp] in lsp.close(path) }
    }

    func diagnostics(_ path: String) -> [Diagnostic] {
        Diagnostic.parse(try? JSONSerialization.jsonObject(with: Data(lsp.diagnostics(path).toString().utf8)))
    }

    // tüm dosyalar: (yol, tanılar)
    func allDiagnostics() -> [(String, [Diagnostic])] {
        let obj = (try? JSONSerialization.jsonObject(with: Data(lsp.all_diagnostics().toString().utf8))) as? [String: Any] ?? [:]
        return obj.compactMap { uri, v in
            guard let url = URL(string: uri), url.isFileURL else { return nil }
            return (url.path, Diagnostic.parse(v))
        }.sorted { $0.0 < $1.0 }
    }

    func status(_ path: String) -> String { lsp.status(path).toString() }

    // istek: JSON sonucu ya da hata metni
    func request(_ path: String, _ call: @escaping (KernLsp) -> RustString, done: @escaping (Any?, String?) -> Void) {
        guard Self.enabled else { return done(nil, "Language servers are disabled") }
        flush(path)
        sync.async { [lsp, work] in
            work.async {
                let raw = call(lsp).toString()
                let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)
                let err = (obj as? [String: Any])?["error"] as? String
                DispatchQueue.main.async { done(err == nil ? obj : nil, err) }
            }
        }
    }
}

// markdown/plaintext hover içeriğini düz metne çevir
func hoverText(_ v: Any?) -> String {
    guard let v = v as? [String: Any], let contents = v["contents"] else { return "" }
    func text(_ c: Any) -> String {
        if let s = c as? String { return s }
        if let d = c as? [String: Any] { return d["value"] as? String ?? "" }
        if let a = c as? [Any] { return a.map(text).joined(separator: "\n\n") }
        return ""
    }
    return text(contents).split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.hasPrefix("```") }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// imleç çevresinde gösterilen küçük bilgi kutusu
final class HoverView: FlippedView {
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.widget
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        border = Palette.inputBorder
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = Palette.text
        label.maximumNumberOfLines = 18
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, at p: NSPoint, in parent: NSView) {
        label.stringValue = text
        let maxW: CGFloat = 520
        let size = label.sizeThatFits(NSSize(width: maxW, height: 400))
        let w = min(maxW, size.width) + 16, h = min(400, size.height) + 12
        var x = p.x, y = p.y - h - 4
        if y < 0 { y = p.y + 22 }
        x = min(max(4, x), parent.bounds.width - w - 4)
        frame = NSRect(x: x, y: y, width: w, height: h)
        label.frame = NSRect(x: 8, y: 6, width: w - 16, height: h - 12)
        if superview !== parent { parent.addSubview(self) }
    }

    func hide() { removeFromSuperview() }
}

struct CompletionItem {
    var label: String
    var detail: String
    var kind: Int
    var insertText: String
    var filterText: String
    var sortText: String
    var edit: (line: Int, col: Int, endLine: Int, endCol: Int)?
    var additional: Any?

    static func parse(_ v: Any?) -> [CompletionItem] {
        (v as? [[String: Any]] ?? []).map { d in
            let label = (d["label"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            var insert = d["insertText"] as? String ?? label
            var edit: (Int, Int, Int, Int)?
            if let te = d["textEdit"] as? [String: Any] {
                insert = te["newText"] as? String ?? insert
                let r = (te["range"] ?? te["replace"]) as? [String: Any]
                if let s = r?["start"] as? [String: Any], let e = r?["end"] as? [String: Any] {
                    edit = (s["line"] as? Int ?? 0, s["character"] as? Int ?? 0, e["line"] as? Int ?? 0, e["character"] as? Int ?? 0)
                }
            }
            if d["insertTextFormat"] as? Int == 2 { insert = stripSnippet(insert) }
            return CompletionItem(label: label, detail: d["detail"] as? String ?? "", kind: d["kind"] as? Int ?? 1,
                                  insertText: insert, filterText: d["filterText"] as? String ?? label,
                                  sortText: d["sortText"] as? String ?? label, edit: edit, additional: d["additionalTextEdits"])
        }
    }

    // ${1:ad} → ad, $0/$1 → boş
    static func stripSnippet(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
            if c == "$", i + 1 < chars.count {
                if chars[i + 1] == "{" {
                    var j = i + 2
                    while j < chars.count, chars[j].isNumber { j += 1 }
                    if j < chars.count, chars[j] == ":" { j += 1 }
                    var depth = 1, inner = ""
                    while j < chars.count {
                        if chars[j] == "{" { depth += 1 }
                        if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
                        inner.append(chars[j])
                        j += 1
                    }
                    out += stripSnippet(inner)
                    i = j + 1
                    continue
                }
                if chars[i + 1].isNumber {
                    var j = i + 1
                    while j < chars.count, chars[j].isNumber { j += 1 }
                    i = j
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }
}

// tamamlama listesi; seçim klavyeden EditorView üzerinden yönetilir
final class CompletionPopup: FlippedView {
    private(set) var items: [CompletionItem] = []
    private var all: [CompletionItem] = []
    private(set) var selected = 0
    private var top = 0
    private let maxRows = 10
    private let rowH: CGFloat = 22
    var onAccept: ((CompletionItem) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.widget
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        border = Palette.inputBorder
    }

    required init?(coder: NSCoder) { fatalError() }

    var isShown: Bool { superview != nil && !items.isEmpty }

    func setItems(_ list: [CompletionItem]) {
        all = list.sorted { $0.sortText < $1.sortText }
    }

    // önek ile süz (alt dizi eşleşmesi, önek eşleşmesi önde)
    func filter(_ prefix: String) {
        let p = prefix.lowercased()
        if p.isEmpty {
            items = all
        } else {
            let scored = all.compactMap { item -> (Int, CompletionItem)? in
                let t = item.filterText.lowercased()
                if t.hasPrefix(p) { return (0, item) }
                var it = p.makeIterator(), c = it.next()
                for ch in t where ch == c { c = it.next() }
                return c == nil ? (1, item) : nil
            }
            items = scored.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.sortText < $1.1.sortText }.map(\.1)
        }
        selected = 0
        top = 0
        let rows = min(maxRows, items.count)
        frame.size = NSSize(width: 440, height: CGFloat(rows) * rowH + 4)
        needsDisplay = true
    }

    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + d + items.count) % items.count
        if selected < top { top = selected }
        if selected >= top + maxRows { top = selected - maxRows + 1 }
        needsDisplay = true
    }

    func accept() {
        guard selected < items.count else { return }
        onAccept?(items[selected])
    }

    private static let kindLetters: [Int: String] = [2: "m", 3: "f", 4: "c", 5: "F", 6: "v", 7: "C", 8: "I", 9: "M", 10: "p",
                                                     13: "E", 14: "k", 15: "s", 21: "K", 22: "S", 25: "T"]

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for (row, i) in (top..<min(items.count, top + maxRows)).enumerated() {
            let item = items[i]
            let r = NSRect(x: 2, y: 2 + CGFloat(row) * rowH, width: bounds.width - 4, height: rowH)
            if i == selected {
                Palette.selection.setFill()
                NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            }
            let k = Self.kindLetters[item.kind] ?? "·"
            (k as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.minY + 3), withAttributes: [.font: font, .foregroundColor: Palette.match])
            (item.label as NSString).draw(in: NSRect(x: r.minX + 24, y: r.minY + 3, width: r.width * 0.6, height: rowH - 4),
                                          withAttributes: [.font: font, .foregroundColor: Palette.text])
            let d = item.detail as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.dimText]
            let dw = min(d.size(withAttributes: attrs).width, r.width * 0.38)
            d.draw(in: NSRect(x: r.maxX - dw - 8, y: r.minY + 4, width: dw, height: rowH - 4), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = top + Int((p.y - 2) / rowH)
        guard i >= 0, i < items.count else { return }
        selected = i
        accept()
    }
}
