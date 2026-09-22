import AppKit

// markdown önizleme penceresi: kaynak değiştikçe (kaydetmeye gerek yok) tazelenir
final class MarkdownPreviewController: NSWindowController {
    private static var open: [String: MarkdownPreviewController] = [:]

    private let textView = NSTextView()
    private var path = ""
    private var provider: (() -> String)?
    private var timer: Timer?

    static func show(path: String, title: String, provider: @escaping () -> String) {
        if let c = open[path] {
            c.provider = provider
            c.refresh()
            c.window?.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Preview — \(title)"
        let c = MarkdownPreviewController(window: window)
        c.path = path
        c.provider = provider
        c.build()
        window.center()
        c.showWindow(nil)
        open[path] = c
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            c.timer?.invalidate()
            open[path] = nil
        }
    }

    // kaynak sekmesi değişince çağrılır
    static func refresh(path: String) { open[path]?.refresh() }

    private func build() {
        guard let window else { return }
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        textView.isEditable = false
        textView.drawsBackground = true
        textView.backgroundColor = Palette.editor
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        window.contentView = scroll
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private var lastSource = ""

    func refresh() {
        let source = provider?() ?? ""
        guard source != lastSource else { return }
        lastSource = source
        textView.textStorage?.setAttributedString(Self.render(source))
    }

    // başlıklar, kalın/italik, kod blokları, listeler ve bağlantılar
    static func render(_ source: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 14)
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var inFence = false
        for raw in source.components(separatedBy: .newlines) {
            if raw.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                out.append(NSAttributedString(string: raw + "\n", attributes: [.font: mono, .foregroundColor: Palette.dimText]))
                continue
            }
            let hashes = raw.prefix(while: { $0 == "#" }).count
            if hashes > 0, hashes <= 6, raw.dropFirst(hashes).hasPrefix(" ") {
                let size: CGFloat = [26, 22, 18, 16, 15, 14][hashes - 1]
                let text = String(raw.dropFirst(hashes + 1))
                out.append(inline(text, font: .systemFont(ofSize: size, weight: .semibold)))
                out.append(NSAttributedString(string: "\n\n"))
                continue
            }
            var line = raw
            var indent: CGFloat = 0
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                line = "  •  " + String(trimmed.dropFirst(2))
                indent = 12
            } else if trimmed.hasPrefix("> ") {
                line = "  ▏ " + String(trimmed.dropFirst(2))
                indent = 12
            }
            let para = NSMutableParagraphStyle()
            para.headIndent = indent
            para.paragraphSpacing = line.isEmpty ? 6 : 2
            let piece = NSMutableAttributedString(attributedString: inline(line, font: body))
            piece.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: piece.length))
            out.append(piece)
            out.append(NSAttributedString(string: "\n"))
        }
        out.addAttribute(.foregroundColor, value: Palette.text, range: NSRange(location: 0, length: out.length))
        return out
    }

    // `kod`, **kalın**, *italik*, [metin](url)
    private static func inline(_ text: String, font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: Palette.text])
        func apply(_ pattern: String, _ change: (NSMutableAttributedString, NSRange, NSRange) -> Void) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            var matches = re.matches(in: out.string, range: NSRange(location: 0, length: out.length))
            matches.reverse()
            for m in matches where m.numberOfRanges > 1 {
                change(out, m.range, m.range(at: m.numberOfRanges - 1))
            }
        }
        apply("\\[([^\\]]+)\\]\\(([^)]+)\\)") { s, full, _ in
            let m = (s.string as NSString).substring(with: full)
            let parts = m.dropFirst().components(separatedBy: "](")
            let title = parts.first ?? m
            let url = parts.count > 1 ? String(parts[1].dropLast()) : ""
            let link = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: Palette.accent])
            if let u = URL(string: url) { link.addAttribute(.link, value: u, range: NSRange(location: 0, length: link.length)) }
            s.replaceCharacters(in: full, with: link)
        }
        apply("`([^`]+)`") { s, full, inner in
            let code = (s.string as NSString).substring(with: inner)
            s.replaceCharacters(in: full, with: NSAttributedString(string: code, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                .foregroundColor: Palette.match,
            ]))
        }
        apply("\\*\\*([^*]+)\\*\\*") { s, full, inner in
            let bold = (s.string as NSString).substring(with: inner)
            s.replaceCharacters(in: full, with: NSAttributedString(string: bold, attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize, weight: .bold), .foregroundColor: Palette.text,
            ]))
        }
        apply("(?<!\\*)\\*([^*]+)\\*(?!\\*)") { s, full, inner in
            let italic = (s.string as NSString).substring(with: inner)
            let f = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            s.replaceCharacters(in: full, with: NSAttributedString(string: italic, attributes: [.font: f, .foregroundColor: Palette.text]))
        }
        return out
    }
}

extension WorkbenchWindowController {
    @objc func showMarkdownPreview(_ sender: Any?) {
        guard let tab = activeTab, !tab.path.isEmpty else { return report("Open a Markdown file first") }
        let path = tab.path
        MarkdownPreviewController.show(path: path, title: tab.title) { [weak tab] in
            tab?.editor.text().toString() ?? ""
        }
    }
}
