import AppKit

// AI paneli: sohbet (Sonnet 5) ve ajan (Opus 5); yanıtlar akışla gelir
final class ChatPanel: FlippedView, NSTextFieldDelegate {
    // (yol, dosya metni, seçim) — denetleyici sağlar
    var context: () -> (path: String, text: String, selection: String)? = { nil }
    var onApply: ((String) -> Void)?
    var root: () -> URL? = { nil }
    let client = AIClient()

    private let title = makeLabel("AI", size: 11, color: Palette.dimText)
    private let mode = NSSegmentedControl(labels: ["Chat", "Agent"], trackingMode: .selectOne, target: nil, action: nil)
    private lazy var clearButton = iconButton("square.and.pencil", tooltip: "New Conversation", size: 13, target: self, action: #selector(clear))
    private lazy var applyButton = iconButton("arrow.down.doc", tooltip: "Apply last code block to the editor", size: 13, target: self, action: #selector(apply))
    private lazy var stopButton = iconButton("stop.circle", tooltip: "Stop", size: 13, target: self, action: #selector(stop))
    private let contextToggle = NSButton(checkboxWithTitle: "Include current file", target: nil, action: nil)
    let input = InputBox(placeholder: "Ask Claude…  (⏎ send)")
    private let scroll = NSTextView.scrollableTextView()
    private var transcript: NSTextView { scroll.documentView as! NSTextView }
    private var history: [[String: Any]] = []
    private var agent: AIAgent?
    private var task: Task<Void, Never>?
    private(set) var busy = false
    private(set) var lastReply = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.chrome
        mode.selectedSegment = 0
        mode.segmentStyle = .rounded
        mode.controlSize = .small
        contextToggle.state = .on
        contextToggle.controlSize = .small
        contextToggle.font = .systemFont(ofSize: 11)
        input.field.delegate = self
        input.field.cell?.wraps = true
        input.field.cell?.isScrollable = false
        input.field.usesSingleLineMode = false
        transcript.isEditable = false
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 8, height: 8)
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        stopButton.isHidden = true
        [title, mode, clearButton, applyButton, stopButton, contextToggle, scroll, input].forEach(addSubview)
        showWelcome()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        title.frame = NSRect(x: 20, y: 11, width: 30, height: 15)
        mode.frame = NSRect(x: 50, y: 6, width: 120, height: 24)
        stopButton.frame = NSRect(x: w - 84, y: 7, width: 22, height: 22)
        applyButton.frame = NSRect(x: w - 58, y: 7, width: 22, height: 22)
        clearButton.frame = NSRect(x: w - 32, y: 7, width: 22, height: 22)
        let inputH: CGFloat = 64
        scroll.frame = NSRect(x: 0, y: 36, width: w, height: max(0, h - 36 - inputH - 34))
        contextToggle.frame = NSRect(x: 12, y: h - inputH - 30, width: w - 24, height: 20)
        input.frame = NSRect(x: 12, y: h - inputH - 8, width: w - 24, height: inputH)
    }

    var isAgent: Bool {
        get { mode.selectedSegment == 1 }
        set { mode.selectedSegment = newValue ? 1 : 0 }
    }

    private func showWelcome() {
        transcript.textStorage?.setAttributedString(NSAttributedString())
        append("Chat uses Claude Sonnet 5 with the current file as context. Agent mode uses Claude Opus 5 and can read files, " +
               "search, and — after your approval — write files and run commands.\n\n", color: Palette.dimText, size: 11)
    }

    private func append(_ s: String, color: NSColor = Palette.text, size: CGFloat = 12.5, bold: Bool = false, mono: Bool = false) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : (bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
        transcript.textStorage?.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        transcript.scrollToEndOfDocument(nil)
    }

    func controlTextDidBeginEditing(_ obj: Notification) { input.setFocused(true) }
    func controlTextDidEndEditing(_ obj: Notification) { input.setFocused(false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if NSEvent.modifierFlags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                send(input.field.stringValue)
            }
            return true
        }
        return false
    }

    func focus() { window?.makeFirstResponder(input.field) }

    @objc func clear() {
        stop()
        history = []
        agent = nil
        lastReply = ""
        showWelcome()
    }

