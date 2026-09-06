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

    /// What the app is currently doing, so the panel can say when the effect
    /// controls are not connected to anything.
    enum RenderMode: Sendable {
        case idle, selfTest, capturing

        var explanation: String? {
            switch self {
            case .idle:
                return "No target window. Relaunch with --bundle <bundle-id> to apply effects to a window."
            case .selfTest:
                return "Self-test draws a fixed calibration border and runs no shader. Effect and colour changes below are stored but will not alter anything on screen."
            case .capturing:
                return nil
            }
        }
    }

    @Published var renderMode: RenderMode = .idle
    /// Games found on this machine, plus whatever the user types in by hand.
    @Published private(set) var detectedGames: [GameLibrary.Game] = []
    @Published private(set) var isScanningGames = false
    @Published var manualBundleID = ""
    @Published private(set) var activeTarget: String?

    /// Set by AppDelegate; starting and stopping capture is its job.
    var onStartCapture: ((String) -> Void)?
    var onStopCapture: (() -> Void)?
    @Published var status = "starting…"
    @Published var effectsEnabled = true { didSet { renderer?.setEffectsEnabled(effectsEnabled); refreshStatus() } }
    @Published var effect: MetalRenderer.Effect = .cas { didSet { renderer?.setEffect(effect); refreshStatus() } }
    /// Starts at zero: a full-screen overlay that begins applying a strong effect
    /// the moment capture starts is alarming and hard to escape.
    @Published var intensity: Float = 0 { didSet { renderer?.setIntensity(intensity); refreshStatus() } }
    @Published var color = BasicColor() { didSet { renderer?.setColor(color) } }
    /// Paints the overlay a solid colour. Answers "is the overlay reaching the
    /// screen at all", which no subtle effect can.
    @Published var diagnosticTint = false { didSet { renderer?.setDiagnosticTint(diagnosticTint) } }

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

    // MARK: - Targets

    func scanForGames() {
        isScanningGames = true
        // codesign runs as a subprocess per game; keep it off the main queue.
        DispatchQueue.global(qos: .userInitiated).async {
            let games = GameLibrary.scan()
            DispatchQueue.main.async {
                self.detectedGames = games
                self.isScanningGames = false
            }
        }
    }

    func startCapture(bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeTarget = trimmed
        renderMode = .capturing
        onStartCapture?(trimmed)
    }

    func stopCapture() {
        activeTarget = nil
        renderMode = .idle
        onStopCapture?()
        status = "Stopped. Pick a target to start again."
    }

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

            guard !report.applied.isEmpty else {
                importNotes.append(.init(
                    level: .failure,
                    text: "\(item.name): nothing in this preset can be reproduced by an overlay."))
                importNotes.append(contentsOf: skippedNotes(report))
                refreshStatus()
                return
            }

            importNotes.append(.init(
                level: .success,
                text: "Applied \(item.name) — \(report.applied.count) setting(s) used, "
                    + "\(report.skippedCount) skipped."))
            importNotes.append(contentsOf: report.applied.map {
                .init(level: .success, text: "\($0.label) → \($0.detail)")
            })
            importNotes.append(contentsOf: skippedNotes(report))
        } catch {
            importNotes.append(.init(level: .failure, text: "\(item.name): \(error.localizedDescription)"))
        }
        refreshStatus()
    }

    /// One line per effect rather than one per setting. A real preset carries a
    /// few hundred keys, and listing them individually buries the handful that
    /// actually took effect.
    private func skippedNotes(_ report: PresetImportReport) -> [ImportNote] {
        report.skipped.map {
            .init(level: .warning, text: "\($0.effect): \($0.count) skipped — \($0.reason)")
        }
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
