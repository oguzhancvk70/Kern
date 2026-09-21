import AppKit

// alt paneldeki hata ayıklama konsolu: bağdaştırıcı çıktısı + ifade değerlendirme
final class DebugConsole: FlippedView, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    var onEvaluate: ((String) -> Void)?

    private let title = makeLabel("DEBUG CONSOLE", size: 11, color: Palette.dimText)
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let input = InputBox(placeholder: "Evaluate expression (↩)")
    private lazy var clearButton = iconButton("trash", tooltip: "Clear Console", size: 12, target: self, action: #selector(clear))
    private lazy var closeButton = iconButton("xmark", tooltip: "Hide Panel", size: 12, target: self, action: #selector(hide))
    private let header: CGFloat = 35
    private var history: [String] = []
    private var historyIndex = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.chrome
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 8, height: 6)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        input.field.delegate = self
        [title, scroll, input, clearButton, closeButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        title.frame = NSRect(x: 12, y: 11, width: w - 80, height: 15)
        clearButton.frame = NSRect(x: w - 58, y: 7, width: 22, height: 22)
        closeButton.frame = NSRect(x: w - 32, y: 7, width: 22, height: 22)
        let inputH: CGFloat = 26
        scroll.frame = NSRect(x: 0, y: header, width: w, height: max(0, h - header - inputH - 8))
        input.frame = NSRect(x: 8, y: max(header, h - inputH - 5), width: w - 16, height: inputH)
        text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        text.frame.size.width = scroll.contentSize.width
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func focusInput() {
        window?.makeFirstResponder(input.field)
    }

    var contents: String { text.string }

    // category: stdout/stderr/console/important
    func append(_ message: String, category: String = "console") {
        let color: NSColor
        switch category {
        case "stderr": color = NSColor(hex: 0xE5534B)
        case "important": color = NSColor(hex: 0xE2C08D)
        case "input": color = Palette.match
        case "result": color = Palette.brightText
        default: color = Palette.text
        }
        let atEnd = scroll.verticalScroller.map { $0.floatValue > 0.995 } ?? true
        let empty = text.string.isEmpty
        text.textStorage?.append(NSAttributedString(string: message, attributes: [
            .foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
        // yeni içerik alttaysa takip et
        if atEnd || empty { text.scrollToEndOfDocument(nil) }
    }

    @objc private func clear() {
        text.string = ""
    }

    @objc private func hide() { onClose?() }

    func controlTextDidBeginEditing(_ obj: Notification) { input.setFocused(true) }
    func controlTextDidEndEditing(_ obj: Notification) { input.setFocused(false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            let expr = input.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expr.isEmpty else { return true }
            history.append(expr)
            historyIndex = history.count
            input.field.stringValue = ""
            append("› \(expr)\n", category: "input")
            onEvaluate?(expr)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard historyIndex > 0 else { return true }
            historyIndex -= 1
            input.field.stringValue = history[historyIndex]
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard historyIndex < history.count - 1 else {
                historyIndex = history.count
                input.field.stringValue = ""
                return true
            }
            historyIndex += 1
            input.field.stringValue = history[historyIndex]
            return true
        default:
            return false
        }
    }
}
