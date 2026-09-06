// Prints what MetalShade would do with a ReShade preset. Compiled against the
// app's own parser by scripts/check-preset.sh, so it cannot drift from it.
import Foundation

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: check-preset.sh <preset.ini>\n".utf8))
    exit(2)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let report: PresetImportReport
do {
    report = try ReShadePreset.importPreset(at: url)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}

print("\(url.lastPathComponent)\n")

if report.applied.isEmpty {
    print("APPLIED: nothing — no effect in this preset has an overlay equivalent.")
} else {
    print("APPLIED (\(report.applied.count)):")
    for entry in report.applied {
        print("  \(entry.label) -> \(entry.detail)")
    }
}

let colour = report.settings.color
func show(_ label: String, _ value: Float?, default fallback: String = "unchanged") -> String {
    value.map { String(format: "%@%.2f", $0 < 0 ? "" : " ", $0) } ?? " \(fallback)"
}
print("""

RESULTING STATE:
  sharpen    \(show("", report.settings.sharpening))
  clarity    \(show("", report.settings.clarity))
  filmic tone\(show("", report.settings.tone))
  bloom      \(show("", report.settings.bloom))
  threshold  \(show("", report.settings.bloomThreshold))
  exposure   \(show("", report.settings.exposure))
  gamma      \(show("", report.settings.gamma))
  vibrance   \(show("", report.settings.vibrance))
  brightness \(String(format: "%+.2f", colour.brightness))
  contrast    \(String(format: "%.2f", colour.contrast))
  saturation  \(String(format: "%.2f", colour.saturation))
  temperature\(String(format: "%+.2f", colour.temperature))
""")

if !report.skipped.isEmpty {
    print("\nSKIPPED (\(report.skippedCount) settings across \(report.skipped.count) effects):")
    for group in report.skipped.sorted(by: { $0.count > $1.count }) {
        print("  \(group.effect) — \(group.count): \(group.reason)")
    }
}
