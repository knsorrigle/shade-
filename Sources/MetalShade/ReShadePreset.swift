import Foundation

struct BasicColor: Sendable, Equatable {
    var brightness: Float = 0
    var contrast: Float = 1
    var saturation: Float = 1
    var temperature: Float = 0
}

struct PresetSettings: Sendable {
    var sharpening: Float?
    var color = BasicColor()
}

struct PresetImportReport: Sendable {
    struct Applied: Sendable {
        let label: String
        let detail: String
    }

    struct Skipped: Sendable {
        let effect: String
        let count: Int
        let reason: String
    }

    let settings: PresetSettings
    let applied: [Applied]
    let skipped: [Skipped]

    var skippedCount: Int { skipped.reduce(0) { $0 + $1.count } }
}

/// Reads the subset of a ReShade preset an overlay can honestly reproduce.
///
/// Keys are only read from effects this file knows, because ReShade key names
/// are scoped to their effect and mean different things in each. `Saturation`
/// inside `FilmicPass.fx` is an offset within a filmic tone curve, not a global
/// saturation multiplier — reading it as one turns the whole image greyscale.
/// Anything from an unknown effect is reported, never guessed at.
enum ReShadePreset {

    // MARK: - What each effect contributes

    private enum Parameter {
        case sharpening
        case brightness
        case contrast
        case saturation
        case temperature
    }

    /// How a preset's stored number maps onto our uniform.
    private enum Scale {
        /// Already in our units.
        case direct
        /// ReShade stores an offset around neutral; our uniform is a multiplier
        /// around 1.
        case offsetAroundOne
    }

    private struct Mapping {
        let parameter: Parameter
        let scale: Scale
        init(_ parameter: Parameter, _ scale: Scale = .direct) {
            self.parameter = parameter
            self.scale = scale
        }
    }

    private enum Support {
        /// Keys we read; every other key in the section is reported as unused.
        case partial([String: Mapping])
        case unsupported(String)
    }

    private static let depthReason =
        "needs the game's depth buffer, which an overlay cannot read"

    private static let effects: [String: Support] = [
        // Supported, in part.
        "CAS": .partial([
            // CAS's own "Contrast" is its contrast-adaptation term, not a
            // global contrast control, so it is deliberately not read.
            "SHARPENING": Mapping(.sharpening),
        ]),
        "LUMASHARPEN": .partial([
            "SHARP_STRENGTH": Mapping(.sharpening),
        ]),
        "ADAPTIVESHARPEN": .partial([
            "CURVE_HEIGHT": Mapping(.sharpening),
        ]),
        "QUINT_LIGHTROOM": .partial([
            "LIGHTROOM_GLOBAL_SATURATION": Mapping(.saturation, .offsetAroundOne),
            "LIGHTROOM_GLOBAL_CONTRAST": Mapping(.contrast, .offsetAroundOne),
            "LIGHTROOM_GLOBAL_TEMPERATURE": Mapping(.temperature),
            "LIGHTROOM_GLOBAL_EXPOSURE": Mapping(.brightness),
        ]),
        "VIBRANCE": .partial([
            "VIBRANCE": Mapping(.saturation, .offsetAroundOne),
        ]),
        "COLOURFULNESS": .partial([
            "COLOURFULNESS": Mapping(.saturation, .offsetAroundOne),
        ]),
        "TONEMAP": .partial([
            "SATURATION": Mapping(.saturation, .offsetAroundOne),
            "EXPOSURE": Mapping(.brightness),
        ]),

        // Known, and knowably impossible here.
        "CINEMATICDOF": .unsupported("depth of field \(depthReason)"),
        "ADOF": .unsupported("depth of field \(depthReason)"),
        "DOF": .unsupported("depth of field \(depthReason)"),
        "RADIANTGI": .unsupported("global illumination \(depthReason)"),
        "RTGI": .unsupported("ray-traced GI \(depthReason)"),
        "QUINT_RTGI": .unsupported("ray-traced GI \(depthReason)"),
        "MXAO": .unsupported("ambient occlusion \(depthReason)"),
        "QUINT_MXAO": .unsupported("ambient occlusion \(depthReason)"),
        "SSAO": .unsupported("ambient occlusion \(depthReason)"),
        "DEPTHHAZE": .unsupported("depth haze \(depthReason)"),
        "AMBIENTLIGHT": .unsupported("bloom and light adaptation are not implemented"),
        "FILMICPASS": .unsupported("filmic tone curve is not implemented"),
        "LOCALCONTRASTCS": .unsupported("local contrast is not implemented"),
    ]

