import Foundation

/// The on-disk home for dropped assets.
///
/// Anything dragged onto the control window is copied here, so a preset
/// survives the app that imported it and the same folder can be populated by
/// hand — dropping files straight into Finder works exactly like dropping them
/// onto the window.
final class PresetLibrary {
    enum Kind: String, CaseIterable, Sendable {
        case preset, lut

        var directoryName: String { self == .preset ? "Presets" : "LUTs" }
        var fileExtension: String { self == .preset ? "ini" : "cube" }
        var title: String { self == .preset ? "ReShade presets" : "LUTs" }

        static func forFile(at url: URL) -> Kind? {
            allCases.first { $0.fileExtension == url.pathExtension.lowercased() }
        }
    }

    struct Item: Identifiable, Hashable, Sendable {
        let url: URL
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    enum LibraryError: LocalizedError {
        case unsupportedFile(String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedFile(name):
                let extensions = Kind.allCases.map { ".\($0.fileExtension)" }.joined(separator: " or ")
                return "\(name) is not a \(extensions) file"
            }
        }
    }

    let root: URL
    /// Called on the main queue whenever the folders change on disk.
    var onChange: (() -> Void)?

    private var watchers: [DirectoryWatcher] = []

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        root = support.appendingPathComponent("MetalShade", isDirectory: true)
        for kind in Kind.allCases {
            try FileManager.default.createDirectory(at: directory(for: kind), withIntermediateDirectories: true)
        }
        watchers = Kind.allCases.map { kind in
            DirectoryWatcher(url: directory(for: kind)) { [weak self] in self?.onChange?() }
        }
    }

    func directory(for kind: Kind) -> URL {
        root.appendingPathComponent(kind.directoryName, isDirectory: true)
    }

    func items(of kind: Kind) -> [Item] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory(for: kind), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == kind.fileExtension }
            .map(Item.init(url:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Copies a dropped file into the library and returns where it landed.
    @discardableResult
    func install(_ source: URL) throws -> (kind: Kind, item: Item) {
        guard let kind = Kind.forFile(at: source) else {
            throw LibraryError.unsupportedFile(source.lastPathComponent)
        }
        let destination = uniqueDestination(for: source, in: directory(for: kind))
        // A dropped file may live on a volume that disappears, so copy rather
        // than reference it.
        try FileManager.default.copyItem(at: source, to: destination)
        return (kind, Item(url: destination))
    }

    func remove(_ item: Item) throws {
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
    }

    private func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = directory.appendingPathComponent(source.lastPathComponent)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }
}

/// Minimal directory watcher: reports that *something* changed, coalescing the
/// write/rename bursts Finder and editors produce.
private final class DirectoryWatcher {
    private var descriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping () -> Void) {
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let queue = DispatchQueue(label: "io.metalshade.library-watch")
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler {
            queue.asyncAfter(deadline: .now() + 0.15) {
                DispatchQueue.main.async(execute: onChange)
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
    }
}
