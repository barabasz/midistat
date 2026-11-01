import AppKit
import MIDIstatCore

/// A small panel showing the last notes played, newest on the left.
/// A new note slides in and pushes the older ones to the right; only the
/// newest is shown at full contrast. Meant as a learning aid.
///
/// The panel can be widened (never narrower than `minimumNoteCount` notes,
/// at most the screen width) to show more notes; its height follows the font size.
final class LastNotesWindowController: NSWindowController, NSWindowDelegate {
    static let minimumNoteCount = 5
    /// Notes remembered, so that widening the window shows earlier ones at once.
    private static let historyLimit = 256

    struct Settings {
        var alwaysOnTop: Bool
        var extraLargeFont: Bool
    }

    /// Called when the user closes the panel with its close button.
    var onClose: (() -> Void)?

    private(set) var settings: Settings
    private let saveSettings: (Settings) -> Void

    private let baseFontSize = NSFont.preferredFont(forTextStyle: .largeTitle).pointSize
    private var style: NoteGlyphView.Style
    private var slotWidth: CGFloat = 0
    private var slotHeight: CGFloat = 0
    private var stageHeight: CGFloat = 0

    private let stage = NSView()
    private let placeholder = NSTextField(labelWithString: "Play a note…")
    private let onTopCheckbox = NSButton(checkboxWithTitle: "Always on Top", target: nil, action: nil)
    private let extraLargeCheckbox = NSButton(checkboxWithTitle: "X-Large Font", target: nil, action: nil)

    /// Newest first.
    private var history: [UInt8] = []
    /// Views for the visible notes, newest first. Notes sliding out are not in this list.
    private var noteViews: [NoteGlyphView] = []

    private let margin: CGFloat = 14
    private let controlsHeight: CGFloat = 34
    private let dimmedAlpha: CGFloat = 0.3

    init(settings: Settings, saveSettings: @escaping (Settings) -> Void) {
        self.settings = settings
        self.saveSettings = saveSettings
        style = NoteGlyphView.Style(fontSize: baseFontSize)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "MIDIstat — Last Notes"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false  // stay visible while another app is in front
        panel.becomesKeyOnlyIfNeeded = true
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)

        applyFontSize(keepingNoteCount: Self.minimumNoteCount)
        applyAlwaysOnTop()
        panel.center()
        // Restores the saved position and width; the height is then corrected for the font size.
        panel.setFrameAutosaveName("MIDIstatLastNotesWindow")
        applyFontSize(keepingNoteCount: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent(in panel: NSPanel) {
        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))

        stage.wantsLayer = true
        stage.layer?.masksToBounds = true  // notes sliding out on the right disappear at the edge
        stage.autoresizingMask = [.width, .minYMargin]
        content.addSubview(stage)

        placeholder.font = .systemFont(ofSize: NSFont.systemFontSize + 2)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        stage.addSubview(placeholder)

