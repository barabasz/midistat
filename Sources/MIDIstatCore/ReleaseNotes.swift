import Foundation

/// Pure helpers for the update check: version comparison and the list of
/// changes shown in the update dialog.
///
/// Each GitHub release's notes list only the commits since the previous
/// release (see scripts/release.sh), so the changes between any installed
/// version and the latest one are simply the "## Changes" sections of all
/// releases newer than the installed version.
public enum ReleaseNotes {
    /// Numeric comparison of dotted versions, ignoring a leading "v": 0.10.0 > 0.9.1.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
    }

    /// The entries of the "## Changes" section, in the order listed, without
    /// commit hashes and without technical "Version x.y.z" commits.
    public static func changes(in notes: String) -> [String] {
        guard let start = notes.range(of: "## Changes") else { return [] }
        return notes[start.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .prefix { !$0.hasPrefix("## ") && !$0.hasPrefix("**Full diff") }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }
            .map { $0.replacingOccurrences(of: #"\s*\([0-9a-f]{7,40}\)$"#, with: "", options: .regularExpression) }
            .filter { $0.range(of: #"^Version \d+(\.\d+)*$"#, options: .regularExpression) == nil }
    }

    public struct Summary: Equatable {
        public let shown: [String]
        public let more: Int

        public init(shown: [String], more: Int) {
            self.shown = shown
            self.more = more
        }
    }

    /// Changes from all releases newer than `current`, newest release first,
    /// cut to `limit` entries; `more` is how many were left out.
    /// `releases` are (version, notes) pairs in any order.
    public static func summary(of releases: [(version: String, notes: String)], since current: String,
                               limit: Int = 5) -> Summary {
        let newer = releases
            .filter { isNewer($0.version, than: current) }
            .sorted { isNewer($0.version, than: $1.version) }
        // Within a release the notes are oldest first; show the newest first.
        let all = newer.flatMap { changes(in: $0.notes).reversed() }
        return Summary(shown: Array(all.prefix(limit)), more: max(0, all.count - limit))
    }
}
