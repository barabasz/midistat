import AppKit
import CoreMIDI
import MIDIstatCore
import ServiceManagement

enum Defaults {
    static let inputUniqueID = "inputUniqueID"
    static let inputName = "inputName"
    // Last Events window (also used for the last event in the menu)
    static let showLastEvents = "showLastEvents"
    static let showTimestamp = "showTimestamp"
    static let showDeviceName = "showDeviceName"
    static let showChannel = "showChannel"
    static let showAftertouch = "showAftertouch"
    static let lastEventsAlwaysOnTop = "lastEventsAlwaysOnTop"
    // Full log window
    static let logShowAftertouch = "logShowAftertouch"
    static let logAlwaysOnTop = "logAlwaysOnTop"
    // Last Notes window
    static let showLastNotes = "showLastNotes"
    static let lastNotesAlwaysOnTop = "lastNotesAlwaysOnTop"
    static let lastNotesExtraLargeFont = "lastNotesExtraLargeFont"
    static let lastNotesVelocity = "lastNotesVelocity"
    static let lastNotesColored = "lastNotesColored"
    static let lastNotesValues = "lastNotesValues"
    // All windows: "auto", "light" or "dark"
    static let appearance = "appearance"
    // Statistics window
    static let showStatistics = "showStatistics"
    static let statisticsAlwaysOnTop = "statisticsAlwaysOnTop"
}

/// The appearance of MIDIstat's windows.
enum AppearanceChoice: String, CaseIterable {
    case auto, light, dark

