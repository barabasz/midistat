// Virtual MIDI devices for load tests (used by scripts/benchmark.sh).
//
//   MIDIstatLoad --seconds 10 [--notes 6] [--aftertouch 10] [--clock 120] [--sensing]
//
// --notes N       "MIDIstat Load" plays N notes per second (Note On + Note Off)
// --aftertouch K  K poly pressure messages after each Note On
// --clock BPM     "MIDIstat Load Clock" sends Start and MIDI Clock at BPM
// --sensing       "MIDIstat Load" also sends Active Sensing every 300 ms
import CoreMIDI
import Foundation

var seconds = 10.0, notesPerSecond = 0.0, aftertouch = 0, bpm = 0.0, sensing = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let option = arguments.next() {
    func value() -> Double {
        guard let text = arguments.next(), let number = Double(text) else {
            FileHandle.standardError.write(Data("\(option) needs a number\n".utf8)); exit(2)
        }
        return number
    }
    switch option {
    case "--seconds": seconds = value()
    case "--notes": notesPerSecond = value()
    case "--aftertouch": aftertouch = Int(value())
    case "--clock": bpm = value()
    case "--sensing": sensing = true
    default:
        FileHandle.standardError.write(Data("unknown option \(option)\n".utf8)); exit(2)
    }
}

var client = MIDIClientRef(), keys = MIDIEndpointRef(), clock = MIDIEndpointRef()
MIDIClientCreateWithBlock("MIDIstat load test" as CFString, &client, nil)
MIDISourceCreateWithProtocol(client, "MIDIstat Load" as CFString, ._1_0, &keys)
if bpm > 0 { MIDISourceCreateWithProtocol(client, "MIDIstat Load Clock" as CFString, ._1_0, &clock) }

func send(_ source: MIDIEndpointRef, _ word: UInt32) {
    var list = MIDIEventList()
    var packet = MIDIEventListInit(&list, ._1_0)
    packet = withUnsafePointer(to: word) { MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, $0) }
    MIDIReceivedEventList(source, &list)
}

Thread.sleep(forTimeInterval: 1)  // let MIDIstat connect to the new sources
if bpm > 0 { send(clock, 0x10FA_0000) }  // Start

let start = Date()
var nextClock = 0.0, nextSensing = 0.0, nextNote = 0.0
var noteOn = false, note: UInt32 = 60, sent = 0
while case let t = Date().timeIntervalSince(start), t < seconds {
    if bpm > 0, t >= nextClock { send(clock, 0x10F8_0000); nextClock += 60 / bpm / 24 }
    if sensing, t >= nextSensing { send(keys, 0x10FE_0000); nextSensing += 0.3 }
    if notesPerSecond > 0, t >= nextNote {
        if noteOn {
            send(keys, 0x2080_0000 | note << 8)
        } else {
            note = UInt32.random(in: 48...84)
            send(keys, 0x2090_0000 | note << 8 | UInt32.random(in: 40...110))
            for i in 0..<aftertouch { send(keys, 0x20A0_0000 | note << 8 | UInt32(30 + i % 90)) }
            sent += 1
        }
        noteOn.toggle()
        nextNote += 0.5 / notesPerSecond
    }
    Thread.sleep(forTimeInterval: 0.001)
}
if bpm > 0 { send(clock, 0x10FC_0000) }  // Stop
MIDIEndpointDispose(keys)
if bpm > 0 { MIDIEndpointDispose(clock) }
print("MIDIstatLoad: \(sent) notes in \(Int(seconds)) s")
