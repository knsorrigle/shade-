import AppKit
import CoreVideo
import MetalKit

/// Mirrors `Uniforms` in EffectChain.metal. Laid out entirely as float4 because
/// Metal pads float3 to 16 bytes, which has already caused one silent bug where
/// a shader read padding instead of a flag.
struct EffectUniforms {
    /// sharpen, clarity, tone, bloom intensity
    var a = SIMD4<Float>(0, 0, 0, 0)
    /// bloom threshold, exposure, gamma, vibrance
    var b = SIMD4<Float>(0.8, 0, 1, 0)
    /// brightness, contrast, saturation, temperature
    var colour = SIMD4<Float>(0, 1, 1, 0)
    /// tint rgb, enabled
    var tint = SIMD4<Float>(0, 1, 0, 0)
    /// LUT mix in x
    var lut = SIMD4<Float>(0, 0, 0, 0)
    var domainMin = SIMD4<Float>(0, 0, 0, 0)
    var domainMax = SIMD4<Float>(1, 1, 1, 0)
    /// Fog amount and depth scale. Always zero here: the overlay has no depth.
    var fog = SIMD4<Float>(0, 0.0003, 0, 0)
    var fogColour = SIMD4<Float>(0.62, 0.68, 0.76, 0)
}

private struct BlurParams {
    var direction = SIMD4<Float>(0, 0, 0, 0)
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
    private var compositePipeline: MTLRenderPipelineState?
    private var brightPassPipeline: MTLRenderPipelineState?
    private var blurPipeline: MTLRenderPipelineState?
    private var lutTexture: MTLTexture?
    private var identityLUT: MTLTexture?
    /// The chain always samples a depth texture. The overlay never has one — it
    /// sees a finished colour image — so a 1x1 stand-in keeps the pipeline valid
    /// and fog stays at zero.
    private var depthStub: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private var bloomSize = CGSize.zero
    private var effect: Effect = .cas
    private var effectsEnabled = true
    private var uniforms = EffectUniforms()
    private let renderLock = NSLock()
    private var frameInFlight = false
    private var hasRenderedFrame = false
    /// Called on the main queue after the first frame actually reaches the screen.
    var onFirstFrame: (() -> Void)?

