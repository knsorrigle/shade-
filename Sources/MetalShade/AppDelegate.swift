import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleOverlay = Self("toggleOverlay", initial: .init(.o, modifiers: [.command, .option]))
    static let cycleEffect = Self("cycleEffect", initial: .init(.rightArrow, modifiers: [.command, .option]))
    static let increaseIntensity = Self("increaseIntensity", initial: .init(.upArrow, modifiers: [.command, .option]))
    static let decreaseIntensity = Self("decreaseIntensity", initial: .init(.downArrow, modifiers: [.command, .option]))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var capture: CaptureController?
    private var renderer: MetalRenderer?
    private var options = LaunchOptions(arguments: CommandLine.arguments)
    private var statusMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        guard let bundleID = options.bundleID else {
            setStatus("Start with --bundle <bundle-id>")
            return
        }

        do {
            let renderer = try MetalRenderer()
            self.renderer = renderer
            let capture = CaptureController(bundleID: bundleID, renderer: renderer) { [weak self] message in
                DispatchQueue.main.async { self?.setStatus(message) }
            }
            self.capture = capture
            installHotkeys()
            applyStartupAssets(to: renderer)
            capture.start()
        } catch {
            setStatus("Metal unavailable: \(error.localizedDescription)")
        }
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "MS"
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "MetalShade: starting…", action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Toggle Overlay", action: #selector(toggleOverlay), keyEquivalent: "")
        menu.addItem(withTitle: "Cycle Effect", action: #selector(cycleEffect), keyEquivalent: "")
        menu.addItem(withTitle: "Increase Intensity", action: #selector(increaseIntensity), keyEquivalent: "")
        menu.addItem(withTitle: "Decrease Intensity", action: #selector(decreaseIntensity), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Load .cube LUT…", action: #selector(showLUTPicker), keyEquivalent: "")
        menu.addItem(withTitle: "Import ReShade preset…", action: #selector(showPresetPicker), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MetalShade", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func installHotkeys() {
        // KeyboardShortcuts uses Carbon's global hotkey API: no Accessibility permission dialog.
        KeyboardShortcuts.onKeyUp(for: .toggleOverlay) { [weak self] in self?.toggleOverlay() }
        KeyboardShortcuts.onKeyUp(for: .cycleEffect) { [weak self] in self?.cycleEffect() }
        KeyboardShortcuts.onKeyUp(for: .increaseIntensity) { [weak self] in self?.increaseIntensity() }
        KeyboardShortcuts.onKeyUp(for: .decreaseIntensity) { [weak self] in self?.decreaseIntensity() }
    }

    private func applyStartupAssets(to renderer: MetalRenderer) {
        if let lut = options.lutPath { loadLUT(at: URL(fileURLWithPath: lut)) }
        if let preset = options.presetPath { importPreset(at: URL(fileURLWithPath: preset)) }
    }

    @objc private func toggleOverlay() { capture?.toggleOverlay() }
    @objc private func cycleEffect() { renderer?.cycleEffect(); setStatus(renderer?.effectDescription ?? "No renderer") }
    @objc private func increaseIntensity() { renderer?.adjustIntensity(by: 0.05); setStatus(renderer?.effectDescription ?? "No renderer") }
    @objc private func decreaseIntensity() { renderer?.adjustIntensity(by: -0.05); setStatus(renderer?.effectDescription ?? "No renderer") }

    @objc private func showLUTPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "cube")!]
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.loadLUT(at: url) }
        }
    }

    private func loadLUT(at url: URL) {
        do { try renderer?.loadLUT(from: url); setStatus("Loaded LUT: \(url.lastPathComponent)") }
        catch { setStatus("LUT error: \(error.localizedDescription)") }
    }

    @objc private func showPresetPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "ini")!]
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.importPreset(at: url) }
        }
    }

    private func importPreset(at url: URL) {
        do {
            let report = try ReShadePreset.importPreset(at: url)
            renderer?.apply(report.settings)
            setStatus(report.warnings.isEmpty ? "Imported \(url.lastPathComponent)" : "Imported with \(report.warnings.count) skipped setting(s); see Console")
            report.warnings.forEach { NSLog("MetalShade preset: \($0)") }
        } catch { setStatus("Preset error: \(error.localizedDescription)") }
    }

    private func setStatus(_ text: String) { statusMenuItem?.title = "MetalShade: \(text)" }
}

private struct LaunchOptions {
    var bundleID: String?
    var lutPath: String?
    var presetPath: String?

    init(arguments: [String]) {
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