    // MARK: - Parsing

    static func importPreset(at url: URL) throws -> PresetImportReport {
        let text = try String(contentsOf: url, encoding: .utf8)
        var sections: [(name: String, keys: [(String, String)])] = []
        var current: (name: String, keys: [(String, String)])?

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                if let current { sections.append(current) }
                current = (String(line.dropFirst().dropLast()), [])
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            current?.keys.append((key, value))
        }
        if let current { sections.append(current) }

        var settings = PresetSettings()
        var applied: [PresetImportReport.Applied] = []
        var skipped: [PresetImportReport.Skipped] = []

        for section in sections {
            let name = section.name
            // Section names carry a ".fx" suffix; global keys sit in "".
            let lookup = name
                .replacingOccurrences(of: ".fx", with: "", options: [.caseInsensitive])
                .uppercased()

            guard let support = effects[lookup] else {
                if !section.keys.isEmpty {
                    skipped.append(.init(
                        effect: name.isEmpty ? "Global settings" : name,
                        count: section.keys.count,
                        reason: "effect is not implemented"))
                }
                continue
            }

            switch support {
            case let .unsupported(reason):
                if !section.keys.isEmpty {
                    skipped.append(.init(effect: name, count: section.keys.count, reason: reason))
                }

            case let .partial(mappings):
                var unused = 0
                for (key, value) in section.keys {
                    guard let mapping = mappings[key], let number = Float(value) else {
                        unused += 1
                        continue
                    }
                    let resolved = apply(mapping, number: number, to: &settings)
                    applied.append(.init(
                        label: "\(name) · \(key.lowercased())",
                        detail: resolved))
                }
                if unused > 0 {
                    skipped.append(.init(
                        effect: name,
                        count: unused,
                        reason: "these parameters have no equivalent here"))
                }
            }
        }

        return PresetImportReport(settings: settings, applied: applied, skipped: skipped)
    }

    private static func apply(
        _ mapping: Mapping, number: Float, to settings: inout PresetSettings
    ) -> String {
        let scaled = mapping.scale == .offsetAroundOne ? 1 + number : number
        switch mapping.parameter {
        case .sharpening:
            let value = clamp(scaled, 0, 1)
            settings.sharpening = value
            return "sharpening \(percent(value))"
        case .brightness:
            let value = clamp(scaled, -1, 1)
            settings.color.brightness = value
            return "brightness \(signed(value))"
        case .contrast:
            let value = clamp(scaled, 0, 3)
            settings.color.contrast = value
            return "contrast \(twoPlaces(value))"
        case .saturation:
            let value = clamp(scaled, 0, 3)
            settings.color.saturation = value
            return "saturation \(twoPlaces(value))"
        case .temperature:
            let value = clamp(scaled, -1, 1)
            settings.color.temperature = value
            return "temperature \(signed(value))"
        }
    }

    private static func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float {
        min(max(value, low), high)
    }

    private static func percent(_ value: Float) -> String { "\(Int((value * 100).rounded()))%" }
    private static func signed(_ value: Float) -> String { String(format: "%+.2f", value) }
    private static func twoPlaces(_ value: Float) -> String { String(format: "%.2f", value) }
}
