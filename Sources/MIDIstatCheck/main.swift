// Self-check for MIDIstatCore. Run with: swift run MIDIstatCheck
// (swift-testing / XCTest are not usable with Command Line Tools alone.)
import Foundation
import MIDIstatCore

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var currentTest = ""
func expect(_ ok: Bool, _ expr: String = "", line: Int = #line) {
    if !ok { failures += 1; print("FAIL \(currentTest) (line \(line))") }
}

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

// 2026-11-01 12:34:04.841 UTC
private let date = Date(timeIntervalSince1970: 1_793_536_444.841)

func noteOnMatchesSpecExample() {
    let e = MIDIEvent.fromBytes(status: 0x90, data1: 79, data2: 93, date: date)!
    expect(MIDIFormat.line(for: e, calendar: utc) == "4.841, ch: 1, Note 079 On (G5), velocity: 93")
}

func noteOnWithZeroVelocityIsNoteOff() {
    let e = MIDIEvent.fromBytes(status: 0x90, data1: 79, data2: 0, date: date)!
    expect(e.kind == .noteOff(note: 79, velocity: 0))
    expect(MIDIFormat.description(of: e.kind) == "Note 079 Off (G5), velocity: 0")
}

func channelIsOneBased() {
    let e = MIDIEvent.fromBytes(status: 0xBF, data1: 64, data2: 127, date: date)!
    expect(e.channel == 16)
    expect(MIDIFormat.description(of: e.kind) == "Control Change 064 (Sustain), value: 127")
}

func noteNames() {
    expect(MIDIFormat.noteName(60) == "C4")
    expect(MIDIFormat.noteName(0) == "C-1")
    expect(MIDIFormat.noteName(61) == "C#4")
    expect(MIDIFormat.noteName(127) == "G9")
}

func pitchBend() {
    let centre = MIDIEvent.fromBytes(status: 0xE0, data1: 0, data2: 0x40, date: date)!
    expect(centre.kind == .pitchBend(value: 0))
    let max = MIDIEvent.fromBytes(status: 0xE0, data1: 0x7F, data2: 0x7F, date: date)!
    expect(MIDIFormat.description(of: max.kind) == "Pitch Bend, value: +8191")
}

func systemMessagesHaveNoChannel() {
    let clock = MIDIEvent.fromBytes(status: 0xF8, data1: 0, data2: 0, date: date)!
    expect(clock.category == .continuousRealtime)
    expect(MIDIFormat.line(for: clock, calendar: utc) == "4.841, Clock")
    let start = MIDIEvent.fromBytes(status: 0xFA, data1: 0, data2: 0, date: date)!
    expect(start.category.isEmpty)
}

func umpPacketWithMixedMessages() {
    let words: [UInt32] = [
        0x2090_4F5D,              // MIDI 1.0 Note On ch1, note 79, vel 93
        0x10F8_0000,              // Clock
        0x3016_F07E, 0x0000_0000, // SysEx complete (2 words)
        0x4090_4F00, 0xFFFF_0000, // MIDI 2.0 note on (ignored, 2 words)
        0x20B0_0764,              // CC 7 = 100
    ]
    let events = UMPParser.parse(words: words, date: date)
    expect(events.map(\.kind) == [
        .noteOn(note: 79, velocity: 93),
        .clock,
        .sysEx,
        .controlChange(controller: 7, value: 100),
    ])
}

func sysExContinuationIsNotRepeated() {
    let words: [UInt32] = [0x3016_0000, 0, 0x3026_0000, 0, 0x3036_0000, 0]
    expect(UMPParser.parse(words: words, date: date).map(\.kind) == [.sysEx])
}

