# How MIDIstat works

MIDIstat is a Swift Package with no third-party dependencies, built with the Xcode Command Line Tools alone.

```
midistat/
├── Package.swift
├── Sources/
│   ├── MIDIstatCore/              pure logic: no AppKit, no CoreMIDI
│   │   ├── MIDIEvent.swift
│   │   ├── UMPParser.swift
│   │   ├── EventStore.swift
│   │   ├── RealtimeStatus.swift
│   │   └── ReleaseNotes.swift
│   ├── MIDIstat/                  the menu bar app
│   │   ├── main.swift
│   │   ├── AppDelegate.swift
│   │   ├── AppDelegate+Control.swift
│   │   ├── ControlServer.swift
│   │   ├── MIDIMonitor.swift
│   │   ├── LogWindowController.swift
│   │   ├── LastEventsWindowController.swift
│   │   ├── LastNotesWindowController.swift
│   │   ├── StatusIcon.swift
│   │   ├── Updater.swift
│   │   ├── WindowBehavior.swift
│   │   └── Activation.swift
│   ├── MIDIstatCheck/             self-checks for MIDIstatCore
│   │   └── main.swift
│   └── MIDIstatLoad/              virtual MIDI devices for load tests
│       └── main.swift
├── Support/
│   └── Info.plist
└── scripts/
    ├── build-app.sh
    ├── benchmark.sh
    └── release.sh
```

## Files

| File | Role |
|---|---|
| `MIDIEvent.swift` | The decoded MIDI message model and its text formatting (note names, timestamps, list lines). |
| `UMPParser.swift` | Turns Universal MIDI Packets, the format CoreMIDI delivers, into events. |
| `EventStore.swift` | The event history behind the menu, Last Events and the log window, including the hideable aftertouch category. |
| `RealtimeStatus.swift` | Summaries of MIDI Clock (tempo, transport, device) and Active Sensing (sending devices), and the aligned text columns of Last Events. |
| `ReleaseNotes.swift` | Version comparison and the list of changes for the update dialog. |
| `main.swift` (app) | Entry point. Starts the app without a Dock icon, or runs the `ctl` client, or (a build-time flag) renders the app icon. |
| `AppDelegate.swift` | Ties everything together: status item, menu, settings, the activity indicator, Launch at Login, MIDI panic. |
| `AppDelegate+Control.swift` | The commands of the command-line control API: reading the state and changing it. |
| `ControlServer.swift` | The local control channel: a socket server in the app and the `ctl` client in the same binary. |
| `MIDIMonitor.swift` | The only code that talks to CoreMIDI: receiving from inputs, tracking devices, sending panic to outputs. |
| `LogWindowController.swift` | The full log window (a table). |
| `LastEventsWindowController.swift` | The Last Events window: the most recent events as aligned text, updated instantly. |
| `LastNotesWindowController.swift` | The Last Notes window: the most recent notes in large type, animated. |
| `StatusIcon.swift` | Draws the MI / DI mark (the solid D is the indicator), both for the menu bar and for the app icon. |
| `Updater.swift` | Checks GitHub Releases for a newer version, verifies the download and swaps the app bundle in place. |
| `WindowBehavior.swift` | "Always on top" (window level and Space behaviour) shared by all windows. |
| `Activation.swift` | Brings the app to the front when one of its windows opens. |
| `main.swift` (check) | Self-checks for `MIDIstatCore` (`swift run MIDIstatCheck`). |
| `Info.plist` | Bundle metadata, including "no Dock icon". |
| `build-app.sh` | Builds the `.app` bundle: release binary, icon, ad-hoc signature. |
| `main.swift` (load) | `MIDIstatLoad`: virtual MIDI devices sending notes, aftertouch, Clock and Active Sensing at a given rate. |
| `benchmark.sh` | Measures CPU and memory of the running app under `MIDIstatLoad`, for different sets of open windows, switched through the control API. |
| `release.sh` | Publishes a GitHub Release with the zipped universal app. |

## Key concepts

**Separation of logic and system code.** Everything that can be tested without hardware (parsing, formatting, filtering, history) lives in `MIDIstatCore`, and `MIDIstatCheck` exercises it. The app target only adapts it to AppKit and CoreMIDI.

**Receiving MIDI.** One CoreMIDI input port, using the MIDI 1.0 protocol, is connected either to all online sources or to the one the user selected. The selected source is remembered by its CoreMIDI unique ID, so it is found again after reconnecting or restarting. When the MIDI setup changes (a device is plugged in or out), the port is reconnected. Each connection is tagged with its source, so every event carries the device name. Messages are decoded on CoreMIDI's thread and handed to the main thread.

