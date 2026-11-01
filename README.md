# MIDIstat

A tiny native macOS menu bar app that shows, at a glance, whether MIDI data is arriving — and what it is.

MIDIstat has no Dock icon and no main window. It lives in the menu bar as a two-row **MI / ▶I** mark; the triangle is the indicator:

| Triangle | Meaning |
|---|---|
| $\color{green}{▶}$ **green** | a MIDI message was received within the last second |
| $\color{gray}{▶}$ **grey** | listening, but nothing has arrived for over a second |
| $\color{red}{▶}$ **red** | not listening: there is no MIDI input, or the selected input is disconnected |

The red state applies even if other devices are connected: when a specific input is selected and it disappears, MIDIstat is not listening to anything. It turns grey again automatically when the device comes back.

## Features

### Menu

Click the icon to open the menu:

- **Last 10 MIDI Events**: the most recent messages, oldest first, updated live while the menu is open. Example:
  ```
  4.841, Xkey Air 25, ch: 1, Note 079 On (G5), velocity: 93
  4.911, Xkey Air 25, ch: 1, Note 079 Off (G5), velocity: 0
  ```
  If some message types are hidden (see Options), a line such as `Hidden: 120 Clock / Active Sensing, 3400 Aftertouch` shows how many were left out.
- **Show Full Log…** (⌘L): opens the log window (see below).
- **MIDI Input**:
  - **Listen to All MIDI Inputs**, or
  - one specific input. Inputs are listed live as devices are connected and disconnected. A selected input that is currently unplugged appears as `Name (disconnected)`.
- **Options**:
  - **Show Timestamp** (default on): show the timestamp in the menu list.
  - **Show Device Name** (default on): show the input name in the menu list.
  - **Show Clock & Active Sensing** (default off): include these real-time messages in the event lists.
  - **Show Aftertouch** (default off): include poly pressure and channel pressure in the event lists.
  - **Launch at Login**: start MIDIstat automatically when you log in.
- **Quit MIDIstat** (⌘Q).

Show Timestamp and Show Device Name affect only the menu list. The log window always shows both.

Show Clock & Active Sensing and Show Aftertouch affect both the menu list and the log window. Hidden messages **still turn the indicator green**; they are only left out of the lists. They are hidden by default because some devices send Clock (~50 per second) or Active Sensing (~3 per second) non-stop, and aftertouch produces a flood of messages while a key is held. Without the filter these would push the notes out of the list in a fraction of a second.

All settings, including the selected input, are remembered between launches.

### Log window

**Show Full Log…** opens a resizable window (it can also be zoomed or made full screen) that lists every message since MIDIstat started, or since the log was last cleared:

- columns **Time** (`HH:mm:ss.SSS`), **Device**, **Ch**, **Message**;
- **Show Clock & Active Sensing** and **Show Aftertouch** checkboxes. These are the same settings as in the menu;
- an event counter, including how many messages are hidden;
- **Clear Log** clears the log window and the menu list;
- **Close** (or Esc).

The window comes to the front when opened. While it has focus, **⌘L** closes it again. Selected rows can be copied with **⌘C** as tab-separated text, ready to paste into a spreadsheet. **⌘A** selects all rows.

The log keeps up to the 100,000 most recent messages per view, which caps memory use when a device sends Clock all the time. The counter says so when the limit is reached.

### Message format

Each line has the parts that are switched on: timestamp, device, channel, message.

- **Timestamp**: seconds within the current minute plus milliseconds (`4.841`). The log window shows the full time.
- **Channel**: 1–16. System messages have no channel (`12.345, Start`).
- **Notes**: zero-padded number plus name, with middle C = 60 = C4 (so 79 = G5). A *Note On with velocity 0*, which many keyboards send on key release, is shown as **Note Off**.
- **Message types**: Note On/Off, Poly Pressure, Control Change (common controllers are named, e.g. `Control Change 064 (Sustain), value: 127`), Program Change (raw value 0–127), Channel Pressure, Pitch Bend (`-8192…+8191`, 0 = centre), SysEx, MTC Quarter Frame, Song Position, Song Select, Tune Request, Clock, Start, Continue, Stop, Active Sensing, System Reset.

## Installing and building

Requirements: macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed.

```sh
./scripts/build-app.sh            # builds build/MIDIstat.app (release, with icon, ad-hoc signed)
./scripts/build-app.sh --install  # also copies it to /Applications and (re)starts it
swift run MIDIstatCheck           # runs the self-checks of the MIDI parsing/formatting logic
```

**Launch at Login** works most reliably when the app is in `/Applications` (use `--install`). If macOS asks for approval, the System Settings → General → Login Items pane opens; in the menu the option then shows a dash (–) until it is approved.

The app is ad-hoc signed, not notarized. If macOS refuses to open a copy that was downloaded or moved from another Mac, right-click it and choose **Open**.

## How it works (for developers and AI assistants)

Swift Package with three targets, no third-party dependencies.
For more details see: [TECH.md].

## License

[MIT](LICENSE) © Andrew Barabasz (github/barabasz)
