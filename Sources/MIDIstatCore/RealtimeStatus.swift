import Foundation

/// Summarises MIDI Clock instead of listing it: Clock is 24 pulses per
/// quarter note (48 messages per second at 120 BPM), sent by a tempo master
/// such as a DAW, drum machine or sequencer, so the useful information is the
/// tempo and whether the transport (Start / Stop / Continue) is running.
public final class ClockTracker {
    public enum Transport: String {
        case running, stopped, unknown
    }

    /// Clock counts as present while ticks keep arriving at least this often.
    public static let timeout: TimeInterval = 1

    public private(set) var transport: Transport = .unknown
    public private(set) var source: String?
    public private(set) var lastTick: Date?
    /// Recent tick times, enough for two beats of averaging.
    private var ticks: [Date] = []

    public init() {}

    public func handle(_ event: MIDIEvent) {
        switch event.kind {
        case .clock:
            if let last = ticks.last, event.date.timeIntervalSince(last) > Self.timeout {
                ticks.removeAll()  // after a pause, don't average across the gap
            }
            ticks.append(event.date)
            if ticks.count > 49 { ticks.removeFirst(ticks.count - 49) }
            lastTick = event.date
            source = event.source
        case .start, .continue:
            transport = .running
        case .stop:
            transport = .stopped
        default:
            break
        }
    }

    public func isPresent(at now: Date) -> Bool {
        lastTick.map { now.timeIntervalSince($0) < Self.timeout } ?? false
    }

    /// Tempo from the average tick interval; nil until there are enough ticks.
    public var bpm: Double? {
        guard ticks.count >= 7, let first = ticks.first, let last = ticks.last else { return nil }
        let interval = last.timeIntervalSince(first) / Double(ticks.count - 1)
        guard interval > 0 else { return nil }
        return 60 / (interval * 24)
    }

    /// e.g. `MIDI Clock: 120.0 BPM, running (Ableton Live)`, or nil when no clock arrives.
    public func summary(at now: Date) -> String? {
        guard isPresent(at: now) else { return nil }
        var text = "MIDI Clock: " + (bpm.map { String(format: "%.1f BPM", $0) } ?? "receiving")
        if transport != .unknown { text += ", \(transport.rawValue)" }
        if let source { text += " (\(source))" }
        return text
    }
}

/// Which devices currently send Active Sensing: a "still connected" heartbeat
/// sent every ~300 ms by some instruments; it carries no musical information.
public final class ActiveSensingTracker {
    public static let timeout: TimeInterval = 1
    private var lastSeen: [String: Date] = [:]

    public init() {}

    public func handle(_ event: MIDIEvent) {
        guard event.kind == .activeSensing else { return }
        lastSeen[event.source ?? "Unknown device"] = event.date
    }

    public func devices(at now: Date) -> [String] {
        lastSeen.filter { now.timeIntervalSince($0.value) < Self.timeout }.keys.sorted()
    }

    /// e.g. `Active Sensing: Yamaha P-125`, or nil when none arrives.
    public func summary(at now: Date) -> String? {
        let devices = devices(at: now)
        return devices.isEmpty ? nil : "Active Sensing: " + devices.joined(separator: ", ")
    }
}

// MARK: - Aligned columns for the Last Events window

extension MIDIFormat {
    public struct Columns: Equatable {
        public var timestamp: Bool
        public var device: Bool
        public var channel: Bool
        public var deviceWidth: Int
        public var eventWidth: Int

        public init(timestamp: Bool, device: Bool, channel: Bool, deviceWidth: Int = 16, eventWidth: Int = 44) {
            self.timestamp = timestamp
            self.device = device
            self.channel = channel
            self.deviceWidth = deviceWidth
            self.eventWidth = eventWidth
        }

        /// Characters in a full line, for sizing a monospaced view.
        public var totalWidth: Int {
            var parts = [eventWidth]
            if timestamp { parts.append(6) }
            if device { parts.append(deviceWidth) }
            if channel { parts.append(5) }
            return parts.reduce(0, +) + 2 * (parts.count - 1)
        }
    }

    /// One line with fixed-width columns for a monospaced font, e.g.
    /// ` 4.841  Xkey Air 25       ch: 1  Note 079 On (G5), velocity: 93`.
    public static func alignedLine(for event: MIDIEvent, columns: Columns, calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if columns.timestamp {
            parts.append(pad(timestamp(event.date, calendar: calendar), to: 6, alignRight: true))
        }
        if columns.device { parts.append(fit(event.source ?? "", to: columns.deviceWidth)) }
        if columns.channel {
            parts.append(event.channel.map { "ch:" + pad(String($0), to: 2, alignRight: true) } ?? String(repeating: " ", count: 5))
        }
        parts.append(truncate(description(of: event.kind), to: columns.eventWidth))
        return parts.joined(separator: "  ")
    }

    private static func pad(_ s: String, to width: Int, alignRight: Bool = false) -> String {
        guard s.count < width else { return s }
        let spaces = String(repeating: " ", count: width - s.count)
        return alignRight ? spaces + s : s + spaces
    }

    private static func truncate(_ s: String, to width: Int) -> String {
        s.count <= width ? s : String(s.prefix(max(0, width - 1))) + "…"
    }

    private static func fit(_ s: String, to width: Int) -> String {
        pad(truncate(s, to: width), to: width)
    }
}