    @objc func stop() {
        task?.cancel()
        task = nil
        setBusy(false)
    }

    private func setBusy(_ b: Bool) {
        busy = b
        stopButton.isHidden = !b
        input.field.isEnabled = !b
    }

    @objc func apply() {
        guard let code = Self.lastCodeBlock(lastReply) else { return NSSound.beep() }
        onApply?(code)
    }

    // son ``` kod bloğu
    static func lastCodeBlock(_ text: String) -> String? {
        let parts = text.components(separatedBy: "```")
        guard parts.count >= 3 else { return nil }
        let block = parts[parts.count - 2]
        guard let nl = block.firstIndex(of: "\n") else { return block }
        return String(block[block.index(after: nl)...]).trimmingCharacters(in: .newlines)
    }

    func send(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        input.field.stringValue = ""
        append("You\n", color: Palette.dimText, size: 11, bold: true)
        append(q + "\n\n")
        append((isAgent ? "Agent" : "Claude") + "\n", color: Palette.match, size: 11, bold: true)
        setBusy(true)
        lastReply = ""
        let onText: (String) -> Void = { [weak self] t in
            DispatchQueue.main.async {
                self?.lastReply += t
                self?.append(t)
            }
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if self.isAgent {
                    try await self.runAgent(q, onText: onText)
                } else {
                    try await self.runChat(q, onText: onText)
                }
                await MainActor.run { self.append("\n\n") }
            } catch is CancellationError {
                await MainActor.run { self.append("\n[stopped]\n\n", color: Palette.dimText) }
            } catch {
                await MainActor.run { self.append("\n⚠ \(error.localizedDescription)\n\n", color: .systemRed) }
            }
            await MainActor.run { self.setBusy(false) }
        }
    }

    private static let chatSystem = """
    You are the assistant built into Kern, a code editor. Answer concisely. When you propose a code change, give the \
    complete replacement for the relevant snippet in a single fenced code block so the user can apply it with one click.
    """

    // büyük dosya: kısaltmak yerine açıkça belirt ve seçim/çevreyi gönder
    private func contextBlock() -> String {
        guard contextToggle.state == .on, let c = context() else { return "" }
        var s = "<file path=\"\(c.path)\">\n"
        if c.text.utf8.count <= 200_000 {
            s += c.text
        } else {
            s += "[The file is \(c.text.utf8.count / 1024) KB, too large to include; only the selection is attached.]"
        }
        s += "\n</file>\n"
        if !c.selection.isEmpty { s += "<selection>\n\(c.selection)\n</selection>\n" }
        return s
    }

    private func runChat(_ q: String, onText: @escaping (String) -> Void) async throws {
        let ctx = await MainActor.run { contextBlock() }
        history.append(["role": "user", "content": ctx.isEmpty ? q : ctx + "\n" + q])
        let body: [String: Any] = [
            "model": AIModel.chat, "max_tokens": 32000, "system": Self.chatSystem,
            "messages": history, "cache_control": ["type": "ephemeral"],
        ]
        let resp = try await client.stream(body, onText: onText)
        history.append(["role": "assistant", "content": resp.content])
    }

    private func runAgent(_ q: String, onText: @escaping (String) -> Void) async throws {
        guard let root = await MainActor.run(body: { root() }) else { throw AIError.stream("Open a folder to use agent mode.") }
        if agent == nil || agent?.root != root.standardizedFileURL {
            agent = AIAgent(client: client, root: root)
        }
        guard let agent else { return }
        agent.onText = onText
        agent.onEvent = { [weak self] e in DispatchQueue.main.async { self?.append("\n" + e + "\n", color: Palette.dimText, size: 11, mono: true) } }
        agent.approve = { [weak self] title, detail in
            await MainActor.run {
                if let auto = self?.autoApprove { return auto }
                let a = NSAlert()
                a.messageText = title
                a.informativeText = String(detail.prefix(3000))
                a.addButton(withTitle: "Allow")
                a.addButton(withTitle: "Reject")
                return a.runModal() == .alertFirstButtonReturn
            }
        }
        _ = try await agent.run(q)
    }

    // yalnız self-test için: onay penceresi yerine sabit yanıt
    var autoApprove: Bool?
}
