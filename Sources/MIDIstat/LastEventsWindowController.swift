import AppKit
import MIDIstatCore

/// A compact text window with the most recent events (newest at the bottom),
/// updated as soon as an event arrives. Options at the bottom choose the
/// columns. Enabling or disabling a column sets the width to fit all columns;
/// the window can then be narrowed (long descriptions end with "…") or
/// widened, and made taller to show more lines (at least `minimumRows`).
final class LastEventsWindowController: NSWindowController, NSWindowDelegate {
    static let minimumRows = 5

    struct Settings {
        var timestamp: Bool
        var device: Bool
        var channel: Bool
        var aftertouch: Bool
        var alwaysOnTop: Bool
    }

    /// Called when the user closes the window with its close button.
    var onClose: (() -> Void)?

    private(set) var settings: Settings
    private let saveSettings: (Settings) -> Void
    private let store: EventStore
    private let deviceNames: () -> [String]
    private let onClear: () -> Void
    /// Characters of the event column at the natural width, and at the minimum.
    private static let naturalEventChars = 44
    private static let minimumEventChars = 20

    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let lineHeight: CGFloat
    private let charWidth: CGFloat
    private let textField = EventLinesView()
    private var checkboxes: [NSButton] = []
    private var columns = MIDIFormat.Columns(timestamp: true, device: true, channel: true)
    private var renderScheduled = false
    private var controlsWidth: CGFloat = 0

    private let margin: CGFloat = 12
    private let controlsHeight: CGFloat = 52  // two rows of options

