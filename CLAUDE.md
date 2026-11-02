# CLAUDE.md

Guidance for AI assistants working on this repository: the working agreement, the full behaviour of the app, the design decisions behind it, and what has been learnt the hard way. This file is the assistant's memory. Keep it current with every change; it is the one document that should describe the details.

## The project

MIDIstat is a native macOS menu bar app (Swift, AppKit, CoreMIDI; macOS 14+) that shows whether MIDI data is arriving, and what it is. A Swift Package with no third-party dependencies, built with the Xcode Command Line Tools only (no Xcode project). Free and open source (MIT), and meant to stay free.

The user (the author, Andrew Barabasz) writes in Polish: reply in Polish. Code, comments, UI text, commit messages and docs are in English.

## The documents

| File | Audience | Content | Changes |
|---|---|---|---|
| `README.md` | potential users | a short pitch: why MIDIstat, that it is free, the main features, the floating windows with screenshots from `img/`, download | only for significant features or changes |
| `DEVELOPMENT.md` | developers | the general architecture, building, layout, releases; no detail that changes with each feature | rarely: only when the architecture changes |
| `CLAUDE.md` | AI assistants | everything else: behaviour, decisions, file roles, pitfalls, procedures | with almost every change |

Screenshots live in `img/` (`midistat.webp` overview, `popup.webp` menu, `events.webp`, `notes.webp`, `stat.webp`, `log.webp`); the user takes and updates them. Mention when a change makes one outdated.

## Commands

```sh
swift build                              # compile check
swift run MIDIstatCheck                  # self-checks of MIDIstatCore (XCTest/swift-testing need Xcode)
./scripts/build-app.sh --install         # build, install to /Applications and restart the app
./scripts/build-app.sh --universal       # arm64 + x86_64 (used by release.sh)
./scripts/benchmark.sh [--quick]         # CPU/memory of the running app under virtual MIDI load
./scripts/release.sh [--dry-run]         # GitHub release from Support/Info.plist's version
swift build -c release --product MIDIstatLoad   # virtual MIDI devices: --notes N --aftertouch K --clock BPM --sensing --seconds S
```

Inspect and drive the running app (JSON replies): `/Applications/MIDIstat.app/Contents/MacOS/MIDIstat ctl help` (status, ver, devices, updates, events, set, input, appearance, open/close, clear-log, reset-stats, panic). See the reference below.

## Working agreement

