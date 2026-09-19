import AppKit

final class FindBar: FlippedView, NSTextFieldDelegate {
    var onQuery: ((String, UInt8) -> Void)?
    var onNext: ((Bool) -> Void)?
    var onReplace: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?

    let find = InputBox(placeholder: "Find")
    let replace = InputBox(placeholder: "Replace")
    private(set) var showsReplace = false
    private let caseButton = OptionToggle("Aa", tip: "Match Case")
    private let wordButton = OptionToggle("ab", tip: "Match Whole Word")
    private let regexButton = OptionToggle(".*", tip: "Use Regular Expression")
    var flags: UInt8 { (caseButton.isOn ? 1 : 0) | (wordButton.isOn ? 2 : 0) | (regexButton.isOn ? 4 : 0) }
    private let count = makeLabel("", size: 12, color: Palette.text)
    private lazy var toggle = iconButton("chevron.right", tooltip: "Toggle Replace", size: 11, target: self, action: #selector(toggleReplace))
    private lazy var prev = iconButton("arrow.up", tooltip: "Previous Match (⇧⏎)", size: 12, target: self, action: #selector(prevTapped))
    private lazy var next = iconButton("arrow.down", tooltip: "Next Match (⏎)", size: 12, target: self, action: #selector(nextTapped))
    private lazy var close = iconButton("xmark", tooltip: "Close (Esc)", size: 12, target: self, action: #selector(closeTapped))
    private lazy var replaceOne = iconButton("arrow.turn.down.left", tooltip: "Replace (⏎)", size: 12, target: self, action: #selector(replaceTapped))
    private lazy var replaceAll = iconButton("text.badge.checkmark", tooltip: "Replace All (⌘⏎)", size: 12, target: self, action: #selector(replaceAllTapped))

    var query: String { find.field.stringValue }
    var preferredHeight: CGFloat { showsReplace ? 66 : 36 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.widget
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        border = Palette.border
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        find.field.delegate = self
        replace.field.delegate = self
        find.trailingInset = 80
        [caseButton, wordButton, regexButton].forEach { $0.onToggle = { [weak self] in self.map { $0.onQuery?($0.query, $0.flags) } } }
        [toggle, find, caseButton, wordButton, regexButton, count, prev, next, close, replace, replaceOne, replaceAll].forEach(addSubview)
        setReplace(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        let boxW = w - 22 - 176
        toggle.frame = NSRect(x: 3, y: 0, width: 16, height: bounds.height)
        find.frame = NSRect(x: 22, y: 5, width: boxW, height: 26)
        for (i, b) in [caseButton, wordButton, regexButton].enumerated() {
            b.frame = NSRect(x: 22 + boxW - 78 + CGFloat(i) * 25, y: 8, width: 23, height: 20)
        }
        count.frame = NSRect(x: 22 + boxW + 8, y: 10, width: 84, height: 16)
        prev.frame = NSRect(x: w - 78, y: 7, width: 22, height: 22)
        next.frame = NSRect(x: w - 54, y: 7, width: 22, height: 22)
        close.frame = NSRect(x: w - 28, y: 7, width: 22, height: 22)
        replace.frame = NSRect(x: 22, y: 35, width: boxW, height: 26)
        replaceOne.frame = NSRect(x: 22 + boxW + 8, y: 37, width: 22, height: 22)
        replaceAll.frame = NSRect(x: 22 + boxW + 32, y: 37, width: 22, height: 22)
    }

    func present(replace withReplace: Bool, query: String?) {
        setReplace(withReplace)
        if let query, !query.isEmpty { find.field.stringValue = query }
        window?.makeFirstResponder(withReplace && query != nil ? replace.field : find.field)
        find.field.currentEditor()?.selectAll(nil)
        onQuery?(self.query, flags)
    }

    func setCount(_ text: String, empty: Bool) {
        count.stringValue = text
        count.textColor = empty && !query.isEmpty ? NSColor(hex: 0xF48771) : Palette.text
    }

    private func setReplace(_ on: Bool) {
        showsReplace = on
        [replace, replaceOne, replaceAll].forEach { $0.isHidden = !on }
        toggle.image = symbol(on ? "chevron.down" : "chevron.right", size: 11)
        superview?.needsLayout = true
        needsLayout = true
    }

    @objc private func toggleReplace() {
        setReplace(!showsReplace)
        if showsReplace { window?.makeFirstResponder(replace.field) }
    }


    @objc private func prevTapped() { onNext?(false) }
    @objc private func nextTapped() { onNext?(true) }
    @objc private func closeTapped() { onClose?() }
    @objc private func replaceTapped() { onReplace?(replace.field.stringValue, false) }
    @objc private func replaceAllTapped() { onReplace?(replace.field.stringValue, true) }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === find.field { onQuery?(query, flags) }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        find.setFocused((obj.object as? NSTextField) === find.field)
        replace.setFocused((obj.object as? NSTextField) === replace.field)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        find.setFocused(false)
        replace.setFocused(false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === replace.field {
                onReplace?(replace.field.stringValue, flags.contains(.command))
            } else {
                onNext?(!flags.contains(.shift))
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
