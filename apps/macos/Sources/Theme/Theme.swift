import AppKit
import simd

// Metal renkleri premultiplied RGBA; kern-syntax token sırasıyla aynı
struct Theme {
    var background: SIMD4<Float>
    var text: SIMD4<Float>
    var lineNumber: SIMD4<Float>
    var activeLineNumber: SIMD4<Float>
    var currentLineBorder: SIMD4<Float>
    var selection: SIMD4<Float>
    var inactiveSelection: SIMD4<Float>
    var cursor: SIMD4<Float>
    var indentGuide: SIMD4<Float>
    var bracketMatch: SIMD4<Float>
    var findMatch: SIMD4<Float>
    var scrollbar: SIMD4<Float>
    var syntax: [SIMD4<Float>]

    func color(for token: UInt32) -> SIMD4<Float> {
        token > 0 && Int(token) < syntax.count ? syntax[Int(token)] : text
    }

    static let dark = Theme(
        background: rgb(0x1F1F1F), text: rgb(0xCCCCCC),
        lineNumber: rgb(0x6E7681), activeLineNumber: rgb(0xCCCCCC),
        currentLineBorder: rgb(0x282828), selection: rgb(0x264F78), inactiveSelection: rgb(0x3A3D41),
        cursor: rgb(0xAEAFAD), indentGuide: rgb(0x404040), bracketMatch: rgb(0x888888, 0.35),
        findMatch: rgb(0x9E6A03, 0.55), scrollbar: rgb(0x797979, 0.4),
        syntax: [
            rgb(0xCCCCCC),  // none
            rgb(0x569CD6),  // keyword
            rgb(0xC586C0),  // control
            rgb(0xCE9178),  // string
            rgb(0x6A9955),  // comment
            rgb(0xDCDCAA),  // function
            rgb(0x4EC9B0),  // type
            rgb(0x9CDCFE),  // variable
            rgb(0xB5CEA8),  // number
            rgb(0x4FC1FF),  // constant
            rgb(0x9CDCFE),  // property
            rgb(0xD4D4D4),  // operator
            rgb(0xCCCCCC),  // punctuation
            rgb(0x9CDCFE),  // attribute
            rgb(0x569CD6),  // tag
            rgb(0xD7BA7D),  // escape
            rgb(0x4EC9B0),  // module
        ])
}

// arayüz renkleri (VS Code Dark Modern)
enum Palette {
    static let editor = NSColor(hex: 0x1F1F1F)
    static let chrome = NSColor(hex: 0x181818)
    static let border = NSColor(hex: 0x2B2B2B)
    static let text = NSColor(hex: 0xCCCCCC)
    static let dimText = NSColor(hex: 0x9D9D9D)
    static let brightText = NSColor.white
    static let accent = NSColor(hex: 0x0078D4)
    static let icon = NSColor(hex: 0x868686)
    static let hover = NSColor(hex: 0x2A2D2E)
    static let selection = NSColor(hex: 0x04395E)
    static let input = NSColor(hex: 0x313131)
    static let inputBorder = NSColor(hex: 0x3C3C3C)
    static let widget = NSColor(hex: 0x252526)
    static let match = NSColor(hex: 0x2AAAFF)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

private func rgb(_ hex: UInt32, _ a: Float = 1) -> SIMD4<Float> {
    let r = Float((hex >> 16) & 0xFF) / 255, g = Float((hex >> 8) & 0xFF) / 255, b = Float(hex & 0xFF) / 255
    return SIMD4(r * a, g * a, b * a, a)
}
