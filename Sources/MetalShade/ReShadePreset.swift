import Foundation

struct BasicColor: Sendable {
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
    let settings: PresetSettings
    let warnings: [String]
}

enum ReShadePreset {
    static func importPreset(at url: URL) throws -> PresetImportReport {
        let text = try String(contentsOf: url, encoding: .utf8)
        var settings = PresetSettings()
        var warnings: [String] = []
        let ignoredKeys: Set<String> = ["TECHNIQUES", "TECHNIQUESORTING", "PREPROCESSORDEFINITIONS", "KEYTOGGLE", "KEYNEXT", "KEYPREVIOUS"]

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("["), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if ignoredKeys.contains(key) { continue }
            guard let number = Float(value) else {
                warnings.append("Skipped unsupported setting \(key)=\(value)")
                continue
            }
            switch key {
            case "CAS_SHARPNESS", "CASSHARPNESS", "SHARPNESS", "SHARPENING": settings.sharpening = min(max(number, 0), 1)
            case "BRIGHTNESS": settings.color.brightness = min(max(number, -1), 1)
            case "CONTRAST": settings.color.contrast = min(max(number, 0), 3)
            case "SATURATION": settings.color.saturation = min(max(number, 0), 3)
            case "TEMPERATURE", "COLORTEMPERATURE": settings.color.temperature = min(max(number, -1), 1)
            case let depthKey where depthKey.contains("DEPTH") || depthKey.contains("DOF") || depthKey.contains("AO") || depthKey.contains("MXAO"):
                warnings.append("Skipped depth-based effect setting \(key): overlay capture has no game depth buffer")
            default: warnings.append("Skipped unsupported setting \(key)")
            }
        }
        return PresetImportReport(settings: settings, warnings: warnings)
    }
}
