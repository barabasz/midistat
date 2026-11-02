# CLAUDE.md

Guidance for AI assistants working on this repository.

## The project

MIDIstat is a native macOS menu bar app (Swift, AppKit, CoreMIDI; macOS 14+) that shows whether MIDI data is arriving, and what it is. A Swift Package, no third-party dependencies, built with the Xcode Command Line Tools only (no Xcode project).

- **README.md**: features and behaviour as the user sees them, plus the command-line control API. Read it before changing behaviour.
- **TECH.md**: file roles and key concepts. Read it before changing the architecture.

Code, comments, UI text, commit messages and docs are in English. Reply to the user in their language.

## Commands

```sh
swift build                              # compile check
swift run MIDIstatCheck                  # self-checks of MIDIstatCore (XCTest/swift-testing need Xcode)
./scripts/build-app.sh --install         # build, install to /Applications and restart the app
./scripts/build-app.sh --universal       # arm64 + x86_64 (used by release.sh)
./scripts/benchmark.sh [--quick]         # CPU/memory of the running app under virtual MIDI load
./scripts/release.sh [--dry-run]         # GitHub release from Support/Info.plist's version
```

Inspect and drive the running app (JSON replies):

```sh
/Applications/MIDIstat.app/Contents/MacOS/MIDIstat ctl help      # also: status, ver, devices, events, set, open/close, …
```

## Working agreement

- **Test live before committing.** Build and install (`build-app.sh --install`), let the user try the change, and commit only after they confirm. Check the app's state with `ctl status` rather than asking.
- **Keep docs in step.** Update README.md (user-facing behaviour, `ctl` commands) and TECH.md (concepts only, no volatile details; keep the tree at the top in sync) with every feature.
- **Commits** are split by feature with descriptive titles: `release.sh` turns the commit titles since the previous tag into the release notes.
- **Releases only when asked.** Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Support/Info.plist`, commit "Version x.y.z", push, run `./scripts/release.sh --yes`, then verify the downloaded asset (signature, `lipo -archs`, version). Users update in-app via Check for Updates.
- **Measure performance** with `scripts/benchmark.sh` after changes to the windows or event handling. Short ad-hoc tests have been misleading (small histories hide costs that grow with the log).

## Testing tips

- MIDIstatCore is pure logic: add checks to `Sources/MIDIstatCheck/main.swift`.
- `MIDIstatLoad` (`swift build -c release --product MIDIstatLoad`) creates virtual MIDI devices: `--notes N --aftertouch K --clock BPM --sensing --seconds S`.
- To check windows or menus without touching the user's running app, compile the app sources into a scratch harness (strip `import MIDIstatCore`, compile together with `Sources/MIDIstatCore/*.swift`) and comment out `startControlServer()`: a second instance would take over the control socket. Render windows offscreen with `cacheDisplay(in:to:)` to PNG and look at them.
- Spaces and full-screen behaviour cannot be tested automatically; describe the steps and ask the user.
- Avoid tools that trigger macOS permission prompts in automated checks (`osascript` with System Events, `screencapture`, `lldb`); they can hang silently waiting for a dialog.

## Pitfalls already met

- Don't keep a reference to `EventStore`'s arrays in a view: copy-on-write then copies the whole history on every new event.
- Don't update views of hidden windows on every event, and don't redraw large views per event: move layers instead (see Last Events, Last Notes).
- `NSApp.activate()` alone is often ignored for menu bar apps: use `activateTakingFocus()`.
- Full screen is detected from the wallpaper window (absent in full-screen Spaces); window sizes and presentation options proved unreliable.
