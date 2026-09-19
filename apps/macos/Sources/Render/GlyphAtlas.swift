import CoreGraphics
import CoreText
import Metal
import simd

struct GlyphEntry {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var bearing: SIMD2<Float>  // kalem noktasından quad sol-üst köşesine (y aşağı)
    var isColor: Bool

    static let empty = GlyphEntry(origin: .zero, size: .zero, bearing: .zero, isColor: false)
}

final class GlyphAtlas {
    let texture: MTLTexture
    private(set) var overflowed = false
    private let dim = 2048
    private var entries: [Key: GlyphEntry] = [:]
    private var fonts: [CTFont] = []
    private var fontIds: [String: Int] = [:]
    private var x = 0, y = 0, rowHeight = 0
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private struct Key: Hashable {
        let font: Int
        let glyph: CGGlyph
    }

    init?(device: MTLDevice) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: dim, height: dim, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        self.texture = texture
    }

    func fontId(_ font: CTFont) -> Int {
        let key = "\(CTFontCopyPostScriptName(font))@\(CTFontGetSize(font))"
        if let id = fontIds[key] { return id }
        fonts.append(font)
        fontIds[key] = fonts.count - 1
        return fonts.count - 1
    }

    // ölçek değişince font id'leri de geçersiz olur
    func resetAll() {
        clear()
        fonts.removeAll()
        fontIds.removeAll()
    }

    func consumeOverflow() -> Bool {
        defer { overflowed = false }
        return overflowed
    }

    func entry(font: Int, glyph: CGGlyph) -> GlyphEntry {
        let key = Key(font: font, glyph: glyph)
        if let e = entries[key] { return e }
        let e = rasterize(fonts[font], glyph)
        entries[key] = e
        return e
    }

    private func clear() {
        entries.removeAll()
        x = 0
        y = 0
        rowHeight = 0
    }

    private func rasterize(_ font: CTFont, _ glyph: CGGlyph) -> GlyphEntry {
        var g = glyph
        let rect = CTFontGetBoundingRectsForGlyphs(font, .default, &g, nil, 1)
        if rect.isNull || rect.isEmpty { return .empty }
        let x0 = floor(rect.minX) - 1, y0 = floor(rect.minY) - 1
        let x1 = ceil(rect.maxX) + 1, y1 = ceil(rect.maxY) + 1
        let w = Int(x1 - x0), h = Int(y1 - y0)
        guard w > 0, h > 0, w < dim, h < dim else { return .empty }

        if x + w > dim {
            x = 0
            y += rowHeight
            rowHeight = 0
        }
        if y + h > dim {
            clear()
            overflowed = true
        }

        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return .empty }
        ctx.setAllowsFontSmoothing(false)
        ctx.setAllowsFontSubpixelPositioning(false)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        var pos = CGPoint(x: -x0, y: -y0)
        CTFontDrawGlyphs(font, &g, &pos, 1, ctx)
        guard let data = ctx.data else { return .empty }
        texture.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)

        let isColor = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
        let e = GlyphEntry(
            origin: SIMD2(Float(x), Float(y)), size: SIMD2(Float(w), Float(h)),
            bearing: SIMD2(Float(x0), Float(-y1)), isColor: isColor)
        x += w + 1
        rowHeight = max(rowHeight, h + 1)
        return e
    }
}
