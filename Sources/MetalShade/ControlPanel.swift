import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ControlPanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusHeader
                if let explanation = model.renderMode.explanation {
                    Label {
                        Text(explanation)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
                }
                Divider()
                targetSection
                Divider()
                effectSection
                Divider()
                colorSection
                Divider()
                performanceSection
                Divider()
                librarySection
                if !model.importNotes.isEmpty {
                    Divider()
                    notesSection
                }
            }
            .padding(18)
        }
        .frame(minWidth: 420, minHeight: 560)
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MetalShade").font(.title2.weight(.semibold))
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.activeTarget != nil {
                HStack(spacing: 8) {
                    Button("Stop effects") { model.effectsEnabled = false }
                        .disabled(!model.effectsEnabled)
                    Button("Stop capture", action: model.stopCapture)
                    Spacer()
                }
                // A full-screen overlay covers everything. These shortcuts work
                // even when it does, and are the way out if the picture goes wrong.
                Text("While playing, use the shortcuts — clicking this window takes "
                    + "focus from the game, and most games pause when that happens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("⌘⌥↑ / ⌘⌥↓ intensity · ⌘⌥→ effect · ⌘⌥O bypass · ⌘⌥Q quit")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Target").font(.headline)
                Spacer()
                if model.isScanningGames {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Rescan", action: model.scanForGames).buttonStyle(.link).font(.caption)
                }
            }

            if let injected = model.injectedGame {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.circle.fill").foregroundStyle(.green)
                    Text("Injected into \(injected.name)").lineLimit(1)
                    Spacer()
                }
                Text("Effects run inside the game. Intensity and tint apply live; "
                    + "quitting the game ends the session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let active = model.activeTarget {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                    Text(active).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Stop", action: model.stopCapture).buttonStyle(.borderless).font(.caption)
                }
            }

            if model.detectedGames.isEmpty {
                Text(model.isScanningGames ? "Scanning…" : "No games detected in your Steam library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.detectedGames) { game in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(game.name).lineLimit(1)
                            Spacer()
                            // Injection is the better route where the signature
                            // allows it: no capture, no compositing, and the game
                            // keeps its direct-to-display path.
                            if game.injection.isOpen {
                                Button("Launch injected") { model.launchInjected(game) }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                    .disabled(model.injectedGame != nil)
                            }
                            Button(model.activeTarget == game.bundleID ? "Restart" : "Overlay") {
                                model.startCapture(bundleID: game.bundleID)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        Text("\(game.architecture) · \(game.injection.summary)")
                            .font(.caption2)
                            .foregroundStyle(game.injection.isOpen ? .secondary : .secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider().padding(.vertical, 2)

            Text("Any app, by bundle identifier")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                TextField("com.apple.Preview", text: $model.manualBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.startCapture(bundleID: model.manualBundleID) }
                Button("Start") { model.startCapture(bundleID: model.manualBundleID) }
                    .disabled(model.manualBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Useful for testing without a game — try com.apple.Preview with a photo open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var effectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The toggle sits outside the .disabled() subtree below. Inside it,
            // switching effects off would disable the control that switches them
            // back on.
            Toggle("Effects enabled", isOn: $model.effectsEnabled)
                .toggleStyle(.switch)
            Text("Bypassing keeps the capture overlay live with a neutral shader; some full-screen games go black if it is removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            effectControls

            Toggle("Diagnostic tint", isOn: $model.diagnosticTint)
            Text("Paints the overlay magenta. If the game does not turn magenta, the overlay is not reaching the screen — which no subtle effect can tell you. Works with effects off too.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var effectControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Effect", selection: $model.effect) {
                ForEach(MetalRenderer.Effect.allCases) { effect in
                    Text(effect.title).tag(effect)
                }
            }
            .pickerStyle(.segmented)

            if model.effect == .lut && model.activeLUT == nil {
                Label("No LUT loaded — drop a .cube file below.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            LabeledSlider(title: "Intensity", value: $model.intensity, range: 0...1, format: .percent)

        }
        .disabled(!model.effectsEnabled)
        .opacityWhenDisabled(model.effectsEnabled)
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Colour").font(.headline)
                Spacer()
                Button("Reset", action: model.resetColor)
                    .buttonStyle(.link)
            }
            LabeledSlider(title: "Brightness", value: $model.color.brightness, range: -1...1, format: .signed)
            LabeledSlider(title: "Contrast", value: $model.color.contrast, range: 0...3, format: .plain)
            LabeledSlider(title: "Saturation", value: $model.color.saturation, range: 0...3, format: .plain)
            LabeledSlider(title: "Temperature", value: $model.color.temperature, range: -1...1, format: .signed)
        }
        .disabled(!model.effectsEnabled)
        .opacityWhenDisabled(model.effectsEnabled)
    }

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Performance").font(.headline)

            Picker("Capture scale", selection: $model.captureScale) {
                ForEach(CaptureSettings.scaleOptions, id: \.self) { scale in
                    Text(CaptureSettings.label(forScale: scale)).tag(scale)
                }
            }
            Picker("Frame cap", selection: $model.frameCap) {
                ForEach(CaptureSettings.frameCapOptions, id: \.self) { cap in
                    Text("\(cap) fps").tag(cap)
                }
            }

            Text("The overlay shares a GPU with the game. Native Retina capture is "
                + "four times the pixels of Points and is usually what makes a "
                + "full-screen game unplayable. Changing either restarts capture.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("If the game is still slow, run it windowed or borderless rather "
                + "than exclusive full-screen: an overlay forces a full-screen game "
                + "out of direct-to-display scanout, and that costs more than "
                + "anything measured here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Library").font(.headline)
            DropZone { urls in model.importFiles(urls) }

            LibraryList(
                kind: .preset,
                items: model.presets,
                activeID: model.activePreset?.id,
                apply: { model.apply(preset: $0) },
                remove: { model.remove($0) },
                reveal: { model.revealLibrary(.preset) })

            LibraryList(
                kind: .lut,
                items: model.luts,
                activeID: model.activeLUT?.id,
                apply: { model.activate(lut: $0) },
                remove: { model.remove($0) },
                reveal: { model.revealLibrary(.lut) })
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last import").font(.headline)
            ForEach(model.importNotes) { note in
                Label {
                    Text(note.text)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: note.iconName).foregroundStyle(note.tint)
                }
            }
        }
    }
}

