import AppKit
import CoreMIDI
import MIDIstatCore
import ServiceManagement

enum Defaults {
    static let inputUniqueID = "inputUniqueID"
    static let inputName = "inputName"
    static let showContinuousRealtime = "showContinuousRealtime"
    static let showAftertouch = "showAftertouch"
    static let showTimestamp = "showTimestamp"
    static let showDeviceName = "showDeviceName"
    static let showChannel = "showChannel"
    static let showLastNotes = "showLastNotes"
    static let lastNotesAlwaysOnTop = "lastNotesAlwaysOnTop"
    static let lastNotesExtraLargeFont = "lastNotesExtraLargeFont"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let recentCount = 10
    private static let activityDuration: TimeInterval = 1

    let defaults = UserDefaults.standard
    let monitor = MIDIMonitor()
    let store = EventStore()
    private var statusItem: NSStatusItem!
    var startError: String?
    lazy var logWindow = LogWindowController(
        store: store,
        shownCategories: { [unowned self] in self.shownCategories },
        setCategory: { [unowned self] category, shown in self.setCategory(category, shown: shown) },
        onClear: { [unowned self] in self.clearLog() })
    lazy var lastNotesWindow: LastNotesWindowController = {
        let controller = LastNotesWindowController(
            settings: .init(alwaysOnTop: defaults.bool(forKey: Defaults.lastNotesAlwaysOnTop),
                            extraLargeFont: defaults.bool(forKey: Defaults.lastNotesExtraLargeFont)),
            saveSettings: { [unowned self] settings in
                self.defaults.set(settings.alwaysOnTop, forKey: Defaults.lastNotesAlwaysOnTop)
                self.defaults.set(settings.extraLargeFont, forKey: Defaults.lastNotesExtraLargeFont)
            })
        // Closing the panel with its close button turns the option off.
        controller.onClose = { [unowned self] in self.defaults.set(false, forKey: Defaults.showLastNotes) }
        return controller
    }()

    var controlServer: ControlServer?
    private var activeUntil = Date.distantPast
    private var activityTimer: Timer?
    var iconState: IconState?

    private var eventItems: [NSMenuItem] = []
    private var hiddenCountItem: NSMenuItem?
    var isMenuOpen = false

    // MARK: - Settings

    /// Optional message categories shown in the event lists (menu and log window).
    var shownCategories: EventCategories {
        var shown: EventCategories = []
        if defaults.bool(forKey: Defaults.showContinuousRealtime) { shown.insert(.continuousRealtime) }
        if defaults.bool(forKey: Defaults.showAftertouch) { shown.insert(.aftertouch) }
        return shown
    }

    func setCategory(_ category: EventCategories, shown: Bool) {
        let key = category == .aftertouch ? Defaults.showAftertouch : Defaults.showContinuousRealtime
        defaults.set(shown, forKey: key)
        logWindow.settingsDidChange()
        if isMenuOpen { updateEventItems() }
    }

