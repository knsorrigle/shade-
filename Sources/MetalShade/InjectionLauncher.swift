import AppKit

/// Launches a game with the MetalShade payload loaded, and writes the settings
/// file the payload reads while running.
///
/// Environment variables configure the payload at launch and cannot change
/// afterwards, so anything adjustable during play goes through the file.
/// Everything the payload can be told, in one place. Sent as JSON because the
/// launch environment is fixed once a game starts.
struct EffectSettings {
    var sharpen: Float = 0
    var clarity: Float = 0
    var tone: Float = 0
    var bloom: Float = 0
    var bloomThreshold: Float = 0.8
    var exposure: Float = 0
    var gamma: Float = 1
    var vibrance: Float = 0
    var colour = BasicColor()
    var tint = false

    var json: [String: Any] {
        [
            "intensity": sharpen, "clarity": clarity, "tone": tone,
            "bloom": bloom, "bloomThreshold": bloomThreshold,
            "exposure": exposure, "gamma": gamma, "vibrance": vibrance,
            "brightness": colour.brightness, "contrast": colour.contrast,
            "saturation": colour.saturation, "temperature": colour.temperature,
            "tint": tint,
        ]
    }
}

enum InjectionLauncher {
    enum LaunchError: LocalizedError {
        case payloadMissing
        case executableMissing(String)
        case architectureMismatch(target: String, payload: String)

        var errorDescription: String? {
            switch self {
            case .payloadMissing:
                return "The injection payload is missing from MetalShade.app. Rebuild with scripts/build-app.sh."
            case let .executableMissing(path):
                return "No executable at \(path)"
            case let .architectureMismatch(target, payload):
                return "The game is \(target) but the payload provides \(payload). Rebuild it with scripts/build-payload.sh."
            }
        }
    }

    /// Shipped inside the app so a launch does not depend on a build directory.
    static var payloadURL: URL? {
        Bundle.main.url(forResource: "libMetalShadeInject", withExtension: "dylib")
    }

    static var settingsURL: URL {
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let root = (support ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("MetalShade", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("inject-settings.json")
    }

    static func writeSettings(_ settings: EffectSettings) {
        guard let data = try? JSONSerialization.data(withJSONObject: settings.json) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    @discardableResult
    static func launch(game: GameLibrary.Game, settings: EffectSettings) throws -> Process {
        guard let payloadURL else { throw LaunchError.payloadMissing }

        let plist = game.bundleURL.appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        } ?? [:]
        let executableName = (info["CFBundleExecutable"] as? String) ?? game.name
        let executable = game.bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LaunchError.executableMissing(executable.path)
        }

        // An arm64-only payload cannot load into an x86_64 process.
        let payloadArchs = architectures(of: payloadURL)
        let targetArch = game.architecture.hasPrefix("x86_64") ? "x86_64" : "arm64"
        guard payloadArchs.contains(targetArch) else {
            throw LaunchError.architectureMismatch(
                target: targetArch, payload: payloadArchs.joined(separator: ", "))
        }

        writeSettings(settings)

        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = payloadURL.path

        let process = Process()
        process.executableURL = executable
        process.environment = environment
        // Games resolve resources relative to the bundle.
        process.currentDirectoryURL = game.bundleURL.deletingLastPathComponent()
        try process.run()
        Diagnostics.log("launched \(game.name) with the payload, pid \(process.processIdentifier)")
        return process
    }

    private static func architectures(of url: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        process.arguments = ["-archs", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init)
    }
}
