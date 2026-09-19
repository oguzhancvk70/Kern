import AppKit

final class TerminalPanel: FlippedView {
    var onClose: (() -> Void)?
    private(set) var terminal: TerminalView?
    private let tab = makeLabel("TERMINAL", size: 11, weight: .regular, color: Palette.brightText)
    private let shellLabel = makeLabel("", size: 11, color: Palette.dimText)
    private lazy var newButton = iconButton("plus", tooltip: "New Terminal", size: 13, target: self, action: #selector(newTerminal))
    private lazy var killButton = iconButton("trash", tooltip: "Kill Terminal", size: 12, target: self, action: #selector(kill))
    private lazy var closeButton = iconButton("xmark", tooltip: "Hide Panel", size: 12, target: self, action: #selector(hide))
    private let header: CGFloat = 35
    var cwd = NSHomeDirectory()

    override init(frame: NSRect) {
        super.init(frame: frame)
        background = Palette.chrome
        [tab, shellLabel, newButton, killButton, closeButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        tab.frame = NSRect(x: 20, y: 11, width: 70, height: 15)
        shellLabel.frame = NSRect(x: 100, y: 11, width: max(0, w - 200), height: 15)
        newButton.frame = NSRect(x: w - 84, y: 7, width: 22, height: 22)
        killButton.frame = NSRect(x: w - 58, y: 7, width: 22, height: 22)
        closeButton.frame = NSRect(x: w - 32, y: 7, width: 22, height: 22)
        terminal?.frame = NSRect(x: 0, y: header, width: w, height: max(0, bounds.height - header))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        Palette.brightText.setFill()
        NSRect(x: 20, y: 29, width: 58, height: 1).fill()
    }

    func focus() {
        if terminal == nil { newTerminal() }
        if let terminal { window?.makeFirstResponder(terminal) }
    }

    @objc func newTerminal() {
        terminal?.removeFromSuperview()
        guard let view = TerminalView(cwd: cwd) else { return }
        view.onExit = { [weak self, weak view] in
            guard let self, view === self.terminal else { return }
            self.terminal?.removeFromSuperview()
            self.terminal = nil
            self.shellLabel.stringValue = ""
            self.onClose?()
        }
        view.onTitle = { [weak self] title in self?.shellLabel.stringValue = title }
        terminal = view
        addSubview(view)
        needsLayout = true
        window?.makeFirstResponder(view)
    }

    @objc private func kill() {
        terminal?.removeFromSuperview()
        terminal = nil
        shellLabel.stringValue = ""
        onClose?()
    }

    @objc private func hide() {
        onClose?()
    }
}
