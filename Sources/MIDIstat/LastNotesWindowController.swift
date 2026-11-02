import AppKit
import MIDIstatCore

/// A small panel showing the last notes played, newest on the left.
/// A new note slides in and pushes the older ones to the right; only the
/// newest is shown at full contrast. Meant as a learning aid.
///
/// The panel can be widened (never narrower than `minimumNoteCount` notes,
/// at most the screen width) to show more notes; its height follows the font
/// size and the velocity option.
final class LastNotesWindowController: NSWindowController, NSWindowDelegate {
    static let minimumNoteCount = 8
    /// Notes remembered, so that widening the window shows earlier ones at once.
    private static let historyLimit = 256

    struct Settings {
        var alwaysOnTop: Bool
        var extraLargeFont: Bool
        var velocity: Bool
        /// Velocity meters in green, yellow and red instead of the text colour.
        var colored: Bool
        /// The velocity value in a black box under each meter.
        var values: Bool
    }

    private struct PlayedNote {
        let note: UInt8
        let velocity: UInt8
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
    private let extraLargeCheckbox = NSButton(checkboxWithTitle: "X-Large", target: nil, action: nil)
    private let velocityCheckbox = NSButton(checkboxWithTitle: "Velocity", target: nil, action: nil)
    private let coloredCheckbox = NSButton(checkboxWithTitle: "Colored", target: nil, action: nil)
    private let valuesCheckbox = NSButton(checkboxWithTitle: "Values", target: nil, action: nil)

    /// Newest first.
    private var history: [PlayedNote] = []
    /// Views for the visible notes, newest first. Notes sliding out are not in this list.
    private var noteViews: [NoteGlyphView] = []

    private let margin: CGFloat = 14
    private var controlsWidth: CGFloat = 0
    private let controlsHeight: CGFloat = 34
    /// How older notes are dimmed. In dark mode the whole view is made
    /// transparent. In light mode faint colours vanish on white, so only the
    /// letter is made transparent and the meter keeps full contrast.
    private var dimsWholeView: Bool { NoteGlyphView.isDark(window?.effectiveAppearance) }
    private let dimmedAlpha: CGFloat = 0.3

    private func targetAlpha(_ index: Int) -> CGFloat {
        index == 0 || !dimsWholeView ? 1 : dimmedAlpha
    }

    private func letterAlpha(_ index: Int) -> CGFloat {
        index == 0 || dimsWholeView ? 1 : dimmedAlpha
    }
    private var appearanceObservation: NSKeyValueObservation?

    init(settings: Settings, saveSettings: @escaping (Settings) -> Void) {
        self.settings = settings
        self.saveSettings = saveSettings
        style = NoteGlyphView.Style(fontSize: baseFontSize, extraLarge: false)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "MIDIstat — Last Notes"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false  // stay visible while another app is in front
        panel.becomesKeyOnlyIfNeeded = true
        super.init(window: panel)
        panel.delegate = self
        // Light and dark mode dim the older notes differently.
        appearanceObservation = panel.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.layoutNotes() }
        }
        buildContent(in: panel)

        applyLayout(keepingNoteCount: Self.minimumNoteCount)
        applyAlwaysOnTop()
        panel.center()
        // Restores the saved position and width; the height is then corrected for the font size.
        panel.setFrameAutosaveName("MIDIstatLastNotesWindow")
        applyLayout(keepingNoteCount: nil)
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

