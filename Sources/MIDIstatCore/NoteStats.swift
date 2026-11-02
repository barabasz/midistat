import Foundation

/// Statistics of the key presses (Note On) for the Statistics window: counts,
/// pace, velocity and range.
///
/// Everything except `totalCount` refers to the time since the last reset, and
/// time-based values start with the first note after it. The pace over a
/// window (last minute, last 15 seconds) is measured from the first note of a
/// run of playing, which starts after a reset or after a gap of a whole
/// minute. While a run is shorter than the window, the pace is projected from
/// the notes so far (8 notes in 2 s are 240 per minute), counting at least
/// one second; after that it is the number of notes in the window, scaled to
/// a minute. Both agree when the window is full.
///
/// A class: the app and the window share one instance, so that recording a
/// note never copies the list of recent times.
public final class NoteStats {
    /// The longest window, how long note times are kept.
    public static let rateWindow: TimeInterval = 60
    /// The window of the short pace and of the peak.
    public static let shortWindow: TimeInterval = 15

    /// Since MIDIstat started; not affected by a reset.
    public private(set) var totalCount = 0
    public private(set) var count = 0
    /// The first note since the reset.
    public private(set) var firstNoteDate: Date?
    /// The highest pace over `shortWindow` reached in a full window since the reset.
    public private(set) var peakPerMinute = 0
    public private(set) var lowestNote: UInt8?
    public private(set) var highestNote: UInt8?
    public private(set) var softestVelocity: UInt8?
    public private(set) var loudestVelocity: UInt8?
    private var velocitySum = 0

    /// Times of the notes of the last `rateWindow`, oldest first, from `start` on.
    private var times: [Date] = []
    private var start = 0
    /// The first note of the current run of playing.
    private var runStart: Date?

    public init() {}

    public func add(note: UInt8, velocity: UInt8, at date: Date = Date()) {
        trim(before: date)
        if start == times.count { runStart = date }  // nothing in the last minute: a new run
        times.append(date)
        totalCount += 1
        count += 1
        if firstNoteDate == nil { firstNoteDate = date }
        velocitySum += Int(velocity)
        lowestNote = min(lowestNote ?? note, note)
        highestNote = max(highestNote ?? note, note)
        softestVelocity = min(softestVelocity ?? velocity, velocity)
        loudestVelocity = max(loudestVelocity ?? velocity, velocity)
        // The count in a sliding window only grows when a note arrives, so
        // checking at each note finds the peak. Projected values don't count.
        if let runStart, date.timeIntervalSince(runStart) >= Self.shortWindow {
            peakPerMinute = max(peakPerMinute, perMinute(over: Self.shortWindow, at: date))
        }
    }

    /// Everything except `totalCount` back to the start.
    public func reset() {
        count = 0
        firstNoteDate = nil
        peakPerMinute = 0
        lowestNote = nil
        highestNote = nil
        softestVelocity = nil
        loudestVelocity = nil
        velocitySum = 0
        times.removeAll(keepingCapacity: true)
        start = 0
        runStart = nil
    }

    /// Notes per minute over the last `window` seconds (at most `rateWindow`),
    /// projected while the current run is shorter than the window.
    public func perMinute(over window: TimeInterval = rateWindow, at date: Date = Date()) -> Int {
        trim(before: date)
        guard let runStart else { return 0 }
        let window = min(window, Self.rateWindow)
        let limit = date.addingTimeInterval(-window)
        var recent = 0
        for time in times[start...].reversed() {
            guard time > limit else { break }
            recent += 1
        }
        guard recent > 0 else { return 0 }
        let elapsed = date.timeIntervalSince(runStart)
        let span = elapsed < window ? max(elapsed, 1) : window
        return Int((Double(recent) * 60 / span).rounded())
    }

    /// The average pace from the first note since the reset to `date`, pauses included.
    public func averagePerMinute(at date: Date = Date()) -> Int {
        guard let firstNoteDate else { return 0 }
        return Int((Double(count) * 60 / max(date.timeIntervalSince(firstNoteDate), 1)).rounded())
    }

    public var averageVelocity: Int? {
        count > 0 ? Int((Double(velocitySum) / Double(count)).rounded()) : nil
    }

    private func trim(before date: Date) {
        let limit = date.addingTimeInterval(-Self.rateWindow)
        while start < times.count, times[start] <= limit { start += 1 }
        // Drop the expired times in batches rather than one by one.
        if start > 256, start * 2 > times.count {
            times.removeFirst(start)
            start = 0
        }
    }

    /// Velocity (1…127; 0 is a Note Off) as a level of a 16-step meter: 0–7 → 1, 8–15 → 2, …, 120–127 → 16.
    public static func velocityLevel(_ velocity: UInt8) -> Int {
        Int(min(velocity, 127)) / 8 + 1
    }

    /// A duration as "m:ss", or "h:mm:ss" from an hour on.
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
