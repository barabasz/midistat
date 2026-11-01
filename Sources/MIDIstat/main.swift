import AppKit

// Build-time helper used by scripts/build-app.sh to produce the app icon.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--export-iconset" {
    do {
        try AppIcon.exportIconset(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        exit(0)
    } catch {
        FileHandle.standardError.write("Icon export failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
