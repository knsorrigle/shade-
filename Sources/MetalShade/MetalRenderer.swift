import AppKit
import CoreVideo
import MetalKit

struct EffectUniforms {
    var intensity: Float = 0.65
    var padding = SIMD3<Float>(repeating: 0)
    var domainMin = SIMD4<Float>(0, 0, 0, 0)
    var domainMax = SIMD4<Float>(1, 1, 1, 0)
    var colorAdjust = SIMD4<Float>(0, 1, 1, 0)
}

final class MetalRenderer {
    enum Effect: String, CaseIterable, Identifiable, Sendable {
        case cas, lut
        var id: String { rawValue }
        var title: String { self == .cas ? "Sharpening" : "LUT grading" }
    }
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let shaderStore: ShaderStore
    private weak var view: MTKView?
    private var casPipeline: MTLRenderPipelineState?
    private var lutPipeline: MTLRenderPipelineState?
    private var lutTexture: MTLTexture?
    private var effect: Effect = .cas
    private var effectsEnabled = true
    private var uniforms = EffectUniforms()
    private let renderLock = NSLock()
    private var frameInFlight = false

    var effectDescription: String {
        guard effectsEnabled else { return "effects bypassed" }
        return "\(effect.title), \(Int(uniforms.intensity * 100))%"
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw RendererError.metalUnavailable }
        self.device = device
        self.commandQueue = queue
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else { throw RendererError.textureCacheUnavailable }
        textureCache = cache
        shaderStore = try ShaderStore()
        try rebuildPipelines(source: shaderStore.source())
        shaderStore.onChange = { [weak self] source in
            do { try self?.rebuildPipelines(source: source); NSLog("MetalShade: reloaded shaders") }
            catch { NSLog("MetalShade: shader reload failed (using last valid pipeline): \(error)") }
        }
    }

    /// `AppModel` owns the user-facing state and pushes it here; these setters are
    /// the only way the render state changes, so the window and the global
    /// shortcuts cannot drift out of sync.
    func attach(view: MTKView) { self.view = view }
    func setEffect(_ newEffect: Effect) { effect = newEffect }
    func setEffectsEnabled(_ enabled: Bool) { effectsEnabled = enabled }
    func setIntensity(_ value: Float) { uniforms.intensity = min(max(value, 0), 1) }
    func setColor(_ color: BasicColor) {
        uniforms.colorAdjust = [color.brightness, color.contrast, color.saturation, color.temperature]
    }

    var hasLUT: Bool { lutTexture != nil }

    func loadLUT(from url: URL) throws {
        let cube = try CubeLUT.parse(url: url)
        guard let texture = cube.makeTexture(on: device) else { throw RendererError.lutTextureUnavailable }
        lutTexture = texture
        uniforms.domainMin = SIMD4(cube.domainMin, 0)
        uniforms.domainMax = SIMD4(cube.domainMax, 0)
    }

    func clearLUT() {
        lutTexture = nil
        uniforms.domainMin = SIMD4(0, 0, 0, 0)
        uniforms.domainMax = SIMD4(1, 1, 1, 0)
    }

    func submit(pixelBuffer: CVPixelBuffer) {
        renderLock.lock()
        guard !frameInFlight else { renderLock.unlock(); return }
        frameInFlight = true
        renderLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.draw(pixelBuffer: pixelBuffer) }
    }

    private func draw(pixelBuffer: CVPixelBuffer) {
        var submitted = false
        defer {
            // Release the capture callback on setup failures. Successful frames release
            // it from the command-buffer completion handler below, preventing latency
            // from growing when the GPU cannot keep up with the capture rate.
            if !submitted { finishFrame() }
        }
        guard let view, let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { return }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        guard let cvTexture, let input = CVMetalTextureGetTexture(cvTexture), let commandBuffer = commandQueue.makeCommandBuffer(), let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let selectedEffect: Effect = effectsEnabled ? effect : .cas
        let pipeline = selectedEffect == .lut && lutTexture != nil ? lutPipeline : casPipeline
        guard let pipeline else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(input, index: 0)
        if selectedEffect == .lut, let lutTexture { encoder.setFragmentTexture(lutTexture, index: 1) }
        var localUniforms = uniforms
        if !effectsEnabled {
            // Do not hide the overlay: some full-screen Metal games present a black
            // backing surface when it is removed. A neutral shader is visually off
            // while preserving the working capture/compositing path.
            localUniforms.intensity = 0
            localUniforms.colorAdjust = SIMD4<Float>(0, 1, 1, 0)
        }
        encoder.setFragmentBytes(&localUniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            _ = cvTexture // Keep the IOSurface-backed capture texture alive through GPU use.
            self?.finishFrame()
        }
        submitted = true
        commandBuffer.commit()
    }

    private func finishFrame() {
        renderLock.lock()
        frameInFlight = false
        renderLock.unlock()
    }

    private func rebuildPipelines(source: String) throws {
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(name: "fullscreenVertex"), let cas = library.makeFunction(name: "casFragment"), let lut = library.makeFunction(name: "lutFragment") else { throw RendererError.missingShaderEntryPoint }
        casPipeline = try makePipeline(vertex: vertex, fragment: cas)
        lutPipeline = try makePipeline(vertex: vertex, fragment: lut)
    }

    private func makePipeline(vertex: MTLFunction, fragment: MTLFunction) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    enum RendererError: LocalizedError {
        case metalUnavailable, textureCacheUnavailable, lutTextureUnavailable, missingShaderEntryPoint
        var errorDescription: String? {
            switch self {
            case .metalUnavailable: return "No Metal device is available"
            case .textureCacheUnavailable: return "Could not create Metal texture cache"
            case .lutTextureUnavailable: return "Could not create 3D LUT texture"
            case .missingShaderEntryPoint: return "Shader source is missing a required entry point"
            }
        }
    }
}
