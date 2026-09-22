import AppKit

struct TabItem {
    var title: String
    var detail: String?
    var dirty: Bool
    var path: String
}

final class TabBarView: FlippedView {
    var items: [TabItem] = [] { didSet { needsDisplay = true } }
    var active = -1 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    // (kaynak bar, kaynak sekme, bu bardaki hedef sıra)
    var onDropTab: ((TabBarView, Int, Int) -> Void)?
    static let tabIndexType = NSPasteboard.PasteboardType("dev.kern.tab-index")

    private var dragCandidate: Int?
    private var dropIndex: Int? { didSet { if oldValue != dropIndex { needsDisplay = true } } }
    private var hover = -1
    private var hoverClose = false
    private var offset: CGFloat = 0
    private let font = NSFont.systemFont(ofSize: 13)
    private let detailFont = NSFont.systemFont(ofSize: 11)

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.chrome
        registerForDraggedTypes([Self.tabIndexType])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    private func tabRects() -> [NSRect] {
        var x = -offset
        return items.map { item in
            var w = (item.title as NSString).size(withAttributes: [.font: font]).width + 34 + 34
            if let d = item.detail { w += (d as NSString).size(withAttributes: [.font: detailFont]).width + 6 }
            let r = NSRect(x: x, y: 0, width: max(90, ceil(w)), height: bounds.height)
            x = r.maxX
            return r
        }
    }

    private func closeRect(_ tab: NSRect) -> NSRect {
        NSRect(x: tab.maxX - 28, y: (tab.height - 20) / 2, width: 20, height: 20)
    }

    func revealActive() {
        let rects = tabRects()
        guard bounds.width > 0, active >= 0, active < rects.count else { return }
        let r = rects[active]
        if r.minX < 0 { offset += r.minX } else if r.maxX > bounds.width { offset += r.maxX - bounds.width }
        clampOffset()
        needsDisplay = true
    }

    private func clampOffset() {
        let total = tabRects().last.map { $0.maxX + offset } ?? 0
        offset = min(max(0, offset), max(0, total - bounds.width))
    }

