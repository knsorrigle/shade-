import AppKit
import Combine
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleOverlay = Self("toggleOverlay", initial: .init(.o, modifiers: [.command, .option]))
    static let cycleEffect = Self("cycleEffect", initial: .init(.rightArrow, modifiers: [.command, .option]))
    static let increaseIntensity = Self("increaseIntensity", initial: .init(.upArrow, modifiers: [.command, .option]))
    static let decreaseIntensity = Self("decreaseIntensity", initial: .init(.downArrow, modifiers: [.command, .option]))
    /// Escape hatch. The overlay sits above the menu bar, so a misplaced one can
    /// leave nothing clickable; this always kills it.
    static let quitApp = Self("quitApp", initial: .init(.q, modifiers: [.command, .option]))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var capture: CaptureController?
    private var renderer: MetalRenderer?
    private let model = AppModel()
    private var controlPanel: ControlPanelWindowController!
    private var options = LaunchOptions(arguments: CommandLine.arguments)
    private var calibration: CalibrationSession?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        controlPanel = ControlPanelWindowController(model: model)
        makeMenu()
        observeModel()

        let library: PresetLibrary?
        do {
            library = try PresetLibrary()
        } catch {
            library = nil
            model.report("Could not create the preset library: \(error.localizedDescription)")
        }

        do {
            let renderer = try MetalRenderer()
            self.renderer = renderer
            model.attach(renderer: renderer, library: library)
            installHotkeys()
            importLaunchAssets()

            guard let bundleID = options.bundleID else {
                model.report("Start with --bundle <bundle-id>")
                controlPanel.show()
                return
            }

            if options.selfTest {
                calibration = CalibrationSession(bundleID: bundleID) { [weak self] message in
                    self?.model.report(message)
                }
                calibration?.start()
                return
            }

            let capture = CaptureController(bundleID: bundleID, renderer: renderer) { [weak self] message in
                DispatchQueue.main.async { self?.model.report(message) }
            }
            self.capture = capture
            capture.start()
        } catch {
            model.report("Metal unavailable: \(error.localizedDescription)")
            controlPanel.show()
        }
    }

    /// Files opened with MetalShade (`open -a MetalShade preset.ini`) are
    /// imported exactly like a drop onto the control window.
    func application(_ application: NSApplication, open urls: [URL]) {
        model.importFiles(urls)
        controlPanel.show()
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "MS"
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "MetalShade: starting…", action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Control Panel…", action: #selector(showControlPanel), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Toggle Effects", action: #selector(toggleOverlay), keyEquivalent: "")
        menu.addItem(withTitle: "Cycle Effect", action: #selector(cycleEffect), keyEquivalent: "")
        menu.addItem(withTitle: "Increase Intensity", action: #selector(increaseIntensity), keyEquivalent: "")
        menu.addItem(withTitle: "Decrease Intensity", action: #selector(decreaseIntensity), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Presets Folder…", action: #selector(revealPresets), keyEquivalent: "")
        menu.addItem(withTitle: "LUTs Folder…", action: #selector(revealLUTs), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MetalShade (⌘⌥Q)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func observeModel() {
        model.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.statusMenuItem?.title = "MetalShade: \(status)" }
            .store(in: &cancellables)
    }

    private func installHotkeys() {
        // KeyboardShortcuts uses Carbon's global hotkey API: no Accessibility permission dialog.
        KeyboardShortcuts.onKeyUp(for: .toggleOverlay) { [weak self] in self?.model.toggleEffects() }
        KeyboardShortcuts.onKeyUp(for: .cycleEffect) { [weak self] in self?.model.cycleEffect() }
        KeyboardShortcuts.onKeyUp(for: .increaseIntensity) { [weak self] in self?.model.adjustIntensity(by: 0.05) }
        KeyboardShortcuts.onKeyUp(for: .decreaseIntensity) { [weak self] in self?.model.adjustIntensity(by: -0.05) }
        KeyboardShortcuts.onKeyUp(for: .quitApp) { NSApp.terminate(nil) }
    }

    private func importLaunchAssets() {
        let paths = [options.lutPath, options.presetPath].compactMap { $0 }
        guard !paths.isEmpty else { return }
        model.importFiles(paths.map { URL(fileURLWithPath: $0) })
    }

    @objc private func showControlPanel() { controlPanel.show() }
    @objc private func toggleOverlay() { model.toggleEffects() }
    @objc private func cycleEffect() { model.cycleEffect() }
    @objc private func increaseIntensity() { model.adjustIntensity(by: 0.05) }
    @objc private func decreaseIntensity() { model.adjustIntensity(by: -0.05) }
    @objc private func revealPresets() { model.revealLibrary(.preset) }
    @objc private func revealLUTs() { model.revealLibrary(.lut) }
}

private struct LaunchOptions {
    var bundleID: String?
    var lutPath: String?
    var presetPath: String?
    var selfTest = false

    init(arguments: [String]) {
        selfTest = arguments.contains("--self-test")
        for (index, argument) in arguments.enumerated() where index + 1 < arguments.count {
            switch argument {
            case "--bundle": bundleID = arguments[index + 1]
            case "--lut": lutPath = arguments[index + 1]
            case "--preset": presetPath = arguments[index + 1]
            default: break
            }
        }
    }
}
