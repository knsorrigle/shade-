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
print("""

RESULTING STATE:
  sharpening  \(report.settings.sharpening.map { String(format: "%.2f", $0) } ?? "unchanged")
  brightness  \(String(format: "%+.2f", colour.brightness))
  contrast    \(String(format: "%.2f", colour.contrast))
  saturation  \(String(format: "%.2f", colour.saturation))
  temperature \(String(format: "%+.2f", colour.temperature))
""")

if !report.skipped.isEmpty {
    print("\nSKIPPED (\(report.skippedCount) settings across \(report.skipped.count) effects):")
    for group in report.skipped.sorted(by: { $0.count > $1.count }) {
        print("  \(group.effect) — \(group.count): \(group.reason)")
    }
}
