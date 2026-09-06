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

            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(window.frame.width * 2))
            configuration.height = max(1, Int(window.frame.height * 2))
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = false

            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: self)
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

    /// Reports the delivered frame rate once a second. Whether frames are
    /// arriving is otherwise invisible, and it is the first thing worth knowing
    /// when the image does not change.
    private func beginRateReporting() {
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
