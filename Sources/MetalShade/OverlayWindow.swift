import AppKit
import MetalKit

enum ScreenGeometry {
    /// `SCWindow.frame` is CoreGraphics display space: origin at the top-left of
    /// the primary display, y increasing downward. `NSWindow` uses AppKit screen
    /// space: origin at the bottom-left, y increasing upward. Passing one to the
    /// other places the overlay mirrored about the screen's centre line — far
    /// enough off that a low window's overlay lands on the menu bar.
    /// A window that is *entirely* covered by another is marked occluded, and a
    /// game that believes it is not visible stops rendering — which presents as a
    /// frozen picture with audio and input still working. Leaving one point
    /// uncovered keeps the target visible to the window server.
    static let occlusionRelief: CGFloat = 1

    static func screenFrame(fromCaptureFrame frame: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return frame }
        return CGRect(
            x: frame.origin.x,
            y: primary.frame.maxY - frame.origin.y - frame.height + occlusionRelief,
            width: frame.width,
            height: max(frame.height - occlusionRelief, 1))
    }
}

@MainActor
final class OverlayWindow: NSPanel {
    private var hasShownFirstFrame = false

    /// Calibration mode: the same window in every respect, showing a border and
    /// crosshair instead of captured frames. It needs no Screen Recording grant,
    /// so overlay geometry can be checked on its own.
    convenience init(calibrationFrame: CGRect) {
        self.init(contentRect: calibrationFrame)
        contentView = CalibrationView(frame: NSRect(origin: .zero, size: calibrationFrame.size))
        contentView?.autoresizingMask = [.width, .height]
        orderFrontRegardless()
    }

    private init(contentRect: CGRect) {
        super.init(
            contentRect: ScreenGeometry.screenFrame(fromCaptureFrame: contentRect),
            // .nonactivatingPanel keeps the overlay from ever becoming key, so it
            // cannot take focus away from the game.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    init(renderer: MetalRenderer, captureFrame: CGRect) throws {
        super.init(
            contentRect: ScreenGeometry.screenFrame(fromCaptureFrame: captureFrame),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let view = MTKView(frame: NSRect(origin: .zero, size: captureFrame.size), device: renderer.device)
        view.autoresizingMask = [.width, .height]
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm
        // An MTKView that has not drawn yet is opaque black. Without this the
        // overlay covers the target in black whenever frames stop arriving —
        // which is exactly what a missing Screen Recording grant looks like.
        view.wantsLayer = true
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.isOpaque = false
        renderer.attach(view: view)
        contentView = view
    }

    func update(captureFrame: CGRect) {
        setFrame(ScreenGeometry.screenFrame(fromCaptureFrame: captureFrame), display: true)
    }

    /// Shown only once a frame has actually been rendered, so a failed capture
    /// leaves the target untouched instead of covering it.
    func showOnFirstFrame() {
        guard !hasShownFirstFrame else { return }
        hasShownFirstFrame = true
        if targetIsFrontmost { orderFrontRegardless() }
    }

    /// Whether the app being processed is the one in front.
    ///
    /// A full-screen target's overlay covers the whole display, so leaving it up
    /// after switching away applies the effect to every other window on screen.
    var targetIsFrontmost = true {
        didSet {
            guard hasShownFirstFrame, targetIsFrontmost != oldValue else { return }
            targetIsFrontmost ? orderFrontRegardless() : orderOut(nil)
        }
    }

    // Deliberately no hide/show control beyond the above: some full-screen Metal
    // games present a black surface when the overlay is ordered out. Bypassing
    // effects switches MetalRenderer to a neutral shader instead.
}


/// Draws the overlay's own edges so misalignment is visible and measurable:
/// the border should sit exactly on the target window's edges.
private final class CalibrationView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        NSColor.systemGreen.withAlphaComponent(0.10).setFill()
        bounds.fill()

        NSColor.systemGreen.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        border.stroke()

        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: bounds.midX, y: bounds.minY))
        cross.line(to: NSPoint(x: bounds.midX, y: bounds.maxY))
        cross.move(to: NSPoint(x: bounds.minX, y: bounds.midY))
        cross.line(to: NSPoint(x: bounds.maxX, y: bounds.midY))
        cross.lineWidth = 1
        cross.stroke()

        let label = "MetalShade calibration — \(Int(bounds.width))x\(Int(bounds.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.systemGreen,
        ]
        label.draw(at: NSPoint(x: bounds.minX + 10, y: bounds.minY + 8), withAttributes: attributes)
    }
}
