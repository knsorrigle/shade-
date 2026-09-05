import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ControlPanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusHeader
                Divider()
                effectSection
                Divider()
                colorSection
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
        VStack(alignment: .leading, spacing: 4) {
            Text("MetalShade").font(.title2.weight(.semibold))
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var effectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Effects enabled", isOn: $model.effectsEnabled)
                .toggleStyle(.switch)
            Text("Bypassing keeps the capture overlay live with a neutral shader; some full-screen games go black if it is removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "MetalShade"
            window.contentView = NSHostingView(rootView: ControlPanelView(model: model))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // The app is an accessory (no Dock icon), so it must activate itself for
        // the window to come forward and accept keyboard input.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
