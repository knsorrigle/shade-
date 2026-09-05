import AppKit
import MetalKit

enum ScreenGeometry {
    /// `SCWindow.frame` is CoreGraphics display space: origin at the top-left of
    /// the primary display, y increasing downward. `NSWindow` uses AppKit screen
    /// space: origin at the bottom-left, y increasing upward. Passing one to the
    /// other places the overlay mirrored about the screen's centre line — far
    /// enough off that a low window's overlay lands on the menu bar.
    static func screenFrame(fromCaptureFrame frame: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return frame }
        return CGRect(
            x: frame.origin.x,
            y: primary.frame.maxY - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height)
    }
}

@MainActor
final class OverlayWindow: NSPanel {
    private var hasShownFirstFrame = false

    init(renderer: MetalRenderer, captureFrame: CGRect) throws {
        super.init(
            contentRect: ScreenGeometry.screenFrame(fromCaptureFrame: captureFrame),
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
        orderFrontRegardless()
    }

    // Deliberately no hide/show control beyond the above: some full-screen Metal
    // games present a black surface when the overlay is ordered out. Bypassing
    // effects switches MetalRenderer to a neutral shader instead.
}
