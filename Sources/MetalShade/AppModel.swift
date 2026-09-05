import AppKit
import Combine

/// Single source of truth for everything the user can change.
///
/// The control window, the status menu, and the global shortcuts all mutate
/// this object; it pushes the result into `MetalRenderer`. Nothing writes to
/// the renderer directly, so the window always reflects what is on screen.
@MainActor
final class AppModel: ObservableObject {
    struct ImportNote: Identifiable, Sendable {
        enum Level: Sendable { case success, warning, failure }
        let id = UUID()
        let level: Level
        let text: String
    }

    @Published var status = "starting…"
    @Published var effectsEnabled = true { didSet { renderer?.setEffectsEnabled(effectsEnabled); refreshStatus() } }
    @Published var effect: MetalRenderer.Effect = .cas { didSet { renderer?.setEffect(effect); refreshStatus() } }
    @Published var intensity: Float = 0.65 { didSet { renderer?.setIntensity(intensity); refreshStatus() } }
    @Published var color = BasicColor() { didSet { renderer?.setColor(color) } }

    @Published private(set) var presets: [PresetLibrary.Item] = []
    @Published private(set) var luts: [PresetLibrary.Item] = []
    @Published private(set) var activePreset: PresetLibrary.Item?
    @Published private(set) var activeLUT: PresetLibrary.Item?
    /// Result of the most recent import, including every ReShade setting that
    /// could not be honoured. These used to go only to the Console, where
    /// nobody saw them.
    @Published private(set) var importNotes: [ImportNote] = []

    private(set) var library: PresetLibrary?
    private weak var renderer: MetalRenderer?

    func attach(renderer: MetalRenderer, library: PresetLibrary?) {
        self.renderer = renderer
        self.library = library
        library?.onChange = { [weak self] in self?.reloadLibrary() }
        reloadLibrary()
        pushAll()
    }

    // MARK: - Shortcut actions

    func toggleEffects() { effectsEnabled.toggle() }
    func cycleEffect() { effect = effect == .cas ? .lut : .cas }
    func adjustIntensity(by delta: Float) { intensity = min(max(intensity + delta, 0), 1) }

    func resetColor() { color = BasicColor() }

    // MARK: - Library

    func reloadLibrary() {
        guard let library else { return }
        presets = library.items(of: .preset)
        luts = library.items(of: .lut)
        // A file removed in Finder should not keep showing as active.
        if let active = activePreset, !presets.contains(active) { activePreset = nil }
        if let active = activeLUT, !luts.contains(active) {
            activeLUT = nil
            renderer?.clearLUT()
            if effect == .lut { effect = .cas }
        }
    }

    /// Handles a drag-and-drop or an Open panel selection.
    func importFiles(_ urls: [URL]) {
        guard let library else { return }
        importNotes = []
        for url in urls {
            do {
                let installed = try library.install(url)
                switch installed.kind {
                case .preset: apply(preset: installed.item, appendNotes: true)
                case .lut: activate(lut: installed.item, appendNotes: true)
                }
            } catch {
                importNotes.append(.init(level: .failure, text: error.localizedDescription))
            }
        }
        reloadLibrary()
    }

    func apply(preset item: PresetLibrary.Item, appendNotes: Bool = false) {
        if !appendNotes { importNotes = [] }
        do {
            let report = try ReShadePreset.importPreset(at: item.url)
            if let sharpening = report.settings.sharpening {
                intensity = sharpening
                effect = .cas
            }
            color = report.settings.color
            activePreset = item
            importNotes.append(.init(
                level: report.warnings.isEmpty ? .success : .warning,
                text: report.warnings.isEmpty
                    ? "Applied \(item.name)."
                    : "Applied \(item.name) — \(report.warnings.count) setting(s) could not be used."))
            importNotes.append(contentsOf: report.warnings.map { .init(level: .warning, text: $0) })
        } catch {
            importNotes.append(.init(level: .failure, text: "\(item.name): \(error.localizedDescription)"))
        }
        refreshStatus()
    }

    func activate(lut item: PresetLibrary.Item, appendNotes: Bool = false) {
        if !appendNotes { importNotes = [] }
        do {
            try renderer?.loadLUT(from: item.url)
            activeLUT = item
            effect = .lut
            importNotes.append(.init(level: .success, text: "Loaded LUT \(item.name)."))
        } catch {
            importNotes.append(.init(level: .failure, text: "\(item.name): \(error.localizedDescription)"))
        }
        refreshStatus()
    }

    func remove(_ item: PresetLibrary.Item) {
        do {
            try library?.remove(item)
        } catch {
            importNotes = [.init(level: .failure, text: error.localizedDescription)]
        }
        reloadLibrary()
    }

    func revealLibrary(_ kind: PresetLibrary.Kind) {
        guard let library else { return }
        NSWorkspace.shared.activateFileViewerSelecting([library.directory(for: kind)])
    }

    // MARK: - Status

    func report(_ text: String) {
        status = text
    }

    private func refreshStatus() {
        guard let renderer else { return }
        status = renderer.effectDescription
    }

    private func pushAll() {
        renderer?.setEffectsEnabled(effectsEnabled)
        renderer?.setEffect(effect)
        renderer?.setIntensity(intensity)
        renderer?.setColor(color)
    }
}
