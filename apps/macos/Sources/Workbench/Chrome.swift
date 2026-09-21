import AppKit

// macOS 14+: görünümler varsayılan olarak kırpmıyor, dirtyRect sınırı aşabiliyor
class FlippedView: NSView {
    var background: NSColor? { didSet { needsDisplay = true } }
    var border: NSColor? { didSet { applyBorder() } }
    override var isFlipped: Bool { true }

    private func applyBorder() {
        guard let border else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance { self.layer?.borderColor = border.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorder()
        needsDisplay = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let background else { return }
        background.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

func makeLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
               color: NSColor = Palette.text) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    return label
}

func symbol(_ name: String, size: CGFloat = 14, color: NSColor = Palette.icon) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        .applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
}

func iconButton(_ name: String, tooltip: String, size: CGFloat = 14, target: AnyObject?, action: Selector) -> NSButton {
    let button = NSButton(image: symbol(name, size: size) ?? NSImage(), target: target, action: action)
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.toolTip = tooltip
    button.setButtonType(.momentaryChange)
    // yalnız simgeli düğmelerin VoiceOver adı olmaz
    button.setAccessibilityLabel(tooltip)
    return button
}

// koyu giriş kutusu
final class InputBox: FlippedView {
    let field = NSTextField()
    var trailingInset: CGFloat = 6 { didSet { needsLayout = true } }

    init(placeholder: String) {
        super.init(frame: .zero)
        field.setAccessibilityLabel(placeholder)
        background = Palette.input
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.borderWidth = 1
        border = Palette.inputBorder
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = Palette.text
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder, attributes: [.foregroundColor: Palette.dimText, .font: NSFont.systemFont(ofSize: 13)])
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h: CGFloat = 17
        field.frame = NSRect(x: 6, y: (bounds.height - h) / 2, width: bounds.width - 6 - trailingInset, height: h)
    }

    func setFocused(_ on: Bool) {
        border = on ? Palette.accent : Palette.inputBorder
    }
}

final class ActivityBar: FlippedView, NSAccessibilityGroup {
    var onSelect: ((Int) -> Void)?
    var selected: Int? { didSet { refresh() } }
    private var buttons: [NSButton] = []
    private let items = [("doc.on.doc", "Explorer (⇧⌘E)"), ("magnifyingglass", "Search (⇧⌘F)"), ("sparkles", "AI (⇧⌘I)"),
                                 ("arrow.triangle.branch", "Source Control (⌃⇧G)"), ("play.circle", "Run and Debug (⇧⌘D)")]

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.chrome
        setAccessibilityLabel("Activity Bar")
        for (i, item) in items.enumerated() {
            let b = iconButton(item.0, tooltip: item.1, size: 20, target: self, action: #selector(tap(_:)))
            b.tag = i
            b.frame = NSRect(x: 0, y: CGFloat(i) * 48, width: 48, height: 48)
            addSubview(b)
            buttons.append(b)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tap(_ sender: NSButton) {
        onSelect?(sender.tag)
    }

    private func refresh() {
        for (i, b) in buttons.enumerated() {
            b.image = symbol(items[i].0, size: 20, color: i == selected ? Palette.brightText : Palette.icon)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.border.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        if let selected {
            Palette.accent.setFill()
            NSRect(x: 0, y: CGFloat(selected) * 48, width: 2, height: 48).fill()
        }
    }
}

final class SplitHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var vertical = false

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: vertical ? .resizeUpDown : .resizeLeftRight)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(vertical ? event.deltaY : event.deltaX)
    }
}

final class StatusBarView: FlippedView {
    var left: [String] = [] { didSet { needsDisplay = true } }
    var right: [String] = [] { didSet { needsDisplay = true } }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Status Bar" }
    override func accessibilityValue() -> Any? { (left + right).joined(separator: ", ") }
    private let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Palette.text]

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.chrome
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        var x: CGFloat = 10
        for item in left {
            let s = item as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attrs)
            x += size.width + 18
        }
        x = bounds.width - 12
        for item in right.reversed() {
            let s = item as NSString
            let size = s.size(withAttributes: attrs)
            x -= size.width
            s.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attrs)
            x -= 18
        }
    }
}

final class BreadcrumbsView: FlippedView {
    var parts: [String] = [] { didSet { needsDisplay = true } }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Breadcrumbs" }
    override func accessibilityValue() -> Any? { parts.joined(separator: " › ") }

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.editor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Palette.dimText]
        var x: CGFloat = 16
        for (i, part) in parts.enumerated() {
            let last = i == parts.count - 1
            if last {
                FileIcons.icon(for: part, directory: false)?.draw(in: NSRect(x: x, y: (bounds.height - 14) / 2, width: 14, height: 14),
                                                                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += 19
            }
            let s = part as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attrs)
            x += size.width + 4
            if !last {
                symbol("chevron.right", size: 9, color: Palette.dimText)?.draw(in: NSRect(x: x, y: (bounds.height - 10) / 2, width: 8, height: 10))
                x += 12
            }
        }
    }
}

final class WelcomeView: FlippedView {
    private let rows = [
        ("Show All Commands", "⇧ ⌘ P"), ("Go to File", "⌘ P"), ("Find in Files", "⇧ ⌘ F"),
        ("Toggle Terminal", "⌃ `"), ("Open Folder", "⇧ ⌘ O"), ("New File", "⌘ N"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.editor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let midX = bounds.midX
        var y = bounds.midY - 130
        let logo: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 88, weight: .ultraLight), .foregroundColor: NSColor(hex: 0x3A3A3A),
        ]
        let title = "Kern" as NSString
        let size = title.size(withAttributes: logo)
        title.draw(at: NSPoint(x: midX - size.width / 2, y: y), withAttributes: logo)
        y += size.height + 28
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.dimText]
        let key: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: Palette.dimText,
        ]
        for (text, shortcut) in rows {
            let t = text as NSString
            let tw = t.size(withAttributes: label).width
            t.draw(at: NSPoint(x: midX - 12 - tw, y: y), withAttributes: label)
            (shortcut as NSString).draw(at: NSPoint(x: midX + 12, y: y + 1), withAttributes: key)
            y += 26
        }
    }
}
