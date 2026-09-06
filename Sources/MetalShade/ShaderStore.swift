import Darwin
import Foundation

/// Watches the user-editable shader source. Invalid edits leave the last good
/// pipeline active; the renderer reports the compiler error in the Console.
final class ShaderStore {
    static let filename = "EffectChain.metal"
    let directory: URL
    private var watcher: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    var onChange: ((String) -> Void)?

    init() throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        directory = root.appendingPathComponent("MetalShade/Shaders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try installDefaultIfNeeded()
        startWatching()
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    func source() throws -> String {
        try String(contentsOf: directory.appendingPathComponent(Self.filename), encoding: .utf8)
    }

    private func startWatching() {
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let queue = DispatchQueue(label: "io.metalshade.shader-watch")
        watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: queue)
        watcher?.setEventHandler { [weak self] in
            guard let self else { return }
            // Editors often write a temporary file then rename it; debounce that sequence.
            queue.asyncAfter(deadline: .now() + 0.15) {
                guard let source = try? self.source() else { return }
                DispatchQueue.main.async { self.onChange?(source) }
            }
        }
        watcher?.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        watcher?.resume()
    }
}

extension ShaderStore {
    /// The shader shipped with this build.
    static var bundledSource: String? {
        guard let url = Bundle.module.url(forResource: "EffectChain", withExtension: "metal") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

private extension ShaderStore {
    /// Writes the bundled shader when absent, and replaces one left by an older
    /// build. The uniform layout is a contract between this file and
    /// `MetalRenderer`; a stale shader compiles but reads the wrong fields.
    func installDefaultIfNeeded() throws {
        guard let bundled = ShaderStore.bundledSource else { return }
        let file = directory.appendingPathComponent(ShaderStore.filename)
        let existing = try? String(contentsOf: file, encoding: .utf8)
        if let existing, existing.contains(ShaderSource.versionMarker) { return }

        if existing != nil {
            var backup = directory.appendingPathComponent("\(ShaderStore.filename).bak")
            var suffix = 2
            while FileManager.default.fileExists(atPath: backup.path) {
                backup = directory.appendingPathComponent("\(ShaderStore.filename).bak\(suffix)")
                suffix += 1
            }
            try? FileManager.default.moveItem(at: file, to: backup)
            NSLog("MetalShade: replaced a shader from an older build; previous kept as \(backup.lastPathComponent)")
        }
        try bundled.write(to: file, atomically: true, encoding: .utf8)
    }
}

enum ShaderSource {
    /// Present in the bundled shader's header. A file on disk without it came
    /// from an older build whose uniform layout no longer matches, so it is
    /// backed up and replaced rather than compiled.
    static let versionMarker = "MetalShade effect chain — v3"
}
