import AppKit

enum IconState {
    case idle       // listening, nothing received in the last second
    case active     // MIDI received within the last second
    case noDevice   // nothing to listen to

    var indicatorColor: NSColor {
        switch self {
        case .idle: return .tertiaryLabelColor
        case .active: return .systemGreen
        case .noDevice: return .systemRed
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .idle: return "MIDIstat: listening"
        case .active: return "MIDIstat: receiving MIDI"
        case .noDevice: return "MIDIstat: no MIDI device"
        }
    }
}

/// The "MI / ▶I" mark in two columns: the triangle (the indicator) sits under
/// the M, the two I's are aligned.
/// All proportions scale with the font size, so the same drawing is used
/// for the 18 pt menu bar icon and the 1024 px app icon.
struct Glyph {
    let font: NSFont
    private let letterSpacing: CGFloat
    private let rowGap: CGFloat
    private let triangleWidth: CGFloat
    private let triangleGap: CGFloat
    private let widthM: CGFloat, widthI: CGFloat

    init(fontSize: CGFloat) {
        font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        letterSpacing = fontSize * 0.06
        rowGap = fontSize * 0.27
        triangleWidth = font.capHeight * 0.9
        triangleGap = fontSize * 0.12
        let measure = { [font] (s: String) in (s as NSString).size(withAttributes: [.font: font]).width }
        widthM = measure("M")
        widthI = measure("I")
    }

    private var leftColumn: CGFloat { max(widthM, triangleWidth) }
    private var columnGap: CGFloat { max(letterSpacing, triangleGap - (leftColumn - triangleWidth) / 2) }

    /// Size of the ink: from the bottom baseline to the top cap height.
    var size: NSSize {
        NSSize(width: leftColumn + columnGap + widthI, height: 2 * font.capHeight + rowGap)
    }

    func draw(at origin: NSPoint, letterColor: NSColor, triangleColor: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: letterColor]
        func text(_ s: String, x: CGFloat, baseline: CGFloat) {
            (s as NSString).draw(at: NSPoint(x: x, y: baseline + font.descender), withAttributes: attributes)
        }
        let capHeight = font.capHeight
        let bottomBaseline = origin.y
        let topBaseline = origin.y + capHeight + rowGap
        let rightX = origin.x + leftColumn + columnGap
        let triangleX = origin.x + (leftColumn - triangleWidth) / 2

        text("M", x: origin.x + (leftColumn - widthM) / 2, baseline: topBaseline)
        text("I", x: rightX, baseline: topBaseline)
        text("I", x: rightX, baseline: bottomBaseline)

        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: triangleX, y: bottomBaseline))
        triangle.line(to: NSPoint(x: triangleX, y: bottomBaseline + capHeight))
        triangle.line(to: NSPoint(x: triangleX + triangleWidth, y: bottomBaseline + capHeight / 2))
        triangle.close()
        triangleColor.setFill()
        triangle.fill()
    }
}

enum StatusIcon {
    private static var cache: [IconState: NSImage] = [:]

    static func image(for state: IconState) -> NSImage {
        if let cached = cache[state] { return cached }

        let glyph = Glyph(fontSize: 9.5)
        let padding: CGFloat = 1
        let size = NSSize(width: ceil(glyph.size.width + 2 * padding), height: 18)
        let origin = NSPoint(x: (size.width - glyph.size.width) / 2,
                             y: ((size.height - glyph.size.height) / 2).rounded())

        let image = NSImage(size: size, flipped: false) { _ in
            // Colours resolve at draw time, so the letters follow light/dark menu bars.
            glyph.draw(at: origin, letterColor: .labelColor, triangleColor: state.indicatorColor)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = state.accessibilityDescription
        cache[state] = image
        return image
    }
}

/// Renders the app icon (`MIDIstat --export-iconset <dir.iconset>`), turned
/// into AppIcon.icns by scripts/build-app.sh.
enum AppIcon {
    static func exportIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try png(pixels: pixels).write(to: directory.appendingPathComponent(name))
            }
        }
    }

    private static func png(pixels: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw CocoaError(.fileWriteUnknown) }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let scale = CGFloat(pixels) / 1024
        context.cgContext.scaleBy(x: scale, y: scale)
        draw1024()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    /// Drawn on the standard 1024 macOS icon grid (824 px rounded square).
    private static func draw1024() {
        let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowBlurRadius = 20
        shadow.set()
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1),
                   ending: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1))?
            .draw(in: shape, angle: -90)

        let glyph = Glyph(fontSize: 290)
        let origin = NSPoint(x: tile.midX - glyph.size.width / 2, y: tile.midY - glyph.size.height / 2)
        glyph.draw(at: origin,
                   letterColor: NSColor(white: 0.96, alpha: 1),
                   triangleColor: NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1))
    }
}
