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
        let defaultFile = directory.appendingPathComponent(Self.filename)
        if !FileManager.default.fileExists(atPath: defaultFile.path) {
            try ShaderSource.defaultMetal.write(to: defaultFile, atomically: true, encoding: .utf8)
        }
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

enum ShaderSource {
    static let defaultMetal = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut { float4 position [[position]]; float2 uv; };
    struct EffectUniforms {
        float intensity; float3 padding;
        float4 domainMin; float4 domainMax;
        float4 colorAdjust; // brightness, contrast, saturation, temperature
    };
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
        return float4(basic(c + (c - average) * adaptive, u), 1.0);
    }
    fragment float4 lutFragment(VertexOut in [[stage_in]], texture2d<float> input [[texture(0)]], texture3d<float> lut [[texture(1)]], constant EffectUniforms& u [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float3 c = input.sample(s, in.uv).rgb;
        float3 coord = clamp((c - u.domainMin.xyz) / max(u.domainMax.xyz - u.domainMin.xyz, float3(0.0001)), 0.0, 1.0);
        float3 graded = lut.sample(s, coord).rgb;
        return float4(basic(mix(c, graded, u.intensity), u), 1.0);
    }
    """#
}
