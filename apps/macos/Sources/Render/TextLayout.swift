import AppKit
import CoreText

struct ShapedGlyph {
    let font: Int
    let glyph: CGGlyph
    let x: CGFloat
    let index: Int  // UTF-16 karakter indeksi
}

final class ShapedLine {
    let line: CTLine
    let glyphs: [ShapedGlyph]
    let width: CGFloat

    init(line: CTLine, glyphs: [ShapedGlyph], width: CGFloat) {
        self.line = line
        self.glyphs = glyphs
        self.width = width
    }

    // UTF-16 sütunun x konumu
    func offset(_ col: Int) -> CGFloat {
        CTLineGetOffsetForStringIndex(line, col, nil)
    }

    func index(at x: CGFloat) -> Int {
        let i = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        return i == kCFNotFound ? 0 : i
    }
}

// tüm ölçüler piksel cinsinden (nokta × backing scale)
final class TextLayout {
    private(set) var font: CTFont
    private(set) var lineHeight: CGFloat = 0
    private(set) var baseline: CGFloat = 0
    private(set) var charWidth: CGFloat = 0
    private let atlas: GlyphAtlas
    private var attributes: [NSAttributedString.Key: Any] = [:]
    private var cache: [String: ShapedLine] = [:]

    init(atlas: GlyphAtlas, pointSize: CGFloat, scale: CGFloat) {
        self.atlas = atlas
        self.font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular) as CTFont
        configure(pointSize: pointSize, scale: scale)
    }

    func configure(pointSize: CGFloat, scale: CGFloat) {
        cache.removeAll()
        atlas.resetAll()
        let family = Settings.shared.string("editor.fontFamily")
        font = (family.isEmpty ? nil : NSFont(name: family, size: pointSize * scale))
            .map { $0 as CTFont } ?? NSFont.monospacedSystemFont(ofSize: pointSize * scale, weight: .regular) as CTFont
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        lineHeight = ceil((ascent + descent + leading) * 1.4)
        baseline = floor((lineHeight - ascent - descent) / 2 + ascent)

        var ch: UniChar = 0x30
        var glyph: CGGlyph = 0
        var advance = CGSize.zero
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        charWidth = advance.width

        let para = NSMutableParagraphStyle()
        para.tabStops = []
        para.defaultTabInterval = charWidth * 4
        attributes = [.font: font, .paragraphStyle: para]
    }

    func shape(_ text: String) -> ShapedLine {
        if let s = cache[text] { return s }
        if cache.count > 4000 { cache.removeAll() }

        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var glyphs: [ShapedGlyph] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
            let fid = atlas.fontId(runFont)
            var ids = [CGGlyph](repeating: 0, count: count)
            var pos = [CGPoint](repeating: .zero, count: count)
            var idx = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &ids)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &pos)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &idx)
            for i in 0..<count {
                glyphs.append(ShapedGlyph(font: fid, glyph: ids[i], x: pos[i].x, index: idx[i]))
            }
        }
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let shaped = ShapedLine(line: line, glyphs: glyphs, width: width)
        cache[text] = shaped
        return shaped
    }
}