    // These affect only the menu list; the log window always shows all of them.
    var showTimestamp: Bool { defaults.bool(forKey: Defaults.showTimestamp) }
    var showDeviceName: Bool { defaults.bool(forKey: Defaults.showDeviceName) }
    var showChannel: Bool { defaults.bool(forKey: Defaults.showChannel) }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            Defaults.showTimestamp: true,
            Defaults.showDeviceName: true,
            Defaults.showChannel: true,
            Defaults.showContinuousRealtime: false,
            Defaults.showAftertouch: false,
            Defaults.showLastNotes: false,
            Defaults.lastNotesAlwaysOnTop: true,
            Defaults.lastNotesExtraLargeFont: false,
        ])
        NSApp.mainMenu = makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        monitor.selection = savedSelection()
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        monitor.onSetupChanged = { [weak self] in
            self?.updateIcon()
            if self?.isMenuOpen == true { self?.rebuildMenu() }
        }
        do {
            try monitor.start()
        } catch {
            startError = "\(error)"
        }
        updateIcon()
        if defaults.bool(forKey: Defaults.showLastNotes) { lastNotesWindow.show() }
        startControlServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
    }

    /// Not visible (the app has no menu bar of its own), but provides the
    /// usual shortcuts in the log window: ⌘C, ⌘A, ⌘L (close the log), ⌘P (MIDI panic), ⌘W, ⌘M, ⌘Q.
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
        ])
        let toggleLog = NSMenuItem(title: "Toggle Full Log", action: #selector(toggleLog), keyEquivalent: "l")
        toggleLog.target = self
        let panic = NSMenuItem(title: "MIDI Panic", action: #selector(sendPanic), keyEquivalent: "p")
        panic.target = self
        submenu("MIDI", [panic])
        let toggleNotes = NSMenuItem(title: "Show Last Notes", action: #selector(toggleLastNotes), keyEquivalent: "n")
        toggleNotes.target = self
        submenu("Window", [
            toggleLog,
            toggleNotes,
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
        ])
        return main
    }

    // MARK: - Events & icon

    private func handle(_ event: MIDIEvent) {
        store.append(event)
        activeUntil = event.date.addingTimeInterval(Self.activityDuration)
        scheduleActivityTimer()
        updateIcon()
        if isMenuOpen { updateEventItems() }
        logWindow.eventsDidChange()
        if case let .noteOn(note, _) = event.kind, lastNotesWindow.isVisible {
            lastNotesWindow.add(note: note)
        }
    }

    func clearLog() {
        store.clear()
        logWindow.settingsDidChange()
        if isMenuOpen { updateEventItems() }
    }

    /// One pending timer that turns the green triangle off 1 s after the last message.
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

    func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true }
    func menuDidClose(_ menu: NSMenu) { isMenuOpen = false }
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

        menu.addItem(.sectionHeader(title: "Last \(Self.recentCount) MIDI Events"))
        eventItems = (0..<Self.recentCount).map { _ in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            menu.addItem(item)
            return item
        }
        let hidden = disabledItem("")
        menu.addItem(hidden)
        hiddenCountItem = hidden
        updateEventItems()

        let fullLog = item("Show Full Log", #selector(toggleLogFromMenu), key: "l")
        fullLog.state = logWindow.isVisible ? .on : .off
        menu.addItem(fullLog)
        let lastNotes = item("Show Last Notes", #selector(toggleLastNotes), key: "n")
        lastNotes.state = lastNotesWindow.isVisible ? .on : .off
        lastNotes.toolTip = "A small window with the last notes played, newest on the left. Widen it to see more notes."
        menu.addItem(lastNotes)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "MIDI Input"))
        addInputItems(to: menu)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Options"))
        menu.addItem(toggleItem("Show Timestamp", key: Defaults.showTimestamp,
                                tip: "Show the seconds.milliseconds timestamp in the list above."))
        menu.addItem(toggleItem("Show Device Name", key: Defaults.showDeviceName,
                                tip: "Show which MIDI input each event came from in the list above."))
        menu.addItem(toggleItem("Show Channel", key: Defaults.showChannel,
                                tip: "Show the MIDI channel (ch: 1–16) in the list above."))
        menu.addItem(toggleItem("Show Clock & Active Sensing", key: Defaults.showContinuousRealtime,
                                tip: "Some devices send these continuously. When hidden, they still light the indicator but are left out of the event lists."))
        menu.addItem(toggleItem("Show Aftertouch", key: Defaults.showAftertouch,
                                tip: "Poly and channel pressure. When hidden, they still light the indicator but are left out of the event lists."))

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed
        default: login.state = .off
        }
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        let panic = item("MIDI Panic", #selector(sendPanic), key: "p")
        let outputs = monitor.destinationCount
        panic.isEnabled = outputs > 0
        panic.toolTip = outputs > 0
            ? "Sends All Sound Off, Reset All Controllers and All Notes Off on all 16 channels to every MIDI output (\(outputs) now)."
            : "No MIDI outputs found."
        menu.addItem(panic)
        menu.addItem(NSMenuItem(title: "Quit MIDIstat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func updateEventItems() {
        let shown = shownCategories
        let events = Array(store.recent(Self.recentCount, including: shown))
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
        for (index, item) in eventItems.enumerated() {
            let text: String
            if index < events.count {
                text = MIDIFormat.line(for: events[index], includeTimestamp: showTimestamp,
                                      includeSource: showDeviceName, includeChannel: showChannel)
            } else if index == 0 && events.isEmpty {
                text = "No MIDI events yet"
            } else {
                item.isHidden = true
                continue
            }
            item.isHidden = false
            item.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
        }

        let summary = store.hiddenSummary(shown: shown)
        hiddenCountItem?.isHidden = summary == nil
        hiddenCountItem?.title = summary ?? ""
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

    /// A checkmark item bound to a Bool in UserDefaults.
    private func toggleItem(_ title: String, key: String, tip: String) -> NSMenuItem {
        let toggle = item(title, #selector(toggleOption(_:)))
        toggle.representedObject = key
        toggle.state = defaults.bool(forKey: key) ? .on : .off
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

    /// The status menu item is a toggle, like Show Last Notes: checked while the
    /// window is open, choosing it again closes the window.
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

    @objc private func toggleOption(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        setOption(key, !defaults.bool(forKey: key))
    }

    /// Sets one of the Bool options shown in the menu (a `Defaults` key).
    func setOption(_ key: String, _ value: Bool) {
        switch key {
        case Defaults.showContinuousRealtime: setCategory(.continuousRealtime, shown: value)
        case Defaults.showAftertouch: setCategory(.aftertouch, shown: value)
        default:
            defaults.set(value, forKey: key)
            if isMenuOpen { updateEventItems() }
        }
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
