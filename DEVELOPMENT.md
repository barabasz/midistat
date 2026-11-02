# Developing MIDIstat

MIDIstat is a native macOS menu bar app written in Swift with AppKit and CoreMIDI. It is a Swift Package with no third-party dependencies, built with the Xcode Command Line Tools alone: no Xcode project, no full Xcode needed.

## Building

Requirements: macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
swift build                              # compile check
swift run MIDIstatCheck                  # self-checks of the core logic
./scripts/build-app.sh                   # build/MIDIstat.app: release build, icon, ad-hoc signature
./scripts/build-app.sh --install         # the same, installed to /Applications and (re)started
./scripts/build-app.sh --universal       # Apple silicon + Intel
./scripts/benchmark.sh [--quick]         # CPU and memory of the running app under virtual MIDI load
./scripts/release.sh [--dry-run]         # GitHub release of the version in Support/Info.plist
```

Launch at Login works most reliably when the app is in `/Applications`.

## Layout

```
Sources/
  MIDIstatCore/    pure logic, no AppKit or CoreMIDI: MIDI parsing and formatting, event history,
                   Clock and Active Sensing tracking, note statistics, release notes
  MIDIstat/        the app: menu bar item, menu, windows, CoreMIDI, updates, command-line control
  MIDIstatCheck/   self-checks of MIDIstatCore (a plain executable; XCTest would need full Xcode)
  MIDIstatLoad/    virtual MIDI devices that play notes, aftertouch, Clock and Active Sensing
Support/           Info.plist
scripts/           build, benchmark and release
```

## How it works

**Logic apart from the system.** Everything that can be tested without hardware lives in `MIDIstatCore` and is exercised by `MIDIstatCheck`. The app target only connects it to CoreMIDI and AppKit.

**Receiving MIDI.** One CoreMIDI input port listens to all sources or to the one the user chose, remembered by its unique ID so it is found again after reconnecting. Packets are decoded into events on CoreMIDI's thread and handed to the main thread, where everything else happens.

**One history, many views.** Events go into a capped history shared by the menu, the windows and the command line. Floods (Clock, Active Sensing, aftertouch) always light the indicator, but the user decides what the lists show; Clock and Active Sensing are summarised rather than stored. Note statistics are kept alongside.

**Derived state.** The indicator is computed, not stored: red without an input, green within a second of the last message, grey otherwise.

**Cheap windows.** MIDI can arrive hundreds of times a second, so the windows do as little as possible per event: hidden windows are not touched, views are moved rather than redrawn, and tables update at a limited rate. `scripts/benchmark.sh` measures this under load and is the reference after changes to the windows or event handling.

**Floating windows.** Every window can float on top of all apps and desktops, full-screen apps included, or behave as an ordinary window. Most are non-activating panels, so they never take the focus from the app the user is working in.

**Command-line control.** The app binary is also its own client: `MIDIstat ctl <command>` talks to the running app through a Unix socket in the user's Application Support folder, readable only by that user, and prints JSON. Commands go through the same code as the menu. `MIDIstat ctl help` lists them.

**Updates.** The app reads its releases from the GitHub API, shows the changes since the installed version, and verifies a download (checksum, bundle identifier, version, signature) before a small helper script swaps the app bundle and restarts it.

**Settings** live in `UserDefaults`. **The icon** is drawn in code at every size, for the menu bar and for the app icon, so the repository holds no image files for it.

## Releases

Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Support/Info.plist`, commit and push, then run `./scripts/release.sh`. It checks that `main` is clean and pushed, runs the self-checks, builds the universal app and publishes a GitHub release whose notes list the commit titles since the previous release. It needs the GitHub CLI (`gh`). Options: `--dry-run`, `--draft`, `--yes`.

Commit titles become the release notes, so each commit should be one feature or fix with a descriptive title.