        var x = margin
        for (checkbox, action) in [(onTopCheckbox, #selector(toggleAlwaysOnTop(_:))),
                                   (extraLargeCheckbox, #selector(toggleExtraLargeFont(_:)))] {
            checkbox.target = self
            checkbox.action = action
            checkbox.controlSize = .small
            checkbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            checkbox.sizeToFit()
            checkbox.setFrameOrigin(NSPoint(x: x, y: 10))
            checkbox.autoresizingMask = [.maxXMargin, .maxYMargin]
            content.addSubview(checkbox)
            x += checkbox.frame.width + 16
        }

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

    /// How many notes fit in the current width.
    var visibleCount: Int {
        let width = window?.contentView?.bounds.width ?? 0
        return max(Self.minimumNoteCount, Int((width - 2 * margin) / slotWidth))
    }

    func add(note: UInt8) {
        placeholder.isHidden = true
        history.insert(note, at: 0)
        if history.count > Self.historyLimit { history.removeLast() }

        let view = makeNoteView(note)
        // Start slightly to the left and transparent, then slide/fade into slot 0.
        view.frame = slotFrame(0).offsetBy(dx: -slotWidth * 0.3, dy: 0)
        view.alphaValue = 0
        noteViews.insert(view, at: 0)

        var leaving: [NoteGlyphView] = []
        while noteViews.count > visibleCount { leaving.append(noteViews.removeLast()) }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            for (index, view) in noteViews.enumerated() {
                view.animator().frame = slotFrame(index)
                view.animator().alphaValue = index == 0 ? 1 : dimmedAlpha
            }
            for view in leaving {
                view.animator().frame = slotFrame(visibleCount)
                view.animator().alphaValue = 0
            }
        } completionHandler: {
            leaving.forEach { $0.removeFromSuperview() }
        }
    }

    private func makeNoteView(_ note: UInt8) -> NoteGlyphView {
        let view = NoteGlyphView(parts: NoteGlyphView.Parts(note: note), style: style)
        view.wantsLayer = true
        stage.addSubview(view)
        return view
    }

    /// Re-creates the note views for the current size and font, without animation.
    private func layoutNotes() {
        noteViews.forEach { $0.removeFromSuperview() }
        noteViews = history.prefix(visibleCount).enumerated().map { index, note in
            let view = makeNoteView(note)
            view.frame = slotFrame(index)
            view.alphaValue = index == 0 ? 1 : dimmedAlpha
            return view
        }
        placeholder.isHidden = !history.isEmpty
    }

    private func slotFrame(_ index: Int) -> NSRect {
        NSRect(x: margin + CGFloat(index) * slotWidth, y: (stageHeight - slotHeight) / 2,
               width: slotWidth, height: slotHeight)
    }

    // MARK: - Size

    func windowDidResize(_ notification: Notification) {
        if noteViews.count != min(visibleCount, history.count) { layoutNotes() }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateSizeLimits()
    }

    /// Applies the font size and sets the window height to match. With
    /// `keepingNoteCount` the width is set to show that many notes; otherwise
    /// the current width is kept, within the limits.
    private func applyFontSize(keepingNoteCount count: Int?) {
        guard let window else { return }
        style = NoteGlyphView.Style(fontSize: baseFontSize * (settings.extraLargeFont ? 2 : 1))
        // Every note gets the same slot, sized for the widest note, so that
        // shifting right is a uniform movement.
        let style = self.style
        let widest = (UInt8(0)...127).map { NoteGlyphView.Parts(note: $0).width(in: style) }.max() ?? 0
        slotWidth = ceil(widest) + (settings.extraLargeFont ? 36 : 22)
        slotHeight = ceil(style.letterFont.boundingRectForFont.height)
        stageHeight = slotHeight + 16

        updateSizeLimits()
        let height = stageHeight + controlsHeight
        let width = count.map { margin * 2 + slotWidth * CGFloat($0) } ?? window.contentLayoutRect.width
        let size = NSSize(width: min(max(width, window.contentMinSize.width), window.contentMaxSize.width),
                          height: height)
        // Keep the top-left corner in place.
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)

        stage.frame = NSRect(x: 0, y: height - stageHeight, width: size.width, height: stageHeight)
        placeholder.frame = NSRect(x: 0, y: (stageHeight - 22) / 2, width: size.width, height: 22)
        extraLargeCheckbox.state = settings.extraLargeFont ? .on : .off
        layoutNotes()
    }

    /// Width: from `minimumNoteCount` notes to the screen width. Height: fixed.
    private func updateSizeLimits() {
        guard let window else { return }
        let height = stageHeight + controlsHeight
        let screenWidth = (window.screen ?? NSScreen.main)?.visibleFrame.width ?? 1440
        let minWidth = margin * 2 + slotWidth * CGFloat(Self.minimumNoteCount)
        window.contentMinSize = NSSize(width: minWidth, height: height)
        window.contentMaxSize = NSSize(width: max(minWidth, screenWidth), height: height)
    }

    @objc private func toggleExtraLargeFont(_ sender: NSButton) {
        setExtraLargeFont(sender.state == .on)
    }

    func setExtraLargeFont(_ on: Bool) {
        let shown = visibleCount  // keep showing as many notes as now, if the screen allows
        settings.extraLargeFont = on
        saveSettings(settings)
        applyFontSize(keepingNoteCount: shown)
    }

    // MARK: - Always on top

    @objc private func toggleAlwaysOnTop(_ sender: NSButton) {
        setAlwaysOnTop(sender.state == .on)
    }

