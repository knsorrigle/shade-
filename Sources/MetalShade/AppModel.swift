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
        case idle, selfTest, capturing, injected

        var explanation: String? {
            switch self {
            case .idle:
                return "No target window. Relaunch with --bundle <bundle-id> to apply effects to a window."
            case .selfTest:
                return "Self-test draws a fixed calibration border and runs no shader. Effect and colour changes below are stored but will not alter anything on screen."
            case .capturing:
                return nil
            case .injected:
                return "Injected: effects are applied inside the game, with no capture and no overlay. Intensity and tint update live."
            }
        }
    }

    @Published var renderMode: RenderMode = .idle
    /// Games found on this machine, plus whatever the user types in by hand.
    @Published private(set) var detectedGames: [GameLibrary.Game] = []
    @Published private(set) var isScanningGames = false
    @Published var manualBundleID = ""
    @Published private(set) var activeTarget: String?
    /// The game launched with the payload, if any. Injection and the overlay are
    /// alternative routes to the same picture, not things to run together.
    @Published private(set) var injectedGame: GameLibrary.Game?
    private var injectedProcess: Process?

    /// Capture cost lands on the same GPU the game uses. Changing either knob
    /// restarts capture, since the stream configuration is fixed at start.
    @Published var captureScale: CGFloat = CaptureSettings.shared.scale {
        didSet {
            CaptureSettings.shared.scale = captureScale
            restartCaptureIfRunning()
        }
    }
    @Published var frameCap: Int = CaptureSettings.shared.frameCap {
        didSet {
            CaptureSettings.shared.frameCap = frameCap
            restartCaptureIfRunning()
        }
    }

    private func restartCaptureIfRunning() {
        guard let target = activeTarget else { return }
        onStartCapture?(target)
    }

    /// Set by AppDelegate; starting and stopping capture is its job.
    var onStartCapture: ((String) -> Void)?
    var onStopCapture: (() -> Void)?
    @Published var status = "starting…"
    @Published var effectsEnabled = true { didSet { renderer?.setEffectsEnabled(effectsEnabled); refreshStatus() } }
    @Published var effect: MetalRenderer.Effect = .cas { didSet { renderer?.setEffect(effect); refreshStatus() } }
    /// Starts at zero: a full-screen overlay that begins applying a strong effect
    /// the moment capture starts is alarming and hard to escape.
    @Published var intensity: Float = 0 {
        didSet {
            renderer?.setIntensity(intensity)
            pushInjectionSettings()
            refreshStatus()
        }
    }
    @Published var color = BasicColor() {
        didSet {
            renderer?.setColor(color)
            pushInjectionSettings()
        }
    }
    /// Paints the overlay a solid colour. Answers "is the overlay reaching the
    /// screen at all", which no subtle effect can.
    // Depth-free stages. None of these need a depth buffer, so they run
    // identically under the overlay and under injection.
    @Published var clarity: Float = 0 { didSet { pushStages() } }
    @Published var tone: Float = 0 { didSet { pushStages() } }
    @Published var bloom: Float = 0 { didSet { pushStages() } }
    @Published var bloomThreshold: Float = 0.8 { didSet { pushStages() } }
    @Published var exposure: Float = 0 { didSet { pushStages() } }
    @Published var gamma: Float = 1 { didSet { pushStages() } }
    @Published var vibrance: Float = 0 { didSet { pushStages() } }
    /// Depth fog needs the scene depth buffer, which only injection can reach.
    @Published var fog: Float = 0 { didSet { pushInjectionSettings() } }
    /// Ambient occlusion. Needs depth, so injection only.
    @Published var ao: Float = 0 { didSet { pushInjectionSettings() } }
    var fogAvailable: Bool { injectedGame != nil }

    /// Both routes compile the same chain, so both take the same values.
    private func pushStages() {
        renderer?.setStages(clarity: clarity, tone: tone, bloom: bloom,
                            bloomThreshold: bloomThreshold, exposure: exposure,
                            gamma: gamma, vibrance: vibrance)
        pushInjectionSettings()
    }

    func resetEffects() {
        clarity = 0; tone = 0; bloom = 0; bloomThreshold = 0.8; fog = 0; ao = 0
        exposure = 0; gamma = 1; vibrance = 0
        intensity = 0
        color = BasicColor()
    }

    @Published var diagnosticTint = false {
        didSet {
            renderer?.setDiagnosticTint(diagnosticTint)
            pushInjectionSettings()
        }
    }

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

    // MARK: - Injection

    private var effectSettings: EffectSettings {
        EffectSettings(
            sharpen: intensity, clarity: clarity, tone: tone,
            bloom: bloom, bloomThreshold: bloomThreshold,
            exposure: exposure, gamma: gamma, vibrance: vibrance,
            colour: color, tint: diagnosticTint, fog: fog, ao: ao)
    }

    func launchInjected(_ game: GameLibrary.Game) {
        importNotes = []
        do {
            // Injection processes inside the game; an overlay on top of it would
            // be a second, redundant pass.
            if activeTarget != nil { stopCapture() }
            let process = try InjectionLauncher.launch(game: game, settings: effectSettings)
            injectedProcess = process
            injectedGame = game
            renderMode = .injected
            status = "Launched \(game.name) with MetalShade injected."
            process.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.injectedProcess === process else { return }
                    self.injectedProcess = nil
                    self.injectedGame = nil
                    self.renderMode = .idle
                    self.status = "\(game.name) exited."
                }
            }
        } catch {
            importNotes = [.init(level: .failure, text: error.localizedDescription)]
            status = "Could not launch with injection."
        }
    }

    /// Injection reads settings from a file, since the launch environment cannot
    /// change while the game runs.
    private func pushInjectionSettings() {
        guard injectedGame != nil else { return }
        InjectionLauncher.writeSettings(effectSettings)
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
            // Only stages the preset actually specifies are changed; the rest
            // keep whatever the user has set.
            if let sharpening = report.settings.sharpening { intensity = sharpening }
            if let value = report.settings.clarity { clarity = value }
            if let value = report.settings.tone { tone = value }
            if let value = report.settings.bloom { bloom = value }
            if let value = report.settings.bloomThreshold { bloomThreshold = value }
            if let value = report.settings.exposure { exposure = value }
            if let value = report.settings.gamma { gamma = value }
            if let value = report.settings.vibrance { vibrance = value }
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
        pushStages()
        renderer?.setEffectsEnabled(effectsEnabled)
        renderer?.setEffect(effect)
        renderer?.setIntensity(intensity)
        renderer?.setColor(color)
    }
}
