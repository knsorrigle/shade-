import Foundation

/// Finds installed games and reports which MetalShade methods can reach them.
///
/// The verdict mirrors `scripts/check-target.sh`: whether a game's main
/// executable could accept a library injected with `DYLD_INSERT_LIBRARIES`.
/// That is a property of the signature, and it genuinely differs between games
/// — a hardened, notarised arm64 title is closed, while an unsigned x86_64 port
/// running under Rosetta has no library validation to enforce.
struct GameLibrary {

    enum Injection: Sendable, Equatable {
        /// No hardened runtime to enforce library validation.
        case openUnsigned
        /// Hardened, but opts out of library validation.
        case openEntitled
        case blocked
        case unknown(String)

        var isOpen: Bool { self == .openUnsigned || self == .openEntitled }

        var summary: String {
            switch self {
            case .openUnsigned: return "Injection possible — executable is unsigned"
            case .openEntitled: return "Injection possible — library validation disabled"
            case .blocked: return "Injection blocked — hardened runtime enforces library validation"
            case let .unknown(why): return "Injection unknown — \(why)"
            }
        }
    }

    struct Game: Identifiable, Sendable {
        let name: String
        let bundleID: String
        let bundleURL: URL
        let architecture: String
        let injection: Injection

        var id: String { bundleURL.path }

        /// Overlay works regardless; it needs nothing from the game.
        var availableMethods: [String] { ["Overlay"] }
    }

    static func scan() -> [Game] {
        var seen = Set<String>()
        var games: [Game] = []
        for bundle in candidateBundles() {
            guard let game = inspect(bundle), !seen.contains(game.bundleID) else { continue }
            seen.insert(game.bundleID)
            games.append(game)
        }
        return games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Locating candidates

    private static func candidateBundles() -> [URL] {
        var results: [URL] = []
        for library in steamLibraries() {
            let common = library.appendingPathComponent("steamapps/common", isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: common, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                let apps = (try? FileManager.default.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                results.append(contentsOf: apps.filter { $0.pathExtension == "app" })
            }
        }
        return results
    }

    private static func steamLibraries() -> [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let root = support?.appendingPathComponent("Steam", isDirectory: true) else { return [] }
        var libraries = [root]
        // Additional libraries are listed in libraryfolders.vdf as "path" entries.
        let vdf = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            for line in text.components(separatedBy: .newlines) where line.contains("\"path\"") {
                let parts = line.components(separatedBy: "\"").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if let path = parts.last, path != "path" {
                    let url = URL(fileURLWithPath: path)
                    if !libraries.contains(url) { libraries.append(url) }
                }
            }
        }
        return libraries
    }

    // MARK: - Inspecting one bundle

    private static func inspect(_ bundleURL: URL) -> Game? {
        let plist = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String,
              let executableName = info["CFBundleExecutable"] as? String
        else { return nil }

        let executable = bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }

        // A launcher shim opens the real game through Steam; inspecting it says
        // nothing about the game. DIAGNOSTIC.md records this exact trap.
        if executableName.hasSuffix(".sh") { return nil }

        let name = (info["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent

        return Game(
            name: name,
            bundleID: bundleID,
            bundleURL: bundleURL,
            architecture: architecture(of: executable),
            injection: injectionVerdict(for: executable))
    }

    private static func architecture(of executable: URL) -> String {
        let output = run("/usr/bin/file", ["-b", executable.path])
        if output.contains("arm64") { return "arm64" }
        if output.contains("x86_64") { return "x86_64 (Rosetta)" }
        return "unknown"
    }

    private static func injectionVerdict(for executable: URL) -> Injection {
        let signing = run("/usr/bin/codesign", ["-d", "-vvv", executable.path])
        if signing.contains("not signed at all") {
            // Nothing to validate against, so DYLD_INSERT_LIBRARIES is honoured.
            return .openUnsigned
        }
        guard let flagsLine = signing
            .components(separatedBy: .newlines)
            .first(where: { $0.contains("CodeDirectory") && $0.contains("flags=") })
        else {
            return .unknown("signing state could not be read")
        }
        guard flagsLine.contains("runtime") else {
            // No hardened runtime means no library validation to enforce.
            return .openUnsigned
        }
        let entitlements = run("/usr/bin/codesign", ["-d", "--entitlements", ":-", executable.path])
        // A malformed blob is parsed by codesign but ignored by the OS, so the
        // entitlement it declares does not actually take effect.
        if signing.contains("invalid entitlements blob")
            || entitlements.contains("invalid entitlements blob") {
            return .unknown("entitlements blob is invalid, so the OS ignores it")
        }
        guard entitlements.contains("com.apple.security.cs.disable-library-validation") else {
            return .blocked
        }
        // Disabling library validation is not sufficient on its own: a hardened
        // process ignores DYLD_* variables without this second entitlement.
        guard entitlements.contains("com.apple.security.cs.allow-dyld-environment-variables") else {
            return .unknown("library validation is disabled but DYLD_* variables are not permitted")
        }
        return .openEntitled
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        // codesign writes its report to stderr.
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
