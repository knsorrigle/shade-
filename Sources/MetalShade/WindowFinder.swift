import AppKit

/// Locates a target window using `CGWindowListCopyWindowInfo`, which reports
/// window bounds without the Screen Recording grant. That lets the overlay's
/// geometry be verified independently of whether capture works — the two failed
/// together previously, which made the cause hard to see.
enum WindowFinder {
    struct Target {
        let windowID: CGWindowID
        /// CoreGraphics display space, as `SCWindow.frame` also reports.
        let frame: CGRect
    }

    static func firstWindow(ofBundleID bundleID: String) -> Target? {
        let pids = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .map(\.processIdentifier))
        guard !pids.isEmpty else { return nil }

        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []

        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 100, height > 100
            else { continue }
            return Target(windowID: id, frame: CGRect(x: x, y: y, width: width, height: height))
        }
        return nil
    }

    static func frame(ofWindowID windowID: CGWindowID) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]] ?? []
        guard let bounds = list.first?[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let width = bounds["Width"], let height = bounds["Height"]
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
