import AppKit
import CoreMIDI
import MIDIstatCore
import ServiceManagement

/// Commands of the local control API (`MIDIstat ctl <command>`). Changes go
/// through the same code paths as the menu, so they are saved and shown the same way.
extension AppDelegate {
    static let controlUsage = [
        "ver                            the MIDIstat version",
        "status                         the whole state: indicator, input, options, windows, event counts",
        "devices                        MIDI inputs and outputs seen by MIDIstat",
        "updates                        check GitHub for a newer release (does not install it)",
        "events [N]                     the last N events as shown in the lists (default 10, max 1000)",
        "set <option> <on|off|toggle>   options: timestamp, device-name, clock, aftertouch,",
        "                               notes-on-top, notes-xlarge, launch-at-login",
        "input all | input <name|ID>    listen to all inputs, or to one (exact name or unique ID)",
        "open <log|notes>               show a window (without taking the focus)",
        "close <log|notes>              hide a window",
        "clear-log                      clear the event history (log window and menu list)",
        "panic                          send MIDI panic to all outputs",
        "help                           this list",
    ]

    /// Option names of `set` and of `status.options`, mapped to UserDefaults keys
    /// (the Last Notes and login options are handled separately).
    private static let listOptions: [String: String] = [
        "timestamp": Defaults.showTimestamp,
        "device-name": Defaults.showDeviceName,
        "clock": Defaults.showContinuousRealtime,
        "aftertouch": Defaults.showAftertouch,
    ]

    private struct ControlError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    func startControlServer() {
        let server = ControlServer(handler: { [unowned self] request in self.handleControlCommand(request) },
                                   backgroundHandler: { [unowned self] request in self.handleSlowControlCommand(request) })
        do {
            try server.start()
            controlServer = server
        } catch {
            NSLog("MIDIstat: control API unavailable: \(error)")
        }
    }

    func handleControlCommand(_ request: String) -> String {
        let words = request.split(separator: " ").map(String.init)
        let command = words.first?.lowercased() ?? "help"
        let arguments = Array(words.dropFirst())
        do {
            switch command {
            case "help":
                return json(["ok": true, "usage": Self.controlUsage])
            case "status":
                return json(["ok": true, "status": controlStatus()])
            case "ver", "version":
                return json(["ok": true, "name": "MIDIstat", "version": Updater.currentVersion,
                             "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"])
            case "devices":
                return json([
                    "ok": true,
                    "inputs": monitor.sources.map {
                        ["name": $0.name, "uniqueID": Int($0.uniqueID), "listening": monitor.isConnected($0)]
                    },
                    "outputs": monitor.outputs.map { ["name": $0.name, "uniqueID": Int($0.uniqueID)] },
                ])
            case "events":
                var count = 10
                if let argument = arguments.first {
                    guard let n = Int(argument), n > 0 else { throw ControlError("events: N must be a positive number") }
                    count = min(n, 1000)
                }
                let events = store.recent(count, including: shownCategories).map(eventJSON)
                return json(["ok": true, "events": events])
            case "set":
                guard arguments.count == 2 else { throw ControlError("usage: set <option> <on|off|toggle>") }
                try setControlOption(arguments[0].lowercased(), arguments[1].lowercased())
            case "input":
                try selectControlInput(arguments.joined(separator: " "))
            case "open", "close":
                let open = command == "open"
                switch arguments.first?.lowercased() {
                case "log": open ? logWindow.show(takeFocus: false) : logWindow.closeLog()
                case "notes": setLastNotesVisible(open)
                default: throw ControlError("usage: \(command) <log|notes>")
                }
            case "clear-log":
                clearLog()
            case "panic":
                return json(["ok": true, "outputs": monitor.sendPanic()])
            default:
                throw ControlError("unknown command '\(command)'; try: help")
            }
            if isMenuOpen { rebuildMenu() }
            return json(["ok": true, "status": controlStatus()])
        } catch {
            return json(["ok": false, "error": "\(error)"])
        }
    }

