import AppKit
import CoreMedia
import ScreenCaptureKit

final class CaptureController: NSObject, SCStreamOutput, SCStreamDelegate {
    private let bundleID: String
    private let renderer: MetalRenderer
    private let report: (String) -> Void
    private var stream: SCStream?
    private var targetWindowID: CGWindowID?
    private var overlay: OverlayWindow?
    private var trackingTimer: Timer?
    private var receivedFrame = false
    private var frameCount = 0
    private var rateTimer: Timer?
    private let countLock = NSLock()
    /// One prompt per launch, however many targets are tried.
    private static var hasRequestedAccess = false
    private var activationObserver: NSObjectProtocol?

    init(bundleID: String, renderer: MetalRenderer, report: @escaping (String) -> Void) {
        self.bundleID = bundleID
        self.renderer = renderer
        self.report = report
    }

    func start() {
        Diagnostics.log("start requested for \(bundleID)")
        guard CGPreflightScreenCaptureAccess() else {
            Diagnostics.log("screen recording permission missing")
            // Ask at most once per launch. Requesting again on every attempt
            // produced a prompt each time a target was picked, which reads as
            // the permission never sticking.
            if !CaptureController.hasRequestedAccess {
                CaptureController.hasRequestedAccess = true
                CGRequestScreenCaptureAccess()
            }
            report("Screen Recording is not granted. Approve MetalShade in "
                + "System Settings › Privacy & Security › Screen Recording, then quit "
                + "and reopen MetalShade. Approving does not affect a process that is "
                + "already running.")
            return
        }
        Task { [weak self] in await self?.startCapture() }
    }

