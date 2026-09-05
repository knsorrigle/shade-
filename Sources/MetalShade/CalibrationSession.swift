import AppKit

/// Positions a calibration overlay over a target window and keeps it there,
/// using only `CGWindowList`. No capture, no Screen Recording grant — this
/// exercises exactly the coordinate conversion and window tracking that a
/// misaligned overlay depends on.
@MainActor
final class CalibrationSession {
    private let bundleID: String
    private let report: (String) -> Void
    private var overlay: OverlayWindow?
    private var windowID: CGWindowID?
    private var timer: Timer?

    init(bundleID: String, report: @escaping (String) -> Void) {
        self.bundleID = bundleID
        self.report = report
    }

    func start() {
        // Poll rather than give up: launching MetalShade before its target is the
        // normal order of events, and failing silently here left nothing on
        // screen at all.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func tick() {
        guard overlay == nil else { return follow() }
        guard let target = WindowFinder.firstWindow(ofBundleID: bundleID) else {
            report("Self-test: waiting for a window from \(bundleID) — open it and the "
                + "calibration overlay appears automatically.")
            return
        }
        windowID = target.windowID
        overlay = OverlayWindow(calibrationFrame: target.frame)
        report("Self-test: overlay on window \(target.windowID) at "
            + "\(Int(target.frame.width))x\(Int(target.frame.height)). "
            + "Its green border should sit exactly on the window's edges.")
    }

    private func follow() {
        guard let windowID, let frame = WindowFinder.frame(ofWindowID: windowID) else { return }
        overlay?.update(captureFrame: frame)
    }
}
