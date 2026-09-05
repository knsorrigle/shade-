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

    init(bundleID: String, renderer: MetalRenderer, report: @escaping (String) -> Void) {
        self.bundleID = bundleID
        self.renderer = renderer
        self.report = report
    }

    func start() {
        guard CGPreflightScreenCaptureAccess() else {
            report("Screen Recording permission required; approve it, then relaunch MetalShade")
            CGRequestScreenCaptureAccess()
            return
        }
        Task { [weak self] in await self?.startCapture() }
    }

    private func startCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: {
                $0.owningApplication?.bundleIdentifier == bundleID && $0.isOnScreen && $0.frame.width > 100 && $0.frame.height > 100
            }) else {
                report("No visible window for \(bundleID). Launch the game, then restart MetalShade.")
                return
            }

            targetWindowID = window.windowID
            let overlay = try await MainActor.run { try OverlayWindow(renderer: self.renderer, frame: window.frame) }
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
            await MainActor.run { overlay.orderFrontRegardless() }
            beginTrackingWindow()
            report("Capturing \(bundleID) — \(renderer.effectDescription)")
        } catch { report("Capture failed: \(error.localizedDescription)") }
    }

    func toggleOverlay() {
        renderer.toggleEffects()
        report(renderer.effectDescription)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        renderer.submit(pixelBuffer: pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { report("Capture stopped: \(error.localizedDescription)") }

    private func beginTrackingWindow() {
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshOverlayFrame() }
        }
    }

    private func refreshOverlayFrame() async {
        guard let targetWindowID else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == targetWindowID }) else { return }
        await MainActor.run { self.overlay?.setFrame(window.frame, display: true) }
    }
}
