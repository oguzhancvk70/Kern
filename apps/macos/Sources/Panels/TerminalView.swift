import AppKit
import MetalKit

final class TerminalView: MTKView, MTKViewDelegate {
    var onExit: (() -> Void)?
    var onTitle: ((String) -> Void)?

    private(set) var terminal: KernTerminal?
    private let renderer: Renderer
    private let cwd: String
    private let pointSize: CGFloat = 12
    private var font: CTFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) as CTFont
    private var boldFont: CTFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold) as CTFont
    private var cellW: CGFloat = 1
    private var cellH: CGFloat = 1
    private var baseline: CGFloat = 0
    private var glyphs: [UInt32: (font: Int, glyph: CGGlyph)] = [:]
    private var cols = 80
    private var rows = 24
    private var timer: Timer?
    private var focused = false
    private var scrollRemainder: CGFloat = 0
    private var dragStart: (row: Int, col: Int, right: Bool)?
    private var lastTitle = ""

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    init?(cwd: String) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = Renderer(device: device, pixelFormat: .bgra8Unorm) else { return nil }
        self.renderer = renderer
        self.cwd = cwd
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    deinit { timer?.invalidate() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func becomeFirstResponder() -> Bool {
        focused = true
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        focused = false
        needsDisplay = true
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            timer?.invalidate()
            return
        }
        configureFont()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.poll() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        configureFont()
        needsDisplay = true
    }

    private func configureFont() {
        renderer.atlas.resetAll()
        glyphs.removeAll()
        font = NSFont.monospacedSystemFont(ofSize: pointSize * scale, weight: .regular) as CTFont
        boldFont = NSFont.monospacedSystemFont(ofSize: pointSize * scale, weight: .bold) as CTFont
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        var ch: UniChar = 0x30
        var g: CGGlyph = 0
        var adv = CGSize.zero
        CTFontGetGlyphsForCharacters(font, &ch, &g, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &adv, 1)
        cellW = adv.width
        cellH = ceil((ascent + descent) * 1.25)
        baseline = ceil((cellH - ascent - descent) / 2 + ascent)
        updateGrid(drawableSize)
    }

    private func updateGrid(_ size: CGSize) {
        guard size.width > 0, size.height > 0, cellW > 0 else { return }
        cols = max(2, Int((size.width - 16 * scale) / cellW))
        rows = max(1, Int((size.height - 4 * scale) / cellH))
        let cw = UInt16(min(CGFloat(UInt16.max), cellW / scale)), ch = UInt16(min(CGFloat(UInt16.max), cellH / scale))
        if let terminal {
            terminal.resize(UInt(cols), UInt(rows), cw, ch)
        } else {
            terminal = spawn_terminal(cwd, UInt(cols), UInt(rows), cw, ch)
        }
        needsDisplay = true
    }

    private func poll() {
        guard let terminal else { return }
        if terminal.take_dirty() {
            needsDisplay = true
            let title = terminal.title().toString()
            if title != lastTitle {
                lastTitle = title
                onTitle?(title)
            }
        }
        if !terminal.is_alive() {
            timer?.invalidate()
            onExit?()
        }
    }

    // çizim

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        updateGrid(size)
    }

    private func color(_ rgb: UInt32, _ alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float((rgb >> 16) & 0xFF) / 255 * alpha, Float((rgb >> 8) & 0xFF) / 255 * alpha, Float(rgb & 0xFF) / 255 * alpha, alpha)
    }

    private func glyph(_ code: UInt32, bold: Bool) -> (font: Int, glyph: CGGlyph)? {
        let key = code | (bold ? 1 << 31 : 0)
        if let g = glyphs[key] { return g }
        guard let scalar = UnicodeScalar(code) else { return nil }
        let s = String(Character(scalar)) as NSString
        var chars = [UniChar](repeating: 0, count: s.length)
        s.getCharacters(&chars, range: NSRange(location: 0, length: s.length))
        var ids = [CGGlyph](repeating: 0, count: chars.count)
        var f = bold ? boldFont : font
        if !CTFontGetGlyphsForCharacters(f, chars, &ids, chars.count) {
            f = CTFontCreateForString(f, s as CFString, CFRange(location: 0, length: s.length))
            CTFontGetGlyphsForCharacters(f, chars, &ids, chars.count)
        }
        let g = (renderer.atlas.fontId(f), ids[0])
        glyphs[key] = g
        return g
    }

    func draw(in view: MTKView) {
        let background: UInt32 = 0x181818
        guard let terminal else {
            return renderer.render([], in: self, clear: color(background))
        }
        let snap = Array(terminal.snapshot())
        let n = cols * rows
        guard snap.count >= n * 4 + 4 else {
            return renderer.render([], in: self, clear: color(background))
        }
        let padX = 8 * scale, padY = 2 * scale
        var back: [Instance] = []
        var text: [Instance] = []
        var front: [Instance] = []
        let selection = color(0x264F78)

        for row in 0..<rows {
            let y = padY + CGFloat(row) * cellH
            var col = 0
            while col < cols {
                let i = (row * cols + col) * 4
                let bg = snap[i + 2], flags = snap[i + 3]
                let selected = flags & 32 != 0
                if bg != background || selected {
                    // aynı arka planlı hücreleri birleştir
                    var end = col + 1
                    while end < cols, snap[(row * cols + end) * 4 + 2] == bg,
                          (snap[(row * cols + end) * 4 + 3] & 32 != 0) == selected { end += 1 }
                    back.append(.rect(padX + CGFloat(col) * cellW, y, CGFloat(end - col) * cellW, cellH,
                                      selected ? selection : color(bg)))
                    col = end
                } else {
                    col += 1
                }
            }
            for col in 0..<cols {
                let i = (row * cols + col) * 4
                let code = snap[i], flags = snap[i + 3]
                let x = padX + CGFloat(col) * cellW
                if flags & 4 != 0 {
                    front.append(.rect(x, y + baseline + scale, cellW, max(1, scale.rounded()), color(snap[i + 1])))
                }
                if flags & 64 != 0 {
                    front.append(.rect(x, y + cellH / 2, cellW, max(1, scale.rounded()), color(snap[i + 1])))
                }
                if code <= 32 || flags & 16 != 0 { continue }
                guard let g = glyph(code, bold: flags & 1 != 0) else { continue }
                let e = renderer.atlas.entry(font: g.font, glyph: g.glyph)
                if e.size.x == 0 { continue }
                text.append(Instance(
                    pos: SIMD2(Float(x.rounded()) + e.bearing.x, Float((y + baseline).rounded()) + e.bearing.y),
                    size: e.size, uv: e.origin, uvSize: e.size,
                    color: e.isColor ? SIMD4(1, 1, 1, 1) : color(snap[i + 1]), mode: e.isColor ? 2 : 1))
            }
        }

        let c = n * 4
        if snap[c + 2] == 1 {
            let x = padX + CGFloat(snap[c + 1]) * cellW, y = padY + CGFloat(snap[c]) * cellH
            let cursor = color(0xAEAFAD)
            let t = max(1, scale.rounded())
            if focused && snap[c + 3] == 1 {
                back.append(.rect(x, y, cellW, cellH, cursor))
                // imleç altındaki karakter koyu
                if let last = text.lastIndex(where: { abs(CGFloat($0.pos.x) - x) < cellW && abs(CGFloat($0.pos.y) - y) < cellH }) {
                    text[last].color = color(background)
                }
            } else if focused {
                front.append(.rect(x, y, 2 * t, cellH, cursor))
            } else {
                front += [.rect(x, y, cellW, t, cursor), .rect(x, y + cellH - t, cellW, t, cursor),
                          .rect(x, y, t, cellH, cursor), .rect(x + cellW - t, y, t, cellH, cursor)]
            }
        }

        if renderer.atlas.consumeOverflow() {
            DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
        }
        renderer.render(back + text + front, in: self, clear: color(background))
    }

    // giriş

    private func send(_ s: String) {
        terminal?.write_text(s)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.command) { return super.keyDown(with: event) }
        let app = terminal?.app_cursor() ?? false
        let arrow = { (c: String) in app ? "\u{1b}O\(c)" : "\u{1b}[\(c)" }
        guard let chars = event.charactersIgnoringModifiers, let scalar = chars.unicodeScalars.first else { return }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return send(arrow("A"))
        case NSDownArrowFunctionKey: return send(arrow("B"))
        case NSRightArrowFunctionKey: return send(flags.contains(.option) ? "\u{1b}f" : arrow("C"))
        case NSLeftArrowFunctionKey: return send(flags.contains(.option) ? "\u{1b}b" : arrow("D"))
        case NSHomeFunctionKey: return send("\u{1b}[H")
        case NSEndFunctionKey: return send("\u{1b}[F")
        case NSPageUpFunctionKey: return send("\u{1b}[5~")
        case NSPageDownFunctionKey: return send("\u{1b}[6~")
        case NSDeleteFunctionKey: return send("\u{1b}[3~")
        case 0x7F: return send(flags.contains(.option) ? "\u{1b}\u{7f}" : "\u{7f}")
        case 0x0D, 0x03: return send("\r")
        case 0x1B: return send("\u{1b}")
        default: break
        }
        if let text = event.characters, !text.isEmpty {
            send(text)
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let text = terminal?.selection_text().toString(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard var text = NSPasteboard.general.string(forType: .string) else { return }
        text = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        send(terminal?.bracketed_paste() == true ? "\u{1b}[200~\(text)\u{1b}[201~" : text)
    }

    @objc func clearTerminal(_ sender: Any?) {
        send("\u{0c}")
    }

    private func cell(at event: NSEvent) -> (row: Int, col: Int, right: Bool) {
        let p = convert(event.locationInWindow, from: nil)
        let x = p.x * scale - 8 * scale, y = p.y * scale - 2 * scale
        let colF = x / cellW
        let col = min(max(0, Int(colF)), cols - 1)
        let row = min(max(0, Int(y / cellH)), rows - 1)
        return (row, col, colF - CGFloat(Int(colF)) > 0.5)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let c = cell(at: event)
        switch event.clickCount {
        case 2: terminal?.select_start(UInt(c.row), UInt(c.col), c.right, 1)
        case 3...: terminal?.select_start(UInt(c.row), UInt(c.col), c.right, 2)
        default:
            terminal?.select_clear()
            dragStart = c
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let c = cell(at: event)
        if let s = dragStart {
            terminal?.select_start(UInt(s.row), UInt(s.col), s.right, 0)
            dragStart = nil
        }
        terminal?.select_update(UInt(c.row), UInt(c.col), c.right)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * scale / cellH : event.scrollingDeltaY * 3
        scrollRemainder += dy
        let lines = Int(scrollRemainder)
        guard lines != 0 else { return }
        scrollRemainder -= CGFloat(lines)
        terminal?.scroll(Int32(lines))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}