**Indicator state.** The state is derived, not stored:
- red: no source is connected;
- green: the last message arrived less than a second ago;
- grey: otherwise.

A single timer, which also runs while the menu is open, switches green back to grey.

**Filtering, not dropping.** Some messages arrive in floods: Clock, Active Sensing, aftertouch. They always light the indicator and are always recorded, but the user decides whether the lists show them. The history keeps a separate list for each combination of filters, so switching a filter is instant, and it counts what is hidden. Its size is capped so that a continuous stream cannot exhaust memory.

**Clock and Active Sensing.** They arrive continuously and carry no musical content, so they are never stored or listed. They light the indicator and feed two small trackers. The clock tracker derives the tempo from the average tick interval and the transport state from Start, Stop and Continue. The Active Sensing tracker records which devices send it. The menu shows their summaries only while messages keep arriving.

**Menu and windows.** The menu is rebuilt each time it opens and shows only the last event. While it is open, the event lines update live, and a timer refreshes the clock and sensing lines. Each window has its own options, saved in `UserDefaults`, and its own "always on top". macOS has no public API to move a window to another Space. So when "always on top" is turned off in a full-screen app's Space, the window is hidden and parked with the "move to active Space" behaviour. It is shown again when a Space without a full-screen app becomes active. Full screen is detected from the active app's presentation options, or from another app's on-screen window covering a whole screen, menu bar area included. Last Events shows each line as a small text layer. A new event moves the existing layers up and draws only the new line, so it is instant and cheap. Redrawing one big text view per event made macOS allocate many window-sized graphics buffers. Last Notes moves ready-made views in the same way. Hidden windows are not updated at all; even setting a label in a hidden window costs layout and drawing. `scripts/benchmark.sh` measures all of this. Its width follows the enabled columns. The log window reads rows straight from the same history and never keeps a copy. A copy shared with the store would make every append copy the whole history. A filter keeps only the indexes of matching rows. Resetting the columns measures only the distinct texts of each column, since the log holds up to 100,000 rows but few different strings. The first event after a pause is shown at once; during a stream the table updates at a limited rate, since every update (insert, scroll, redraw) costs a few milliseconds. It inserts only the new rows and rebuilds the table only after a filter change, a clear or trimming, because rebuilding it while MIDI streams in is expensive. It follows new events when scrolled to the bottom. A hidden main menu supplies the standard keyboard shortcuts while the window has focus. A menu bar app is not normally active, so opening a window explicitly takes over the focus.

**Last Notes window.** A non-activating panel. It shows only key presses and never takes the focus, so the user can keep working in another app. Each note is drawn by a small custom view: letter, plus a column with the sharp sign above and the octave below. Notes occupy fixed-width slots, so a new note shifts all the others by the same distance. The window can only be resized horizontally. The number of visible notes follows from its width, and a short note history fills newly uncovered slots. The font size option changes the slot size and the window height. The movement is an eased view animation, skipped when the system asks to reduce motion. "Always on top" controls both the window level and its Space behaviour. On top, the window joins all Spaces and full-screen apps. Otherwise it is a normal window that belongs to one Space.

**MIDI panic.** Sends "all sound off", "reset all controllers" and "all notes off" on every channel to every MIDI output. Hanging notes are usually stuck in a synth, not in the controller being monitored.

**Command-line control.** The app binary is also its own client: `MIDIstat ctl <command>` connects to the running instance through a Unix domain socket in the user's Application Support folder, readable only by that user, and prints the JSON reply. Requests are handled on the main thread through the same functions the menu uses, so the effect is identical to clicking. A local socket was chosen over a localhost HTTP server, which web pages could reach, and over AppleScript, which needs more infrastructure.

**Updates.** One GitHub API request returns all releases with their notes. Each release's notes list only the commits since the previous release, so the changes since the installed version are the "Changes" sections of all newer releases. Version commits are left out, and the dialog shows the newest 5 plus a count and a link to GitHub's comparison page. Before anything is replaced, the downloaded zip is checked against GitHub's SHA-256 digest, and the unpacked app against the expected bundle identifier, version and code signature. The running app cannot replace itself safely, so it starts a small detached shell script and quits. The script waits for the old process to exit, swaps the bundle (restoring the old one if the swap fails) and launches the new version. Settings live in `UserDefaults`, so they are kept.

**Settings.** Stored in `UserDefaults`, with defaults registered at launch. Launch at Login uses the system's login item service (`SMAppService`).

**Icon.** A single drawing routine scales from the menu bar size to the 1024 px app icon. Menu bar colours are resolved at draw time, so they follow light and dark mode. The build script asks the app binary to render the iconset and converts it with `iconutil`, so no image files are kept in the repository.

Go back to [README.md](README.md).