// MARK: - Drop target

/// Accepts files dragged from Finder. Dropping is the primary way to add a
/// ReShade preset; the button is the same action for people who would rather
/// browse.
private struct DropZone: View {
    let onDrop: ([URL]) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 22))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop ReShade presets (.ini) or LUTs (.cube)")
                .font(.callout)
            Button("Choose files…", action: chooseFiles)
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = PresetLibrary.Kind.allCases.compactMap {
            UTType(filenameExtension: $0.fileExtension)
        }
        panel.begin { response in
            guard response == .OK else { return }
            onDrop(panel.urls)
        }
    }
}

// MARK: - Library list

private struct LibraryList: View {
    let kind: PresetLibrary.Kind
    let items: [PresetLibrary.Item]
    let activeID: URL?
    let apply: (PresetLibrary.Item) -> Void
    let remove: (PresetLibrary.Item) -> Void
    let reveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(kind.title).font(.subheadline.weight(.medium))
                Spacer()
                Button("Show in Finder", action: reveal).buttonStyle(.link).font(.caption)
            }

            if items.isEmpty {
                Text("Nothing here yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.id == activeID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.id == activeID ? Color.accentColor : .secondary)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Apply") { apply(item) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        Button {
                            remove(item)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Move to Trash")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - Small shared pieces

private struct LabeledSlider: View {
    enum Format { case percent, signed, plain }

    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: Format

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(formatted)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }

    private var formatted: String {
        switch format {
        case .percent: return "\(Int((value * 100).rounded()))%"
        case .signed: return String(format: "%+.2f", value)
        case .plain: return String(format: "%.2f", value)
        }
    }
}

private extension AppModel.ImportNote {
    var iconName: String {
        switch level {
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .failure: return "xmark.octagon"
        }
    }

    var tint: Color {
        switch level {
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }
}

private extension View {
    @ViewBuilder
    func opacityWhenDisabled(_ enabled: Bool) -> some View {
        opacity(enabled ? 1 : 0.5)
    }
}

// MARK: - Hosting window

@MainActor
final class ControlPanelWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func show() {
        if window == nil {
            // A non-activating panel: adjusting a slider must not pull focus away
            // from the game, which pauses when it loses focus.
            let window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
                backing: .buffered, defer: false)
            window.isFloatingPanel = true
            window.becomesKeyOnlyIfNeeded = true
            window.hidesOnDeactivate = false
            window.title = "MetalShade"
            // Above the overlay's .screenSaver level. The overlay covers every
            // window on the display, so at any lower level the controls that stop
            // it are themselves hidden behind it.
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            window.contentView = NSHostingView(rootView: ControlPanelView(model: model))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // Only steal focus when nothing is being captured. Activating while a
        // game is running deactivates it, and many games pause when they lose
        // focus — which looks exactly like a frozen overlay.
        if model.activeTarget == nil {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }
}