    private func startCapture() async {
        do {
            // onScreenWindowsOnly must be false. A game running full-screen lives on
            // its own Space, and from MetalShade's Space its window is not "on
            // screen" — the previous filter therefore never found it, and the
            // failure was invisible because the panel is on another Space too.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let candidates = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleID
                    && $0.frame.width > 200 && $0.frame.height > 200
            }
            Diagnostics.log("target \(bundleID): \(candidates.count) candidate window(s)")
            for candidate in candidates {
                Diagnostics.log("  id=\(candidate.windowID) \(Int(candidate.frame.width))x\(Int(candidate.frame.height))"
                    + " onScreen=\(candidate.isOnScreen) title=\(candidate.title ?? "-")")
            }
            // Games spawn helper windows; take the largest.
            guard let window = candidates.max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }) else {
                let message = "No window found for \(bundleID). Is it running?"
                Diagnostics.log(message)
                report(message)
                return
            }
            Diagnostics.log("chose window \(window.windowID) at \(window.frame)")

            targetWindowID = window.windowID
            let overlay = try await MainActor.run { try OverlayWindow(renderer: self.renderer, captureFrame: window.frame) }
            self.overlay = overlay

            // A window that covers a whole display is a full-screen game. Capturing
            // the display instead of the window is far more reliable there:
            // window capture of a surface on another Space frequently delivers
            // nothing. Our own app is excluded from the filter, which also makes
            // an overlay-feedback loop impossible.
            let display = content.displays.first { $0.frame.contains(window.frame) }
                ?? content.displays.first
            let coversDisplay = display.map { d in
                window.frame.width >= d.frame.width - 2 && window.frame.height >= d.frame.height - 2
            } ?? false

            let filter: SCContentFilter
            // Display capture draws our own output back into the next frame unless
            // MetalShade is excluded. When that exclusion silently failed the
            // result was runaway feedback: sharpen, present, capture, sharpen
            // again, dozens of times a second, across the whole screen. Refuse to
            // capture the display at all unless the exclusion is confirmed.
            let selfBundleID = Bundle.main.bundleIdentifier
            // Re-read shareable content: the snapshot above predates our overlay,
            // so it cannot list it.
            let refreshed = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let selfApps = (refreshed ?? content).applications.filter { $0.bundleIdentifier == selfBundleID }
            let selfWindows = (refreshed ?? content).windows.filter {
                $0.owningApplication?.bundleIdentifier == selfBundleID
            }

            if coversDisplay, let display, !selfApps.isEmpty {
                filter = SCContentFilter(display: display,
                                         excludingApplications: selfApps,
                                         exceptingWindows: [])
                Diagnostics.log("window covers the display; capturing display \(display.displayID) "
                    + "\(Int(display.frame.width))x\(Int(display.frame.height)); "
                    + "excluding \(selfApps.count) of our app(s), \(selfWindows.count) of our window(s)")
            } else {
                if coversDisplay {
                    Diagnostics.log("REFUSING display capture: could not identify our own app to exclude "
                        + "(bundle \(selfBundleID ?? "nil")). Falling back to window capture to avoid a "
                        + "feedback loop.")
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
                Diagnostics.log("capturing the window directly")
            }

            let configuration = SCStreamConfiguration()
            // Capturing a Retina display at 2x is 7.6 megapixels a frame. That
            // cost lands on the same GPU the game is using, so it is a setting
            // rather than a constant.
            let scale = CaptureSettings.shared.scale
            let cap = CaptureSettings.shared.frameCap
            configuration.width = max(1, Int(window.frame.width * scale))
            configuration.height = max(1, Int(window.frame.height * scale))
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(cap))
            Diagnostics.log("capture scale \(scale)x, frame cap \(cap)")
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = false

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "io.metalshade.capture", qos: .userInteractive))
            self.stream = stream
            try await stream.startCapture()
            Diagnostics.log("stream started \(configuration.width)x\(configuration.height)")
            await MainActor.run {
                // Reveal only once a frame has been drawn; an overlay shown before
                // that covers the target in black.
                self.renderer.onFirstFrame = { [weak self] in
                    guard let self else { return }
                    self.overlay?.showOnFirstFrame()
                    self.report("Capturing \(self.bundleID) — \(self.renderer.effectDescription)")
                }
            }
            beginTrackingWindow()
            beginRateReporting()
            observeFrontmostApplication()
            scheduleNoFrameCheck()
            report("Waiting for frames from \(bundleID)…")
        } catch {
            Diagnostics.log("capture failed: \(error.localizedDescription)")
            report("Capture failed: \(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        receivedFrame = true
        countLock.lock(); frameCount += 1; countLock.unlock()
        renderer.submit(pixelBuffer: pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { report("Capture stopped: \(error.localizedDescription)") }

    /// Tears the session down so another target can be selected without
    /// relaunching the app.
    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        trackingTimer?.invalidate()
        trackingTimer = nil
        rateTimer?.invalidate()
        rateTimer = nil
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
        Task { @MainActor in
            self.overlay?.orderOut(nil)
            self.overlay = nil
        }
        renderer.onFirstFrame = nil
    }

    private func beginTrackingWindow() {
        // Timer.scheduledTimer installs on the *calling* thread's run loop.
        // startCapture() runs inside an async Task on a cooperative thread with
        // no run loop, so timers created there never fire — which is why no
        // frame-rate line was ever logged and why the overlay never tracked a
        // moving window.
        DispatchQueue.main.async { [weak self] in self?.installTrackingTimer() }
    }

    private func installTrackingTimer() {
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshOverlayFrame() }
        }
    }

    private func refreshOverlayFrame() async {
        guard let targetWindowID else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let window = content.windows.first(where: { $0.windowID == targetWindowID }) else { return }
        await MainActor.run { self.overlay?.update(captureFrame: window.frame) }
    }

    /// Hides the overlay whenever the target is not the frontmost app.
    ///
    /// A full-screen target's overlay spans the whole display. Left up after
    /// switching away, it applies the effect to every other window on screen —
    /// including MetalShade's own controls.
    private func observeFrontmostApplication() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncOverlayVisibility()
            self.activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.syncOverlayVisibility()
            }
        }
    }

    private func syncOverlayVisibility() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isTarget = front == bundleID
        Task { @MainActor [weak self] in
            self?.overlay?.targetIsFrontmost = isTarget
        }
        // Most games pause when they lose focus, and their pause screen reads as a
        // frozen overlay. Say so rather than leaving it to be worked out.
        if !isTarget {
            report("Target is not in front — most games pause when they lose focus, "
                + "which looks like a frozen picture. Click the game to resume. The "
                + "⌘⌥ shortcuts adjust effects without taking focus.")
        }
        Diagnostics.log("frontmost=\(front ?? "none") target=\(bundleID) overlay=\(isTarget ? "shown" : "hidden")")
    }

    /// Reports the delivered frame rate once a second. Whether frames are
    /// arriving is otherwise invisible, and it is the first thing worth knowing
    /// when the image does not change.
    private func beginRateReporting() {
        DispatchQueue.main.async { [weak self] in self?.installRateTimer() }
    }

    private func installRateTimer() {
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.countLock.lock()
            let count = self.frameCount
            self.frameCount = 0
            self.countLock.unlock()
            // Log every tick, including zeroes. Silence is ambiguous: it cannot
            // distinguish a stream that never delivers from one that delivers
            // only while the game's Space is in front.
            Diagnostics.log("\(count) fps")
            guard self.receivedFrame else { return }
            self.report("Capturing \(self.bundleID) — \(count) fps, \(self.renderer.effectDescription)")
        }
    }

    /// Silence here almost always means the Screen Recording grant is missing or
    /// stale, which `startCapture()` itself reports as success.
    private func scheduleNoFrameCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.receivedFrame else { return }
            Diagnostics.log("no frames after 3s")
            self.report("No frames after 3s — check Screen Recording for MetalShade in System Settings, then relaunch.")
        }
    }
}
