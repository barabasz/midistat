import AppKit

extension NSWindow {
    /// "Always on Top" for all MIDIstat windows.
    /// On top: floats above other windows on every Space, full-screen apps included.
    /// Not on top: an ordinary window that appears on the Space the user is on
    /// when it is shown (so after closing it, it reopens where the user is).
    /// If it is turned off while a full-screen app is showing, the window is
    /// hidden there and comes back on the next regular desktop the user switches to.
    func setAlwaysOnTop(_ onTop: Bool) {
        if onTop {
            let wasWaiting = DesktopReturn.isWaiting(self)
            DesktopReturn.cancel(self)
            level = .floating
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            if wasWaiting { orderFrontRegardless() }
            return
        }
        level = .normal
        collectionBehavior = [.moveToActiveSpace]
        if isVisible && DesktopReturn.isFullScreenShowing(on: screen) {
            DesktopReturn.wait(self)
        }
    }

    /// Visible, or hidden only while waiting to come back on a regular desktop.
    var isShownOrWaiting: Bool {
        isVisible || DesktopReturn.isWaiting(self)
    }
}

/// Windows whose "Always on Top" was turned off over a full-screen app wait
/// here (hidden) until a regular desktop is showing, then appear there.
enum DesktopReturn {
    private static var waiting: [NSWindow] = []
    private static var observers: [NSObjectProtocol] = []

    /// Whether a full-screen app's Space (not a regular desktop) is showing on
    /// the screen. A regular desktop shows its wallpaper: an on-screen window at
    /// or below the desktop window level owned by the wallpaper process (not the
    /// Window Server or WindowManager, which are there in full-screen Spaces too).
    /// A full-screen Space has no wallpaper. (Measured on macOS 27: the window
    /// size alone can't tell a full-screen window from a maximised one.)
    static func isFullScreenShowing(on screen: NSScreen?) -> Bool {
        guard let screen = screen ?? NSScreen.main, let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // Window bounds use global coordinates with the origin at the primary screen's top left.
        let area = CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY,
                          width: screen.frame.width, height: screen.frame.height)
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let wallpaperShowing = list.contains { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer <= desktopLevel,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  owner != "Window Server", owner != "WindowManager",
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { return false }
            return bounds.intersects(area)
        }
        return !wallpaperShowing
    }

    static func isWaiting(_ window: NSWindow) -> Bool {
        waiting.contains { $0 === window }
    }

    static func wait(_ window: NSWindow) {
        window.orderOut(nil)
        if !isWaiting(window) { waiting.append(window) }
        startObserving()
    }

    /// The window was closed, opened explicitly or put back on top: stop waiting.
    static func cancel(_ window: NSWindow) {
        waiting.removeAll { $0 === window }
        if waiting.isEmpty { stopObserving() }
    }

    private static func startObserving() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // Check after the Space-switch animation, twice, so a frame of the
                // animation is not mistaken for a desktop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard onDesktop() else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { returnIfOnDesktop() }
                }
            })
        }
    }

    private static func stopObserving() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }

    /// The screen the user is working on: the one with the mouse pointer.
    private static func onDesktop() -> Bool {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        return !isFullScreenShowing(on: screen)
    }

    private static func returnIfOnDesktop() {
        guard !waiting.isEmpty, onDesktop() else { return }
        let windows = waiting
        waiting.removeAll()
        stopObserving()
        // .moveToActiveSpace: ordering the window in puts it on this desktop.
        windows.forEach { $0.orderFrontRegardless() }
    }
}

extension NSButton {
    /// Small checkbox used in the windows' option bars.
    static func smallCheckbox(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: target, action: action)
        checkbox.controlSize = .small
        checkbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        checkbox.sizeToFit()
        return checkbox
    }
}