    init(store: EventStore, settings: Settings, saveSettings: @escaping (Settings) -> Void,
         deviceNames: @escaping () -> [String], onClear: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        self.saveSettings = saveSettings
        self.deviceNames = deviceNames
        self.onClear = onClear
        lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "MIDIstat — Last Events"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
        updateLayout(resetHeight: true, resetWidth: true)
        panel.setAlwaysOnTop(settings.alwaysOnTop)
        panel.center()
        panel.setFrameAutosaveName("MIDIstatLastEventsWindow")  // restores position and size
        updateLayout(resetHeight: false, resetWidth: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent(in panel: NSPanel) {
        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))

        textField.font = font
        textField.lineHeight = lineHeight
        textField.autoresizingMask = [.width, .height]
        content.addSubview(textField)

        let options: [(String, Bool)] = [
            ("Timestamp", settings.timestamp), ("Device Name", settings.device), ("Channel", settings.channel),
            ("Aftertouch", settings.aftertouch), ("Always on Top", settings.alwaysOnTop),
        ]
        // Two rows (columns on top; Aftertouch and Always on Top below), so that a
        // window showing only the event column stays narrow.
        var x = margin
        for (index, (title, on)) in options.enumerated() {
            if index == 3 { x = margin }
            let checkbox = NSButton.smallCheckbox(title, target: self, action: #selector(toggleOption(_:)))
            checkbox.tag = index
            checkbox.state = on ? .on : .off
            checkbox.setFrameOrigin(NSPoint(x: x, y: index < 3 ? 29 : 8))
            checkbox.autoresizingMask = [.maxXMargin, .maxYMargin]
            content.addSubview(checkbox)
            checkboxes.append(checkbox)
            x += checkbox.frame.width + 10
        }
        // Clear Log after Always on Top, in the second row.
        let clear = NSButton(title: "Clear Log", target: self, action: #selector(clearLog))
        clear.controlSize = .small
        clear.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        clear.bezelStyle = .push
        clear.sizeToFit()
        clear.setFrameOrigin(NSPoint(x: x, y: 4))
        clear.autoresizingMask = [.maxXMargin, .maxYMargin]
        clear.toolTip = "Clear the event history (also the full log and the menu)."
        content.addSubview(clear)
        controlsWidth = max(checkboxes.map(\.frame.maxX).max() ?? 0, clear.frame.maxX) + margin
        panel.contentView = content
    }

    // MARK: - Showing

    /// Also true while hidden, waiting to come back on a regular desktop.
    var isVisible: Bool { window?.isShownOrWaiting == true }

    /// Shows the window without taking the focus away from the current app.
    func show() {
        render()
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

    // MARK: - Content

    /// Called for every new event. Rendering happens on the next pass of the
    /// run loop, so a burst of events costs one update, without visible delay.
    func eventsDidChange() {
        guard isVisible, !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderScheduled = false
            self?.render()
        }
    }

    /// The device column is as wide as the longest input name (within limits).
    func devicesDidChange() {
        updateLayout(resetHeight: false, resetWidth: false)
    }

    private var visibleRows: Int {
        let height = (window?.contentView?.bounds.height ?? 0) - controlsHeight - margin
        return max(Self.minimumRows, Int(height / lineHeight))
    }

    private func render() {
        guard window != nil else { return }
        let events = store.recent(visibleRows, including: settings.aftertouch ? [.aftertouch] : [])
        textField.placeholder = events.isEmpty ? "No MIDI events yet" : nil
        textField.lines = events.map { MIDIFormat.alignedLine(for: $0, columns: columns) }
    }

    func windowDidResize(_ notification: Notification) {
        fitEventColumn()
        render()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateLayout(resetHeight: false, resetWidth: false)
    }

    @objc private func clearLog() {
        onClear()
    }

    /// Characters taken by the enabled columns other than the event description.
    private var fixedChars: Int {
        var withoutEvent = columns
        withoutEvent.eventWidth = 0
        return withoutEvent.totalWidth
    }

    private func width(forEventChars chars: Int) -> CGFloat {
        ceil(CGFloat(fixedChars + chars) * charWidth + 8 + 2 * margin)
    }

    /// The event column takes whatever width is left; longer descriptions end with "…".
    private func fitEventColumn() {
        let available = Int((textField.bounds.width - 8) / charWidth) - fixedChars
        columns.eventWidth = max(Self.minimumEventChars, available)
    }

    /// With `resetWidth` the width fits all enabled columns; otherwise the current
    /// width is kept within the limits. Height: from `minimumRows` lines to the screen.
    private func updateLayout(resetHeight: Bool, resetWidth: Bool) {
        guard let window, let content = window.contentView else { return }
        let longestName = deviceNames().map(\.count).max() ?? 12
        columns = MIDIFormat.Columns(timestamp: settings.timestamp, device: settings.device,
                                     channel: settings.channel, deviceWidth: min(max(longestName, 8), 24))

        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let minWidth = max(controlsWidth, width(forEventChars: Self.minimumEventChars))
        let naturalWidth = max(controlsWidth, width(forEventChars: Self.naturalEventChars))
        let minHeight = CGFloat(Self.minimumRows) * lineHeight + controlsHeight + margin + 6
        window.contentMinSize = NSSize(width: minWidth, height: minHeight)
        window.contentMaxSize = NSSize(width: max(minWidth, screen.width), height: max(minHeight, screen.height))

        let width = resetWidth ? min(naturalWidth, screen.width)
            : min(max(content.bounds.width, minWidth), max(minWidth, screen.width))
        let height = resetHeight ? minHeight : min(max(content.bounds.height, minHeight), screen.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: width, height: height)))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)  // keep the top edge
        window.setFrame(frame, display: true)
        textField.frame = NSRect(x: margin, y: controlsHeight, width: width - 2 * margin,
                                 height: height - controlsHeight - margin)
        fitEventColumn()
        render()
    }

    // MARK: - Options

    @objc private func toggleOption(_ sender: NSButton) {
        let on = sender.state == .on
        let wasOnTop = settings.alwaysOnTop
        let columnsChanged = sender.tag < 3
        switch sender.tag {
        case 0: settings.timestamp = on
        case 1: settings.device = on
        case 2: settings.channel = on
        case 3: settings.aftertouch = on
        default: settings.alwaysOnTop = on
        }
        apply(onTopChanged: settings.alwaysOnTop != wasOnTop, columnsChanged: columnsChanged)
    }

    /// Applies changed settings (from the checkboxes or the control API).
    func update(_ newSettings: Settings) {
        let old = settings
        settings = newSettings
        apply(onTopChanged: settings.alwaysOnTop != old.alwaysOnTop,
              columnsChanged: (old.timestamp, old.device, old.channel) != (settings.timestamp, settings.device, settings.channel))
    }

    private func apply(onTopChanged: Bool, columnsChanged: Bool) {
        let states = [settings.timestamp, settings.device, settings.channel, settings.aftertouch, settings.alwaysOnTop]
        for (checkbox, on) in zip(checkboxes, states) { checkbox.state = on ? .on : .off }
        saveSettings(settings)
        if onTopChanged { window?.setAlwaysOnTop(settings.alwaysOnTop) }
        updateLayout(resetHeight: false, resetWidth: columnsChanged)
    }
}

