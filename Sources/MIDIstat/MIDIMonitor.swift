import CoreMIDI
import Foundation
import MIDIstatCore

enum InputSelection: Equatable {
    case all
    case source(uniqueID: MIDIUniqueID, name: String)
}

struct MIDISource {
    let endpoint: MIDIEndpointRef
    let uniqueID: MIDIUniqueID
    let name: String
}

struct MIDIError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "CoreMIDI error \(status)" }
}

/// Owns the CoreMIDI client, keeps the input port connected to the selected
/// source(s) and reports decoded events on the main queue.
final class MIDIMonitor {
    var onEvent: ((MIDIEvent) -> Void)?
    var onSetupChanged: (() -> Void)?

    var selection: InputSelection = .all {
        didSet { reconnect() }
    }

    private(set) var sources: [MIDISource] = []
    private var connected: [MIDIEndpointRef] = []
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var outputPort = MIDIPortRef()

    /// Source names by unique ID, read from the CoreMIDI receive thread.
    private let namesLock = NSLock()
    private var sourceNames: [MIDIUniqueID: String] = [:]

    /// True when at least one source is connected, i.e. the app is actually listening.
    var isListening: Bool { !connected.isEmpty }

    func start() throws {
        var status = MIDIClientCreateWithBlock("MIDIstat" as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async {
                self?.reconnect()
                self?.onSetupChanged?()
            }
        }
        guard status == noErr else { throw MIDIError(status: status) }

        status = MIDIInputPortCreateWithProtocol(client, "MIDIstat Input" as CFString, ._1_0, &port) { [weak self] list, refCon in
            let date = Date()
            guard let self else { return }
            let events = MIDIMonitor.decode(list, date: date, source: self.sourceName(forRefCon: refCon))
            guard !events.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                for event in events { self?.onEvent?(event) }
            }
        }
        guard status == noErr else { throw MIDIError(status: status) }

        status = MIDIOutputPortCreate(client, "MIDIstat Output" as CFString, &outputPort)
        guard status == noErr else { throw MIDIError(status: status) }

        reconnect()
    }

    /// Number of MIDI outputs (destinations) currently online.
    var destinationCount: Int { Self.onlineDestinations().count }

    /// MIDI panic: sends All Sound Off, Reset All Controllers and All Notes Off
    /// on all 16 channels to every MIDI output. Returns how many outputs got it.
    @discardableResult
    func sendPanic() -> Int {
        guard outputPort != 0 else { return 0 }
        var words: [UInt32] = []
        for channel in UInt32(0)..<16 {
            for controller: UInt32 in [120, 121, 123] {
                // UMP message type 2 (MIDI 1.0 channel voice): Control Change, value 0.
                words.append(0x2000_0000 | (0xB0 | channel) << 16 | controller << 8)
            }
        }
        var sent = 0
        for destination in Self.onlineDestinations() {
            var list = MIDIEventList()
            var packet = MIDIEventListInit(&list, ._1_0)
            for word in words {
                packet = withUnsafePointer(to: word) {
                    MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, $0)
                }
            }
            if MIDISendEventList(outputPort, destination, &list) == noErr { sent += 1 }
        }
        return sent
    }

    /// Re-reads the list of sources and connects the port to the selected one(s).
    func reconnect() {
        sources = Self.currentSources()
        namesLock.lock()
        sourceNames = Dictionary(sources.map { ($0.uniqueID, $0.name) }, uniquingKeysWith: { first, _ in first })
        namesLock.unlock()
        guard port != 0 else { return }

        for endpoint in connected { MIDIPortDisconnectSource(port, endpoint) }
        connected = []

        let targets: [MIDISource]
        switch selection {
        case .all: targets = sources
        case let .source(uniqueID, _): targets = sources.filter { $0.uniqueID == uniqueID }
        }
        for source in targets where MIDIPortConnectSource(port, source.endpoint, Self.refCon(for: source.uniqueID)) == noErr {
            connected.append(source.endpoint)
        }
    }

    // MARK: - Helpers

    private static func onlineDestinations() -> [MIDIEndpointRef] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { index in
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else { return nil }
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
            return offline == 0 ? endpoint : nil
        }
    }

    /// The connection refCon carries the source's unique ID (never a null pointer).
    private static func refCon(for uniqueID: MIDIUniqueID) -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: UInt(UInt32(bitPattern: uniqueID)) | (1 << 32))
    }

    private func sourceName(forRefCon refCon: UnsafeMutableRawPointer?) -> String? {
        guard let refCon else { return nil }
        let uniqueID = MIDIUniqueID(bitPattern: UInt32(truncatingIfNeeded: UInt(bitPattern: refCon)))
        namesLock.lock()
        defer { namesLock.unlock() }
        return sourceNames[uniqueID]
    }

    private static func currentSources() -> [MIDISource] {
        (0..<MIDIGetNumberOfSources()).compactMap { index in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { return nil }
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
            guard offline == 0 else { return nil }
            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
            return MIDISource(endpoint: endpoint, uniqueID: uniqueID, name: displayName(of: endpoint))
        }
    }

    private static func displayName(of object: MIDIObjectRef) -> String {
        for property in [kMIDIPropertyDisplayName, kMIDIPropertyName] {
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(object, property, &name) == noErr, let name {
                return name.takeRetainedValue() as String
            }
        }
        return "Unknown MIDI source"
    }

    private static let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words)!

    private static func decode(_ list: UnsafePointer<MIDIEventList>, date: Date, source: String?) -> [MIDIEvent] {
        var events: [MIDIEvent] = []
        for packet in list.unsafeSequence() {
            let base = UnsafeRawPointer(packet)
                .advanced(by: wordsOffset)
                .assumingMemoryBound(to: UInt32.self)
            let words = UnsafeBufferPointer(start: base, count: Int(packet.pointee.wordCount))
            events += UMPParser.parse(words: words, date: date, source: source)
        }
        return events
    }
}
