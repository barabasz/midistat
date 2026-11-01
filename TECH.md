# How MIDIstat works

MIDIstat is a Swift Package with no third-party dependencies, built with the Xcode Command Line Tools alone.

```
midistat/
├── Package.swift
├── Sources/
│   ├── MIDIstatCore/              pure logic: no AppKit, no CoreMIDI
│   │   ├── MIDIEvent.swift
│   │   ├── UMPParser.swift
│   │   └── EventStore.swift
│   ├── MIDIstat/                  the menu bar app
│   │   ├── main.swift
│   │   ├── AppDelegate.swift
│   │   ├── MIDIMonitor.swift
│   │   ├── LogWindowController.swift
│   │   ├── StatusIcon.swift
│   │   └── Activation.swift
│   └── MIDIstatCheck/             self-checks for MIDIstatCore
│       └── main.swift
├── Support/
│   └── Info.plist
└── scripts/
    └── build-app.sh
```

## Files

| File | Role |
|---|---|
| `MIDIEvent.swift` | The decoded MIDI message model and its text formatting (note names, timestamps, list lines). |
| `UMPParser.swift` | Turns Universal MIDI Packets, the format CoreMIDI delivers, into events. |
| `EventStore.swift` | The event history behind the menu list and the log window, including the hideable message categories. |
| `main.swift` (app) | Entry point. Starts the app without a Dock icon. A build-time flag renders the app icon instead. |
| `AppDelegate.swift` | Ties everything together: status item, menu, settings, the activity indicator, Launch at Login, MIDI panic. |
| `MIDIMonitor.swift` | The only code that talks to CoreMIDI: receiving from inputs, tracking devices, sending panic to outputs. |
| `LogWindowController.swift` | The full log window. |
| `StatusIcon.swift` | Draws the MI / ▶I mark, both for the menu bar and for the app icon. |
| `Activation.swift` | Brings the app to the front when one of its windows opens. |
| `main.swift` (check) | Self-checks for `MIDIstatCore` (`swift run MIDIstatCheck`). |
| `Info.plist` | Bundle metadata, including "no Dock icon". |
| `build-app.sh` | Builds the `.app` bundle: release binary, icon, ad-hoc signature. |

## Key concepts

**Separation of logic and system code.** Everything that can be tested without hardware (parsing, formatting, filtering, history) lives in `MIDIstatCore`, and `MIDIstatCheck` exercises it. The app target only adapts it to AppKit and CoreMIDI.

**Receiving MIDI.** One CoreMIDI input port, using the MIDI 1.0 protocol, is connected either to all online sources or to the one the user selected. The selected source is remembered by its CoreMIDI unique ID, so it is found again after reconnecting or restarting. When the MIDI setup changes (a device is plugged in or out), the port is reconnected. Each connection is tagged with its source, so every event carries the device name. Messages are decoded on CoreMIDI's thread and handed to the main thread.

**Indicator state.** The state is derived, not stored:
- red: no source is connected;
- green: the last message arrived less than a second ago;
- grey: otherwise.

A single timer, which also runs while the menu is open, switches green back to grey.

**Filtering, not dropping.** Some messages arrive in floods: Clock, Active Sensing, aftertouch. They always light the indicator and are always recorded, but the user decides whether the lists show them. The history keeps a separate list for each combination of filters, so switching a filter is instant, and it counts what is hidden. Its size is capped so that a continuous stream cannot exhaust memory.

**Menu and log window.** The menu is rebuilt each time it opens. While it is open, its event lines update live. The log window reads the same history, reloads at a limited rate and follows new events when scrolled to the bottom. A hidden main menu supplies the standard keyboard shortcuts while the window has focus. A menu bar app is not normally active, so opening a window explicitly takes over the focus.

**MIDI panic.** Sends "all sound off", "reset all controllers" and "all notes off" on every channel to every MIDI output. Hanging notes are usually stuck in a synth, not in the controller being monitored.

**Settings.** Stored in `UserDefaults`, with defaults registered at launch. Launch at Login uses the system's login item service (`SMAppService`).

**Icon.** A single drawing routine scales from the menu bar size to the 1024 px app icon. Menu bar colours are resolved at draw time, so they follow light and dark mode. The build script asks the app binary to render the iconset and converts it with `iconutil`, so no image files are kept in the repository.

Go back to [README.md](README.md).
