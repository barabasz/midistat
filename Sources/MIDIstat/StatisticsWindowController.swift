import AppKit
import MIDIstatCore

/// A small panel with statistics of the notes played: a table of names and
/// values, and below it "Always on Top" and a Reset button (⌘R while the panel is key).
///
/// Values are refreshed at most ten times a second after a note, and every
/// second for the paces that change with time, only while the panel is visible.
final class StatisticsWindowController: NSWindowController, NSWindowDelegate {
    /// Called when the user closes the panel with its close button.
    var onClose: (() -> Void)?

    private let stats: NoteStats
    private let onReset: () -> Void

    struct Settings {
        var alwaysOnTop: Bool
    }

    private(set) var settings: Settings
    private let saveSettings: (Settings) -> Void
    private let onTopCheckbox = NSButton(checkboxWithTitle: "Always on Top", target: nil, action: nil)

    private struct Row {
        let title: String
        let help: String
        let value: (NoteStats, Date) -> String
    }

    private static let dash = "—"

    private static let sections: [(title: String, rows: [Row])] = [
        ("Notes", [
            Row(title: "Since start", help: "Key presses since MIDIstat started; Reset does not change it.") { stats, _ in
                stats.totalCount.formatted()
            },
            Row(title: "Since reset", help: "Key presses since the last Reset.") { stats, _ in
                stats.count.formatted()
            },
        ]),
        ("Notes per minute", [
            Row(title: "Average since reset",
                help: "From the first note after Reset until now, pauses included.") { stats, now in
                stats.count > 0 ? "\(stats.averagePerMinute(at: now))" : dash
            },
            Row(title: "Last minute",
                help: "Notes of the last 60 seconds. During the first minute of playing, projected from the notes so far.") { stats, now in
                "\(stats.perMinute(over: 60, at: now))"
            },
            Row(title: "Last 15 seconds",
                help: "Notes of the last 15 seconds, as a pace per minute. Shows changes of pace sooner.") { stats, now in
                "\(stats.perMinute(over: NoteStats.shortWindow, at: now))"
            },
            Row(title: "Peak (15 seconds)",
                help: "The highest pace over 15 seconds since Reset, after at least 15 seconds of playing.") { stats, _ in
                stats.peakPerMinute > 0 ? "\(stats.peakPerMinute)" : dash
            },
        ]),
        ("Since reset", [
            Row(title: "Time since first note", help: "Time since the first note after Reset.") { stats, now in
                stats.firstNoteDate.map { NoteStats.formatDuration(now.timeIntervalSince($0)) } ?? dash
            },
            Row(title: "Note range", help: "The lowest and the highest note played.") { stats, _ in
                guard let low = stats.lowestNote, let high = stats.highestNote else { return dash }
                return low == high ? MIDIFormat.noteName(low)
                    : "\(MIDIFormat.noteName(low)) – \(MIDIFormat.noteName(high))"
            },
            Row(title: "Average velocity", help: "How hard the keys were pressed, 1–127.") { stats, _ in
                stats.averageVelocity.map(String.init) ?? dash
            },
            Row(title: "Velocity range", help: "The softest and the hardest key press, 1–127.") { stats, _ in
                guard let soft = stats.softestVelocity, let loud = stats.loudestVelocity else { return dash }
                return soft == loud ? "\(soft)" : "\(soft) – \(loud)"
            },
        ]),
    ]

    /// Value labels in the order of the rows.
    private var valueLabels: [NSTextField] = []
    private var refreshTimer: Timer?
    private var refreshScheduled = false

