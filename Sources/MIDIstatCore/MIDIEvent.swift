import Foundation

/// A single decoded MIDI 1.0 message.
public enum MIDIEventKind: Equatable, Sendable {
    // Channel voice
    case noteOn(note: UInt8, velocity: UInt8)
    case noteOff(note: UInt8, velocity: UInt8)
    case polyPressure(note: UInt8, value: UInt8)
    case controlChange(controller: UInt8, value: UInt8)
    case programChange(program: UInt8)
    case channelPressure(value: UInt8)
    case pitchBend(value: Int)  // -8192 ... +8191, 0 = centre

    // System common
    case sysEx
    case mtcQuarterFrame(value: UInt8)
    case songPosition(beats: Int)
    case songSelect(song: UInt8)
    case tuneRequest

    // System real-time
    case clock
    case start
    case `continue`
    case stop
    case activeSensing
    case reset
}

public struct MIDIEvent: Equatable, Sendable {
    public let date: Date
    /// Name of the MIDI source (device/port) the message came from.
    public let source: String?
    /// 1-based MIDI channel; `nil` for system messages.
    public let channel: Int?
    public let kind: MIDIEventKind

    public init(date: Date, source: String? = nil, channel: Int?, kind: MIDIEventKind) {
        self.date = date
        self.source = source
        self.channel = channel
        self.kind = kind
    }

    /// Builds an event from MIDI 1.0 status and data bytes.
    /// A Note On with velocity 0 is reported as a Note Off.
    public static func fromBytes(status: UInt8, data1: UInt8, data2: UInt8, date: Date,
                                 source: String? = nil) -> MIDIEvent? {
        let d1 = data1 & 0x7F
        let d2 = data2 & 0x7F
        if status < 0xF0 {
            let channel = Int(status & 0x0F) + 1
            let kind: MIDIEventKind
            switch status & 0xF0 {
            case 0x80: kind = .noteOff(note: d1, velocity: d2)
            case 0x90: kind = d2 == 0 ? .noteOff(note: d1, velocity: 0) : .noteOn(note: d1, velocity: d2)
            case 0xA0: kind = .polyPressure(note: d1, value: d2)
            case 0xB0: kind = .controlChange(controller: d1, value: d2)
            case 0xC0: kind = .programChange(program: d1)
            case 0xD0: kind = .channelPressure(value: d1)
            case 0xE0: kind = .pitchBend(value: (Int(d2) << 7 | Int(d1)) - 8192)
            default: return nil
            }
            return MIDIEvent(date: date, source: source, channel: channel, kind: kind)
        }
        let kind: MIDIEventKind
        switch status {
        case 0xF0: kind = .sysEx
        case 0xF1: kind = .mtcQuarterFrame(value: d1)
        case 0xF2: kind = .songPosition(beats: Int(d2) << 7 | Int(d1))
        case 0xF3: kind = .songSelect(song: d1)
        case 0xF6: kind = .tuneRequest
        case 0xF8: kind = .clock
        case 0xFA: kind = .start
        case 0xFB: kind = .continue
        case 0xFC: kind = .stop
        case 0xFE: kind = .activeSensing
        case 0xFF: kind = .reset
        default: return nil
        }
        return MIDIEvent(date: date, source: source, channel: nil, kind: kind)
    }
}

// MARK: - Formatting

public enum MIDIFormat {
    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Note name with octave, where 60 = C4 (so 79 = G5).
    public static func noteName(_ note: UInt8) -> String {
        "\(noteNames[Int(note) % 12])\(Int(note) / 12 - 1)"
    }

    private static let controllerNames: [UInt8: String] = [
        0: "Bank Select", 1: "Modulation", 2: "Breath", 4: "Foot", 5: "Portamento Time",
        7: "Volume", 8: "Balance", 10: "Pan", 11: "Expression", 32: "Bank Select LSB",
        64: "Sustain", 65: "Portamento", 66: "Sostenuto", 67: "Soft Pedal",
        120: "All Sound Off", 121: "Reset All Controllers", 122: "Local Control",
        123: "All Notes Off", 124: "Omni Off", 125: "Omni On", 126: "Mono On", 127: "Poly On",
    ]

    private static func pad3(_ value: UInt8) -> String {
        String(format: "%03d", Int(value))
    }

    public static func description(of kind: MIDIEventKind) -> String {
        switch kind {
        case let .noteOn(note, velocity):
            return "Note \(pad3(note)) On (\(noteName(note))), velocity: \(velocity)"
        case let .noteOff(note, velocity):
            return "Note \(pad3(note)) Off (\(noteName(note))), velocity: \(velocity)"
        case let .polyPressure(note, value):
            return "Poly Pressure \(pad3(note)) (\(noteName(note))), value: \(value)"
        case let .controlChange(controller, value):
            let name = controllerNames[controller].map { " (\($0))" } ?? ""
            return "Control Change \(pad3(controller))\(name), value: \(value)"
        case let .programChange(program):
            return "Program Change \(pad3(program))"
        case let .channelPressure(value):
            return "Channel Pressure, value: \(value)"
        case let .pitchBend(value):
            return "Pitch Bend, value: \(value > 0 ? "+" : "")\(value)"
        case .sysEx: return "SysEx"
        case let .mtcQuarterFrame(value): return "MTC Quarter Frame, value: \(value)"
        case let .songPosition(beats): return "Song Position, beat: \(beats)"
        case let .songSelect(song): return "Song Select \(pad3(song))"
        case .tuneRequest: return "Tune Request"
        case .clock: return "Clock"
        case .start: return "Start"
        case .continue: return "Continue"
        case .stop: return "Stop"
        case .activeSensing: return "Active Sensing"
        case .reset: return "System Reset"
        }
    }

    /// Seconds within the current minute plus milliseconds, e.g. `4.841`.
    public static func timestamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.second, .nanosecond], from: date)
        return String(format: "%d.%03d", c.second ?? 0, (c.nanosecond ?? 0) / 1_000_000)
    }

    /// e.g. `4.841, ch: 1, Note 079 On (G5), velocity: 93`, or with the source
    /// name: `4.841, Xkey Air 25, ch: 1, Note 079 On (G5), velocity: 93`.
    public static func line(for event: MIDIEvent, includeTimestamp: Bool = true, includeSource: Bool = false,
                            includeChannel: Bool = true, calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if includeTimestamp { parts.append(timestamp(event.date, calendar: calendar)) }
        if includeSource, let source = event.source { parts.append(source) }
        if includeChannel, let channel = event.channel { parts.append("ch: \(channel)") }
        parts.append(description(of: event.kind))
        return parts.joined(separator: ", ")
    }
}
