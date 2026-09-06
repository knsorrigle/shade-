// MetalShade effect chain — v3
//
// One source of truth. The overlay and the injected payload both compile this
// file, so a change reaches whichever route a game happens to use.
//
// Order: sharpen -> clarity -> bloom -> filmic tone -> grade -> LUT
// Every stage is skipped when its strength is neutral.
//
// Nothing here can depend on scene depth. Both routes see a finished colour
// image, so ambient occlusion, depth of field and depth fog are out of reach by
// construction, not by omission.
#include <metal_stdlib>
using namespace metal;

struct VertexOut { float4 position [[position]]; float2 uv; };

// Laid out entirely as float4 so the C, Swift and Metal views cannot disagree
// about alignment. Metal pads float3 to 16 bytes, which has already caused one
// silent bug here.
struct Uniforms {
    float4 a;         // x sharpen, y clarity, z tone, w bloom intensity
    float4 b;         // x bloom threshold, y exposure, z gamma, w vibrance
    float4 colour;    // brightness, contrast, saturation, temperature
    float4 tint;      // rgb tint colour, w enabled
    float4 lut;       // x mix
    float4 domainMin; // LUT input domain
    float4 domainMax;
};

struct BlurParams { float4 direction; };  // xy = step in UV space

constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);

vertex VertexOut fullscreenVertex(uint id [[vertex_id]]) {
    float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(p[id], 0, 1);
    out.uv = float2((p[id].x + 1) * 0.5, 1 - (p[id].y + 1) * 0.5);
    return out;
}

// MARK: - Bloom

/// Keeps only what is brighter than the threshold, so bloom follows light
/// sources rather than washing the whole image.
fragment float4 brightPassFragment(VertexOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   constant Uniforms& u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float3 c = src.sample(s, in.uv).rgb;
    float luma = dot(c, kLuma);
    float knee = max(luma - u.b.x, 0.0) / max(luma, 0.0001);
    return float4(c * knee, 1.0);
}

/// One axis of a separable Gaussian. Run twice, horizontally then vertically.
fragment float4 blurFragment(VertexOut in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             constant BlurParams& p [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    const float weights[5] = { 0.227027, 0.194594, 0.121621, 0.054054, 0.016216 };
    float2 step = p.direction.xy;
    float3 sum = src.sample(s, in.uv).rgb * weights[0];
    for (int i = 1; i < 5; ++i) {
        sum += src.sample(s, in.uv + step * float(i)).rgb * weights[i];
        sum += src.sample(s, in.uv - step * float(i)).rgb * weights[i];
    }
    return float4(sum, 1.0);
}

// MARK: - Colour stages

/// Contrast-adaptive sharpening: less where local contrast is already high, so
/// edges do not ring.
float3 applySharpen(texture2d<float> src, sampler s, float2 uv, float3 c, float amount) {
    if (amount <= 0.0) { return c; }
    float2 px = 1.0 / float2(src.get_width(), src.get_height());
    float3 n  = src.sample(s, uv + float2(0, -px.y)).rgb;
    float3 e  = src.sample(s, uv + float2(px.x, 0)).rgb;
    float3 w  = src.sample(s, uv - float2(px.x, 0)).rgb;
    float3 so = src.sample(s, uv + float2(0, px.y)).rgb;
    float3 average = (n + e + w + so) * 0.25;
    float range = max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b);
    return c + (c - average) * (amount * (1.0 - smoothstep(0.2, 0.9, range)));
}

/// Local contrast: an unsharp mask at a wide radius. The radius is what makes
/// this lift midtone structure rather than sharpen edges.
float3 applyClarity(texture2d<float> src, sampler s, float2 uv, float3 c, float amount) {
    if (amount <= 0.0) { return c; }
    float2 px = 4.0 / float2(src.get_width(), src.get_height());
    float3 blur = float3(0.0);
    blur += src.sample(s, uv + float2(-px.x, -px.y)).rgb;
    blur += src.sample(s, uv + float2( px.x, -px.y)).rgb;
    blur += src.sample(s, uv + float2(-px.x,  px.y)).rgb;
    blur += src.sample(s, uv + float2( px.x,  px.y)).rgb;
    blur += src.sample(s, uv + float2(0, -px.y * 2.0)).rgb;
    blur += src.sample(s, uv + float2(0,  px.y * 2.0)).rgb;
    blur += src.sample(s, uv + float2(-px.x * 2.0, 0)).rgb;
    blur += src.sample(s, uv + float2( px.x * 2.0, 0)).rgb;
    blur *= 0.125;
    return c + (dot(c, kLuma) - dot(blur, kLuma)) * amount * 2.0;
}

/// Uncharted 2 filmic curve, normalised so white stays white.
float3 filmicCurve(float3 x) {
    const float A = 0.15, B = 0.50, C = 0.10, D = 0.20, E = 0.02, F = 0.30;
    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
}

float3 applyTone(float3 c, float amount) {
    if (amount <= 0.0) { return c; }
    const float W = 11.2;
    return mix(c, filmicCurve(c * 2.0) / filmicCurve(float3(W)).x, amount);
}

/// Raises saturation most where there is least, so already-saturated colours do
/// not clip.
float3 applyVibrance(float3 c, float amount) {
    if (abs(amount) <= 0.001) { return c; }
    float sat = max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b);
    return mix(float3(dot(c, kLuma)), c, 1.0 + amount * (1.0 - sat));
}

float3 applyGrade(float3 c, constant Uniforms& u) {
    c *= pow(2.0, u.b.y);                                   // exposure, in stops
    c = pow(max(c, 0.0), float3(1.0 / max(u.b.z, 0.0001))); // gamma
    c += u.colour.x;                                        // brightness
    c = (c - 0.5) * u.colour.y + 0.5;                       // contrast
    c = mix(float3(dot(c, kLuma)), c, u.colour.z);          // saturation
    c = applyVibrance(c, u.b.w);
    c += u.colour.w * float3(0.05, 0.0, -0.05);             // temperature
    return c;
}

// MARK: - Composite

fragment float4 compositeFragment(VertexOut in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> bloom [[texture(1)]],
                                  texture3d<float> lut [[texture(2)]],
                                  constant Uniforms& u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float3 c = src.sample(s, in.uv).rgb;

    c = applySharpen(src, s, in.uv, c, u.a.x);
    c = applyClarity(src, s, in.uv, c, u.a.y);
    if (u.a.w > 0.0) { c += bloom.sample(s, in.uv).rgb * u.a.w; }
    c = applyTone(c, u.a.z);
    c = applyGrade(c, u);

    if (u.lut.x > 0.0) {
        float3 span = max(u.domainMax.xyz - u.domainMin.xyz, float3(0.0001));
        float3 coord = clamp((c - u.domainMin.xyz) / span, 0.0, 1.0);
        c = mix(c, lut.sample(s, coord).rgb, u.lut.x);
    }

    if (u.tint.w > 0.5) { c = mix(c, u.tint.rgb, 0.75); }
    return float4(clamp(c, 0.0, 1.0), 1.0);
}
