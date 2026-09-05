import Foundation

/// Appends to a log file beside the preset library.
///
/// A game running full-screen occupies its own Space, so the control panel —
/// and every status message on it — is invisible while playing. Anything worth
/// knowing about a capture session has to survive to be read afterwards.
enum Diagnostics {
    static let url: URL = {
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let root = (support ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("MetalShade", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("diagnostics.log")
    }()

    private static let queue = DispatchQueue(label: "io.metalshade.diagnostics")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Starts a fresh section so one session's lines are not confused with the last.
    static func beginSession(_ note: String) {
        log("──────── \(note) ────────")
    }
}
