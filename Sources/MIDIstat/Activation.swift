import AppKit

extension NSApplication {
    /// Makes this menu bar app the active app. Plain `activate()` is cooperative
    /// since macOS 14 and is often ignored for apps without a Dock icon, so take
    /// over activation from the frontmost app instead.
    func activateTakingFocus() {
        if let front = NSWorkspace.shared.frontmostApplication, front != .current {
            NSRunningApplication.current.activate(from: front, options: [])
        } else {
            activate()
        }
    }
}
