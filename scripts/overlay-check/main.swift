// Compares MetalShade's overlay window against its target window using
// CGWindowList, so alignment is a measurement rather than an impression.
import AppKit

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: validate-overlay.sh <target-bundle-id>\n".utf8))
    exit(2)
}
let targetBundleID = CommandLine.arguments[1]

func windows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
}

func rect(_ entry: [String: Any]) -> CGRect? {
    guard let b = entry[kCGWindowBounds as String] as? [String: CGFloat],
          let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"]
    else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
}

func pids(_ bundleID: String) -> Set<pid_t> {
    Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
}

let all = windows()
let targetPIDs = pids(targetBundleID)
let shadePIDs = pids("io.metalshade.app")

guard !targetPIDs.isEmpty else {
    print("FAIL  target \(targetBundleID) is not running")
    exit(1)
}
guard !shadePIDs.isEmpty else {
    print("FAIL  MetalShade is not running")
    exit(1)
}

let targetWindows = all.filter {
    guard let pid = $0[kCGWindowOwnerPID as String] as? pid_t else { return false }
    guard let r = rect($0) else { return false }
    return targetPIDs.contains(pid) && r.width > 100 && r.height > 100
}
// The overlay is borderless and sized to the target; the control panel is not.
let shadeWindows = all.filter {
    guard let pid = $0[kCGWindowOwnerPID as String] as? pid_t else { return false }
    guard let r = rect($0) else { return false }
    return shadePIDs.contains(pid) && r.width > 100 && r.height > 100
}

guard let target = targetWindows.first, let targetRect = rect(target) else {
    print("FAIL  no visible window for \(targetBundleID)")
    exit(1)
}
print("target   \(targetBundleID)")
print("         \(Int(targetRect.origin.x)),\(Int(targetRect.origin.y)) "
    + "\(Int(targetRect.width))x\(Int(targetRect.height))")

guard !shadeWindows.isEmpty else {
    print("FAIL  MetalShade is running but has no on-screen overlay window")
    print("      (with capture this means no frames arrived; check Screen Recording)")
    exit(1)
}

// Pick the MetalShade window closest in size to the target.
let best = shadeWindows.min { a, b in
    guard let ra = rect(a), let rb = rect(b) else { return false }
    func score(_ r: CGRect) -> CGFloat {
        abs(r.width - targetRect.width) + abs(r.height - targetRect.height)
    }
    return score(ra) < score(rb)
}!
let overlayRect = rect(best)!
print("overlay  \(Int(overlayRect.origin.x)),\(Int(overlayRect.origin.y)) "
    + "\(Int(overlayRect.width))x\(Int(overlayRect.height))")

let dx = overlayRect.origin.x - targetRect.origin.x
let dy = overlayRect.origin.y - targetRect.origin.y
let dw = overlayRect.width - targetRect.width
let dh = overlayRect.height - targetRect.height
print(String(format: "delta    x %+.0f  y %+.0f  w %+.0f  h %+.0f", dx, dy, dw, dh))

// Ordering: a lower index in the list is nearer the front.
let overlayIndex = all.firstIndex { ($0[kCGWindowNumber as String] as? CGWindowID) == (best[kCGWindowNumber as String] as? CGWindowID) }
let targetIndex = all.firstIndex { ($0[kCGWindowNumber as String] as? CGWindowID) == (target[kCGWindowNumber as String] as? CGWindowID) }
if let overlayIndex, let targetIndex {
    print(overlayIndex < targetIndex
        ? "order    overlay is in front of the target  PASS"
        : "order    overlay is BEHIND the target       FAIL")
}

let tolerance: CGFloat = 1
if abs(dx) <= tolerance, abs(dy) <= tolerance, abs(dw) <= tolerance, abs(dh) <= tolerance {
    print("\nPASS  overlay is aligned with the target window")
    exit(0)
}
print("\nFAIL  overlay is misaligned")
if abs(dy) > tolerance, abs(dx) <= tolerance {
    print("      vertical-only error suggests a CoreGraphics/AppKit coordinate mix-up")
}
exit(1)