    var title: String {
        switch self {
        case .auto: "Auto (System)"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil follows the system setting.
    var appearance: NSAppearance? {
        switch self {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let activityDuration: TimeInterval = 1

    let defaults = UserDefaults.standard
    let monitor = MIDIMonitor()
    let store = EventStore()
    let clock = ClockTracker()
    let activeSensing = ActiveSensingTracker()
    /// Statistics of the key presses (Note On), shown in the Statistics window.
    let noteStats = NoteStats()
    private var statusItem: NSStatusItem!
    var startError: String?

    lazy var logWindow: LogWindowController = {
        let controller = LogWindowController(
            store: store,
            settings: .init(aftertouch: defaults.bool(forKey: Defaults.logShowAftertouch),
                            alwaysOnTop: defaults.bool(forKey: Defaults.logAlwaysOnTop)),
            saveSettings: { [unowned self] settings in
                self.defaults.set(settings.aftertouch, forKey: Defaults.logShowAftertouch)
                self.defaults.set(settings.alwaysOnTop, forKey: Defaults.logAlwaysOnTop)
            },
            deviceNames: { [unowned self] in self.monitor.sources.map(\.name) },
            onClear: { [unowned self] in self.clearLog() })
        adoptAppearance(controller)
        return controller
    }()

    lazy var lastEventsWindow: LastEventsWindowController = {
        let controller = LastEventsWindowController(
            store: store,
            settings: .init(timestamp: defaults.bool(forKey: Defaults.showTimestamp),
                            device: defaults.bool(forKey: Defaults.showDeviceName),
                            channel: defaults.bool(forKey: Defaults.showChannel),
                            aftertouch: defaults.bool(forKey: Defaults.showAftertouch),
                            alwaysOnTop: defaults.bool(forKey: Defaults.lastEventsAlwaysOnTop)),
            saveSettings: { [unowned self] settings in
                self.defaults.set(settings.timestamp, forKey: Defaults.showTimestamp)
                self.defaults.set(settings.device, forKey: Defaults.showDeviceName)
                self.defaults.set(settings.channel, forKey: Defaults.showChannel)
                self.defaults.set(settings.aftertouch, forKey: Defaults.showAftertouch)
                self.defaults.set(settings.alwaysOnTop, forKey: Defaults.lastEventsAlwaysOnTop)
            },
            deviceNames: { [unowned self] in self.monitor.sources.map(\.name) },
            onClear: { [unowned self] in self.clearLog() })
        controller.onClose = { [unowned self] in self.defaults.set(false, forKey: Defaults.showLastEvents) }
        adoptAppearance(controller)
        return controller
    }()

    lazy var lastNotesWindow: LastNotesWindowController = {
        let controller = LastNotesWindowController(
            settings: .init(alwaysOnTop: defaults.bool(forKey: Defaults.lastNotesAlwaysOnTop),
                            extraLargeFont: defaults.bool(forKey: Defaults.lastNotesExtraLargeFont),
                            velocity: defaults.bool(forKey: Defaults.lastNotesVelocity),
                            colored: defaults.bool(forKey: Defaults.lastNotesColored),
                            values: defaults.bool(forKey: Defaults.lastNotesValues)),
            saveSettings: { [unowned self] settings in
                self.defaults.set(settings.alwaysOnTop, forKey: Defaults.lastNotesAlwaysOnTop)
                self.defaults.set(settings.extraLargeFont, forKey: Defaults.lastNotesExtraLargeFont)
                self.defaults.set(settings.velocity, forKey: Defaults.lastNotesVelocity)
                self.defaults.set(settings.colored, forKey: Defaults.lastNotesColored)
                self.defaults.set(settings.values, forKey: Defaults.lastNotesValues)
            })
        // Closing the panel with its close button turns the option off.
        controller.onClose = { [unowned self] in self.defaults.set(false, forKey: Defaults.showLastNotes) }
        adoptAppearance(controller)
        return controller
    }()

    lazy var statisticsWindow: StatisticsWindowController = {
        let controller = StatisticsWindowController(
            stats: noteStats,
            settings: .init(alwaysOnTop: defaults.bool(forKey: Defaults.statisticsAlwaysOnTop)),
            saveSettings: { [unowned self] settings in
                self.defaults.set(settings.alwaysOnTop, forKey: Defaults.statisticsAlwaysOnTop)
            },
            onReset: { [unowned self] in self.resetNoteStats() })
        // Closing the panel with its close button turns the option off.
        controller.onClose = { [unowned self] in self.defaults.set(false, forKey: Defaults.showStatistics) }
        adoptAppearance(controller)
        return controller
    }()

    var controlServer: ControlServer?
    private var activeUntil = Date.distantPast
    private var activityTimer: Timer?
    var iconState: IconState?

    // Menu items updated live while the menu is open.
    private var lastEventItems: [NSMenuItem] = []
    private var clockItem: NSMenuItem?
    private var activeSensingItem: NSMenuItem?
    private var menuRefreshTimer: Timer?
    var isMenuOpen = false

    /// The Last Events window's aftertouch option (also used by `ctl events`).
    var lastEventsCategories: EventCategories {
        defaults.bool(forKey: Defaults.showAftertouch) ? [.aftertouch] : []
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            Defaults.showLastEvents: false,
            Defaults.showTimestamp: true,
            Defaults.showDeviceName: true,
            Defaults.showChannel: true,
            Defaults.showAftertouch: false,
            Defaults.lastEventsAlwaysOnTop: true,
            Defaults.logShowAftertouch: false,
            Defaults.logAlwaysOnTop: false,
            Defaults.showLastNotes: false,
            Defaults.lastNotesAlwaysOnTop: true,
            Defaults.lastNotesExtraLargeFont: false,
            Defaults.lastNotesVelocity: false,
            Defaults.lastNotesColored: false,
            Defaults.lastNotesValues: false,
            Defaults.showStatistics: false,
            Defaults.appearance: AppearanceChoice.auto.rawValue,
            Defaults.statisticsAlwaysOnTop: true,
        ])
        defaults.removeObject(forKey: "showContinuousRealtime")  // option removed in 0.7
        NSApp.mainMenu = makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        monitor.selection = savedSelection()
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        monitor.onSetupChanged = { [weak self] in
            guard let self else { return }
            self.updateIcon()
            self.lastEventsWindow.devicesDidChange()
            if self.isMenuOpen { self.rebuildMenu() }
        }
        do {
            try monitor.start()
        } catch {
            startError = "\(error)"
        }
        updateIcon()
        if defaults.bool(forKey: Defaults.showLastEvents) { lastEventsWindow.show() }
        if defaults.bool(forKey: Defaults.showLastNotes) { lastNotesWindow.show() }
        if defaults.bool(forKey: Defaults.showStatistics) { statisticsWindow.show() }
        startControlServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
    }

    /// Not visible (the app has no menu bar of its own), but provides the usual
    /// shortcuts while one of its windows has focus: ⌘C, ⌘A, ⌘F (log filter),
    /// ⌘L / ⌘E / ⌘N (toggle the windows), ⌘P (MIDI panic), ⌘W, ⌘M, ⌘Q.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        submenu("MIDIstat", [NSMenuItem(title: "Quit MIDIstat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")])
        submenu("Edit", [
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
            item("Filter Log", #selector(focusLogFilter), key: "f"),
        ])
        submenu("MIDI", [item("MIDI Panic", #selector(sendPanic), key: "p")])
        submenu("Window", [
            item("Toggle Full Log", #selector(toggleLog), key: "l"),
            item("Show Last Events", #selector(toggleLastEvents), key: "e"),
            item("Show Last Notes", #selector(toggleLastNotes), key: "n"),
            item("Show Statistics", #selector(toggleStatistics), key: "s"),
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
        ])
        return main
    }

    // MARK: - Events & icon

    private func handle(_ event: MIDIEvent) {
        activeUntil = event.date.addingTimeInterval(Self.activityDuration)
        scheduleActivityTimer()
        updateIcon()

        // Clock and Active Sensing are summarised, not listed.
        clock.handle(event)
        activeSensing.handle(event)
        guard event.category != .continuousRealtime else { return }

        store.append(event)
        if isMenuOpen { updateLastEventItems() }
        logWindow.eventsDidChange()
        lastEventsWindow.eventsDidChange()
        if case let .noteOn(note, velocity) = event.kind {
            noteStats.add(note: note, velocity: velocity, at: event.date)
            statisticsWindow.statsDidChange()
            if lastNotesWindow.isVisible { lastNotesWindow.add(note: note, velocity: velocity) }
        }
    }

    func clearLog() {
        store.clear()
        logWindow.settingsDidChange()
        lastEventsWindow.eventsDidChange()
        if isMenuOpen { updateLastEventItems() }
    }

    /// Resets all statistics except the notes since start.
    func resetNoteStats() {
        noteStats.reset()
        statisticsWindow.statsDidChange()
    }

    /// One pending timer that turns the green indicator off 1 s after the last message.
    private func scheduleActivityTimer() {
        guard activityTimer == nil else { return }
        let timer = Timer(fire: activeUntil, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.activityTimer = nil
            if Date() < self.activeUntil { self.scheduleActivityTimer() }
            self.updateIcon()
        }
        RunLoop.main.add(timer, forMode: .common)  // keeps running while the menu is open
        activityTimer = timer
    }

    func updateIcon() {
        let state: IconState
        if !monitor.isListening {
            state = .noDevice
        } else if Date() < activeUntil {
            state = .active
        } else {
            state = .idle
        }
        guard state != iconState, let button = statusItem.button else { return }
        iconState = state
        button.image = StatusIcon.image(for: state)
        button.toolTip = state.accessibilityDescription
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        // Clock tempo and presence change without list events: refresh twice a second.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateRealtimeItems() }
        RunLoop.main.add(timer, forMode: .common)
        menuRefreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        menu.addItem(disabledItem("MIDIstat \(Updater.currentVersion)"))
        menu.addItem(.separator())

        if let startError {
            menu.addItem(disabledItem("MIDI unavailable: \(startError)"))
            menu.addItem(.separator())
        }

        menu.addItem(.sectionHeader(title: "Last MIDI Event"))
        lastEventItems = (0..<3).map { _ in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            menu.addItem(item)
            return item
        }
        let clockLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let sensingLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        clockLine.toolTip = "MIDI Clock synchronises tempo; it is sent by a DAW, drum machine or sequencer."
        sensingLine.toolTip = "Active Sensing is a \u{201C}still connected\u{201D} signal some instruments send every ~300 ms."
        menu.addItem(clockLine)
        menu.addItem(sensingLine)
        clockItem = clockLine
        activeSensingItem = sensingLine
        updateLastEventItems()
        updateRealtimeItems()

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Floating Windows"))
        menu.addItem(windowItem("Show Full Log", #selector(toggleLogFromMenu), key: "l", open: logWindow.isVisible,
                                tip: "All MIDI events since MIDIstat started, in a table."))
        menu.addItem(windowItem("Show Last Events", #selector(toggleLastEvents), key: "e", open: lastEventsWindow.isVisible,
                                tip: "A compact window with the most recent events, updated instantly."))
        menu.addItem(windowItem("Show Last Notes", #selector(toggleLastNotes), key: "n", open: lastNotesWindow.isVisible,
                                tip: "The last notes played in large type, newest on the left."))
        menu.addItem(windowItem("Show Statistics", #selector(toggleStatistics), key: "s", open: statisticsWindow.isVisible,
                                tip: "Notes count, notes per minute, velocity and range of the notes played."))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "MIDI Input"))
        addInputItems(to: menu)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Options"))
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin), key: "l")
        login.keyEquivalentModifierMask = [.option]
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed
        default: login.state = .off
        }
        menu.addItem(login)
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearance.toolTip = "Light or dark windows, or following the system setting."
        let appearanceMenu = NSMenu(title: "Appearance")
        appearanceMenu.autoenablesItems = false
        for choice in AppearanceChoice.allCases {
            let choiceItem = item(choice.title, #selector(selectAppearance(_:)))
            choiceItem.representedObject = choice.rawValue
            choiceItem.state = choice == appearanceChoice ? .on : .off
            appearanceMenu.addItem(choiceItem)
        }
        appearance.submenu = appearanceMenu
        menu.addItem(appearance)

        menu.addItem(.separator())
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates), key: "u"))
        let panic = item("MIDI Panic", #selector(sendPanic), key: "p")
        let outputs = monitor.destinationCount
        panic.isEnabled = outputs > 0
        panic.toolTip = outputs > 0
            ? "Sends All Sound Off, Reset All Controllers and All Notes Off on all 16 channels to every MIDI output (\(outputs) now)."
            : "No MIDI outputs found."
        menu.addItem(panic)
        menu.addItem(NSMenuItem(title: "Quit MIDIstat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private static let fullTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// The last event in three lines: time, device and channel, event.
    func updateLastEventItems() {
        guard lastEventItems.count == 3 else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
        let label: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let value: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        func line(_ parts: [(String, String)]) -> NSAttributedString {
            let text = NSMutableAttributedString()
            for (index, (name, content)) in parts.enumerated() {
                if index > 0 { text.append(NSAttributedString(string: "    ", attributes: value)) }
                text.append(NSAttributedString(string: "\(name): ", attributes: label))
                text.append(NSAttributedString(string: content, attributes: value))
            }
            return text
        }

        // Everything, aftertouch included: the menu is the quick "is anything arriving?" check.
        guard let event = store.recent(1, including: .all).last else {
            lastEventItems[0].attributedTitle = NSAttributedString(string: "No MIDI events yet", attributes: label)
            lastEventItems[1].isHidden = true
            lastEventItems[2].isHidden = true
            return
        }
        var source: [(String, String)] = [("Device", event.source ?? "unknown")]
        if let channel = event.channel { source.append(("Channel", String(channel))) }
        lastEventItems[0].attributedTitle = line([("Time", Self.fullTime.string(from: event.date))])
        lastEventItems[1].attributedTitle = line(source)
        lastEventItems[2].attributedTitle = line([("Event", MIDIFormat.description(of: event.kind))])
        lastEventItems[1].isHidden = false
        lastEventItems[2].isHidden = false
    }

    /// MIDI Clock and Active Sensing lines, shown only while they arrive.
    func updateRealtimeItems() {
        let now = Date()
        for (item, text) in [(clockItem, clock.summary(at: now)), (activeSensingItem, activeSensing.summary(at: now))] {
            guard let item else { continue }
            item.isHidden = text == nil
            if let text {
                item.attributedTitle = NSAttributedString(string: text, attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
            }
        }
    }

    private func addInputItems(to menu: NSMenu) {
        let all = item("Listen to All MIDI Inputs", #selector(selectAllInputs), key: "a")
        all.state = monitor.selection == .all ? .on : .off
        menu.addItem(all)

        var selectedIsPresent = false
        for source in monitor.sources {
            let sourceItem = item(source.name, #selector(selectInput(_:)))
            sourceItem.representedObject = source
            sourceItem.indentationLevel = 1
            if case let .source(uniqueID, _) = monitor.selection, uniqueID == source.uniqueID {
                sourceItem.state = .on
                selectedIsPresent = true
            }
            menu.addItem(sourceItem)
        }

        if case let .source(_, name) = monitor.selection, !selectedIsPresent {
            let missing = disabledItem("\(name) (disconnected)")
            missing.state = .on
            missing.indentationLevel = 1
            menu.addItem(missing)
        }
        if monitor.sources.isEmpty {
            let none = disabledItem("No MIDI devices found")
            none.indentationLevel = 1
            menu.addItem(none)
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// A window toggle: checked while the window is open.
    private func windowItem(_ title: String, _ action: Selector, key: String, open: Bool, tip: String) -> NSMenuItem {
        let toggle = item(title, action, key: key)
        toggle.state = open ? .on : .off
        toggle.toolTip = tip
        return toggle
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func showLog() {
        // Let the status menu finish closing before bringing the window forward.
        DispatchQueue.main.async { self.logWindow.show() }
    }

    /// The status menu item is a toggle, like the other windows: checked while
    /// the window is open, choosing it again closes the window.
    @objc private func toggleLogFromMenu() {
        if logWindow.isVisible {
            logWindow.closeLog()
        } else {
            showLog()
        }
    }

    /// ⌘L while the log window is focused closes it; otherwise opens it.
    @objc private func toggleLog() {
        if logWindow.isKeyAndVisible {
            logWindow.closeLog()
        } else {
            showLog()
        }
    }

    /// ⌘F: the filter field of the log window.
    @objc private func focusLogFilter() {
        logWindow.focusFilter()
    }

    @objc private func selectAllInputs() {
        setInput(.all)
    }

    @objc private func selectInput(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? MIDISource else { return }
        setInput(.source(uniqueID: source.uniqueID, name: source.name))
    }

    /// Selects the input(s) to listen to and remembers the choice.
    func setInput(_ selection: InputSelection) {
        switch selection {
        case .all:
            defaults.removeObject(forKey: Defaults.inputUniqueID)
            defaults.removeObject(forKey: Defaults.inputName)
        case let .source(uniqueID, name):
            defaults.set(Int(uniqueID), forKey: Defaults.inputUniqueID)
            defaults.set(name, forKey: Defaults.inputName)
        }
        monitor.selection = selection
        updateIcon()
        if isMenuOpen { rebuildMenu() }
    }

    /// ⌘E: shows or hides the Last Events window; the choice is remembered.
    @objc private func toggleLastEvents() {
        setLastEventsVisible(!lastEventsWindow.isVisible)
    }

    func setLastEventsVisible(_ show: Bool) {
        defaults.set(show, forKey: Defaults.showLastEvents)
        if show {
            lastEventsWindow.show()
        } else {
            lastEventsWindow.hide()
        }
    }

    /// ⌘N: shows or hides the Last Notes panel; the choice is remembered.
    @objc private func toggleLastNotes() {
        setLastNotesVisible(!lastNotesWindow.isVisible)
    }

    func setLastNotesVisible(_ show: Bool) {
        defaults.set(show, forKey: Defaults.showLastNotes)
        if show {
            lastNotesWindow.show()
        } else {
            lastNotesWindow.hide()
        }
    }

    /// ⌘S: shows or hides the Statistics panel; the choice is remembered.
    @objc private func toggleStatistics() {
        setStatisticsVisible(!statisticsWindow.isVisible)
    }

    func setStatisticsVisible(_ show: Bool) {
        defaults.set(show, forKey: Defaults.showStatistics)
        if show {
            statisticsWindow.show()
        } else {
            statisticsWindow.hide()
        }
    }

    // MARK: - Updates

    @objc private func checkForUpdates() {
        Task { @MainActor in
            do {
                let check = try await Updater.check()
                NSApp.activateTakingFocus()
                guard check.updateAvailable else {
                    let alert = NSAlert()
                    alert.messageText = "You’re up to date"
                    alert.informativeText = "MIDIstat \(check.current) is the latest version."
                    alert.runModal()
                    return
                }
                if Self.updateAlert(for: check).runModal() == .alertFirstButtonReturn {
                    await upgrade(to: check.latest)
                }
            } catch {
                showUpdateError("Could not check for updates", error, pageURL: nil)
            }
        }
    }

    /// "MIDIstat x is available": up to 5 changes (newest first, from all releases
    /// since the installed one), then "…and N more. See all changes" with a link.
    static func updateAlert(for check: Updater.Check) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "MIDIstat \(check.latest.version) is available"
        let changes = check.changes.shown.map { "• \($0)" }.joined(separator: "\n")
        alert.informativeText = "You have version \(check.current)."
            + (changes.isEmpty ? "" : "\n\nWhat’s new:\n\(changes)")

        // NSAlert's text cannot contain links, so the rest goes into an accessory view.
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSMutableAttributedString()
        func add(_ string: String, _ attributes: [NSAttributedString.Key: Any] = [:]) {
            text.append(NSAttributedString(string: string, attributes: [.font: font].merging(attributes) { $1 }))
        }
        if check.changes.more > 0 {
            add("…and \(check.changes.more) more. ")
            add("See all changes", [.link: check.allChangesURL])
            add("\n\n")
        } else if !check.changes.shown.isEmpty {
            add("See all changes", [.link: check.allChangesURL])
            add("\n\n")
        }
        add("Upgrade downloads the new version, replaces this one and restarts MIDIstat.",
            [.foregroundColor: NSColor.secondaryLabelColor])

        let field = NSTextField(labelWithAttributedString: text)
        field.isSelectable = true               // needed for the link to be clickable
        field.allowsEditingTextAttributes = true
        field.preferredMaxLayoutWidth = 260
        field.frame.size = field.fittingSize
        alert.accessoryView = field

        alert.addButton(withTitle: "Upgrade")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    @MainActor private func upgrade(to release: Updater.Release) async {
        do {
            let bundle = Bundle.main.bundleURL
            guard bundle.pathExtension == "app", let identifier = Bundle.main.bundleIdentifier else {
                throw Updater.UpdateError("Only the MIDIstat.app bundle can be updated.")
            }
            let newApp = try await Updater.downloadAndVerify(release, bundleIdentifier: identifier)
            try Updater.install(newApp, replacing: bundle)
            NSApp.terminate(nil)
        } catch {
            showUpdateError("Could not upgrade MIDIstat", error, pageURL: release.pageURL)
        }
    }

    private func showUpdateError(_ title: String, _ error: Error, pageURL: URL?) {
        NSApp.activateTakingFocus()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
            + (pageURL == nil ? "" : "\n\nYou can download the new version from its release page.")
        if pageURL != nil {
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Close")
        }
        if alert.runModal() == .alertFirstButtonReturn, let pageURL {
            NSWorkspace.shared.open(pageURL)
        }
    }

    @objc private func sendPanic() {
        monitor.sendPanic()
    }

    // MARK: - Appearance

    var appearanceChoice: AppearanceChoice {
        AppearanceChoice(rawValue: defaults.string(forKey: Defaults.appearance) ?? "") ?? .auto
    }

    /// Windows created so far; windows are created lazily, on first use.
    private static var appearanceWindows: [NSWindow] = []

    /// Gives a newly created window the chosen appearance and follows later changes.
    private func adoptAppearance(_ controller: NSWindowController) {
        guard let window = controller.window else { return }
        window.appearance = appearanceChoice.appearance
        Self.appearanceWindows.append(window)
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = AppearanceChoice(rawValue: raw) else { return }
        setAppearance(choice)
    }

    /// Applies to all MIDIstat windows; the menu keeps following the menu bar.
    func setAppearance(_ choice: AppearanceChoice) {
        defaults.set(choice.rawValue, forKey: Defaults.appearance)
        Self.appearanceWindows.forEach { $0.appearance = choice.appearance }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            NSApp.activateTakingFocus()
            let alert = NSAlert(error: error)
            alert.messageText = "Could not change “Launch at Login”"
            alert.informativeText = "\(error.localizedDescription)\n\nTip: move MIDIstat.app to the Applications folder and try again."
            alert.runModal()
        }
    }

    private func savedSelection() -> InputSelection {
        guard let id = defaults.object(forKey: Defaults.inputUniqueID) as? Int else { return .all }
        let name = defaults.string(forKey: Defaults.inputName) ?? "Unknown MIDI source"
        return .source(uniqueID: MIDIUniqueID(truncatingIfNeeded: id), name: name)
    }
}