    init(stats: NoteStats, settings: Settings, saveSettings: @escaping (Settings) -> Void,
         onReset: @escaping () -> Void) {
        self.stats = stats
        self.settings = settings
        self.saveSettings = saveSettings
        self.onReset = onReset
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "MIDIstat — Statistics"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false  // stay visible while another app is in front
        // Clicking the panel makes it key (for ⌘R) without activating the app.
        panel.becomesKeyOnlyIfNeeded = false
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
        applyAlwaysOnTop()
        panel.center()
        panel.setFrameAutosaveName("MIDIstatStatisticsWindow")  // restores the position
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent(in panel: NSPanel) {
        let margin: CGFloat = 16
        let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let nameFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)

        let grid = NSGridView()
        grid.rowSpacing = 4
        grid.columnSpacing = 24
        var headerRows: [Int] = []
        for (sectionIndex, section) in Self.sections.enumerated() {
            let header = NSTextField(labelWithString: section.title.uppercased())
            header.font = headerFont
            header.textColor = .secondaryLabelColor
            grid.addRow(with: [header, NSGridCell.emptyContentView])
            headerRows.append(grid.numberOfRows - 1)
            if sectionIndex > 0 { grid.row(at: grid.numberOfRows - 1).topPadding = 10 }
            for row in section.rows {
                let name = NSTextField(labelWithString: row.title)
                name.font = nameFont
                name.toolTip = row.help
                let value = NSTextField(labelWithString: Self.dash)
                value.font = valueFont
                value.alignment = .right
                value.toolTip = row.help
                value.setAccessibilityLabel(row.title)
                grid.addRow(with: [name, value])
                valueLabels.append(value)
            }
        }
        for index in headerRows { grid.row(at: index).mergeCells(in: NSRange(location: 0, length: 2)) }
        grid.column(at: 1).xPlacement = .trailing
        // Room for wide values, so that the window doesn't change size.
        grid.column(at: 1).width = ceil(("C#-1 – C#-1" as NSString).size(withAttributes: [.font: valueFont]).width)

        let reset = NSButton(title: "Reset", target: self, action: #selector(resetStats))
        reset.controlSize = .small
        reset.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        reset.bezelStyle = .push
        reset.keyEquivalent = "r"
        reset.keyEquivalentModifierMask = .command
        reset.toolTip = "Reset all statistics except the notes since start (⌘R after clicking the window)."
        reset.sizeToFit()
        let shortcut = NSTextField(labelWithString: "⌘R")
        shortcut.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shortcut.textColor = .tertiaryLabelColor
        shortcut.sizeToFit()

        let gridSize = grid.fittingSize
        onTopCheckbox.target = self
        onTopCheckbox.action = #selector(toggleAlwaysOnTop(_:))
        onTopCheckbox.controlSize = .small
        onTopCheckbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        onTopCheckbox.sizeToFit()

        let height = margin + reset.frame.height + 12 + gridSize.height + margin
        // The table, or the bottom row if it is wider.
        let bottomRowWidth = onTopCheckbox.frame.width + 12 + reset.frame.width + 2 + shortcut.frame.width
        let width = max(gridSize.width, bottomRowWidth) + 2 * margin
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        grid.frame = NSRect(x: margin, y: height - margin - gridSize.height,
                            width: gridSize.width, height: gridSize.height)
        // Always on Top, then Reset and its shortcut, in one row.
        onTopCheckbox.setFrameOrigin(NSPoint(x: margin - 1, y: margin))
        reset.setFrameOrigin(NSPoint(x: onTopCheckbox.frame.maxX + 12,
                                     y: onTopCheckbox.frame.midY - reset.frame.height / 2))
        shortcut.setFrameOrigin(NSPoint(x: reset.frame.maxX + 2,
                                        y: reset.frame.midY - shortcut.frame.height / 2))
        [grid, onTopCheckbox, reset, shortcut].forEach(content.addSubview)
        // Size first: setting the content view resizes it to the current content size.
        panel.setContentSize(content.frame.size)
        panel.contentView = content
    }

    // MARK: - Showing

    /// Also true while hidden, waiting to come back on a regular desktop.
    var isVisible: Bool { window?.isShownOrWaiting == true }

    /// Shows the panel without taking the focus away from the current app.
    func show() {
        if let window { DesktopReturn.cancel(window) }  // opened explicitly: show it here
        window?.orderFrontRegardless()
        refresh()
        startTimer()
    }

    func hide() {
        if let window { DesktopReturn.cancel(window) }
        window?.orderOut(nil)
        stopTimer()
    }

    func windowWillClose(_ notification: Notification) {
        if let window { DesktopReturn.cancel(window) }
        stopTimer()
        onClose?()
    }

    // MARK: - Values

    /// Called for every note and after a reset. Labels of a hidden window are
    /// not touched; while visible, a burst of notes costs one refresh per 0.1 s.
    func statsDidChange() {
        guard window?.isVisible == true, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        guard window?.isVisible == true else { return }
        let now = Date()
        let rows = Self.sections.flatMap(\.rows)
        for (row, label) in zip(rows, valueLabels) {
            let text = row.value(stats, now)
            if label.stringValue != text { label.stringValue = text }
        }
    }

    /// The paces and the time change without notes, so they are refreshed every second.
    private func startTimer() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
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

    @objc private func resetStats() {
        onReset()
    }
}
