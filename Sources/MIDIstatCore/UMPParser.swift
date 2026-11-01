import Foundation

/// Decodes Universal MIDI Packet words (as delivered by CoreMIDI for a
/// port created with the MIDI 1.0 protocol) into `MIDIEvent`s.
public enum UMPParser {
    /// Number of 32-bit words in a UMP, by message type (top nibble of word 0).
    static func wordCount(forMessageType type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }

    public static func parse<C: Collection>(words: C, date: Date, source: String? = nil) -> [MIDIEvent]
    where C.Element == UInt32 {
        let words = Array(words)
        var events: [MIDIEvent] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            let type = w >> 28
            switch type {
            case 0x1, 0x2:  // system common / real-time, MIDI 1.0 channel voice
                let status = UInt8((w >> 16) & 0xFF)
                let d1 = UInt8((w >> 8) & 0x7F)
                let d2 = UInt8(w & 0x7F)
                if let e = MIDIEvent.fromBytes(status: status, data1: d1, data2: d2, date: date, source: source) {
                    events.append(e)
                }
            case 0x3:  // 7-bit SysEx: report once per message (complete or start)
                let sysexStatus = (w >> 20) & 0xF
                if sysexStatus == 0x0 || sysexStatus == 0x1 {
                    events.append(MIDIEvent(date: date, source: source, channel: nil, kind: .sysEx))
                }
            default:
                break
            }
            i += wordCount(forMessageType: type)
        }
        return events
    }
}
