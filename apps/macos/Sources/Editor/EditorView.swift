import AppKit
import MetalKit

final class EditorView: MTKView, MTKViewDelegate, NSTextInputClient {
    let editor: KernEditor
    var onChange: ((_ edited: Bool) -> Void)?
    var findQuery = "" { didSet { needsDisplay = true } }
    var findFlags: UInt8 = 0 { didSet { needsDisplay = true } }

    private let renderer: Renderer
    private let layout: TextLayout
    private var pointSize: CGFloat { Self.fontSize }
    private var theme = Theme.dark

    // ayar + yakınlaştırma farkı
    static var fontSize: CGFloat {
        min(max(6, CGFloat(Settings.shared.double("editor.fontSize")) + CGFloat(UserDefaults.standard.double(forKey: "zoomDelta"))), 40)
    }
    private static let fontSizeChanged = Notification.Name("KernEditorFontSizeChanged")

    static func setFontSize(_ size: CGFloat) {
        let base = CGFloat(Settings.shared.double("editor.fontSize"))
        UserDefaults.standard.set(Double(min(max(6, size), 40) - base), forKey: "zoomDelta")
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
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.layout.configure(pointSize: self.pointSize, scale: self.scale)
            self.mtkView(self, drawableSizeWillChange: self.drawableSize)
            self.mapDirty = true
            self.scrollX = 0
            self.revealCursor()
            self.needsDisplay = true
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    deinit { blinkTimer?.invalidate() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    var onFocus: (() -> Void)?

    // dil özellikleri
    var diagnostics: [Diagnostic] = [] { didSet { needsDisplay = true } }
    var ghostText: String? { didSet { if oldValue != ghostText { needsDisplay = true } } }
    // git: satır → 'A'/'M'/'D'; çakışma: satır → 0 işaret, 1 mevcut, 2 gelen
    var gitMarks: [Int: Character] = [:] { didSet { needsDisplay = true } }
    var conflictLines: [Int: Int] = [:] { didSet { needsDisplay = true } }
    // hata ayıklama: kesme noktası satırları ve duran satır (0 tabanlı)
    var breakpointLines: Set<Int> = [] { didSet { if oldValue != breakpointLines { needsDisplay = true } } }
    var stoppedLine: Int? { didSet { if oldValue != stoppedLine { needsDisplay = true } } }
    var onToggleBreakpoint: ((Int) -> Void)?
    var keyInterceptor: ((String) -> Bool)?
    var onTyped: ((String) -> Void)?
    var onHover: ((Int, Int, NSPoint) -> Void)?
    var onHoverEnd: (() -> Void)?
    var onCommandClick: ((Int, Int) -> Void)?
    private var hoverTimer: Timer?

    var fontLineHeight: CGFloat { layout.lineHeight / scale }

    // imlecin altındaki nokta (görünüm koordinatı, pt)
    func caretPoint() -> NSPoint {
        let line = Int(editor.cursor_line()), col = Int(editor.cursor_col())
        let shaped = shapedLine(line)
        let segs = segments(line)
        let s = segs[segs.lastIndex { $0 <= col } ?? 0]
        let x = textLeft - scrollX + shaped.offset(col) - shaped.offset(s)
        let y = CGFloat(rowOf(line: line, col: col) + 1) * layout.lineHeight - scrollY
        return NSPoint(x: x / scale, y: y / scale)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverTimer?.invalidate()
        onHoverEnd?()
        let p = pixelPoint(event)
        guard p.x > textLeft, p.x < textRight else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            let (line, col) = self.position(at: p)
            // satır sonundan sonra değil, metnin üzerinde
            let shaped = self.shapedLine(line)
            let segs = self.segments(line)
            let x = p.x - self.textLeft + self.scrollX + shaped.offset(segs[0])
            guard x <= shaped.width + self.layout.charWidth else { return }
            self.onHover?(line, col, NSPoint(x: p.x / self.scale, y: p.y / self.scale))
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate()
    }

    override func becomeFirstResponder() -> Bool {
        focused = true
        onFocus?()
        restartBlink()
        return true
    }

    override func resignFirstResponder() -> Bool {
        focused = false
        blinkTimer?.invalidate()
        needsDisplay = true
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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
    private var minimapWidth: CGFloat { lineCount > 1 && Settings.shared.bool("editor.minimap") ? 90 * scale : 0 }
    private var minimapLine: CGFloat { 2 * scale }
    private var textRight: CGFloat { drawableSize.width - minimapWidth }

    private func shapedLine(_ i: Int) -> ShapedLine {
        layout.shape(editor.line(UInt(i)).toString())
    }

    private var maxScrollY: CGFloat {
        max(0, CGFloat(totalRows - 1) * layout.lineHeight)
    }

    var topLine: Int {
        get { lineAt(Int(scrollY / max(1, layout.lineHeight))).line }
        set {
            rebuildMapIfNeeded()
            scrollY = CGFloat(rowOf(line: max(0, newValue))) * layout.lineHeight
            clampScroll()
            needsDisplay = true
        }
    }

    private func clampScroll() {
        let maxX = wrapOn ? 0 : max(0, contentWidth - (textRight - textLeft) + layout.charWidth * 4)
        scrollY = min(max(0, scrollY), maxScrollY)
        scrollX = min(max(0, scrollX), maxX)
    }

    func revealCursor(center: Bool = false) {
        let lh = layout.lineHeight
        let height = drawableSize.height
        guard height > 0 else { return }
        rebuildMapIfNeeded()
        let top = CGFloat(rowOf(line: Int(editor.cursor_line()), col: Int(editor.cursor_col()))) * lh
        if center {
            scrollY = top - height / 3
        } else if top < scrollY {
            scrollY = top
        } else if top + lh > scrollY + height {
            scrollY = top + lh - height
        }
        guard !wrapOn else { scrollX = 0; return clampScroll() }
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

    private var lastCursorLine = 0
    private var lastLineCount = -1

    func changed(edited: Bool) {
        if edited {
            // düzenleme noktasından sonraki katlamaları satır farkı kadar kaydır
            let delta = lineCount - (lastLineCount < 0 ? lineCount : lastLineCount)
            if delta != 0 {
                let pivot = min(lastCursorLine, Int(editor.cursor_line()))
                folds = Dictionary(uniqueKeysWithValues: folds.map { s, e in s > pivot ? (s + delta, e + delta) : (s, e) })
            }
            mapDirty = true
        }
        goalX = nil
        revealFolded()
        lastCursorLine = Int(editor.cursor_line())
        lastLineCount = lineCount
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
        theme = Theme.for(effectiveAppearance)
        let size = drawableSize
        let lh = layout.lineHeight
        rebuildMapIfNeeded()
        clampScroll()

        let firstRow = max(0, Int(scrollY / lh))
        let lastRow = min(totalRows - 1, Int((scrollY + size.height) / lh))
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
        guard firstRow <= lastRow else {
            return renderer.render(front, in: self, clear: theme.background)
        }
        let first = lineAt(firstRow).line, last = lineAt(lastRow).line

        let spans = groupByLine(Array(editor.highlights(UInt(first), UInt(last))), stride: 4)
        // büyük dosya: ilk renklendirme arka planda bitince tekrar çiz
        if editor.syntax_pending() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.needsDisplay = true }
        }
        let matches = findQuery.isEmpty ? [:] : groupByLine(
            Array(editor.find_in_lines(findQuery, findFlags, UInt(first), UInt(last))), stride: 3)
        let bracket = Array(editor.matching_bracket())
        let hair = max(1, scale.rounded())
        var guideIndent = 0
        var shapedCache: [Int: (String, ShapedLine, [Int])] = [:]
        let cursorRow = rowOf(line: cursorLine, col: cursorCol)

        for row in firstRow...lastRow {
            let (i, sub) = lineAt(row)
            let y = CGFloat(row) * lh - scrollY
            if shapedCache[i] == nil {
                let str = editor.line(UInt(i)).toString()
                shapedCache[i] = (str, layout.shape(str), segments(i))
            }
            let (str, shaped, segs) = shapedCache[i]!
            let segStart = segs[sub]
            let isLast = sub == segs.count - 1
            let segEnd = isLast ? Int.max : segs[sub + 1]
            let shift = shaped.offset(segStart)
            let len16 = (str as NSString).length
            widest = max(widest, shaped.width)
            // satır içi sütunun bu parçadaki x'i
            func colX(_ c: Int) -> CGFloat { x0 + shaped.offset(min(c, segEnd, len16)) - shift }

            if row == cursorRow && !hasSelection {
                back.append(.rect(0, y, size.width, hair, theme.currentLineBorder))
                back.append(.rect(0, y + lh - hair, size.width, hair, theme.currentLineBorder))
            }

            // girinti çizgileri
            let indent = str.prefix(while: { $0 == " " || $0 == "\t" })
            let level = str.trimmingCharacters(in: .whitespaces).isEmpty ? guideIndent : indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 4
            guideIndent = level
            if sub == 0 {
                for g in 0..<level {
                    let gx = (x0 + CGFloat(g * 4) * layout.charWidth).rounded()
                    if gx >= gutter { back.append(.rect(gx, y, hair, lh, theme.indentGuide)) }
                }
            }

            if let c = conflictLines[i] {
                back.append(.rect(gutter, y, size.width - gutter, lh, c == 2 ? theme.conflictIncoming : theme.conflictCurrent))
            }

            // duran satır vurgusu
            if i == stoppedLine {
                back.append(.rect(gutter, y, size.width - gutter, lh, theme.stoppedLine))
            }

            for m in matches[i] ?? [] {
                let ms = Int(m[1]), me = Int(m[2])
                guard me > segStart, ms < segEnd else { continue }
                let a = colX(max(ms, segStart)), b = colX(me)
                back.append(.rect(a, y, b - a, lh, theme.findMatch))
            }
            for (s, e) in ranges where i >= s.0 && i <= e.0 {
                let lo = max(i == s.0 ? s.1 : 0, segStart)
                let hiCol = i == e.0 ? e.1 : Int.max
                guard hiCol > segStart, lo < segEnd || (isLast && hiCol == .max) else { continue }
                let a = colX(lo)
                let b = hiCol == .max ? (isLast ? colX(len16) + layout.charWidth : colX(segEnd)) : colX(hiCol)
                if b > a { back.append(.rect(a, y, b - a, lh, focused ? theme.selection : theme.inactiveSelection)) }
            }
            // tanı alt çizgileri
            for d in diagnostics where i >= d.line && i <= d.endLine {
                let dStart = i == d.line ? d.col : 0
                var dEnd = i == d.endLine ? d.endCol : len16
                if dEnd <= dStart { dEnd = dStart + 1 }
                guard dEnd > segStart, dStart < segEnd || isLast else { continue }
                let a = colX(max(dStart, segStart))
                let b = max(colX(dEnd), a + layout.charWidth * 0.8)
                let color = d.severity == 1 ? theme.error : (d.severity == 2 ? theme.warning : theme.info)
                let t = max(1, scale.rounded())
                // dalgalı çizgi: kısa kaymalı parçalar
                var x = a, up = false
                while x < b {
                    let w = min(2 * scale, b - x)
                    front.append(.rect(x, y + lh - (up ? 3 : 2) * t, w, t, color))
                    x += w
                    up.toggle()
                }
            }
            if bracket.count == 4 {
                for (bl, bc) in [(Int(bracket[0]), Int(bracket[1])), (Int(bracket[2]), Int(bracket[3]))]
                    where bl == i && bc >= segStart && bc < segEnd {
                    let a = colX(bc), b = colX(bc + 1)
                    back.append(.rect(a, y, b - a, lh, theme.bracketMatch))
                }
            }

            let lineSpans = spans[i] ?? []
            appendGlyphs(shaped, x: x0 - shift, baseline: y + layout.baseline, into: &text, range: segStart..<segEnd) { idx in
                for sp in lineSpans.reversed() where idx >= Int(sp[1]) && idx < Int(sp[2]) {
                    return self.theme.color(for: sp[3])
                }
                return self.theme.text
            }

            if sub == 0 {
                let number = layout.shape(String(i + 1))
                let color = i == cursorLine ? theme.activeLineNumber : theme.lineNumber
                appendGlyphs(number, x: gutter - layout.charWidth * 2.6 - number.width,
                             baseline: y + layout.baseline, into: &front, clip: false) { _ in color }
                if foldRanges[i] != nil {
                    let mark = layout.shape(folds[i] != nil ? "›" : "⌄")
                    appendGlyphs(mark, x: gutter - layout.charWidth * 1.6, baseline: y + layout.baseline,
                                 into: &front, clip: false) { _ in self.theme.lineNumber }
                }
                // kesme noktası ve duran satır işareti
                if i == stoppedLine {
                    let arrow = layout.shape("▶")
                    appendGlyphs(arrow, x: layout.charWidth * 0.2, baseline: y + layout.baseline, into: &front, clip: false) { _ in
                        self.theme.stoppedArrow
                    }
                } else if breakpointLines.contains(i) {
                    let dot = layout.shape("●")
                    appendGlyphs(dot, x: layout.charWidth * 0.2, baseline: y + layout.baseline, into: &front, clip: false) { _ in
                        self.theme.breakpoint
                    }
                }
            }
            // git gutter işareti
            if let k = gitMarks[i] {
                let gx = gutter - layout.charWidth * 2.3, bw = 3 * hair
                if k == "D" {
                    front.append(.rect(gx, y - 2 * hair, bw * 2, 4 * hair, theme.gitDeleted))
                } else {
                    front.append(.rect(gx, y, bw, lh, k == "A" ? theme.gitAdded : theme.gitModified))
                }
            }
            if isLast, folds[i] != nil {
                let dots = layout.shape(" ⋯ ")
                let fx = colX(len16) + layout.charWidth
                back.append(.rect(fx, y + hair * 2, dots.width, lh - hair * 4, theme.findMatch))
                appendGlyphs(dots, x: fx, baseline: y + layout.baseline, into: &text) { _ in self.theme.lineNumber }
            }

            // satır içi AI önerisi (ilk satırı imleçten sonra soluk)
            if let ghost = ghostText, i == cursorLine, cursorCol >= segStart, cursorCol < segEnd || isLast {
                let first = ghost.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                let shown = first + (ghost.contains("\n") ? " …" : "")
                let g = layout.shape(shown)
                appendGlyphs(g, x: colX(cursorCol), baseline: y + layout.baseline, into: &front) { _ in self.theme.lineNumber }
            }
            for h in heads where h.0 == i && h.1 >= segStart && (h.1 < segEnd || isLast) {
                if h.0 == cursorLine && h.1 == cursorCol {
                    appendCursor(at: colX(cursorCol), y: y, into: &front)
                } else {
                    appendCaret(at: colX(h.1), y: y, into: &front)
                }
            }
        }
        contentWidth = wrapOn ? 0 : widest
        appendMinimap(first: first, last: last, into: &front)
        appendScrollbar(into: &front)

        if renderer.atlas.consumeOverflow() {
            DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
        }
        renderer.render(back + text + front, in: self, clear: theme.background)
    }

    // görüntü satırları: sarma + katlama

    static var wordWrap: Bool { Settings.shared.bool("editor.wordWrap") }
    private static let wrapMaxBytes = 5 * 1024 * 1024
    private static let foldMaxLines = 200_000

    static func setWordWrap(_ on: Bool) {
        Settings.shared.set("editor.wordWrap", on)
    }

    private var wrapOn: Bool { Self.wordWrap && editor.byte_len() <= Self.wrapMaxBytes }
    private(set) var folds: [Int: Int] = [:]        // kapalı katlamalar: başlangıç → son
    private var foldRanges: [Int: Int] = [:]   // katlanabilir aralıklar
    private var rowStart: [Int]? = nil         // nil = satır başına bir görüntü satırı
    private var mapVersion: UInt64 = .max
    private var mapCols = -1
    private var mapLines = -1
    private var mapDirty = true
    private var segmentCache: [Int: [Int]] = [:]
    private var goalX: CGFloat?

    private var wrapCols: Int { max(20, Int((textRight - textLeft) / max(1, layout.charWidth)) - 1) }

    func rebuildMapIfNeeded() {
        let version = editor.version()
        let cols = wrapOn ? wrapCols : 0
        guard mapDirty || version != mapVersion || cols != mapCols || lineCount != mapLines else { return }
        if version != mapVersion || lineCount != mapLines {
            foldRanges = [:]
            if lineCount <= Self.foldMaxLines {
                let flat = Array(editor.fold_ranges())
                var j = 0
                while j + 2 <= flat.count { foldRanges[Int(flat[j])] = Int(flat[j + 1]); j += 2 }
            }
            folds = Dictionary(uniqueKeysWithValues: folds.keys.compactMap { s in foldRanges[s].map { (s, $0) } })
        }
        mapDirty = false
        mapVersion = version
        mapCols = cols
        mapLines = lineCount
        segmentCache = [:]
        guard cols > 0 || !folds.isEmpty else { rowStart = nil; return }
        var counts = cols > 0 ? Array(editor.wrap_rows(UInt(cols))).map(Int.init) : Array(repeating: 1, count: lineCount)
        for (s, e) in folds where e < counts.count && s < e {
            for l in (s + 1)...e { counts[l] = 0 }
        }
        var starts = [Int](repeating: 0, count: counts.count + 1)
        for (i, c) in counts.enumerated() { starts[i + 1] = starts[i] + c }
        rowStart = starts
    }

    var totalRows: Int { rowStart?.last ?? lineCount }

    private func segments(_ line: Int) -> [Int] {
        guard wrapOn else { return [0] }
        if let s = segmentCache[line] { return s }
        let s = [0] + Array(editor.wrap_breaks(UInt(line), UInt(mapCols))).map(Int.init)
        segmentCache[line] = s
        return s
    }

    private func lineAt(_ row: Int) -> (line: Int, sub: Int) {
        guard let starts = rowStart else { return (min(max(0, row), lineCount - 1), 0) }
        let row = min(max(0, row), max(0, totalRows - 1))
        var lo = 0, hi = lineCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= row { lo = mid } else { hi = mid - 1 }
        }
        return (lo, row - starts[lo])
    }

    private func rowOf(line: Int, col: Int = 0) -> Int {
        guard let starts = rowStart else { return line }
        let line = min(max(0, line), lineCount - 1)
        let segs = segments(line)
        let sub = max(0, (segs.lastIndex { $0 <= col } ?? 0))
        return starts[line] + min(sub, max(0, starts[line + 1] - starts[line] - 1))
    }

    private func foldAt(_ line: Int) -> Int? {
        foldRanges.filter { $0.key <= line && $0.value >= line }.max { $0.key < $1.key }?.key
    }

    func fold(line: Int? = nil) {
        rebuildMapIfNeeded()
        guard let s = foldAt(line ?? Int(editor.cursor_line())), let e = foldRanges[s] else { return }
        folds[s] = e
        if Int(editor.cursor_line()) > s { editor.click(UInt(s), 0, false) }
        mapDirty = true
        changed(edited: false)
    }

    func unfold(line: Int? = nil) {
        let l = line ?? Int(editor.cursor_line())
        let hit = folds.filter { $0.key <= l && $0.value >= l }.map(\.key)
        guard !hit.isEmpty else { return }
        hit.forEach { folds[$0] = nil }
        mapDirty = true
        needsDisplay = true
    }

    func foldAll() {
        rebuildMapIfNeeded()
        folds = foldRanges
        let l = Int(editor.cursor_line())
        if let s = folds.filter({ $0.key < l && $0.value >= l }).map(\.key).min() { editor.click(UInt(s), 0, false) }
        mapDirty = true
        changed(edited: false)
    }

    func unfoldAll() {
        folds = [:]
        mapDirty = true
        needsDisplay = true
    }

    // imleç gizli satıra girerse aç
    private func revealFolded() {
        let l = Int(editor.cursor_line())
        let hit = folds.filter { $0.key < l && $0.value >= l }.map(\.key)
        guard !hit.isEmpty else { return }
        hit.forEach { folds[$0] = nil }
        mapDirty = true
    }

    // sarma/katlama açıkken yukarı-aşağı görüntü satırına göre
    private func verticalMove(_ delta: Int, extend: Bool) -> Bool {
        guard rowStart != nil, editor.selections().count == 4 else { return false }
        rebuildMapIfNeeded()
        let line = Int(editor.cursor_line()), col = Int(editor.cursor_col())
        let row = rowOf(line: line, col: col)
        let shaped = shapedLine(line)
        let segs = segments(line)
        let segStart = segs[segs.lastIndex { $0 <= col } ?? 0]
        let x = goalX ?? (shaped.offset(col) - shaped.offset(segStart))
        let target = row + delta
        guard target >= 0, target < totalRows else {
            editor.move_cursor(delta < 0 ? .DocStart : .DocEnd, extend)
            return true
        }
        let (tl, sub) = lineAt(target)
        let tShaped = shapedLine(tl)
        let tSegs = segments(tl)
        let s = tSegs[min(sub, tSegs.count - 1)]
        var c = tShaped.index(at: x + tShaped.offset(s))
        if sub + 1 < tSegs.count { c = min(c, tSegs[sub + 1] - 1) }
        editor.click(UInt(tl), UInt(max(s, c)), extend)
        goalX = x
        return true
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
        let line = Int(CGFloat(minimapTop) + p.y / minimapLine)
        let visible = drawableSize.height / layout.lineHeight
        scrollY = (CGFloat(rowOf(line: line)) - visible / 2) * layout.lineHeight
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
        let cursorY = CGFloat(rowOf(line: Int(editor.cursor_line()))) / CGFloat(max(1, totalRows)) * drawableSize.height
        out.append(.rect(w - scrollbarWidth, cursorY, scrollbarWidth, max(2, scale), theme.cursor))
    }

    private func appendGlyphs(_ shaped: ShapedLine, x: CGFloat, baseline: CGFloat, into out: inout [Instance],
                              clip: Bool = true, range: Range<Int>? = nil, color: (Int) -> SIMD4<Float>) {
        let width = clip ? textRight : drawableSize.width
        let minX = clip ? gutterWidth - layout.charWidth * 4 : -.greatestFiniteMagnitude
        let by = Float(baseline.rounded())
        for g in shaped.glyphs {
            if let range, !range.contains(g.index) { continue }
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
        rebuildMapIfNeeded()
        let (line, sub) = lineAt(Int((p.y + scrollY) / layout.lineHeight))
        let shaped = shapedLine(line)
        let segs = segments(line)
        let s = segs[min(sub, segs.count - 1)]
        var col = shaped.index(at: p.x - textLeft + scrollX + shaped.offset(s))
        if sub + 1 < segs.count { col = min(col, segs[sub + 1] - 1) }
        return (line, max(s, col))
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
        // gutter'ın en solu: kesme noktası
        if p.x < layout.charWidth * 1.6, let toggle = onToggleBreakpoint {
            return toggle(line)
        }
        if p.x < gutterWidth && p.x > gutterWidth - layout.charWidth * 2.2 && foldRanges[line] != nil {
            if folds[line] != nil { unfold(line: line) } else { fold(line: line) }
            return
        }
        if event.modifierFlags.contains(.command), event.clickCount == 1, let go = onCommandClick {
            editor.click(UInt(line), UInt(col), false)
            changed(edited: false)
            return go(line, col)
        }
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
        if let k = keyInterceptor, k(name) { return }
        if let m = Self.motions[name] {
            if m.0 == .Up || m.0 == .Down {
                let keep = goalX
                if verticalMove(m.0 == .Up ? -1 : 1, extend: m.1) {
                    let g = goalX
                    changed(edited: false)
                    goalX = g ?? keep
                    return
                }
            }
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
        onTyped?(text)
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
        let shaped = shapedLine(line)
        let segs = segments(line)
        let s = segs[segs.lastIndex { $0 <= range.location } ?? 0]
        let x = textLeft - scrollX + shaped.offset(range.location) - shaped.offset(s)
        let y = CGFloat(rowOf(line: line, col: range.location)) * layout.lineHeight - scrollY
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

    @objc func toggleWordWrap(_ sender: Any?) { Self.setWordWrap(!Self.wordWrap) }
    @objc func foldRegion(_ sender: Any?) { fold() }
    @objc func unfoldRegion(_ sender: Any?) { unfold() }
    @objc func foldAllRegions(_ sender: Any?) { foldAll() }
    @objc func unfoldAllRegions(_ sender: Any?) { unfoldAll() }

    func goTo(line: Int, col: Int, length: Int = 0) {
        editor.select_range(UInt(max(0, line)), UInt(max(0, col)), UInt(length))
        revealCursor(center: true)
        restartBlink()
        onChange?(false)
    }
}

// VoiceOver: düzenlenebilir metin alanı (konum hesapları UTF-16)
extension EditorView {
    private var axText: NSString { editor.text().toString() as NSString }

    // satır başlangıçlarının UTF-16 ofsetleri
    private func lineStarts(_ text: NSString) -> [Int] {
        var starts = [0]
        var i = 0
        while i < text.length {
            if text.character(at: i) == 10 { starts.append(i + 1) }
            i += 1
        }
        return starts
    }

    private func offset(line: Int, col: Int, in text: NSString) -> Int {
        let starts = lineStarts(text)
        guard line >= 0, line < starts.count else { return text.length }
        return min(starts[line] + col, text.length)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? {
        let path = editor.path().toString()
        return path.isEmpty ? "Untitled editor" : (path as NSString).lastPathComponent
    }
    override func accessibilityHelp() -> String? { editor.language().toString() }
    override func accessibilityValue() -> Any? { axText as String }
    override func accessibilityNumberOfCharacters() -> Int { axText.length }
    override func accessibilitySelectedText() -> String? { editor.selected_text().toString() }
    override func accessibilityInsertionPointLineNumber() -> Int { Int(editor.cursor_line()) }

    override func accessibilitySelectedTextRange() -> NSRange {
        let text = axText
        let start = offset(line: Int(editor.anchor_line()), col: Int(editor.anchor_col()), in: text)
        let end = offset(line: Int(editor.cursor_line()), col: Int(editor.cursor_col()), in: text)
        return NSRange(location: min(start, end), length: abs(end - start))
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        let text = axText
        let starts = lineStarts(text)
        let line = (starts.lastIndex { $0 <= range.location }) ?? 0
        goTo(line: line, col: range.location - starts[line], length: range.length)
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let text = axText
        return text.substring(with: NSIntersectionRange(range, NSRange(location: 0, length: text.length)))
    }

    override func accessibilityLine(for index: Int) -> Int {
        (lineStarts(axText).lastIndex { $0 <= index }) ?? 0
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        let text = axText
        let starts = lineStarts(text)
        guard line >= 0, line < starts.count else { return NSRange(location: 0, length: 0) }
        let end = line + 1 < starts.count ? starts[line + 1] : text.length
        return NSRange(location: starts[line], length: end - starts[line])
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        let text = axText
        let starts = lineStarts(text)
        let first = min(max(0, topLine), starts.count - 1)
        let lastRow = min(starts.count - 1, first + Int(drawableSize.height / max(1, layout.lineHeight)))
        let end = lastRow + 1 < starts.count ? starts[lastRow + 1] : text.length
        return NSRange(location: starts[first], length: max(0, end - starts[first]))
    }
}
