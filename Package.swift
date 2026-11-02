// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MIDIstat",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MIDIstatCore"),
        .executableTarget(name: "MIDIstat", dependencies: ["MIDIstatCore"]),
        // Self-check of the parsing/formatting logic: `swift run MIDIstatCheck`
        .executableTarget(name: "MIDIstatCheck", dependencies: ["MIDIstatCore"]),
        // Virtual MIDI devices for load tests: used by scripts/benchmark.sh.
        .executableTarget(name: "MIDIstatLoad"),
    ]
)