/// Shows lines of monospaced text, top-aligned, one small text layer per line.
/// When new events arrive the existing lines are only moved up (no redrawing)
/// and just the new lines are drawn, like scrolling. Redrawing one big view for
/// every event made macOS allocate many full-window buffers (~90 MB of graphics
/// memory in scripts/benchmark.sh for a full-height window).
final class EventLinesView: NSView {
    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var lineHeight: CGFloat = 15

    var lines: [String] = [] {
        didSet { if lines != oldValue { update(from: oldValue) } }
    }
    var placeholder: String? {
        didSet { if placeholder != oldValue { placeholderLayer.string = placeholder } }
    }

    /// One layer per shown line, in order (top first).
    private var lineLayers: [CATextLayer] = []
    private let placeholderLayer = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()  // layer-hosting: the view's layer tree is managed here
        layer?.isGeometryFlipped = true  // y grows downwards: first line at the top
        wantsLayer = true
        configure(placeholderLayer)
        layer?.addSublayer(placeholderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func configure(_ text: CATextLayer) {
        text.font = font
        text.fontSize = font.pointSize
        text.truncationMode = .end
        text.isWrapped = false
        text.contentsScale = window?.backingScaleFactor ?? 2
        text.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        text.foregroundColor = color(text === placeholderLayer ? .tertiaryLabelColor : .labelColor)
    }

    private func color(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }

    private func frame(forLine index: Int) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * lineHeight, width: bounds.width, height: lineHeight)
    }

    private func update(from old: [String]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // How far the old lines moved up: old[shift...] continues as new[0...].
        let shift = (0...old.count).first { s in
            let kept = old.count - s
            return kept <= lines.count && Array(old[s...]) == Array(lines.prefix(kept))
        } ?? old.count

        var layers = lineLayers
        let recycled = Array(layers.prefix(shift))
        layers.removeFirst(min(shift, layers.count))
        var spare = recycled
        while layers.count < lines.count {
            let text = spare.popLast() ?? {
                let created = CATextLayer()
                configure(created)
                layer?.addSublayer(created)
                return created
            }()
            text.string = lines[layers.count]  // only new lines are drawn
            layers.append(text)
        }
        while layers.count > lines.count { spare.append(layers.removeLast()) }
        spare.forEach { $0.removeFromSuperlayer() }
        for (index, text) in layers.enumerated() { text.frame = frame(forLine: index) }
        lineLayers = layers
        placeholderLayer.isHidden = !lines.isEmpty
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, text) in lineLayers.enumerated() { text.frame = frame(forLine: index) }
        placeholderLayer.frame = frame(forLine: 0)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        (lineLayers + [placeholderLayer]).forEach { $0.contentsScale = scale }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lineLayers.forEach { $0.foregroundColor = color(.labelColor) }
        placeholderLayer.foregroundColor = color(.tertiaryLabelColor)
    }
}
