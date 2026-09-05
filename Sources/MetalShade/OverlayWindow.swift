import AppKit
import MetalKit

@MainActor
final class OverlayWindow: NSPanel {
    private var shown = true

    init(renderer: MetalRenderer, frame: CGRect) throws {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let view = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: renderer.device)
        view.autoresizingMask = [.width, .height]
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm
        renderer.attach(view: view)
        contentView = view
    }

    func toggleVisibility() {
        shown.toggle()
        shown ? orderFrontRegardless() : orderOut(nil)
    }
}