    func setAlwaysOnTop(_ on: Bool) {
        settings.alwaysOnTop = on
        saveSettings(settings)
        applyAlwaysOnTop()
    }

    /// On top: floats above other windows on every Space, full-screen apps included.
    /// Not on top: an ordinary window that stays on the Space (desktop) where it is.
    private func applyAlwaysOnTop() {
        let onTop = settings.alwaysOnTop
        onTopCheckbox.state = onTop ? .on : .off
        guard let window else { return }
        window.level = onTop ? .floating : .normal
        window.collectionBehavior = onTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.managed]
        // Space membership is re-evaluated when the window is ordered in again.
        if window.isVisible {
            window.orderOut(nil)
            window.orderFrontRegardless()
        }
    }
}

/// Draws one note: a large bold letter, followed by a column as tall as the
/// letter with the sharp sign on top and the octave number below, e.g.
///
///     C#      the "#" and "4" are small, the "#" bold, the "4" light,
///      4      stacked without line spacing between the letter's top and baseline.
final class NoteGlyphView: NSView {
    struct Style {
        let letterFont: NSFont
        let sharpFont: NSFont
        let octaveFont: NSFont
        let columnGap: CGFloat

        init(fontSize: CGFloat) {
            letterFont = .systemFont(ofSize: fontSize, weight: .bold)
            // Two small lines (cap height ≈ 0.48 of the letter's each) fill the letter's height.
            let small = (fontSize * 0.48).rounded()
            sharpFont = .systemFont(ofSize: small, weight: .bold)
            octaveFont = .systemFont(ofSize: small, weight: .light)
            columnGap = (fontSize * 0.05).rounded()
        }
    }

    struct Parts {
        let letter: String
        let sharp: Bool
        let octave: String

        init(note: UInt8) {
            let name = MIDIFormat.noteName(note)  // e.g. "C#4", "C-1"
            let octaveStart = name.firstIndex { $0.isNumber || $0 == "-" } ?? name.endIndex
            let pitch = name[..<octaveStart]
            letter = String(pitch.prefix(1))
            sharp = pitch.contains("#")
            octave = String(name[octaveStart...])
        }

        func width(in style: Style) -> CGFloat {
            let letterWidth = (letter as NSString).size(withAttributes: [.font: style.letterFont]).width
            let sharpWidth = sharp ? ("#" as NSString).size(withAttributes: [.font: style.sharpFont]).width : 0
            let octaveWidth = (octave as NSString).size(withAttributes: [.font: style.octaveFont]).width
            return letterWidth + style.columnGap + max(sharpWidth, octaveWidth)
        }
    }

    private let parts: Parts
    private let style: Style

    init(parts: Parts, style: Style) {
        self.parts = parts
        self.style = style
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(parts.letter)\(parts.sharp ? " sharp" : "") \(parts.octave)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor.labelColor  // resolved now, so it follows light/dark mode
        func text(_ string: String, _ font: NSFont, x: CGFloat, baseline: CGFloat) {
            (string as NSString).draw(at: NSPoint(x: x, y: baseline + font.descender),
                                      withAttributes: [.font: font, .foregroundColor: color])
        }
        let capHeight = style.letterFont.capHeight
        let baseline = ((bounds.height - capHeight) / 2).rounded()
        let x = ((bounds.width - parts.width(in: style)) / 2).rounded()
        let letterWidth = (parts.letter as NSString).size(withAttributes: [.font: style.letterFont]).width
        let columnX = x + letterWidth + style.columnGap

        text(parts.letter, style.letterFont, x: x, baseline: baseline)
        // Octave sits on the letter's baseline, lowered by one device pixel: round
        // letters (C, D, G) overshoot the baseline slightly, so a flat-bottomed
        // digit placed exactly on it looks higher. The sharp's top meets the letter's top.
        let onePixel = 1 / (window?.backingScaleFactor ?? 2)
        text(parts.octave, style.octaveFont, x: columnX, baseline: baseline - onePixel)
        if parts.sharp {
            text("#", style.sharpFont, x: columnX, baseline: baseline + capHeight - style.sharpFont.capHeight)
        }
    }
}
