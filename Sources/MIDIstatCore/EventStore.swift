import Foundation

/// Optional categories of MIDI messages that the user can hide from the
/// event lists. They still light the activity indicator.
public struct EventCategories: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Clock and Active Sensing: some devices send them continuously.
    public static let continuousRealtime = EventCategories(rawValue: 1 << 0)
    /// Poly and channel pressure: can produce a flood of messages while a key is held.
    public static let aftertouch = EventCategories(rawValue: 1 << 1)

    public static let all: EventCategories = [.continuousRealtime, .aftertouch]
}

extension MIDIEvent {
    /// The optional category this event belongs to (empty for regular messages).
    public var category: EventCategories {
        switch kind {
        case .clock, .activeSensing: return .continuousRealtime
        case .polyPressure, .channelPressure: return .aftertouch
        default: return []
        }
    }
}

/// Keeps every event received since launch (up to `limit` per view).
/// One list is kept for each combination of shown categories, so switching
/// a filter is instant and appending stays O(1).
public final class EventStore {
    public let limit: Int

    private var views: [[MIDIEvent]]
    /// Events ever appended to each view since the last clear (not reduced by trimming).
    private var appendedCounts: [Int]
    private var hiddenCounts: [EventCategories: Int] = [:]

    /// Incremented by `clear()`, so a viewer can tell that its rows are stale.
    public private(set) var generation = 0

    /// `limit` caps memory use: devices sending Clock produce ~50 messages per second.
    public init(limit: Int = 100_000) {
        self.limit = limit
        views = Array(repeating: [], count: EventCategories.all.rawValue + 1)
        appendedCounts = Array(repeating: 0, count: views.count)
    }

    public func append(_ event: MIDIEvent) {
        let category = event.category
        if !category.isEmpty { hiddenCounts[category, default: 0] += 1 }
        for raw in views.indices where EventCategories(rawValue: raw).isSuperset(of: category) {
            views[raw].append(event)
            appendedCounts[raw] += 1
            // Trim in chunks so that removing from the front stays cheap.
            if views[raw].count > limit + max(1, limit / 10) {
                views[raw].removeFirst(views[raw].count - limit)
            }
        }
    }

    /// Events, oldest first, including only the given optional categories.
    public func events(including shown: EventCategories) -> [MIDIEvent] {
        views[shown.intersection(.all).rawValue]
    }

    /// How many events were ever appended to this view since the last clear.
    /// Lets a viewer tell "only new events at the end" apart from "trimmed or cleared".
    public func appendedCount(including shown: EventCategories) -> Int {
        appendedCounts[shown.intersection(.all).rawValue]
    }

    public func recent(_ count: Int, including shown: EventCategories) -> ArraySlice<MIDIEvent> {
        events(including: shown).suffix(count)
    }

    /// How many messages of a category were received since launch / last clear.
    public func count(of category: EventCategories) -> Int {
        hiddenCounts[category, default: 0]
    }

    /// e.g. `Hidden: 120 Clock / Active Sensing, 3400 Aftertouch`, or nil if nothing is hidden.
    public func hiddenSummary(shown: EventCategories) -> String? {
        var parts: [String] = []
        if !shown.contains(.continuousRealtime), count(of: .continuousRealtime) > 0 {
            parts.append("\(count(of: .continuousRealtime)) Clock / Active Sensing")
        }
        if !shown.contains(.aftertouch), count(of: .aftertouch) > 0 {
            parts.append("\(count(of: .aftertouch)) Aftertouch")
        }
        return parts.isEmpty ? nil : "Hidden: " + parts.joined(separator: ", ")
    }

    public func clear() {
        for raw in views.indices { views[raw].removeAll() }
        appendedCounts = Array(repeating: 0, count: views.count)
        hiddenCounts.removeAll()
        generation += 1
    }
}
