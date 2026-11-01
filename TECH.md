# How MIDIstat works

MIDIstat is a pure Swift Package with three targets, no third-party dependencies.

| Path | Purpose |
|---|---|
| `Sources/MIDIstatCore/` | Pure logic, no AppKit/CoreMIDI. |
| ├ `MIDIEvent.swift` | `MIDIEvent` / `MIDIEventKind` (decoded MIDI 1.0 messages, `fromBytes` incl. Note On vel 0 → Note Off) and `MIDIFormat` (note names, timestamps, line formatting). |
| ├ `UMPParser.swift` | Decodes Universal MIDI Packet words: message types 1 (system), 2 (MIDI 1.0 channel voice) and 3 (SysEx, reported once per message). Other types are skipped by their word count. |
| └ `EventStore.swift` | Event history. `EventCategories` (`.continuousRealtime`, `.aftertouch`) are the optional, hideable categories. One list is kept per combination of shown categories, so filter changes are instant and appends are O(1). Also counts hidden messages. |
| `Sources/MIDIstat/` | The app (AppKit + CoreMIDI + ServiceManagement). |
| ├ `main.swift` | Starts the app as `.accessory` (menu bar only). With `--export-iconset <dir>` it renders the app icon instead (used by the build script). |
| ├ `AppDelegate.swift` | Status item, menu (rebuilt in `menuNeedsUpdate`, event lines updated live while open), settings in `UserDefaults`, the 1-second activity timer (`.common` run loop mode, so it also runs while the menu is open), Launch at Login (`SMAppService.mainApp`), and a hidden main menu that provides ⌘C/⌘A/⌘L/⌘W/⌘M/⌘Q in the log window. |
| ├ `MIDIMonitor.swift` | CoreMIDI client + input port created with the MIDI 1.0 protocol (`MIDIInputPortCreateWithProtocol`). Lists online sources, connects the port to all of them or to the selected one (matched by `kMIDIPropertyUniqueID`), and reconnects on `msgSetupChanged`. Each connection's refCon carries the source's unique ID, so events are tagged with the device name. Events are decoded on the CoreMIDI thread and delivered on the main queue. `isListening` (≥ 1 connected source) drives the red state. |
| ├ `LogWindowController.swift` | The log window (`NSTableView`, reloads throttled to ~10 per second, auto-scroll when at the bottom, copy support). |
| ├ `StatusIcon.swift` | `Glyph` draws the MI / ▶I mark at any size. `StatusIcon` makes the 18 pt menu bar images (colours resolved at draw time, so they follow light/dark mode). `AppIcon` renders the iconset on the 1024 px macOS grid. |
| └ `Activation.swift` | Brings the app to the front reliably (`NSApp.activate()` alone is often ignored for menu bar apps since macOS 14). |
| `Sources/MIDIstatCheck/` | Self-check executable for `MIDIstatCore`. swift-testing/XCTest need full Xcode, so it is a plain program. |
| `Support/Info.plist` | Bundle metadata (`LSUIElement` = no Dock icon, version, icon name). |
| `scripts/build-app.sh` | Release build → `.app` bundle → icon (`--export-iconset` + `iconutil`) → ad-hoc `codesign`. |

UserDefaults keys: `inputUniqueID` and `inputName` (absent = all inputs), `showTimestamp`, `showDeviceName`, `showContinuousRealtime`, `showAftertouch`.

Go back to [README.md](README.md).