    override func layout() {
        super.layout()
        clampOffset()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        for (i, r) in tabRects().enumerated() {
            let item = items[i]
            let isActive = i == active
            (isActive ? Palette.editor : (i == hover ? NSColor(hex: 0x1F1F1F) : Palette.chrome)).setFill()
            r.fill()
            Palette.border.setFill()
            NSRect(x: r.maxX - 1, y: 0, width: 1, height: r.height).fill()
            if isActive {
                Palette.accent.setFill()
                NSRect(x: r.minX, y: 0, width: r.width - 1, height: 1).fill()
            } else {
                NSRect(x: r.minX, y: r.height - 1, width: r.width, height: 1).fill()
            }

            let color = isActive ? Palette.brightText : Palette.dimText
            FileIcons.icon(for: item.title, directory: false)?
                .draw(in: NSRect(x: r.minX + 12, y: (r.height - 16) / 2, width: 16, height: 16),
                      from: .zero, operation: .sourceOver, fraction: isActive ? 1 : 0.75, respectFlipped: true, hints: nil)
            let title = item.title as NSString
            let tAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let ts = title.size(withAttributes: tAttrs)
            title.draw(at: NSPoint(x: r.minX + 34, y: (r.height - ts.height) / 2), withAttributes: tAttrs)
            if let d = item.detail {
                let dAttrs: [NSAttributedString.Key: Any] = [.font: detailFont, .foregroundColor: Palette.dimText]
                let ds = (d as NSString).size(withAttributes: dAttrs)
                (d as NSString).draw(at: NSPoint(x: r.minX + 40 + ts.width, y: (r.height - ds.height) / 2 + 1), withAttributes: dAttrs)
            }

            let c = closeRect(r)
            let hovering = i == hover && hoverClose
            if hovering {
                NSColor(hex: 0x3C3C3C).setFill()
                NSBezierPath(roundedRect: c, xRadius: 4, yRadius: 4).fill()
            }
            if item.dirty && !hovering {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.midX - 4, y: c.midY - 4, width: 8, height: 8)).fill()
            } else if isActive || i == hover {
                symbol("xmark", size: 11, color: color)?.draw(in: NSRect(x: c.midX - 6, y: c.midY - 6, width: 12, height: 12))
            }
        }
    }

    private func hit(_ event: NSEvent) -> (Int, Bool) {
        let p = convert(event.locationInWindow, from: nil)
        for (i, r) in tabRects().enumerated() where r.contains(p) {
            return (i, closeRect(r).insetBy(dx: -2, dy: -2).contains(p))
        }
        return (-1, false)
    }

    override func mouseMoved(with event: NSEvent) {
        let (i, close) = hit(event)
        if i != hover || close != hoverClose {
            hover = i
            hoverClose = close
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hover = -1
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let (i, close) = hit(event)
        guard i >= 0 else { return }
        if close { return onClose?(i) ?? () }
        onSelect?(i)
        dragCandidate = i
    }

    // sekmeyi başka gruba (ya da aynı barda başka yere) sürükle
    override func mouseDragged(with event: NSEvent) {
        guard let i = dragCandidate, i < items.count else { return }
        dragCandidate = nil
        let item = NSPasteboardItem()
        item.setString(items[i].path.isEmpty ? items[i].title : items[i].path, forType: .string)
        item.setString(String(i), forType: Self.tabIndexType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let rect = tabRects()[i]
        let image = NSImage(size: rect.size)
        image.lockFocus()
        Palette.hover.setFill()
        NSRect(origin: .zero, size: rect.size).fill()
        (items[i].title as NSString).draw(at: NSPoint(x: 10, y: 8), withAttributes: [.font: font, .foregroundColor: Palette.text])
        image.unlockFocus()
        dragItem.setDraggingFrame(rect, contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragCandidate = nil
    }

    override func otherMouseDown(with event: NSEvent) {
        let (i, _) = hit(event)
        if i >= 0 { onClose?(i) }
    }

    override func scrollWheel(with event: NSEvent) {
        offset -= event.scrollingDeltaX + event.scrollingDeltaY
        clampOffset()
        needsDisplay = true
    }

    // sürükle-bırak hedefi

    private func dropTarget(_ p: NSPoint) -> Int {
        let rects = tabRects()
        for (i, r) in rects.enumerated() where p.x < r.midX { return i }
        return rects.count
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropIndex = dropTarget(convert(sender.draggingLocation, from: nil))
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropIndex = dropTarget(convert(sender.draggingLocation, from: nil))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndex = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropIndex = nil }
        guard let source = sender.draggingSource as? TabBarView,
              let raw = sender.draggingPasteboard.propertyList(forType: Self.tabIndexType) as? String ?? sender
                  .draggingPasteboard.string(forType: Self.tabIndexType),
              let from = Int(raw) else { return false }
        let to = dropTarget(convert(sender.draggingLocation, from: nil))
        onDropTab?(source, from, to)
        return true
    }

    // erişilebilirlik: her sekme ayrı öğe

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override func accessibilityLabel() -> String? { "Editor Tabs" }
    override func accessibilityValue() -> Any? { active >= 0 && active < items.count ? items[active].title : nil }

    override func accessibilityChildren() -> [Any]? {
        let rects = tabRects()
        return items.enumerated().map { i, item in
            let e = TabElement()
            e.bar = self
            e.index = i
            e.setAccessibilityParent(self)
            e.setAccessibilityRole(.radioButton)
            e.setAccessibilityLabel(item.title + (item.dirty ? ", unsaved" : ""))
            e.setAccessibilityHelp(item.path)
            e.setAccessibilityValue(i == active ? 1 : 0)
            e.setAccessibilityFrameInParentSpace(rects[i])
            return e
        }
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        guard active >= 0, let children = accessibilityChildren(), active < children.count else { return nil }
        return [children[active]]
    }
}

extension TabBarView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }
}

final class TabElement: NSAccessibilityElement {
    weak var bar: TabBarView?
    var index = 0

    override func accessibilityPerformPress() -> Bool {
        bar?.onSelect?(index)
        return true
    }
}
