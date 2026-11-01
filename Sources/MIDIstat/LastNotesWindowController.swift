import AppKit
import MIDIstatCore

/// A small panel showing the last few notes played, newest on the left.
/// A new note slides in and pushes the older ones to the right; only the
/// newest is shown at full contrast. Meant as a learning aid.
final class LastNotesWindowController: NSWindowController, NSWindowDelegate {
    static let noteCount = 5

    /// Called when the user closes the panel with its close button.
    var onClose: (() -> Void)?

    private let setAlwaysOnTop: (Bool) -> Void
    private static let fontSize = NSFont.preferredFont(forTextStyle: .largeTitle).pointSize
    /// Note letter (and ♯) in bold; the octave number is secondary information.
    private let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    private let octaveFont = NSFont.systemFont(ofSize: fontSize, weight: .light)
    private let stage = NSView()
    private let placeholder = NSTextField(labelWithString: "Play a note…")
    private let onTopCheckbox = NSButton(checkboxWithTitle: "Always on Top", target: nil, action: nil)

    /// Newest first. May briefly hold one extra label that is fading out.
    private var labels: [NSTextField] = []

    private let margin: CGFloat = 14
    private let slotWidth: CGFloat
    private let stageHeight: CGFloat
    private let dimmedAlpha: CGFloat = 0.3

    init(alwaysOnTop: Bool, setAlwaysOnTop: @escaping (Bool) -> Void) {
        self.setAlwaysOnTop = setAlwaysOnTop
        // Every note gets the same slot, sized for the widest name, so that
        // shifting right is a uniform movement.
        let (bold, light) = (font, octaveFont)
        let sizes = (UInt8(0)...127).map { Self.attributedName(of: $0, font: bold, octaveFont: light).size() }
        slotWidth = ceil(sizes.map(\.width).max() ?? 0) + 18
        stageHeight = ceil(sizes.map(\.height).max() ?? 0) + 16

        let contentSize = NSSize(width: margin * 2 + slotWidth * CGFloat(Self.noteCount),
                                 height: stageHeight + 34)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: contentSize),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "MIDIstat — Last Notes"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false  // stay visible while another app is in front
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel, size: contentSize)
        applyAlwaysOnTop(alwaysOnTop)
        panel.center()
        panel.setFrameAutosaveName("MIDIstatLastNotesWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent(in panel: NSPanel, size: NSSize) {
        let content = NSView(frame: NSRect(origin: .zero, size: size))

        stage.frame = NSRect(x: 0, y: size.height - stageHeight, width: size.width, height: stageHeight)
        stage.wantsLayer = true
        stage.layer?.masksToBounds = true  // notes sliding out on the right disappear at the edge
        content.addSubview(stage)

        placeholder.font = .systemFont(ofSize: NSFont.systemFontSize + 2)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.frame = NSRect(x: 0, y: (stageHeight - 22) / 2, width: size.width, height: 22)
        stage.addSubview(placeholder)

        onTopCheckbox.target = self
        onTopCheckbox.action = #selector(toggleAlwaysOnTop(_:))
        onTopCheckbox.controlSize = .small
        onTopCheckbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        onTopCheckbox.sizeToFit()
        onTopCheckbox.setFrameOrigin(NSPoint(x: margin, y: 10))
        content.addSubview(onTopCheckbox)

        panel.contentView = content
    }

    // MARK: - Showing

    var isVisible: Bool { window?.isVisible == true }

    /// Shows the panel without taking the focus away from the current app.
    func show() {
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: - Notes

    func add(note: UInt8) {
        placeholder.isHidden = true

        let label = NSTextField(labelWithAttributedString:
            Self.attributedName(of: note, font: font, octaveFont: octaveFont))
        label.wantsLayer = true
        // Start slightly to the left and transparent, then slide/fade into slot 0.
        label.frame = slotFrame(0).offsetBy(dx: -slotWidth * 0.3, dy: 0)
        label.alphaValue = 0
        stage.addSubview(label)
        labels.insert(label, at: 0)

        var leaving: [NSTextField] = []
        while labels.count > Self.noteCount { leaving.append(labels.removeLast()) }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            for (index, label) in labels.enumerated() {
                label.animator().frame = slotFrame(index)
                label.animator().alphaValue = index == 0 ? 1 : dimmedAlpha
            }
            for label in leaving {
                label.animator().frame = slotFrame(Self.noteCount)
                label.animator().alphaValue = 0
            }
        } completionHandler: {
            leaving.forEach { $0.removeFromSuperview() }
        }
    }

    /// e.g. "F♯" in bold followed by "4" in light, centred.
    private static func attributedName(of note: UInt8, font: NSFont, octaveFont: NSFont) -> NSAttributedString {
        let name = MIDIFormat.noteName(note).replacingOccurrences(of: "#", with: "♯")
        // The octave starts at the first digit or minus sign (octave -1 for the lowest notes).
        let split = name.firstIndex { $0.isNumber || $0 == "-" } ?? name.endIndex
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let result = NSMutableAttributedString(string: String(name[..<split]), attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])
        result.append(NSAttributedString(string: String(name[split...]), attributes: [
            .font: octaveFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]))
        return result
    }

    private func slotFrame(_ index: Int) -> NSRect {
        let height = ceil(font.boundingRectForFont.height)
        return NSRect(x: margin + CGFloat(index) * slotWidth,
                      y: (stageHeight - height) / 2,
                      width: slotWidth, height: height)
    }

    // MARK: - Always on top

    @objc private func toggleAlwaysOnTop(_ sender: NSButton) {
        let onTop = sender.state == .on
        applyAlwaysOnTop(onTop)
        setAlwaysOnTop(onTop)
    }

    private func applyAlwaysOnTop(_ onTop: Bool) {
        onTopCheckbox.state = onTop ? .on : .off
        window?.level = onTop ? .floating : .normal
    }
}
