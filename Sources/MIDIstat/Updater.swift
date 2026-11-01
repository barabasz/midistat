import CryptoKit
import Foundation

/// Checks GitHub Releases for a newer version and installs it in place.
///
/// Installing: the release zip is downloaded, checked (SHA-256 digest from
/// GitHub, bundle identifier, version, code signature) and unpacked next to
/// nothing important (a temporary folder). A small detached shell script then
/// waits for MIDIstat to quit, swaps the app bundle (restoring the old one if
/// the swap fails) and launches the new version.
enum Updater {
    static let repository = "barabasz/midistat"

    struct Release {
        let version: String  // "0.6.0"
        let pageURL: URL
        let zipURL: URL
        let sha256: String?  // hex, from the asset's "digest"
        let notes: String
    }

    struct UpdateError: Error, LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Numeric comparison of dotted versions: 0.10.0 > 0.9.1.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Checking

    static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MIDIstat/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]]
        else { throw UpdateError("GitHub did not return release information.") }

        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard let asset = assets.first(where: { ($0["name"] as? String) == "MIDIstat-\(version).zip" }),
              let zip = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
        else { throw UpdateError("Release \(tag) has no MIDIstat-\(version).zip.") }
        let digest = (asset["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: version, pageURL: page, zipURL: zip, sha256: digest,
                       notes: json["body"] as? String ?? "")
    }

    /// The "## Changes" list from the release notes, for the update dialog.
    static func changes(in notes: String, limit: Int = 12) -> String {
        guard let start = notes.range(of: "## Changes") else { return "" }
        let lines = notes[start.upperBound...].split(separator: "\n").map(String.init)
            .prefix { !$0.hasPrefix("## ") && !$0.hasPrefix("**Full diff") }
            .filter { $0.hasPrefix("- ") }
            .map { $0.replacingOccurrences(of: #" \([0-9a-f]{7,}\)$"#, with: "", options: .regularExpression) }
        let shown = (lines.count > limit ? ["…"] : []) + lines.suffix(limit)
        return shown.joined(separator: "\n")
    }

    // MARK: - Installing

    /// Downloads and verifies the release; returns the unpacked MIDIstat.app.
    static func downloadAndVerify(_ release: Release, bundleIdentifier: String) async throws -> URL {
        var request = URLRequest(url: release.zipURL)
        request.setValue("MIDIstat/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        let (download, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }

        let data = try Data(contentsOf: download)
        if let expected = release.sha256 {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw UpdateError("The download is damaged (checksum mismatch).") }
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MIDIstat-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent("MIDIstat.zip")
        try data.write(to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path], failure: "Could not unpack the download.")

        let app = folder.appendingPathComponent("MIDIstat.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == release.version
        else { throw UpdateError("The downloaded app is not MIDIstat \(release.version).") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
                failure: "The downloaded app's signature is invalid.")
        return app
    }

    /// Starts the swap-and-relaunch script; the caller must quit the app right after.
    static func install(_ newApp: URL, replacing currentApp: URL) throws {
        let parent = currentApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError("No permission to replace the app in \(parent.path).")
        }
        let script = """
            pid="$1"; old="$2"; new="$3"; backup="$old.previous"
            while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
            rm -rf "$backup"
            if mv "$old" "$backup" && mv "$new" "$old"; then
                rm -rf "$backup"
            else
                [ -e "$old" ] || mv "$backup" "$old"
            fi
            xattr -dr com.apple.quarantine "$old" 2>/dev/null
            open "$old"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "midistat-update",
                             String(getpid()), currentApp.path, newApp.path]
        try process.run()  // keeps running after MIDIstat quits
    }

    private static func run(_ tool: String, _ arguments: [String], failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError(failure) }
    }
}
