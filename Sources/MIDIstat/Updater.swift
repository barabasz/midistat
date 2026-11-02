import CryptoKit
import Foundation
import MIDIstatCore

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
        let tag: String      // "v0.6.0"
        let pageURL: URL
        let zipURL: URL?
        let sha256: String?  // hex, from the asset's "digest"
        let notes: String
    }

    /// The result of an update check: the newest release, and what changed
    /// since the installed version (across all releases in between).
    struct Check {
        let latest: Release
        let current: String
        let changes: ReleaseNotes.Summary
        /// GitHub's comparison page from the installed version to the latest one.
        let allChangesURL: URL
        var updateAvailable: Bool { ReleaseNotes.isNewer(latest.version, than: current) }
    }

    struct UpdateError: Error, LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Checking

    /// One request: all published releases (newest first), with their notes.
    static func check(limit: Int = 5) async throws -> Check {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MIDIstat/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw UpdateError("GitHub did not return release information.") }

        let releases = list.compactMap(release(from:))
            .sorted { ReleaseNotes.isNewer($0.version, than: $1.version) }
        guard let latest = releases.first(where: { $0.zipURL != nil }) else {
            throw UpdateError("No downloadable MIDIstat release was found.")
        }
        let current = currentVersion
        let summary = ReleaseNotes.summary(of: releases.filter { !ReleaseNotes.isNewer($0.version, than: latest.version) }
                                                       .map { ($0.version, $0.notes) },
                                           since: current, limit: limit)
        let compare = URL(string: "https://github.com/\(repository)/compare/v\(current)...\(latest.tag)")
        let all = current == "0.0.0" ? URL(string: "https://github.com/\(repository)/releases") : compare
        return Check(latest: latest, current: current, changes: summary, allChangesURL: all ?? latest.pageURL)
    }

    private static func release(from json: [String: Any]) -> Release? {
        guard json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let asset = (json["assets"] as? [[String: Any]])?.first { ($0["name"] as? String) == "MIDIstat-\(version).zip" }
        let digest = (asset?["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: version, tag: tag, pageURL: page,
                       zipURL: (asset?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                       sha256: digest, notes: json["body"] as? String ?? "")
    }

    // MARK: - Installing

    /// Downloads and verifies the release; returns the unpacked MIDIstat.app.
    static func downloadAndVerify(_ release: Release, bundleIdentifier: String) async throws -> URL {
        guard let zipURL = release.zipURL else { throw UpdateError("Release \(release.tag) has no download.") }
        var request = URLRequest(url: zipURL)
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
