import AppKit
import MetalKit

final class EditorView: MTKView, MTKViewDelegate, NSTextInputClient {
    let editor: KernEditor
    var onChange: ((_ edited: Bool) -> Void)?
    var findQuery = "" { didSet { needsDisplay = true } }
    var findCaseSensitive = false { didSet { needsDisplay = true } }

    private let renderer: Renderer
    private let layout: TextLayout
    private var pointSize: CGFloat { Self.fontSize }
    private let theme = Theme.dark

    static private(set) var fontSize: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "editorFontSize")
        return saved > 0 ? saved : 13
    }()
    private static let fontSizeChanged = Notification.Name("KernEditorFontSizeChanged")

    static func setFontSize(_ size: CGFloat) {
        fontSize = min(max(8, size), 32)
        UserDefaults.standard.set(Double(fontSize), forKey: "editorFontSize")
        NotificationCenter.default.post(name: fontSizeChanged, object: nil)
    }
    private var scrollX: CGFloat = 0  // piksel
    private var scrollY: CGFloat = 0
    private var contentWidth: CGFloat = 0
    private var markedText = ""
    private var focused = false
    private var cursorOn = true
    private var blinkTimer: Timer?
    private var draggingScrollbar: CGFloat?  // tutamaç içindeki tıklama ofseti
    private var draggingMinimap = false

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    init?(editor: KernEditor) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = Renderer(device: device, pixelFormat: .bgra8Unorm) else { return nil }
        self.editor = editor
        self.renderer = renderer
        self.layout = TextLayout(atlas: renderer.atlas, pointSize: EditorView.fontSize, scale: 2)
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        NotificationCenter.default.addObserver(forName: Self.fontSizeChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.layout.configure(pointSize: self.pointSize, scale: self.scale)
            self.mtkView(self, drawableSizeWillChange: self.drawableSize)
            self.revealCursor()
            self.needsDisplay = true
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    deinit { blinkTimer?.invalidate() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func becomeFirstResponder() -> Bool {
        focused = true
        restartBlink()
        return true
    }

    override func resignFirstResponder() -> Bool {
        focused = false
        blinkTimer?.invalidate()
        needsDisplay = true
        return true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layout.configure(pointSize: pointSize, scale: scale)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            blinkTimer?.invalidate()
            return
        }
        layout.configure(pointSize: pointSize, scale: scale)
    }

    private func restartBlink() {
        cursorOn = true
        needsDisplay = true
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self, self.focused, self.window?.isKeyWindow == true else { return }
            self.cursorOn.toggle()
            self.needsDisplay = true
        }
    }

    // ölçüler

    private var lineCount: Int { Int(editor.line_count()) }
    private var gutterWidth: CGFloat { CGFloat(max(3, String(lineCount).count) + 4) * layout.charWidth }
    private var textLeft: CGFloat { gutterWidth + layout.charWidth }
    private var scrollbarWidth: CGFloat { 14 * scale }
    private var minimapWidth: CGFloat { lineCount > 1 ? 90 * scale : 0 }
    private var minimapLine: CGFloat { 2 * scale }
    private var textRight: CGFloat { drawableSize.width - minimapWidth }

    private func shapedLine(_ i: Int) -> ShapedLine {
        layout.shape(editor.line(UInt(i)).toString())
    }

    private var maxScrollY: CGFloat {
        max(0, CGFloat(lineCount - 1) * layout.lineHeight)
    }

    private func clampScroll() {
        let maxX = max(0, contentWidth - (textRight - textLeft) + layout.charWidth * 4)
        scrollY = min(max(0, scrollY), maxScrollY)
        scrollX = min(max(0, scrollX), maxX)
    }

    func revealCursor(center: Bool = false) {
        let lh = layout.lineHeight
        let height = drawableSize.height
        guard height > 0 else { return }
        let top = CGFloat(editor.cursor_line()) * lh
        if center {
            scrollY = top - height / 3
        } else if top < scrollY {
            scrollY = top
        } else if top + lh > scrollY + height {
            scrollY = top + lh - height
        }
        let x = shapedLine(Int(editor.cursor_line())).offset(Int(editor.cursor_col()))
        let visible = textRight - textLeft
        if x < scrollX {
            scrollX = max(0, x - layout.charWidth * 4)
        } else if x > scrollX + visible - layout.charWidth * 2 {
            scrollX = x - visible + layout.charWidth * 4
        }
        contentWidth = max(contentWidth, x)
        clampScroll()
    }

    func changed(edited: Bool) {
        revealCursor()
        restartBlink()
        inputContext?.invalidateCharacterCoordinates()
        onChange?(edited)
    }

    // çizim

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let rows = Int(size.height / max(1, layout.lineHeight))
        editor.set_page_lines(UInt(max(1, rows - 1)))
    }

    func draw(in view: MTKView) {
        let size = drawableSize
        let lh = layout.lineHeight
        clampScroll()

        let first = max(0, Int(scrollY / lh))
        let last = min(lineCount - 1, Int((scrollY + size.height) / lh))
        let gutter = gutterWidth
        let x0 = textLeft - scrollX
        let cursorLine = Int(editor.cursor_line())
        let cursorCol = Int(editor.cursor_col())
        let hasSelection = editor.has_selection()
        // tüm seçimler (çoklu imleç)
        let selFlat = Array(editor.selections())
        var ranges: [((Int, Int), (Int, Int))] = []
        var heads: [(Int, Int)] = []
        var k = 0
        while k + 4 <= selFlat.count {
            var a = (Int(selFlat[k]), Int(selFlat[k + 1])), b = (Int(selFlat[k + 2]), Int(selFlat[k + 3]))
            heads.append(b)
            if a != b {
                if a > b { swap(&a, &b) }
                ranges.append((a, b))
            }
            k += 4
        }

        var back: [Instance] = []
        var text: [Instance] = []
        var front: [Instance] = [.rect(0, 0, gutter, size.height, theme.background)]
        var widest: CGFloat = 0
        guard first <= last else {
            return renderer.render(front, in: self, clear: theme.background)
        }

        let spans = groupByLine(Array(editor.highlights(UInt(first), UInt(last))), stride: 4)
        let matches = findQuery.isEmpty ? [:] : groupByLine(
            Array(editor.find_in_lines(findQuery, findCaseSensitive, UInt(first), UInt(last))), stride: 3)
        let bracket = Array(editor.matching_bracket())
        let hair = max(1, scale.rounded())
        var guideIndent = 0

        for i in first...last {
            let y = CGFloat(i) * lh - scrollY
            let str = editor.line(UInt(i)).toString()
            let shaped = layout.shape(str)
            widest = max(widest, shaped.width)

            if i == cursorLine && !hasSelection {
                back.append(.rect(0, y, size.width, hair, theme.currentLineBorder))
                back.append(.rect(0, y + lh - hair, size.width, hair, theme.currentLineBorder))
            }

            // girinti çizgileri
            let indent = str.prefix(while: { $0 == " " || $0 == "\t" })
            let level = str.trimmingCharacters(in: .whitespaces).isEmpty ? guideIndent : indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 4
            guideIndent = level
            for g in 0..<level {
                let gx = (x0 + CGFloat(g * 4) * layout.charWidth).rounded()
                if gx >= gutter { back.append(.rect(gx, y, hair, lh, theme.indentGuide)) }
            }

            for m in matches[i] ?? [] {
                let a = shaped.offset(Int(m[1])), b = shaped.offset(Int(m[2]))
                back.append(.rect(x0 + a, y, b - a, lh, theme.findMatch))
            }
            for (s, e) in ranges where i >= s.0 && i <= e.0 {
                let a = i == s.0 ? shaped.offset(s.1) : 0
                let b = i == e.0 ? shaped.offset(e.1) : shaped.width + layout.charWidth
                if b > a { back.append(.rect(x0 + a, y, b - a, lh, focused ? theme.selection : theme.inactiveSelection)) }
            }
            if bracket.count == 4 {
                for (bl, bc) in [(Int(bracket[0]), Int(bracket[1])), (Int(bracket[2]), Int(bracket[3]))] where bl == i {
                    let a = shaped.offset(bc), b = shaped.offset(bc + 1)
                    back.append(.rect(x0 + a, y, b - a, lh, theme.bracketMatch))
                }
            }

            let lineSpans = spans[i] ?? []
            appendGlyphs(shaped, x: x0, baseline: y + layout.baseline, into: &text) { idx in
                for sp in lineSpans.reversed() where idx >= Int(sp[1]) && idx < Int(sp[2]) {
                    return self.theme.color(for: sp[3])
                }
                return self.theme.text
            }

            let number = layout.shape(String(i + 1))
            let color = i == cursorLine ? theme.activeLineNumber : theme.lineNumber
            appendGlyphs(number, x: gutter - layout.charWidth * 2 - number.width,
                         baseline: y + layout.baseline, into: &front, clip: false) { _ in color }

            for h in heads where h.0 == i {
                if h.0 == cursorLine && h.1 == cursorCol {
                    appendCursor(at: x0 + shaped.offset(cursorCol), y: y, into: &front)
                } else {
                    appendCaret(at: x0 + shaped.offset(h.1), y: y, into: &front)
                }
            }
        }
        contentWidth = widest
        appendMinimap(first: first, last: last, into: &front)
        appendScrollbar(into: &front)

        if renderer.atlas.consumeOverflow() {
            DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
        }
        renderer.render(back + text + front, in: self, clear: theme.background)
    }

    private func groupByLine(_ flat: [UInt32], stride n: Int) -> [Int: [[UInt32]]] {
        var out: [Int: [[UInt32]]] = [:]
        var i = 0
        while i + n <= flat.count {
            out[Int(flat[i]), default: []].append(Array(flat[i..<i + n]))
            i += n
        }
        return out
    }

    private func appendCursor(at cx: CGFloat, y: CGFloat, into out: inout [Instance]) {
        let lh = layout.lineHeight
        var x = cx
        if !markedText.isEmpty {
            let marked = layout.shape(markedText)
            out.append(.rect(x, y, marked.width, lh, theme.background))
            appendGlyphs(marked, x: x, baseline: y + layout.baseline, into: &out) { _ in self.theme.text }
            out.append(.rect(x, y + lh - scale * 2, marked.width, scale, theme.text))
            x += marked.width
        }
        appendCaret(at: x, y: y, into: &out)
    }

    private func appendCaret(at x: CGFloat, y: CGFloat, into out: inout [Instance]) {
        if focused && cursorOn && x >= gutterWidth && x < textRight {
            out.append(.rect(x.rounded(), y, max(2, (1.5 * scale).rounded()), layout.lineHeight, theme.cursor))
        }
    }

    // minimap: satır başına 2pt, karakter başına 1pt blok
    private var minimapTop: Int {
        let rows = Int(drawableSize.height / minimapLine)
        guard lineCount > rows, maxScrollY > 0 else { return 0 }
        return Int(scrollY / maxScrollY * CGFloat(lineCount - rows))
    }

    private func appendMinimap(first: Int, last: Int, into out: inout [Instance]) {
        guard minimapWidth > 0 else { return }
        let x0 = textRight, h = drawableSize.height, mlh = minimapLine
        out.append(.rect(x0, 0, minimapWidth, h, theme.background))
        let top = minimapTop
        let bottom = min(lineCount - 1, top + Int(h / mlh))
        guard top <= bottom else { return }
        let spans = groupByLine(Array(editor.highlights(UInt(top), UInt(bottom))), stride: 4)
        let cw = scale, maxChars = Int((minimapWidth - 8 * scale) / cw)
        for i in top...bottom {
            let y = CGFloat(i - top) * mlh
            let chars = Array(editor.line(UInt(i)).toString().utf16.prefix(maxChars))
            let lineSpans = spans[i] ?? []
            var col = 0
            while col < chars.count {
                if chars[col] == 32 || chars[col] == 9 { col += 1; continue }
                let color = lineSpans.last(where: { col >= Int($0[1]) && col < Int($0[2]) }).map { theme.color(for: $0[3]) } ?? theme.text
                var end = col + 1
                while end < chars.count, chars[end] != 32, chars[end] != 9,
                      (lineSpans.last(where: { end >= Int($0[1]) && end < Int($0[2]) }).map { theme.color(for: $0[3]) } ?? theme.text) == color {
                    end += 1
                }
                out.append(.rect(x0 + 4 * scale + CGFloat(col) * cw, y, CGFloat(end - col) * cw, mlh * 0.75, color * 0.6))
                col = end
            }
        }
        let sliderY = CGFloat(first - top) * mlh
        out.append(.rect(x0, sliderY, minimapWidth, CGFloat(last - first + 1) * mlh, theme.scrollbar * 0.5))
    }

    private func scrollToMinimap(_ p: CGPoint) {
        let line = CGFloat(minimapTop) + p.y / minimapLine
        let visible = drawableSize.height / layout.lineHeight
        scrollY = (line - visible / 2) * layout.lineHeight
        clampScroll()
        needsDisplay = true
    }

    private var scrollbarThumb: (y: CGFloat, height: CGFloat)? {
        let h = drawableSize.height
        let content = maxScrollY + h
        guard content > h * 1.01 else { return nil }
        let height = max(20 * scale, h * h / content)
        let y = maxScrollY > 0 ? scrollY / maxScrollY * (h - height) : 0
        return (y, height)
    }

    private func appendScrollbar(into out: inout [Instance]) {
        guard let thumb = scrollbarThumb else { return }
        let w = drawableSize.width
        out.append(.rect(w - scrollbarWidth, thumb.y, scrollbarWidth, thumb.height, theme.scrollbar))
        let cursorY = CGFloat(editor.cursor_line()) / CGFloat(max(1, lineCount)) * drawableSize.height
        out.append(.rect(w - scrollbarWidth, cursorY, scrollbarWidth, max(2, scale), theme.cursor))
    }

    private func appendGlyphs(_ shaped: ShapedLine, x: CGFloat, baseline: CGFloat, into out: inout [Instance],
                              clip: Bool = true, color: (Int) -> SIMD4<Float>) {
        let width = clip ? textRight : drawableSize.width
        let minX = clip ? gutterWidth - layout.charWidth * 4 : -.greatestFiniteMagnitude
        let by = Float(baseline.rounded())
        for g in shaped.glyphs {
            let pen = (x + g.x).rounded()
            if pen > width || pen < minX { continue }
            let entry = renderer.atlas.entry(font: g.font, glyph: g.glyph)
            if entry.size.x == 0 { continue }
            out.append(Instance(
                pos: SIMD2(Float(pen) + entry.bearing.x, by + entry.bearing.y),
                size: entry.size, uv: entry.origin, uvSize: entry.size,
                color: color(g.index), mode: entry.isColor ? 2 : 1))
        }
    }

    // fare ve kaydırma

    private func pixelPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x * scale, y: p.y * scale)
    }

    private func position(at p: CGPoint) -> (line: Int, col: Int) {
        let line = min(max(0, Int((p.y + scrollY) / layout.lineHeight)), lineCount - 1)
        let col = shapedLine(line).index(at: p.x - textLeft + scrollX)
        return (line, col)
    }

    private func scrollToThumb(_ p: CGPoint, grab: CGFloat) {
        guard let thumb = scrollbarThumb else { return }
        let track = drawableSize.height - thumb.height
        guard track > 0 else { return }
        scrollY = (p.y - grab) / track * maxScrollY
        clampScroll()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = pixelPoint(event)
        if p.x >= textRight && p.x < drawableSize.width - scrollbarWidth {
            draggingMinimap = true
            return scrollToMinimap(p)
        }
        if p.x >= drawableSize.width - scrollbarWidth, let thumb = scrollbarThumb {
            let inside = p.y >= thumb.y && p.y <= thumb.y + thumb.height
            let grab = inside ? p.y - thumb.y : thumb.height / 2
            draggingScrollbar = grab
            scrollToThumb(p, grab: grab)
            return
        }
        inputContext?.discardMarkedText()
        markedText = ""
        let (line, col) = position(at: p)
        switch event.clickCount {
        case 2: editor.select_word(UInt(line), UInt(col))
        case 3...: editor.select_line(UInt(line))
        default:
            if event.modifierFlags.contains(.option) {
                editor.add_cursor(UInt(line), UInt(col))
            } else {
                editor.click(UInt(line), UInt(col), event.modifierFlags.contains(.shift))
            }
        }
        changed(edited: false)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = pixelPoint(event)
        if draggingMinimap { return scrollToMinimap(p) }
        if let grab = draggingScrollbar {
            return scrollToThumb(p, grab: grab)
        }
        let (line, col) = position(at: p)
        editor.click(UInt(line), UInt(col), true)
        changed(edited: false)
    }

    override func mouseUp(with event: NSEvent) {
        draggingScrollbar = nil
        draggingMinimap = false
    }

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= layout.lineHeight * 3 / scale
            dy *= layout.lineHeight * 3 / scale
        }
        if abs(dy) > abs(dx) * 2 { dx = 0 }
        scrollX -= dx * scale
        scrollY -= dy * scale
        clampScroll()
        needsDisplay = true
    }

    override func resetCursorRects() {
        let bar = 14.0
        addCursorRect(NSRect(x: 0, y: 0, width: max(0, bounds.width - bar), height: bounds.height), cursor: .iBeam)
        addCursorRect(NSRect(x: bounds.width - bar, y: 0, width: bar, height: bounds.height), cursor: .arrow)
    }

    // klavye

    override func keyDown(with event: NSEvent) {
        if inputContext?.handleEvent(event) != true {
            interpretKeyEvents([event])
        }
    }

    private static let motions: [String: (KernMotion, Bool)] = {
        let base: [(String, KernMotion)] = [
            ("moveLeft", .Left), ("moveRight", .Right), ("moveUp", .Up), ("moveDown", .Down),
            ("moveBackward", .Left), ("moveForward", .Right),
            ("moveWordLeft", .WordLeft), ("moveWordRight", .WordRight),
            ("moveWordBackward", .WordLeft), ("moveWordForward", .WordRight),
            ("moveToBeginningOfLine", .LineStart), ("moveToLeftEndOfLine", .LineStart),
            ("moveToEndOfLine", .LineEnd), ("moveToRightEndOfLine", .LineEnd),
            ("moveToBeginningOfParagraph", .LineStart), ("moveToEndOfParagraph", .LineEnd),
            ("moveToBeginningOfDocument", .DocStart), ("moveToEndOfDocument", .DocEnd),
            ("pageUp", .PageUp), ("pageDown", .PageDown),
            ("scrollPageUp", .PageUp), ("scrollPageDown", .PageDown),
        ]
        var map: [String: (KernMotion, Bool)] = [:]
        for (name, motion) in base {
            map[name + ":"] = (motion, false)
            map[name + "AndModifySelection:"] = (motion, true)
        }
        return map
    }()

    override func doCommand(by selector: Selector) {
        let name = NSStringFromSelector(selector)
        if let m = Self.motions[name] {
            editor.move_cursor(m.0, m.1)
            return changed(edited: false)
        }
        switch name {
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:": editor.delete_backward()
        case "deleteForward:": editor.delete_forward()
        case "deleteWordBackward:": editor.delete_word_backward()
        case "deleteWordForward:": editor.delete_word_forward()
        case "deleteToBeginningOfLine:": editor.delete_to_line_start()
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:": editor.insert_newline()
        case "insertTab:", "insertTabIgnoringFieldEditor:": editor.insert_tab()
        case "insertBacktab:": editor.indent_lines(false)
        case "cancelOperation:":
            if editor.has_selection() {
                editor.collapse_selection()
                return changed(edited: false)
            }
            (window?.windowController as? WorkbenchWindowController)?.hideFind()
            return
        case "scrollToBeginningOfDocument:":
            scrollY = 0
            needsDisplay = true
            return
        case "scrollToEndOfDocument:":
            scrollY = .greatestFiniteMagnitude
            needsDisplay = true
            return
        default:
            return
        }
        changed(edited: true)
    }

    // NSTextInputClient — koordinat alanı: imlecin bulunduğu satırın UTF-16 ofsetleri

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        if replacementRange.location != NSNotFound {
            let line = editor.cursor_line()
            editor.click(line, UInt(replacementRange.location), false)
            editor.click(line, UInt(NSMaxRange(replacementRange)), true)
            editor.insert_text(text)
        } else {
            editor.type_text(text)
        }
        changed(edited: true)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        needsDisplay = true
    }

    func unmarkText() {
        guard !markedText.isEmpty else { return }
        let text = markedText
        markedText = ""
        editor.insert_text(text)
        changed(edited: true)
    }

    func selectedRange() -> NSRange {
        let col = Int(editor.cursor_col())
        if editor.anchor_line() == editor.cursor_line() {
            let anchor = Int(editor.anchor_col())
            return NSRange(location: min(anchor, col), length: abs(anchor - col))
        }
        return NSRange(location: col, length: 0)
    }

    func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: Int(editor.cursor_col()), length: (markedText as NSString).length)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let line = editor.line(editor.cursor_line()).toString() as NSString
        let r = NSIntersectionRange(range, NSRange(location: 0, length: line.length))
        actualRange?.pointee = r
        return NSAttributedString(string: line.substring(with: r))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let line = Int(editor.cursor_line())
        let x = textLeft - scrollX + shapedLine(line).offset(range.location)
        let y = CGFloat(line) * layout.lineHeight - scrollY
        let local = NSRect(x: x / scale, y: y / scale, width: 1, height: layout.lineHeight / scale)
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // Edit menüsü

    @objc func undo(_ sender: Any?) {
        if editor.undo() { changed(edited: true) }
    }

    @objc func redo(_ sender: Any?) {
        if editor.redo() { changed(edited: true) }
    }

    @objc func copy(_ sender: Any?) {
        let text = editor.has_selection()
            ? editor.selected_text().toString()
            : editor.line(editor.cursor_line()).toString() + "\n"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        if editor.has_selection() { editor.delete_backward() } else { editor.delete_lines() }
        changed(edited: true)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        editor.insert_text(text)
        changed(edited: true)
    }

    override func selectAll(_ sender: Any?) {
        editor.select_all()
        changed(edited: false)
    }

    @objc func addCursorAbove(_ sender: Any?) {
        editor.add_cursor_vertical(true)
        changed(edited: false)
    }

    @objc func addCursorBelow(_ sender: Any?) {
        editor.add_cursor_vertical(false)
        changed(edited: false)
    }

    @objc func addNextOccurrence(_ sender: Any?) {
        editor.add_next_occurrence()
        changed(edited: false)
    }

    @objc func selectAllOccurrences(_ sender: Any?) {
        editor.select_all_occurrences()
        changed(edited: false)
    }

    @objc func toggleLineComment(_ sender: Any?) {
        editor.toggle_comment()
        changed(edited: true)
    }

    @objc func moveLineUp(_ sender: Any?) {
        editor.move_lines(true)
        changed(edited: true)
    }

    @objc func moveLineDown(_ sender: Any?) {
        editor.move_lines(false)
        changed(edited: true)
    }

    @objc func copyLineUp(_ sender: Any?) {
        editor.duplicate_lines(false)
        changed(edited: true)
    }

    @objc func copyLineDown(_ sender: Any?) {
        editor.duplicate_lines(true)
        changed(edited: true)
    }

    @objc func deleteLine(_ sender: Any?) {
        editor.delete_lines()
        changed(edited: true)
    }

    @objc func indentLines(_ sender: Any?) {
        editor.indent_lines(true)
        changed(edited: true)
    }

    @objc func outdentLines(_ sender: Any?) {
        editor.indent_lines(false)
        changed(edited: true)
    }

    func goTo(line: Int, col: Int, length: Int = 0) {
        editor.select_range(UInt(max(0, line)), UInt(max(0, col)), UInt(length))
        revealCursor(center: true)
        restartBlink()
        onChange?(false)
    }
}