    var effectDescription: String {
        guard effectsEnabled else { return "effects bypassed" }
        return "\(effect.title), \(Int(uniforms.a.x * 100))%"
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
    func setIntensity(_ value: Float) { uniforms.a.x = min(max(value, 0), 1) }
    func setDiagnosticTint(_ enabled: Bool) {
        uniforms.tint = SIMD4(0, 1, 0, enabled ? 1 : 0)
    }

    /// The depth-free stages, matching what the injected payload applies so both
    /// routes produce the same picture.
    func setStages(clarity: Float, tone: Float, bloom: Float, bloomThreshold: Float,
                   exposure: Float, gamma: Float, vibrance: Float) {
        uniforms.a.y = clarity
        uniforms.a.z = tone
        uniforms.a.w = bloom
        uniforms.b = [bloomThreshold, exposure, gamma, vibrance]
    }

    func setColor(_ color: BasicColor) {
        uniforms.colour = [color.brightness, color.contrast, color.saturation, color.temperature]
    }

    var hasLUT: Bool { lutTexture != nil }

    func loadLUT(from url: URL) throws {
        let cube = try CubeLUT.parse(url: url)
        guard let texture = cube.makeTexture(on: device) else { throw RendererError.lutTextureUnavailable }
        lutTexture = texture
        uniforms.domainMin = SIMD4(cube.domainMin, 0)
        uniforms.domainMax = SIMD4(cube.domainMax, 0)
        uniforms.lut.x = 1
    }

    func clearLUT() {
        lutTexture = nil
        uniforms.lut.x = 0
        uniforms.domainMin = SIMD4(0, 0, 0, 0)
        uniforms.domainMax = SIMD4(1, 1, 1, 0)
    }

    func setLUTMix(_ value: Float) { uniforms.lut.x = min(max(value, 0), 1) }

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
        guard let view, let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor else { return }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        guard let cvTexture, let input = CVMetalTextureGetTexture(cvTexture),
              let composite = compositePipeline,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        var localUniforms = uniforms
        if !effectsEnabled {
            // Do not hide the overlay: some full-screen Metal games present a black
            // backing surface when it is removed. A neutral chain is visually off
            // while preserving the working capture and compositing path. The
            // diagnostic tint survives, since it answers "is the overlay on
            // screen" — exactly the question being asked when effects are off.
            localUniforms.a = SIMD4<Float>(0, 0, 0, 0)
            localUniforms.b = SIMD4<Float>(0.8, 0, 1, 0)
            localUniforms.colour = SIMD4<Float>(0, 1, 1, 0)
            localUniforms.lut.x = 0
        }

        // Bloom needs its own targets, so it runs as passes before the composite.
        if localUniforms.a.w > 0.001 {
            ensureBloomTextures(width: input.width, height: input.height)
            if let bloomA, let bloomB, let bright = brightPassPipeline, let blur = blurPipeline {
                fullscreenPass(commandBuffer, into: bloomA, pipeline: bright,
                               textures: [input], uniforms: &localUniforms,
                               length: MemoryLayout<EffectUniforms>.stride)
                var horizontal = BlurParams(direction: [1.0 / Float(bloomA.width), 0, 0, 0])
                fullscreenPass(commandBuffer, into: bloomB, pipeline: blur,
                               textures: [bloomA], uniforms: &horizontal,
                               length: MemoryLayout<BlurParams>.stride)
                var vertical = BlurParams(direction: [0, 1.0 / Float(bloomA.height), 0, 0])
                fullscreenPass(commandBuffer, into: bloomA, pipeline: blur,
                               textures: [bloomB], uniforms: &vertical,
                               length: MemoryLayout<BlurParams>.stride)
            }
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(composite)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentTexture(bloomA ?? input, index: 1)
        // The composite always samples a LUT, so an identity keeps it valid when
        // none is loaded rather than leaving an unbound texture to sample.
        encoder.setFragmentTexture(lutTexture ?? identityLUT, index: 2)
        encoder.setFragmentTexture(depthStub, index: 3)
        encoder.setFragmentBytes(&localUniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable, afterMinimumDuration: 1.0 / Double(CaptureSettings.shared.frameCap))
        commandBuffer.addCompletedHandler { [weak self] _ in
            _ = cvTexture // Keep the IOSurface-backed capture texture alive through GPU use.
            self?.finishFrame()
        }
        submitted = true
        commandBuffer.commit()
        if !hasRenderedFrame {
            hasRenderedFrame = true
            onFirstFrame?()
        }
    }

    private func finishFrame() {
        renderLock.lock()
        frameInFlight = false
        renderLock.unlock()
    }

    private func rebuildPipelines(source: String) throws {
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(name: "fullscreenVertex"),
              let composite = library.makeFunction(name: "compositeFragment"),
              let bright = library.makeFunction(name: "brightPassFragment"),
              let blur = library.makeFunction(name: "blurFragment")
        else { throw RendererError.missingShaderEntryPoint }
        compositePipeline = try makePipeline(vertex: vertex, fragment: composite)
        brightPassPipeline = try makePipeline(vertex: vertex, fragment: bright)
        blurPipeline = try makePipeline(vertex: vertex, fragment: blur)
        if identityLUT == nil { identityLUT = makeIdentityLUT() }
        if depthStub == nil { depthStub = makeDepthStub() }
    }

    /// A 2x2x2 identity, so the composite's LUT sampler is always bound.
    private func makeIdentityLUT() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = 2; descriptor.height = 2; descriptor.depth = 2
        descriptor.usage = .shaderRead
        return device.makeTexture(descriptor: descriptor)
    }

    private func makeDepthStub() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// Bloom is blurred anyway, so quarter resolution costs nothing visible and a
    /// sixteenth of the work.
    private func ensureBloomTextures(width: Int, height: Int) {
        let target = CGSize(width: width / 4, height: height / 4)
        guard bloomA == nil || bloomSize != target else { return }
        bloomSize = target
        bloomA = makeTarget(width: Int(target.width), height: Int(target.height))
        bloomB = makeTarget(width: Int(target.width), height: Int(target.height))
    }

    private func makeTarget(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: max(width, 1), height: max(height, 1), mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func fullscreenPass(_ commandBuffer: MTLCommandBuffer, into destination: MTLTexture,
                                pipeline: MTLRenderPipelineState, textures: [MTLTexture],
                                uniforms: UnsafeRawPointer, length: Int) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        encoder.setFragmentBytes(uniforms, length: length, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
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
