import AppKit

struct PaletteItem {
    var title: String
    var detail: String = ""
    var key: String = ""
    var icon: NSImage? = nil
    var run: () -> Void
}

// hızlı açma (⌘P), komutlar (>), satıra git (:)
final class PaletteView: FlippedView, NSTextFieldDelegate {
    var provider: ((String) -> [PaletteItem])?
    var onDismiss: (() -> Void)?

    let input = InputBox(placeholder: "Search files by name (append : to go to a line, > for commands)")
    private var items: [PaletteItem] = []
    private var selected = 0
    private var top = 0
    private let maxRows = 12
    private let rowHeight: CGFloat = 24
    private let header: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.widget
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        border = Palette.inputBorder
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.6
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        input.field.delegate = self
        input.setFocused(true)
        addSubview(input)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        input.frame = NSRect(x: 7, y: 7, width: bounds.width - 14, height: 26)
    }

    func present(text: String) {
        input.field.stringValue = text
        refresh()
        window?.makeFirstResponder(input.field)
        if let editor = input.field.currentEditor() {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    private var query: String {
        let q = input.field.stringValue
        if q.hasPrefix(">") || q.hasPrefix(":") || q.hasPrefix("@") { return String(q.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return q
    }

    private func refresh() {
        items = provider?(input.field.stringValue) ?? []
        selected = 0
        top = 0
        let rows = min(items.count, maxRows)
        var f = frame
        f.size.height = header + CGFloat(rows) * rowHeight + (rows > 0 ? 6 : 0)
        frame = f
        needsDisplay = true
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
        if selected < top { top = selected }
        if selected >= top + maxRows { top = selected - maxRows + 1 }
        needsDisplay = true
    }

    private func runSelected(_ index: Int? = nil) {
        let i = index ?? selected
        guard i >= 0, i < items.count else { return }
        let item = items[i]
        dismiss()
        item.run()
    }

    func dismiss() {
        guard superview != nil else { return }
        removeFromSuperview()
        onDismiss?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let q = Array(query.lowercased())
        let w = bounds.width
        for (row, i) in (top..<min(items.count, top + maxRows)).enumerated() {
            let item = items[i]
            let r = NSRect(x: 4, y: header + CGFloat(row) * rowHeight, width: w - 8, height: rowHeight)
            if i == selected {
                Palette.selection.setFill()
                NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            }
            var x = r.minX + 10
            if let icon = item.icon {
                icon.draw(in: NSRect(x: x, y: r.minY + 4, width: 16, height: 16), from: .zero,
                          operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += 22
            }
            let title = NSMutableAttributedString(string: item.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.text,
            ])
            var qi = 0
            var offset = 0
            for ch in item.title {
                let len = ch.utf16.count
                if qi < q.count, ch.lowercased() == String(q[qi]) {
                    title.addAttributes([.foregroundColor: Palette.match, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)],
                                        range: NSRange(location: offset, length: len))
                    qi += 1
                }
                offset += len
            }
            let ts = title.size()
            title.draw(at: NSPoint(x: x, y: r.minY + (rowHeight - ts.height) / 2))
            x += ts.width + 8
            let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Palette.dimText]
            var keyWidth: CGFloat = 0
            if !item.key.isEmpty {
                let k = item.key as NSString
                keyWidth = k.size(withAttributes: dim).width + 16
                k.draw(at: NSPoint(x: r.maxX - keyWidth + 6, y: r.minY + 4), withAttributes: dim)
            }
            if !item.detail.isEmpty {
                let d = item.detail as NSString
                let rect = NSRect(x: x, y: r.minY + 5, width: max(0, r.maxX - keyWidth - x - 8), height: 16)
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingHead
                var attrs = dim
                attrs[.paragraphStyle] = style
                d.draw(in: rect, withAttributes: attrs)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard p.y >= header else { return }
        runSelected(top + Int((p.y - header) / rowHeight))
    }

    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder !== self.input.field.currentEditor() else { return }
            self.dismiss()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }
}
