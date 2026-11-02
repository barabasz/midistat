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

/// The "MI / DI" mark in two columns: the bottom-left "D" (the indicator)
/// sits under the M and is as wide as the M's ink, the two I's are aligned.
/// The D is a solid shape: a straight left edge, flat top and bottom, and a
/// semicircle on the right, very slightly taller than the letters (like the
/// optical overshoot of round letters).
/// All proportions scale with the font size, so the same drawing is used
/// for the 18 pt menu bar icon and the 1024 px app icon.
struct Glyph {
    let font: NSFont
    private let letterSpacing: CGFloat
    private let rowGap: CGFloat
    private let widthM: CGFloat, widthI: CGFloat
    /// The M's ink (outline) within its advance width.
    private let inkM: CGRect

    init(fontSize: CGFloat) {
        font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        letterSpacing = fontSize * 0.06
        rowGap = fontSize * 0.27
        let measure = { [font] (s: String) in (s as NSString).size(withAttributes: [.font: font]).width }
        widthM = measure("M")
        widthI = measure("I")
        var character: UniChar = 0x4D  // "M"
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1)
        inkM = font.boundingRect(forCGGlyph: glyph)
    }

    private var leftColumn: CGFloat { widthM }
    private var columnGap: CGFloat { letterSpacing }

    /// Size of the ink: from the bottom baseline to the top cap height.
    var size: NSSize {
        NSSize(width: leftColumn + columnGap + widthI, height: 2 * font.capHeight + rowGap)
    }

    func draw(at origin: NSPoint, letterColor: NSColor, indicatorColor: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: letterColor]
        func text(_ s: String, x: CGFloat, baseline: CGFloat) {
            (s as NSString).draw(at: NSPoint(x: x, y: baseline + font.descender), withAttributes: attributes)
        }
        let capHeight = font.capHeight
        let bottomBaseline = origin.y
        let topBaseline = origin.y + capHeight + rowGap
        let rightX = origin.x + leftColumn + columnGap

        text("M", x: origin.x, baseline: topBaseline)
        text("I", x: rightX, baseline: topBaseline)
        text("I", x: rightX, baseline: bottomBaseline)

        // The D: under the M's ink, a hair taller than the cap height.
        let overshoot = capHeight * 0.02
        let rect = NSRect(x: origin.x + inkM.minX, y: bottomBaseline - overshoot,
                          width: inkM.width, height: capHeight + 2 * overshoot)
        let radius = min(rect.height / 2, rect.width)
        let d = NSBezierPath()
        d.move(to: NSPoint(x: rect.minX, y: rect.minY))
        d.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        d.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.midY), radius: radius,
                    startAngle: -90, endAngle: 90)
        d.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        d.close()
        indicatorColor.setFill()
        d.fill()
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
            glyph.draw(at: origin, letterColor: .labelColor, indicatorColor: state.indicatorColor)
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
                   indicatorColor: NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1))
    }
}
