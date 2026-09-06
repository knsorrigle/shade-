import Darwin
import Foundation

/// Watches the user-editable shader source. Invalid edits leave the last good
/// pipeline active; the renderer reports the compiler error in the Console.
final class ShaderStore {
    static let filename = "MetalShadeEffects.metal"
    let directory: URL
    private var watcher: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    var onChange: ((String) -> Void)?

    init() throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        directory = root.appendingPathComponent("MetalShade/Shaders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try installDefaultIfNeeded()
        try installEffectChain()
        startWatching()
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    func source() throws -> String {
        try String(contentsOf: directory.appendingPathComponent(Self.filename), encoding: .utf8)
    }

    private func startWatching() {
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let queue = DispatchQueue(label: "io.metalshade.shader-watch")
        watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: queue)
        watcher?.setEventHandler { [weak self] in
            guard let self else { return }
            // Editors often write a temporary file then rename it; debounce that sequence.
            queue.asyncAfter(deadline: .now() + 0.15) {
                guard let source = try? self.source() else { return }
                DispatchQueue.main.async { self.onChange?(source) }
            }
        }
        watcher?.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        watcher?.resume()
    }
}

extension ShaderStore {
    /// The chain both routes compile. The injected payload reads it from here at
    /// runtime, so editing this one file changes the overlay and injection alike.
    func installEffectChain() throws {
        let destination = directory.appendingPathComponent("EffectChain.metal")
        guard let bundled = Bundle.main.url(forResource: "EffectChain", withExtension: "metal"),
              let source = try? String(contentsOf: bundled, encoding: .utf8) else {
            return
        }
        let existing = try? String(contentsOf: destination, encoding: .utf8)
        guard existing != source else { return }
        try source.write(to: destination, atomically: true, encoding: .utf8)
    }
}

private extension ShaderStore {
    /// Writes the bundled shader when absent, and replaces one left by an older
    /// build. The uniform layout is a contract between this file and
    /// `MetalRenderer`; a stale shader compiles but reads the wrong fields.
    func installDefaultIfNeeded() throws {
        let file = directory.appendingPathComponent(ShaderStore.filename)
        let existing = try? String(contentsOf: file, encoding: .utf8)
        if let existing, existing.contains(ShaderSource.versionMarker) { return }

        if existing != nil {
            var backup = directory.appendingPathComponent("\(ShaderStore.filename).bak")
            var suffix = 2
            while FileManager.default.fileExists(atPath: backup.path) {
                backup = directory.appendingPathComponent("\(ShaderStore.filename).bak\(suffix)")
                suffix += 1
            }
            try? FileManager.default.moveItem(at: file, to: backup)
            NSLog("MetalShade: replaced a shader from an older build; previous kept as \(backup.lastPathComponent)")
        }
        try ShaderSource.defaultMetal.write(to: file, atomically: true, encoding: .utf8)
    }
}

enum ShaderSource {
    /// Bump whenever the uniform layout or entry points change.
    static let versionMarker = "MetalShade shader v2"

    static let defaultMetal = #"""
    // MetalShade shader v2
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut { float4 position [[position]]; float2 uv; };
    struct EffectUniforms {
        float intensity; float3 padding;
        float4 domainMin; float4 domainMax;
        float4 colorAdjust; // brightness, contrast, saturation, temperature
        float4 debug;       // x: tint strength, yzw: tint colour
    };

    // Deliberately unmissable. Judging a sharpening filter by eye cannot
    // distinguish "the shader did nothing" from "the overlay never reached the
    // screen"; a strong tint answers that in one glance.
    float3 debugTint(float3 c, constant EffectUniforms& u) {
        if (u.debug.x <= 0.0) { return c; }
        return mix(c, u.debug.yzw, u.debug.x);
    }
    vertex VertexOut fullscreenVertex(uint id [[vertex_id]]) {
        float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VertexOut out; out.position = float4(positions[id], 0.0, 1.0);
        out.uv = float2((positions[id].x + 1.0) * 0.5, 1.0 - (positions[id].y + 1.0) * 0.5);
        return out;
    }
    float3 basic(float3 c, constant EffectUniforms& u) {
        c += u.colorAdjust.x;
        c = (c - 0.5) * u.colorAdjust.y + 0.5;
        float l = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(float3(l), c, u.colorAdjust.z);
        c += u.colorAdjust.w * float3(0.05, 0.0, -0.05);
        return clamp(c, 0.0, 1.0);
    }
    fragment float4 casFragment(VertexOut in [[stage_in]], texture2d<float> input [[texture(0)]], constant EffectUniforms& u [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 px = 1.0 / float2(input.get_width(), input.get_height());
        float3 c = input.sample(s, in.uv).rgb;
        float3 n = input.sample(s, in.uv + float2(0, -px.y)).rgb;
        float3 e = input.sample(s, in.uv + float2(px.x, 0)).rgb;
        float3 w = input.sample(s, in.uv - float2(px.x, 0)).rgb;
        float3 so = input.sample(s, in.uv + float2(0, px.y)).rgb;
        float3 average = (n + e + w + so) * 0.25;
        float localRange = max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b);
        float adaptive = u.intensity * (1.0 - smoothstep(0.2, 0.9, localRange));
        return float4(debugTint(basic(c + (c - average) * adaptive, u), u), 1.0);
    }
    fragment float4 lutFragment(VertexOut in [[stage_in]], texture2d<float> input [[texture(0)]], texture3d<float> lut [[texture(1)]], constant EffectUniforms& u [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float3 c = input.sample(s, in.uv).rgb;
        float3 coord = clamp((c - u.domainMin.xyz) / max(u.domainMax.xyz - u.domainMin.xyz, float3(0.0001)), 0.0, 1.0);
        float3 graded = lut.sample(s, coord).rgb;
        return float4(debugTint(basic(mix(c, graded, u.intensity), u), u), 1.0);
    }
    """#
}
