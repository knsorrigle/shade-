import Foundation

struct BasicColor: Sendable, Equatable {
    var brightness: Float = 0
    var contrast: Float = 1
    var saturation: Float = 1
    var temperature: Float = 0
}

struct PresetSettings: Sendable {
    var sharpening: Float?
    var clarity: Float?
    var tone: Float?
    var bloom: Float?
    var bloomThreshold: Float?
    var exposure: Float?
    var gamma: Float?
    var vibrance: Float?
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
        case clarity
        case tone
        case bloom
        case bloomThreshold
        case brightness
        case contrast
        case saturation
        case temperature
        case exposure
        case gamma
        case vibrance
    }

    /// How a preset's stored number maps onto our uniform.
    private enum Scale {
        /// Already in our units.
        case direct
        /// ReShade stores an offset around neutral; our uniform is a multiplier
        /// around 1.
        case offsetAroundOne
        /// Ranges differ between shaders. The divisor brings a shader's own
        /// range into ours, and is a judgement rather than a published mapping.
        case divided(by: Float)
    }

    /// What happens when more than one effect writes the same parameter.
    ///
    /// ReShade runs its effects in sequence, so two shaders each adjusting
    /// saturation compose. Taking the last one seen instead would make the
    /// result depend on section order in the file.
    private enum Composition {
        /// Multipliers around 1 compose by multiplying.
        case multiply
        /// Offsets around 0 compose by adding.
        case add
        /// Strengths do not stack: two sharpening passes are not twice as sharp.
        case strongest
        /// A threshold has no meaningful composition; the last one wins.
        case replace
    }

    private struct Mapping {
        let parameter: Parameter
        let scale: Scale
        let composition: Composition
        init(_ parameter: Parameter, _ scale: Scale = .direct,
             _ composition: Composition = .replace) {
            self.parameter = parameter
            self.scale = scale
            self.composition = composition
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
            "SHARPENING": Mapping(.sharpening, .direct, .strongest),
        ]),
        "LUMASHARPEN": .partial([
            "SHARP_STRENGTH": Mapping(.sharpening, .direct, .strongest),
        ]),
        "ADAPTIVESHARPEN": .partial([
            "CURVE_HEIGHT": Mapping(.sharpening, .direct, .strongest),
        ]),
        "QUINT_LIGHTROOM": .partial([
            "LIGHTROOM_GLOBAL_SATURATION": Mapping(.saturation, .offsetAroundOne, .multiply),
            "LIGHTROOM_GLOBAL_CONTRAST": Mapping(.contrast, .offsetAroundOne, .multiply),
            "LIGHTROOM_GLOBAL_TEMPERATURE": Mapping(.temperature, .direct, .add),
            "LIGHTROOM_GLOBAL_EXPOSURE": Mapping(.exposure, .direct, .add),
            "LIGHTROOM_GLOBAL_GAMMA": Mapping(.gamma, .offsetAroundOne, .multiply),
            "LIGHTROOM_GLOBAL_VIBRANCE": Mapping(.vibrance, .direct, .add),
        ]),

        // Ambient Light is predominantly a bloom. Its own ranges are much wider
        // than ours, so the divisors below bring them into range; they are a
        // judgement, not a published mapping, and the adaptation, lens and dirt
        // features it also provides are not implemented.
        "AMBIENTLIGHT": .partial([
            "ALINT": Mapping(.bloom, .divided(by: 4), .strongest),
            "ALTHRESHOLD": Mapping(.bloomThreshold, .divided(by: 100)),
        ]),
        // Other common bloom shaders.
        "BLOOM": .partial([
            "BLOOMINTENSITY": Mapping(.bloom, .direct, .strongest),
            "BLOOMTHRESHOLD": Mapping(.bloomThreshold, .divided(by: 100)),
        ]),
        "MAGICBLOOM": .partial([
            "FMB_INTENSITY": Mapping(.bloom, .direct, .strongest),
            "FMB_THRESHOLD": Mapping(.bloomThreshold),
        ]),

        // FilmicPass is a tone curve. Its Strength is how much of the curve is
        // applied, which is exactly our tone stage. Its Saturation and Contrast
        // are offsets applied inside that curve, so only Saturation — whose
        // offset semantics are unambiguous — is carried across; the rest of the
        // curve's internals have no equivalent here.
        "FILMICPASS": .partial([
            "STRENGTH": Mapping(.tone, .direct, .strongest),
            "SATURATION": Mapping(.saturation, .offsetAroundOne, .multiply),
        ]),
        "TONEMAP": .partial([
            "SATURATION": Mapping(.saturation, .offsetAroundOne, .multiply),
            "EXPOSURE": Mapping(.exposure, .direct, .add),
            "GAMMA": Mapping(.gamma, .direct, .multiply),
        ]),

        // Local contrast, which is our clarity stage.
        "LOCALCONTRASTCS": .partial([
            "STRENGTH": Mapping(.clarity, .direct, .strongest),
        ]),
        "CLARITY": .partial([
            "CLARITYSTRENGTH": Mapping(.clarity, .direct, .strongest),
        ]),
        "VIBRANCE": .partial([
            "VIBRANCE": Mapping(.vibrance, .direct, .add),
        ]),
        "COLOURFULNESS": .partial([
            "COLOURFULNESS": Mapping(.saturation, .offsetAroundOne, .multiply),
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
        let scaled: Float
        switch mapping.scale {
        case .direct: scaled = number
        case .offsetAroundOne: scaled = 1 + number
        case let .divided(by: divisor): scaled = number / divisor
        }

        func compose(_ existing: Float?, _ incoming: Float, neutral: Float) -> Float {
            guard let existing else { return incoming }
            switch mapping.composition {
            case .multiply: return (existing / neutral) * (incoming / neutral) * neutral
            case .add: return existing + incoming - neutral
            case .strongest: return max(existing, incoming)
            case .replace: return incoming
            }
        }

        switch mapping.parameter {
        case .sharpening:
            let value = clamp(compose(settings.sharpening, scaled, neutral: 0), 0, 1)
            settings.sharpening = value
            return "sharpen \(percent(value))"
        case .clarity:
            let value = clamp(compose(settings.clarity, scaled, neutral: 0), 0, 1)
            settings.clarity = value
            return "clarity \(percent(value))"
        case .tone:
            let value = clamp(compose(settings.tone, scaled, neutral: 0), 0, 1)
            settings.tone = value
            return "filmic tone \(percent(value))"
        case .bloom:
            let value = clamp(compose(settings.bloom, scaled, neutral: 0), 0, 2)
            settings.bloom = value
            return "bloom \(twoPlaces(value))"
        case .bloomThreshold:
            let value = clamp(scaled, 0, 1)
            settings.bloomThreshold = value
            return "bloom threshold \(twoPlaces(value))"
        case .exposure:
            let value = clamp(compose(settings.exposure, scaled, neutral: 0), -3, 3)
            settings.exposure = value
            return "exposure \(signed(value))"
        case .gamma:
            let value = clamp(compose(settings.gamma, scaled, neutral: 1), 0.2, 3)
            settings.gamma = value
            return "gamma \(twoPlaces(value))"
        case .vibrance:
            let value = clamp(compose(settings.vibrance, scaled, neutral: 0), -1, 1)
            settings.vibrance = value
            return "vibrance \(signed(value))"
        case .brightness:
            let value = clamp(compose(settings.color.brightness, scaled, neutral: 0), -1, 1)
            settings.color.brightness = value
            return "brightness \(signed(value))"
        case .contrast:
            let value = clamp(compose(settings.color.contrast, scaled, neutral: 1), 0, 3)
            settings.color.contrast = value
            return "contrast \(twoPlaces(value))"
        case .saturation:
            let value = clamp(compose(settings.color.saturation, scaled, neutral: 1), 0, 3)
            settings.color.saturation = value
            return "saturation \(twoPlaces(value))"
        case .temperature:
            let value = clamp(compose(settings.color.temperature, scaled, neutral: 0), -1, 1)
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
