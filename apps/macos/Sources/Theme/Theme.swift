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
    var error = rgb(0xF14C4C)
    var warning = rgb(0xCCA700)
    var info = rgb(0x3794FF)
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

    static let light = Theme(
        background: rgb(0xFFFFFF), text: rgb(0x3B3B3B),
        lineNumber: rgb(0x6E7681), activeLineNumber: rgb(0x171184),
        currentLineBorder: rgb(0xEEEEEE), selection: rgb(0xADD6FF), inactiveSelection: rgb(0xE5EBF1),
        cursor: rgb(0x000000), indentGuide: rgb(0xD3D3D3), bracketMatch: rgb(0x0064C8, 0.18),
        findMatch: rgb(0xF6B94D, 0.6), scrollbar: rgb(0x646464, 0.35),
        syntax: [
            rgb(0x3B3B3B),  // none
            rgb(0x0000FF),  // keyword
            rgb(0xAF00DB),  // control
            rgb(0xA31515),  // string
            rgb(0x008000),  // comment
            rgb(0x795E26),  // function
            rgb(0x267F99),  // type
            rgb(0x001080),  // variable
            rgb(0x098658),  // number
            rgb(0x0070C1),  // constant
            rgb(0x001080),  // property
            rgb(0x000000),  // operator
            rgb(0x3B3B3B),  // punctuation
            rgb(0xE50000),  // attribute
            rgb(0x800000),  // tag
            rgb(0xEE0000),  // escape
            rgb(0x267F99),  // module
        ])

    static func `for`(_ appearance: NSAppearance) -> Theme {
        if let t = Extensions.shared.theme(named: Settings.shared.string("workbench.colorTheme")) { return custom(t) }
        return appearance.isLight ? .light : .dark
    }

    static let tokenNames = ["none", "keyword", "control", "string", "comment", "function", "type", "variable", "number",
                             "constant", "property", "operator", "punctuation", "attribute", "tag", "escape", "module"]
    static var customCache: (String, Theme)?

    // eklenti teması: temel koyu/açık tema üzerine renkler; "#RRGGBB" ya da "#RRGGBBAA"
    static func custom(_ json: [String: Any]) -> Theme {
        let name = json["name"] as? String ?? ""
        if let c = customCache, c.0 == name { return c.1 }
        var t: Theme = json["type"] as? String == "light" ? .light : .dark
        func color(_ v: Any?) -> SIMD4<Float>? {
            guard var s = v as? String, s.hasPrefix("#") else { return nil }
            s.removeFirst()
            guard s.count == 6 || s.count == 8, let n = UInt32(s, radix: 16) else { return nil }
            return s.count == 6 ? rgb(n) : rgb(n >> 8, Float(n & 0xFF) / 255)
        }
        let colors = json["colors"] as? [String: Any] ?? [:]
        let map: [(String, WritableKeyPath<Theme, SIMD4<Float>>)] = [
            ("background", \.background), ("text", \.text), ("lineNumber", \.lineNumber), ("activeLineNumber", \.activeLineNumber),
            ("currentLineBorder", \.currentLineBorder), ("selection", \.selection), ("inactiveSelection", \.inactiveSelection),
            ("cursor", \.cursor), ("indentGuide", \.indentGuide), ("bracketMatch", \.bracketMatch), ("findMatch", \.findMatch),
            ("scrollbar", \.scrollbar),
        ]
        for (k, path) in map { if let c = color(colors[k]) { t[keyPath: path] = c } }
        if let tokens = json["tokens"] as? [String: Any] {
            for (i, n) in tokenNames.enumerated() where i < t.syntax.count { if let c = color(tokens[n]) { t.syntax[i] = c } }
        }
        if color(colors["text"]) != nil, color((json["tokens"] as? [String: Any])?["none"]) == nil { t.syntax[0] = t.text }
        customCache = (name, t)
        return t
    }
}

extension NSAppearance {
    var isLight: Bool { bestMatch(from: [.darkAqua, .aqua]) == .aqua }
}

// arayüz renkleri (VS Code Dark Modern / Light Modern), görünüme göre çözülür
enum Palette {
    static let editor = dyn(0x1F1F1F, 0xFFFFFF)
    static let chrome = dyn(0x181818, 0xF8F8F8)
    static let border = dyn(0x2B2B2B, 0xE5E5E5)
    static let text = dyn(0xCCCCCC, 0x3B3B3B)
    static let dimText = dyn(0x9D9D9D, 0x616161)
    static let brightText = dyn(0xFFFFFF, 0x000000)
    static let accent = NSColor(hex: 0x0078D4)
    static let icon = dyn(0x868686, 0x616161)
    static let hover = dyn(0x2A2D2E, 0xF2F2F2)
    static let selection = dyn(0x04395E, 0xE8E8E8)
    static let input = dyn(0x313131, 0xFFFFFF)
    static let inputBorder = dyn(0x3C3C3C, 0xCECECE)
    static let widget = dyn(0x252526, 0xF8F8F8)
    static let match = dyn(0x2AAAFF, 0x0066BF)

    private static func dyn(_ dark: UInt32, _ light: UInt32) -> NSColor {
        NSColor(name: nil) { $0.isLight ? NSColor(hex: light) : NSColor(hex: dark) }
    }
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