    /// Commands that wait for the network; they run on the control thread, not the main thread.
    func handleSlowControlCommand(_ request: String) -> String? {
        guard request.split(separator: " ").first?.lowercased() == "updates" else { return nil }
        final class Box { var result: Result<Updater.Release, Error>? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await Updater.latestRelease()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        let current = Updater.currentVersion
        switch box.result {
        case let .success(release):
            return json(["ok": true, "current": current, "latest": release.version,
                         "updateAvailable": Updater.isNewer(release.version, than: current),
                         "releasePage": release.pageURL.absoluteString])
        case let .failure(error):
            return json(["ok": false, "error": "could not check for updates: \(error.localizedDescription)"])
        case nil:
            return json(["ok": false, "error": "could not check for updates"])
        }
    }

    // MARK: - Changing state

    private func setControlOption(_ name: String, _ value: String) throws {
        func newValue(current: Bool) throws -> Bool {
            switch value {
            case "on", "true", "yes", "1": return true
            case "off", "false", "no", "0": return false
            case "toggle": return !current
            default: throw ControlError("value must be on, off or toggle")
            }
        }
        if let key = Self.listOptions[name] {
            setOption(key, try newValue(current: defaults.bool(forKey: key)))
            return
        }
        switch name {
        case "notes-on-top":
            lastNotesWindow.setAlwaysOnTop(try newValue(current: lastNotesWindow.settings.alwaysOnTop))
        case "notes-xlarge":
            lastNotesWindow.setExtraLargeFont(try newValue(current: lastNotesWindow.settings.extraLargeFont))
        case "launch-at-login":
            let service = SMAppService.mainApp
            let enable = try newValue(current: service.status == .enabled)
            do {
                if enable { try service.register() } else { try service.unregister() }
            } catch {
                throw ControlError("launch-at-login: \(error.localizedDescription)")
            }
        default:
            let all = (Self.listOptions.keys + ["notes-on-top", "notes-xlarge", "launch-at-login"]).sorted()
            throw ControlError("unknown option '\(name)'; options: \(all.joined(separator: ", "))")
        }
    }

    private func selectControlInput(_ argument: String) throws {
        guard !argument.isEmpty else { throw ControlError("usage: input all | input <name|ID>") }
        if argument.lowercased() == "all" {
            setInput(.all)
            return
        }
        let match = monitor.sources.first { $0.name.caseInsensitiveCompare(argument) == .orderedSame }
            ?? Int32(argument).flatMap { id in monitor.sources.first { $0.uniqueID == id } }
        guard let source = match else {
            let names = monitor.sources.map { "\($0.name) (\($0.uniqueID))" }
            throw ControlError("no MIDI input '\(argument)'; available: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        }
        setInput(.source(uniqueID: source.uniqueID, name: source.name))
    }

    // MARK: - Reading state

    func controlStatus() -> [String: Any] {
        let input: [String: Any]
        switch monitor.selection {
        case .all:
            input = ["mode": "all"]
        case let .source(uniqueID, name):
            input = ["mode": "single", "name": name, "uniqueID": Int(uniqueID),
                     "connected": monitor.sources.contains { $0.uniqueID == uniqueID }]
        }
        let indicator: String
        switch iconState {
        case .active: indicator = "green (receiving)"
        case .idle: indicator = "grey (listening)"
        case .noDevice, nil: indicator = "red (not listening)"
        }
        let login: String
        switch SMAppService.mainApp.status {
        case .enabled: login = "on"
        case .requiresApproval: login = "requires approval"
        case .notFound: login = "off (app not registered)"
        default: login = "off"
        }
        var options: [String: Any] = Self.listOptions.mapValues { defaults.bool(forKey: $0) }
        options["notes-on-top"] = lastNotesWindow.settings.alwaysOnTop
        options["notes-xlarge"] = lastNotesWindow.settings.extraLargeFont
        options["launch-at-login"] = login

        let shown = shownCategories
        return [
            "app": [
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build",
                "pid": Int(getpid()),
                "midiError": startError.map { $0 as Any } ?? NSNull(),
            ],
            "indicator": indicator,
            "midi": [
                "listening": monitor.isListening,
                "input": input,
                "inputs": monitor.sources.map { ["name": $0.name, "uniqueID": Int($0.uniqueID)] },
                "outputs": monitor.destinationCount,
            ],
            "options": options,
            "windows": [
                "log": ["open": logWindow.isVisible],
                "notes": ["open": lastNotesWindow.isVisible, "notesShown": lastNotesWindow.visibleCount],
            ],
            "events": [
                "stored": store.events(including: .all).count,
                "inLists": store.events(including: shown).count,
                "hiddenClockAndActiveSensing": shown.contains(.continuousRealtime) ? 0 : store.count(of: .continuousRealtime),
                "hiddenAftertouch": shown.contains(.aftertouch) ? 0 : store.count(of: .aftertouch),
            ],
        ]
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    private func eventJSON(_ event: MIDIEvent) -> [String: Any] {
        [
            "time": Self.isoFormatter.string(from: event.date),
            "device": event.source ?? NSNull(),
            "channel": event.channel ?? NSNull(),
            "message": MIDIFormat.description(of: event.kind),
            "line": MIDIFormat.line(for: event, includeSource: true),
        ]
    }

    private func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return #"{"ok": false, "error": "could not encode the response"}"# }
        return String(decoding: data, as: UTF8.self)
    }
}