        for (checkbox, action) in [(onTopCheckbox, #selector(toggleAlwaysOnTop(_:))),
                                   (extraLargeCheckbox, #selector(toggleExtraLargeFont(_:))),
                                   (velocityCheckbox, #selector(toggleVelocity(_:))),
                                   (coloredCheckbox, #selector(toggleColored(_:))),
                                   (valuesCheckbox, #selector(toggleValues(_:)))] {
            checkbox.target = self
            checkbox.action = action
            checkbox.controlSize = .small
            checkbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            checkbox.sizeToFit()
        }
        coloredCheckbox.toolTip = "Velocity meters in green (velocity up to 79), yellow (up to 111) and red."
        valuesCheckbox.toolTip = "Show the velocity value (1–127) on each meter."
        for checkbox in [onTopCheckbox, extraLargeCheckbox, velocityCheckbox, coloredCheckbox, valuesCheckbox] {
            checkbox.autoresizingMask = [.maxXMargin, .maxYMargin]
            content.addSubview(checkbox)
        }

        panel.contentView = content
    }

    /// The options in one row, starting at the left edge of the first note's
    /// velocity meter, which depends on the slot width. "Colored" and "Values"
    /// are shown only with the velocity meters.
    private func layoutControls() {
        let meterOptions = [coloredCheckbox, valuesCheckbox]
        meterOptions.forEach { $0.isHidden = !settings.velocity }
        let shown = [onTopCheckbox, extraLargeCheckbox, velocityCheckbox] + (settings.velocity ? meterOptions : [])
        // A checkbox's box is inset in its frame by about a point.
        var x = margin + NoteGlyphView.meterFrame(inWidth: slotWidth).minX - 1
        for checkbox in shown {
            checkbox.setFrameOrigin(NSPoint(x: x, y: 10))
            x += checkbox.frame.width + 16
        }
        controlsWidth = x - 16 + margin
    }

    // MARK: - Showing

    /// Also true while hidden, waiting to come back on a regular desktop.
    var isVisible: Bool { window?.isShownOrWaiting == true }

    /// Shows the panel without taking the focus away from the current app.
    func show() {
        if let window { DesktopReturn.cancel(window) }  // opened explicitly: show it here
        window?.orderFrontRegardless()
    }

    func hide() {
        if let window { DesktopReturn.cancel(window) }
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window { DesktopReturn.cancel(window) }
        onClose?()
    }

    // MARK: - Notes

    /// How many notes fit in the current width.
    var visibleCount: Int {
        let width = window?.contentView?.bounds.width ?? 0
        return max(Self.minimumNoteCount, Int((width - 2 * margin) / slotWidth))
    }

    func add(note: UInt8, velocity: UInt8) {
        placeholder.isHidden = true
        let played = PlayedNote(note: note, velocity: velocity)
        history.insert(played, at: 0)
        if history.count > Self.historyLimit { history.removeLast() }

        let view = makeNoteView(played)
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
                view.animator().alphaValue = targetAlpha(index)
                view.letterView.animator().alphaValue = letterAlpha(index)
            }
            for view in leaving {
                view.animator().frame = slotFrame(visibleCount)
                view.animator().alphaValue = 0
            }
        } completionHandler: {
            leaving.forEach { $0.removeFromSuperview() }
        }
    }

    private func makeNoteView(_ played: PlayedNote) -> NoteGlyphView {
        let view = NoteGlyphView(parts: NoteGlyphView.Parts(note: played.note),
                                 velocity: settings.velocity ? played.velocity : nil,
                                 colored: settings.colored, showsValue: settings.values, style: style)
        view.wantsLayer = true
        stage.addSubview(view)
        return view
    }

    /// Re-creates the note views for the current size and font, without animation.
    private func layoutNotes() {
        noteViews.forEach { $0.removeFromSuperview() }
        noteViews = history.prefix(visibleCount).enumerated().map { index, played in
            let view = makeNoteView(played)
            view.frame = slotFrame(index)
            view.alphaValue = targetAlpha(index)
            view.letterView.alphaValue = letterAlpha(index)
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

    /// Applies the font size and the velocity option and sets the window height to match. With
    /// `keepingNoteCount` the width is set to show that many notes; otherwise
    /// the current width is kept, within the limits.
    private func applyLayout(keepingNoteCount count: Int?) {
        guard let window else { return }
        style = NoteGlyphView.Style(fontSize: baseFontSize * (settings.extraLargeFont ? 2 : 1),
                                    extraLarge: settings.extraLargeFont)
        // Every note gets the same slot, sized for the widest note, so that
        // shifting right is a uniform movement.
        let style = self.style
        let widest = (UInt8(0)...127).map { NoteGlyphView.Parts(note: $0).width(in: style) }.max() ?? 0
        slotWidth = ceil(widest) + (settings.extraLargeFont ? 36 : 22)
        slotHeight = style.glyphHeight
            + (settings.velocity ? style.meterGap + style.meterHeight : 0)
            + (settings.velocity && settings.values ? style.barGap + style.valueBoxHeight : 0)
        stageHeight = slotHeight + 16

        layoutControls()
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
        velocityCheckbox.state = settings.velocity ? .on : .off
        coloredCheckbox.state = settings.colored ? .on : .off
        valuesCheckbox.state = settings.values ? .on : .off
        layoutNotes()
    }

    /// Width: from `minimumNoteCount` notes to the screen width. Height: fixed.
    private func updateSizeLimits() {
        guard let window else { return }
        let height = stageHeight + controlsHeight
        let screenWidth = (window.screen ?? NSScreen.main)?.visibleFrame.width ?? 1440
        let minWidth = max(margin * 2 + slotWidth * CGFloat(Self.minimumNoteCount), controlsWidth)
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
        applyLayout(keepingNoteCount: shown)
    }

    // MARK: - Velocity

    @objc private func toggleVelocity(_ sender: NSButton) {
        setVelocity(sender.state == .on)
    }

    func setVelocity(_ on: Bool) {
        settings.velocity = on
        saveSettings(settings)
        applyLayout(keepingNoteCount: nil)
    }

    @objc private func toggleColored(_ sender: NSButton) {
        setColored(sender.state == .on)
    }

    func setColored(_ on: Bool) {
        settings.colored = on
        saveSettings(settings)
        coloredCheckbox.state = on ? .on : .off
        layoutNotes()  // redraws the meters
    }

    @objc private func toggleValues(_ sender: NSButton) {
        setValues(sender.state == .on)
    }

    func setValues(_ on: Bool) {
        settings.values = on
        saveSettings(settings)
        applyLayout(keepingNoteCount: nil)  // the value box changes the slot and window height
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

    private func applyAlwaysOnTop() {
        onTopCheckbox.state = settings.alwaysOnTop ? .on : .off
        window?.setAlwaysOnTop(settings.alwaysOnTop)
    }
}

/// Draws one note: a large bold letter, followed by a column as tall as the
/// letter with the sharp sign on top and the octave number below, e.g.
///
///     C#      the "#" and "4" are small, the "#" bold, the "4" light,
///      4      stacked without line spacing between the letter's top and baseline.
///
/// With a velocity, a meter of 16 thin bars below the letter shows it,
/// lit from the bottom: velocity 0–7 lights 1 bar, 120–127 all 16. Colored,
/// like a level meter: bars 1–10 green (velocity up to 79), 11–14 yellow
/// (up to 111), 15–16 red. Optionally, a black box under the meter shows the value.
final class NoteGlyphView: NSView {
    static let meterSteps = 16

    struct Style {
        let letterFont: NSFont
        let sharpFont: NSFont
        let octaveFont: NSFont
        let columnGap: CGFloat
        /// Height of the area of the letter, without the meter.
        let glyphHeight: CGFloat
        /// Distance between the bottoms of two meter bars, and the height of one bar.
        let barPitch: CGFloat
        let barHeight: CGFloat
        let meterGap: CGFloat
        var meterHeight: CGFloat { barPitch * CGFloat(NoteGlyphView.meterSteps) - (barPitch - barHeight) }
        /// Device pixels the sharp sign is moved up and left: at the X-Large size
        /// it otherwise looks slightly off the letter's top.
        let sharpNudge: CGFloat
        /// The value under the meter: bold, the size of the option labels.
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)
        /// Space above and below the value's digits in its box.
        let valuePadding: CGFloat
        var valueBoxHeight: CGFloat { ceil(valueFont.capHeight) + 2 * valuePadding }
        /// The gap between two bars, also between the meter and the value box.
        var barGap: CGFloat { barPitch - barHeight }

        init(fontSize: CGFloat, extraLarge: Bool) {
            sharpNudge = extraLarge ? 1 : 0
            valuePadding = extraLarge ? 4 : 3
            letterFont = .systemFont(ofSize: fontSize, weight: .bold)
            // Two small lines (cap height ≈ 0.48 of the letter's each) fill the letter's height.
            let small = (fontSize * 0.48).rounded()
            sharpFont = .systemFont(ofSize: small, weight: .bold)
            octaveFont = .systemFont(ofSize: small, weight: .light)
            columnGap = (fontSize * 0.05).rounded()
            glyphHeight = ceil(letterFont.boundingRectForFont.height)
            // Multiples of half a point, so that bars fall on whole Retina pixels.
            barPitch = max(3, (fontSize * 0.12 * 2).rounded() / 2)
            barHeight = (barPitch).rounded(.down) / 2
            meterGap = (fontSize * 0.1).rounded()
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

    /// The letter and the meter are separate layer-backed views, so that light
    /// mode can dim the letter alone by its opacity, without redrawing.
    let letterView: NSView
    private let meterView: NSView?

    init(parts: Parts, velocity: UInt8?, colored: Bool, showsValue: Bool, style: Style) {
        let letter = LetterView(parts: parts, style: style)
        letterView = letter
        meterView = velocity.map { MeterView(velocity: $0, colored: colored, showsValue: showsValue, style: style) }
        super.init(frame: .zero)
        wantsLayer = true
        for view in [letterView, meterView].compactMap({ $0 }) {
            view.wantsLayer = true
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        let name = "\(parts.letter)\(parts.sharp ? " sharp" : "") \(parts.octave)"
        setAccessibilityLabel(velocity.map { "\(name), velocity \($0)" } ?? name)
        letterView.setAccessibilityElement(false)
        meterView?.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The letter fills the top `glyphHeight`, the meter (with its value box) the rest.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let glyphHeight = (letterView as? LetterView)?.style.glyphHeight ?? newSize.height
        letterView.frame = NSRect(x: 0, y: newSize.height - glyphHeight, width: newSize.width, height: glyphHeight)
        meterView?.frame = NSRect(x: 0, y: 0, width: newSize.width, height: max(0, newSize.height - glyphHeight))
    }

    static func isDark(_ appearance: NSAppearance?) -> Bool {
        appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Colours of the colored meter, by bar (0-based): 10 green, 4 yellow, 2 red.
    /// In light mode yellow is barely visible on white: a deeper green and orange instead.
    static func meterColor(step: Int, dark: Bool) -> NSColor {
        switch step {
        case ..<10: dark ? .systemGreen : NSColor(srgbRed: 0.13, green: 0.60, blue: 0.22, alpha: 1)
        case ..<14: dark ? .systemYellow : .systemOrange
        default: .systemRed
        }
    }

    /// The meter's horizontal extent in a view (slot) of the given width.
    static func meterFrame(inWidth width: CGFloat) -> (minX: CGFloat, width: CGFloat) {
        let meterWidth = (width * 0.6).rounded()
        return (((width - meterWidth) / 2).rounded(), meterWidth)
    }
}

/// The letter of a note, with the sharp sign and the octave in a column to its right.
private final class LetterView: NSView {
    let parts: NoteGlyphView.Parts
    let style: NoteGlyphView.Style

    init(parts: NoteGlyphView.Parts, style: NoteGlyphView.Style) {
        self.parts = parts
        self.style = style
        super.init(frame: .zero)
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
            let nudge = style.sharpNudge * onePixel
            text("#", style.sharpFont, x: columnX - nudge,
                 baseline: baseline + capHeight - style.sharpFont.capHeight + nudge)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The velocity meter of a note, standing on the value box if values are shown.
private final class MeterView: NSView {
    private let velocity: UInt8
    private let colored: Bool
    private let showsValue: Bool
    private let style: NoteGlyphView.Style

    init(velocity: UInt8, colored: Bool, showsValue: Bool, style: NoteGlyphView.Style) {
        self.velocity = velocity
        self.colored = colored
        self.showsValue = showsValue
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let meterBase = showsValue ? style.valueBoxHeight + style.barGap : 0
        drawMeter(level: NoteStats.velocityLevel(velocity), color: .labelColor, base: meterBase)
        if showsValue { drawValueBox("\(velocity)") }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func drawMeter(level: Int, color: NSColor, base: CGFloat) {
        let (x, width) = NoteGlyphView.meterFrame(inWidth: bounds.width)
        let dark = NoteGlyphView.isDark(effectiveAppearance)
        // Unlit bars are faint. Light mode doesn't dim the meter of older notes
        // (only the letter), so its unlit bars are as faint as those of a dimmed
        // note would be, and lit bars keep full colour: the highest contrast on white.
        let unlitAlpha: CGFloat = dark ? (colored ? 0.22 : 0.15) : (colored ? 0.3 : 0.2) * 0.5
        for step in 0..<NoteGlyphView.meterSteps {
            let barColor = colored ? NoteGlyphView.meterColor(step: step, dark: dark) : color
            (step < level ? barColor : barColor.withAlphaComponent(unlitAlpha)).setFill()
            NSRect(x: x, y: base + CGFloat(step) * style.barPitch, width: width, height: style.barHeight)
                .fill(using: .sourceOver)
        }
    }

    /// A black box as wide as the meter, at the bottom of the view, with the value in white.
    /// Black and white in both light and dark mode, like a display.
    private func drawValueBox(_ value: String) {
        let font = style.valueFont
        let (x, width) = NoteGlyphView.meterFrame(inWidth: bounds.width)
        let box = NSRect(x: x, y: 0, width: width, height: style.valueBoxHeight)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).fill()
        let onePixel = 1 / (window?.backingScaleFactor ?? 2)
        func toPixel(_ value: CGFloat) -> CGFloat { (value / onePixel).rounded() * onePixel }
        let textWidth = (value as NSString).size(withAttributes: [.font: font]).width
        // Centred on the cap height, then a device pixel lower: measured, the digits
        // otherwise have two pixels less space above them than below.
        let baseline = toPixel(box.minY + (box.height - font.capHeight) / 2) - onePixel
        (value as NSString).draw(at: NSPoint(x: toPixel(box.midX - textWidth / 2), y: baseline + font.descender),
                                 withAttributes: [.font: font, .foregroundColor: NSColor.white])
    }
}