func lineOptions() {
    let e = MIDIEvent.fromBytes(status: 0x90, data1: 79, data2: 93, date: date, source: "Xkey Air 25")!
    expect(MIDIFormat.line(for: e, includeSource: true, calendar: utc)
        == "4.841, Xkey Air 25, ch: 1, Note 079 On (G5), velocity: 93")
    expect(MIDIFormat.line(for: e, calendar: utc) == "4.841, ch: 1, Note 079 On (G5), velocity: 93")
    expect(MIDIFormat.line(for: e, includeTimestamp: false, includeSource: true, calendar: utc)
        == "Xkey Air 25, ch: 1, Note 079 On (G5), velocity: 93")
    expect(MIDIFormat.line(for: e, includeTimestamp: false) == "ch: 1, Note 079 On (G5), velocity: 93")
    let parsed = UMPParser.parse(words: [0x2090_4F5D], date: date, source: "Xkey Air 25")
    expect(parsed.first?.source == "Xkey Air 25")
}

func storeFilters() {
    let store = EventStore()
    let note = MIDIEvent.fromBytes(status: 0x90, data1: 60, data2: 100, date: date)!
    let clock = MIDIEvent.fromBytes(status: 0xF8, data1: 0, data2: 0, date: date)!
    let sensing = MIDIEvent.fromBytes(status: 0xFE, data1: 0, data2: 0, date: date)!
    let poly = MIDIEvent.fromBytes(status: 0xA0, data1: 60, data2: 40, date: date)!
    let channel = MIDIEvent.fromBytes(status: 0xD0, data1: 50, data2: 0, date: date)!
    expect(poly.category == .aftertouch && channel.category == .aftertouch)

    store.append(note)
    for _ in 0..<10 { store.append(clock); store.append(sensing) }
    for _ in 0..<3 { store.append(poly); store.append(channel) }

    // Both hidden: only the note.
    expect(store.events(including: []) == [note])
    expect(Array(store.recent(10, including: [])) == [note])
    // Each filter on its own.
    expect(store.events(including: .continuousRealtime).count == 21)
    expect(store.events(including: .aftertouch).count == 7)
    expect(store.events(including: .all).count == 27)
    // Shown: the last 5 are aftertouch, the note is pushed out.
    expect(!store.recent(5, including: .all).contains(note))

    expect(store.count(of: .continuousRealtime) == 20 && store.count(of: .aftertouch) == 6)
    expect(store.hiddenSummary(shown: []) == "Hidden: 20 Clock / Active Sensing, 6 Aftertouch")
    expect(store.hiddenSummary(shown: .aftertouch) == "Hidden: 20 Clock / Active Sensing")
    expect(store.hiddenSummary(shown: .all) == nil)

    store.clear()
    expect(store.events(including: .all).isEmpty && store.hiddenSummary(shown: []) == nil)
}

func storeIsCapped() {
    let store = EventStore(limit: 100)
    for i in 0..<1_000 {
        store.append(MIDIEvent.fromBytes(status: 0xB0, data1: 1, data2: UInt8(i % 128), date: date)!)
    }
    let all = store.events(including: .all)
    expect(all.count >= 100 && all.count <= 110)
    expect(all.last?.kind == .controlChange(controller: 1, value: UInt8(999 % 128)))
}

let tests: [(String, () -> Void)] = [
    ("noteOnMatchesSpecExample", noteOnMatchesSpecExample),
    ("noteOnWithZeroVelocityIsNoteOff", noteOnWithZeroVelocityIsNoteOff),
    ("channelIsOneBased", channelIsOneBased),
    ("noteNames", noteNames),
    ("pitchBend", pitchBend),
    ("systemMessagesHaveNoChannel", systemMessagesHaveNoChannel),
    ("umpPacketWithMixedMessages", umpPacketWithMixedMessages),
    ("sysExContinuationIsNotRepeated", sysExContinuationIsNotRepeated),
    ("lineOptions", lineOptions),
    ("storeFilters", storeFilters),
    ("storeIsCapped", storeIsCapped),
]
for (name, test) in tests { currentTest = name; test() }
print(failures == 0 ? "All \(tests.count) checks passed." : "\(failures) failure(s).")
exit(failures == 0 ? 0 : 1)