- **Test live before committing.** Build and install (`build-app.sh --install`), let the user try the change, and commit only after they confirm. Check the app's state with `ctl status` rather than asking.
- **Show, then ask.** Render windows offscreen and look at them before installing (see Testing). When a visual detail is in question, measure pixels rather than judge by eye, and report the numbers.
- **Pixels.** When the user says "1 px", they mean a device pixel on their Retina screen (half a point). Use `1 / backingScaleFactor`. A font size "1 px smaller" was taken as 1 point and accepted.
- **Commits** are split by feature with descriptive titles: `release.sh` turns the commit titles since the previous tag into the release notes. End messages with the Co-Authored-By line. When features share files, build intermediate states from the final files (remove the later features' parts), compile each and commit in order.
- **Releases only when asked** (often the user says "commit, no release"). See Releases below.
- **Docs.** Update this file with every change; README and DEVELOPMENT.md only as described above.
- **Measure performance** with `scripts/benchmark.sh` after changes to the windows or event handling. Single short measurements are noisy (±3 percentage points at 16 notes/s): repeat and alternate before concluding.

## Files

| File | Role |
|---|---|
| `MIDIstatCore/MIDIEvent.swift` | The decoded MIDI message model and its text formatting: note names, timestamps, list lines, the log's columns (`logColumns`). |
| `MIDIstatCore/UMPParser.swift` | Turns Universal MIDI Packets, the format CoreMIDI delivers, into events. |
| `MIDIstatCore/EventStore.swift` | The event history behind the menu, Last Events and the log, with the hideable aftertouch category. |
| `MIDIstatCore/RealtimeStatus.swift` | Clock (tempo, transport, device) and Active Sensing trackers, and the aligned text columns of Last Events. |
| `MIDIstatCore/NoteStats.swift` | Note statistics (counts, paces, peak, velocity, range), the velocity meter's steps, duration formatting. A class shared by the app and the Statistics window. |
| `MIDIstatCore/ReleaseNotes.swift` | Version comparison and the list of changes for the update dialog. |
| `MIDIstat/main.swift` | Entry point: the app without a Dock icon, or the `ctl` client, or (build-time flag) rendering the app icon. |
| `MIDIstat/AppDelegate.swift` | Ties everything together: status item, menu, settings (`Defaults` keys), the indicator, the windows (lazy), appearance, Launch at Login, panic, updates (dialog). |
| `MIDIstat/AppDelegate+Control.swift` | The `ctl` commands: reading the state and changing it. |
| `MIDIstat/ControlServer.swift` | The Unix socket server in the app and the `ctl` client. |
| `MIDIstat/MIDIMonitor.swift` | The only code that talks to CoreMIDI: inputs, device tracking, panic to outputs. |
| `MIDIstat/LogWindowController.swift` | The full log window (a table, a filter, Reset Columns). |
| `MIDIstat/LastEventsWindowController.swift` | Last Events: the latest events as aligned text layers. |
| `MIDIstat/LastNotesWindowController.swift` | Last Notes: notes in large type with velocity meters (`NoteGlyphView` = `LetterView` + `MeterView`). |
| `MIDIstat/StatisticsWindowController.swift` | Statistics: a grid of names and values, Always on Top, Reset. |
| `MIDIstat/StatusIcon.swift` | Draws the MI / DI mark (the solid D is the indicator) for the menu bar and the app icon. |
| `MIDIstat/Updater.swift` | GitHub releases, download verification, bundle swap. |
| `MIDIstat/WindowBehavior.swift` | "Always on Top" (level and Space behaviour) and `DesktopReturn` for all windows. |
| `MIDIstat/Activation.swift` | `activateTakingFocus()`. |
| `MIDIstatCheck/main.swift` | Self-checks for MIDIstatCore. |
| `MIDIstatLoad/main.swift` | Virtual MIDI devices for load tests. |
| `scripts/build-app.sh`, `benchmark.sh`, `release.sh` | Build the bundle (icon, ad-hoc signature), measure, publish. |

## Behaviour reference

### Indicator and menu

- The D is **green** within a second of any MIDI message (also hidden ones: Clock, Active Sensing, aftertouch), **grey** when listening and quiet, **red** when not listening: no input, or the selected input is disconnected (even if other devices are present). It turns grey again when the device returns.
- Menu, top to bottom: the version line; **Last MIDI Event** (time, device + channel, event; updated live while open), then MIDI Clock and Active Sensing lines only while they arrive; **Floating Windows**: Show Full Log ⌘L, Show Last Events ⌘E, Show Last Notes ⌘N, Show Statistics ⌘S (checked while open); **MIDI Input**: Listen to All MIDI Inputs ⌘A, or one input (a missing one shows as `Name (disconnected)`); **Options**: Launch at Login ⌥L (dash while approval is pending), Appearance ▸ Auto (System) / Light / Dark; Check for Updates… ⌘U; MIDI Panic ⌘P (disabled without outputs); Quit ⌘Q.
- A hidden main menu provides the window shortcuts, Copy, Select All, Filter Log ⌘F, Close ⌘W and Minimize while a MIDIstat window has focus.
- All settings, the selected input and which windows are open are remembered.

### Windows in general

- Each window has its own options and **Always on Top**. On top: floats above all windows, on every Space and over full-screen apps. Off: an ordinary window on one Space. Turned off in a full-screen Space, the window hides and reappears on the next regular desktop (`DesktopReturn`).
- All but the log are non-activating panels: they never take the focus. The log window takes the focus when opened explicitly.
- A window open at quit opens again at launch; closing it turns its option off.
- Appearance (Auto/Light/Dark) is set per window, so the status menu keeps following the menu bar.
- **Aftertouch** is off by default in the lists (it floods them); hidden messages still light the indicator.

### Last Events

- Latest events, newest at the bottom, updated instantly. Options: Timestamp (seconds.milliseconds within the minute), Device Name, Channel, Aftertouch, Always on Top (default on), Clear Log (clears the shared history: Last Events, log, menu).
- Toggling a column sets the width to fit; the window can then be narrowed (descriptions end with "…") or widened, and made taller (at least 5 lines).

### Full Log

- Every message since launch or Clear Log, up to 100,000 (the counter says when the limit is reached). Columns: Time `HH:mm:ss.SSS`, Device, Ch, Message (`Note 067 On`, `Control Change 064 (Sustain)`), Note (name for Note On/Off and Poly Pressure, else empty), Value (velocity, value, pressure, bend).
- Filter (⌘F): space-separated words, all must appear in some column, case-insensitive (`d4 on`, `xkey 064`, `ch 2`; note names are searchable). Esc clears the filter, then closes.
- Reset Columns restores the order and fits widths to the distinct texts of each column plus the widest expected values (device names of the connected inputs, `16`, `C#-1`, `-8192`); spare width goes to Message. It also runs the first time the window opens in a session (the default widths did not fit narrow windows).
- ⌘C copies selected rows as tab-separated text (all six columns); ⌘A selects all. First event after a pause shows at once; during streams at most 10 updates per second.

### Last Notes

- Note On only (velocity-0 Note On counts as Note Off), newest on the left with a slide-and-fade (no animation with Reduce Motion). Older notes dimmed. Middle C = C4. A note is a bold letter with a column: the sharp on top (level with the letter's top), the light octave number on the baseline (1 device pixel lower, as round letters overshoot). At X-Large the sharp is 1 device pixel up and left.
- Options in one row, starting at the left edge of the first note's meter: Always on Top (default on), X-Large (doubles notes and meters; renamed from "X-Large Font"), Velocity, and with Velocity only: Colored, Values.
- Minimum width 8 notes (default width too), up to the screen width; height fixed by the options. Widening shows earlier notes (history of 256).
- **Velocity meter:** 16 bars, lit from the bottom: level = velocity / 8 + 1 (0–7 → 1 bar, 120–127 → 16). **Colored:** bars 1–10 green (velocity 0–79, ppp–mf), 11–14 yellow (80–111, f–ff), 15–16 red (112–127, fff); in light mode orange instead of yellow and a deeper green. **Values:** a black box with the value in white, bold, 11 pt (the option labels' size), exactly the meter's width, below the meter at the same gap as between bars; the window grows to make room.
- **Dimming:** dark mode makes the whole older note 30% opaque. Light mode dims only the letter (30%); the meter and value box keep full contrast, and unlit bars use the dimmed-unlit strength (alpha 0.15 colored, 0.1 mono). This was the user's solution after faint bars were unreadable on white.

### Statistics

- Rows: NOTES (Since start: not affected by Reset; Since reset), NOTES PER MINUTE (Average since reset: from the first note after Reset to now, pauses included; Last minute; Last 15 seconds; Peak (15 seconds)), SINCE RESET (Time since first note `m:ss`/`h:mm:ss`, Note range `C3 – G5`, Average velocity, Velocity range). A dash: nothing since Reset.
- **Pace** over a window (60 s or 15 s) is measured from the first note of a run: a run starts at the first note after Reset or after 60 s without notes. While the run is shorter than the window, the pace is projected: notes × 60 / elapsed, elapsed at least 1 s (8 notes in 2 s = 240). Then it is the notes in the window scaled to a minute; both agree at the switch. The peak is checked at each note and only over full 15 s windows (no projected bursts).
- Refresh: at most every 0.1 s after notes, every second for time-dependent values, only while visible. Always on Top (default on), then Reset with "⌘R" shown; ⌘R works once the panel is key (it becomes key on click without activating the app).
- History of the design: the notes count and notes per minute were first in Last Notes; the user moved them here to keep Last Notes single-purpose.

### Clock, Active Sensing, message format

- MIDI Clock (24 per quarter note) shows tempo, transport (Start/Stop/Continue) and device; Active Sensing (~300 ms, often digital pianos) shows the devices. Neither is stored or listed; both appear only while arriving (also in `ctl status`). Start, Stop, Continue and Song Position are listed as events.
- Lines: timestamp, device, channel (1–16; system messages have none), message. Notes are zero-padded numbers plus names (79 = G5). Controllers with common names are named. Pitch bend −8192…+8191.

### Updates

- Check for Updates reads all releases (one GitHub API request). The dialog: "MIDIstat x is available", "You have version y.", then in a 520 pt accessory view (which sets the alert's width; NSAlert's own text is narrow and cannot hold links) "What's new:" with up to 5 changes from all skipped releases, newest first, version commits left out, then "…and N more. See all changes" (GitHub comparison link) and what Upgrade does. The accessory text is inset 4 pt to line up with the alert's text.
- Upgrade verifies the zip's SHA-256 against GitHub's digest and the app's bundle identifier, version and signature, then a detached script waits for the app to quit, swaps the bundle (restoring on failure) and relaunches. Settings are kept.
- The network is used only for update checks (menu or `ctl updates`).

### MIDI Panic

All Sound Off, Reset All Controllers and All Notes Off on all 16 channels to every output (hanging notes live in synths, not in the monitored controller).

## Command-line reference

`MIDIstat ctl <command>`; the reply is JSON with `"ok"` and, on failure, `"error"`. Commands that change something reply with the new `status`. Exit code 0 ok, 1 app error, 2 not running. The socket is in `~/Library/Application Support/MIDIstat/`, user-only.

| Command | Effect |
|---|---|
| `ver` | Version and build. |
| `devices` | Inputs (and whether listened to) and outputs. |
| `updates` | Latest release and the changes since the installed one; installs nothing. |
| `status` | Indicator, input, inputs/outputs, options (incl. `appearance`), windows open (`notesShown` for Last Notes), Clock, Active Sensing, `stats` (all Statistics values; null when empty), event counts. |
| `events [N]` | Last N events (default 10, max 1000), filtered like Last Events. |
| `set <option> <on\|off\|toggle>` | `events-timestamp`, `events-device`, `events-channel`, `events-aftertouch`, `events-on-top`, `log-aftertouch`, `log-on-top`, `notes-on-top`, `notes-xlarge`, `notes-velocity`, `notes-colored`, `notes-values`, `stats-on-top`, `launch-at-login`. |
| `input all` / `input <name or ID>` | Listen to all inputs or one. |
| `appearance <auto\|light\|dark>` | Window appearance. |
| `open`/`close <log\|events\|notes\|stats>` | Show or hide a window without taking the focus. |
| `clear-log` | Clear the event history. |
| `reset-stats` | Reset the statistics (replaced `reset-notes` in 0.8.0). |
| `panic` | MIDI Panic. |

Keep `ctl help` (in `AppDelegate+Control.swift`) and this table in step.

## Architecture notes

- **Logic vs system.** Testable logic in MIDIstatCore; the app adapts it. Add checks for every core change.
- **Receiving.** One input port (MIDI 1.0 protocol), connected to all sources or the selected one (by unique ID), reconnected on setup changes; each connection tagged with its source. Decoded on CoreMIDI's thread (event date = `Date()` at arrival), handled on the main thread.
- **History.** Separate lists per filter combination, so switching filters is instant; capped. The log reads rows straight from the store and keeps only indexes for a filter.
- **Last Events** draws each line as a text layer and moves layers up per event (one big text view per event made macOS allocate many window-sized buffers). **Last Notes** moves ready-made views in fixed-width slots; the letter and the meter are separate layer-backed subviews so that light mode dims the letter by opacity without redrawing. Changing font size, Velocity or Values goes through `applyLayout` (slot size and window height); Colored only redraws (`layoutNotes`).
- **Log table** inserts only new rows, rebuilds only after a filter change, clear or trim, follows new rows when scrolled to the bottom, at most 10 updates per second.
- **Full screen** is detected from the wallpaper window (absent in full-screen Spaces); window sizes and presentation options proved unreliable.
- **Windows are created lazily** and register for appearance changes when created (`adoptAppearance`).
- **Control API** goes through the same functions as the menu. A Unix socket was chosen over a localhost HTTP server (reachable by web pages) and AppleScript (more infrastructure).
- **Icon:** one drawing routine for all sizes; `build-app.sh` makes the app render its iconset and runs `iconutil`.

## Testing

- MIDIstatCore: add checks to `Sources/MIDIstatCheck/main.swift`. Test sliding windows by adding notes only up to the time you query (the counter has no notion of future notes).
- **Offscreen harness** for windows and dialogs: copy the needed app sources into a scratchpad folder, strip `import MIDIstatCore`, compile with `Sources/MIDIstatCore/*.swift` and a `main.swift` that creates the controller, sets `window.appearance`, feeds data and renders `contentView.superview` with `cacheDisplay(in:to:)` to PNG. Don't start the control server: a second instance would take over the socket. For a function inside AppDelegate (e.g. the update alert), extract its source into the harness with stub types. Private `@objc` actions can be called with `perform(Selector(("name")))`.
- **Pixel measurements:** a short Python/PIL script that finds the black value box and the white digits in the PNG and prints the gaps worked well (light mode needs a different detection, white is the background).
- **Live window titles and frames:** `CGWindowListCopyWindowInfo` from a small Swift tool (no permission prompt). There is no `timeout` command: run in the background and kill.
- **Testing Check for Updates:** temporarily set `Support/Info.plist` to the previous version, `build-app.sh --install`, restore the plist with `git checkout`. `ctl updates` shows what the dialog will list. Upgrade then installs the published release.
- Spaces and full-screen behaviour cannot be tested automatically; describe the steps and ask the user.
- Avoid tools that trigger permission prompts (`osascript` with System Events, `screencapture`, `lldb`); they hang silently.
- Locale: `ps`/`bc` output uses commas in the user's locale; set `LC_ALL=C` in measuring scripts.

## Releases

1. Only when asked. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Support/Info.plist` (PlistBuddy reorders the keys alphabetically; harmless, or edit by hand), commit "Version x.y.z", push.
2. `./scripts/release.sh --yes` (needs a clean, pushed `main` and `gh`).
3. Verify the asset: download with `gh release download`, compare the SHA-256 with the notes, `codesign --verify --deep --strict`, `lipo -archs` (x86_64 arm64), version and build from its Info.plist.
4. The user updates via Check for Updates.

Releases so far: 0.7.0, 0.8.0 (velocity meters, Statistics, appearance, log Note column). After 0.8.0: wider update dialog (unreleased).

## Performance reference

`benchmark.sh --quick` (6 s per measurement) on the user's Mac, 0.8.0: no windows 0.17 % / 0.33 % CPU at 6 / 16 notes/s; all four windows ~18 % / ~31 %. Last Notes alone at 16 notes/s ~14–19 % (light and dark the same within noise), Statistics alone ~4 %. Memory ~30–40 MB.

## Pitfalls already met

- Don't keep a reference to `EventStore`'s arrays in a view: copy-on-write then copies the whole history on every new event. The same holds for any shared growing state (hence `NoteStats` is a class).
- Don't update views of hidden windows on every event, and don't redraw large views per event: move layers instead.
- `NSApp.activate()` alone is often ignored for menu bar apps: use `activateTakingFocus()`.
- A non-activating panel with `becomesKeyOnlyIfNeeded = true` never becomes key, so key equivalents (⌘R) don't reach it; Statistics sets it to false.
- `NSRect.fill()` uses copy compositing; use `fill(using: .sourceOver)` for translucent colours.
- Setting `contentView` resizes it to the window's current content size: call `setContentSize` first.
- `NSTableView` column widths: account for `intercellSpacing` and set `columnAutoresizingStyle = .noColumnAutoresizing` while assigning widths, or the table redistributes them.
- Toggles that change a window's height must go through the full layout, not just a redraw (Values once pushed the meters into the letters).
- Layout positions that should be centred to the pixel need rounding to device pixels, not points.
- Once the Statistics window showed no title until the app was restarted; not reproducible. If it recurs, investigate.
