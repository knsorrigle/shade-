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
    float4 fog;       // x amount, y depth scale
    float4 fogColour; // rgb
    float4 ao;        // x strength, y radius scale, z bias, w range
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

/// Depth fog: the first effect here that uses scene geometry rather than colour
/// alone.
///
/// Depth is reversed-Z, so distant geometry sits near zero and the whole scene
/// occupies a few thousandths. The scale brings that into 0..1; fog then grows
/// with distance. Sky, which never had geometry written, reads as maximally
/// distant and fogs fully — which is what it should do.
float3 applyFog(float3 c, float depth, constant Uniforms& u) {
    if (u.fog.x <= 0.0) { return c; }
    // Nothing was rendered here. Both sky and the game's own HUD and menus leave
    // depth untouched, and this effect runs after the game has composited them,
    // so without this the interface fogs along with the world. Leaving the sky
    // unfogged is the cost; fogging the menu is not acceptable.
    if (depth <= 0.0) { return c; }
    // Reversed-Z: distance is inversely proportional to depth, not linear in it.
    // Treating depth as linear fogged everything past a few metres solid, because
    // the entire scene occupies a few thousandths at the near end of the range.
    float distance = 1.0 / max(depth, 1e-6);
    // Exponential falloff, the standard atmospheric model: near stays clear and
    // density accumulates with distance rather than switching on at a threshold.
    float density = 1.0 - exp(-distance * u.fog.y);
    return mix(c, u.fogColour.rgb, saturate(density) * u.fog.x);
}

/// Screen-space ambient occlusion from depth alone.
///
/// No surface normals are provided — a hook at presentation sees a finished
/// colour image and a depth buffer — so they are reconstructed from the depth
/// gradient. That matters more than it sounds: without a normal, the only test
/// available is "is this neighbour nearer than the centre", and on any surface
/// tilting away from the camera roughly half the neighbours always are. Every
/// flat surface then reads as half-occluded and darkens uniformly, which no
/// amount of bias tuning removes because the error depends on the tilt.
///
/// With a normal, occlusion is only counted for samples above the surface's own
/// tangent plane, so a flat plane occludes itself by nothing at all.

/// A position in a pseudo view space. The lateral scale is arbitrary — the true
/// one needs the projection's field of view — but it is applied consistently to
/// the centre and its neighbours, so directions and angles between them are
/// correct even though absolute units are not.
float3 depthPosition(depth2d<float> tex, sampler s, float2 uv, float aspect) {
    float d = tex.sample(s, uv);
    float distance = (d > 0.0) ? (1.0 / d) : 0.0;
    return float3((uv.x - 0.5) * aspect * distance, (uv.y - 0.5) * distance, distance);
}

/// Reconstructs a normal from neighbouring depths, taking the nearer neighbour
/// on each axis so a silhouette edge does not drag the normal with it.
float3 reconstructNormal(depth2d<float> tex, sampler s, float2 uv, float2 texel, float aspect) {
    float3 centre = depthPosition(tex, s, uv, aspect);
    float3 right  = depthPosition(tex, s, uv + float2(texel.x, 0), aspect);
    float3 left   = depthPosition(tex, s, uv - float2(texel.x, 0), aspect);
    float3 down   = depthPosition(tex, s, uv + float2(0, texel.y), aspect);
    float3 up     = depthPosition(tex, s, uv - float2(0, texel.y), aspect);

    float3 dx = (abs(right.z - centre.z) < abs(centre.z - left.z)) ? (right - centre) : (centre - left);
    float3 dy = (abs(down.z - centre.z) < abs(centre.z - up.z)) ? (down - centre) : (centre - up);

    float3 normal = cross(dx, dy);
    float len = length(normal);
    return (len > 1e-8) ? (normal / len) : float3(0.0, 0.0, 1.0);
}

float ambientOcclusion(depth2d<float> depthTex, sampler s, float2 uv, constant Uniforms& u) {
    float centreDepth = depthTex.sample(s, uv);
    // Nothing rendered here: sky, and the game's own interface. Both must be left
    // alone, since this runs after the interface has been composited.
    if (centreDepth <= 0.0) { return 1.0; }

    float width = float(depthTex.get_width());
    float height = float(depthTex.get_height());
    float aspect = width / height;
    float2 texel = float2(1.0 / width, 1.0 / height);

    float3 centre = depthPosition(depthTex, s, uv, aspect);
    float3 normal = reconstructNormal(depthTex, s, uv, texel, aspect);

    // A fixed world radius covers fewer pixels further away, which is what stops
    // distant geometry from smearing.
    float radius = clamp(u.ao.y / centre.z, 0.0015, 0.03);

    const float2 taps[8] = {
        float2( 1.0,  0.0), float2( 0.707,  0.707), float2( 0.0,  1.0), float2(-0.707,  0.707),
        float2(-1.0,  0.0), float2(-0.707, -0.707), float2( 0.0, -1.0), float2( 0.707, -0.707)
    };
    // Rotate the pattern per pixel, or eight fixed directions band visibly. The
    // grain this produces is removed by blurring the occlusion pass.
    float angle = fract(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453) * 6.2831853;
    float cosA = cos(angle), sinA = sin(angle);

    float range = u.ao.w * centre.z * 0.02;
    float occlusion = 0.0;
    for (int i = 0; i < 8; ++i) {
        float2 tap = float2(taps[i].x * cosA - taps[i].y * sinA,
                            taps[i].x * sinA + taps[i].y * cosA);
        float2 sampleUV = uv + tap * radius;
        float sampled = depthTex.sample(s, sampleUV);
        if (sampled <= 0.0) { continue; }

        float3 offset = depthPosition(depthTex, s, sampleUV, aspect) - centre;
        float length2 = dot(offset, offset);
        if (length2 < 1e-10) { continue; }
        float distance = sqrt(length2);

        // How far the sample sits above this surface's own tangent plane. A
        // neighbour lying on the same plane gives zero, which is what makes a
        // flat surface occlude itself by nothing.
        float above = dot(normal, offset / distance);
        if (above <= u.ao.z) { continue; }

        // Nearby occluders count for more than distant ones.
        occlusion += above * saturate(range / distance);
    }
    return 1.0 - saturate(occlusion / 8.0) * u.ao.x;
}

/// Writes occlusion to its own target so it can be blurred before use.
///
/// The estimator rotates its sample pattern per pixel, which trades banding for
/// high-frequency grain. Applying that directly to the image looks like noise;
/// blurring it first is what makes it read as shading.
fragment float4 aoFragment(VertexOut in [[stage_in]],
                           depth2d<float> sceneDepth [[texture(0)]],
                           constant Uniforms& u [[buffer(0)]]) {
    constexpr sampler depthSampler(address::clamp_to_edge, filter::nearest);
    float ao = ambientOcclusion(sceneDepth, depthSampler, in.uv, u);
    return float4(ao, ao, ao, 1.0);
}

fragment float4 compositeFragment(VertexOut in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> bloom [[texture(1)]],
                                  texture3d<float> lut [[texture(2)]],
                                  depth2d<float> sceneDepth [[texture(3)]],
                                  texture2d<float> occlusion [[texture(4)]],
                                  constant Uniforms& u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    constexpr sampler depthSampler(address::clamp_to_edge, filter::nearest);
    float3 c = src.sample(s, in.uv).rgb;

    // Occlusion first: it is a lighting term, so it belongs before the effects
    // that shape and grade the light. Sampled from the blurred pass rather than
    // computed here, or its per-pixel noise lands directly on the image.
    if (u.ao.x > 0.0) { c *= occlusion.sample(s, in.uv).r; }
    c = applySharpen(src, s, in.uv, c, u.a.x);
    c = applyClarity(src, s, in.uv, c, u.a.y);
    if (u.a.w > 0.0) { c += bloom.sample(s, in.uv).rgb * u.a.w; }
    // Fog before tone mapping, so the added light is shaped by the curve rather
    // than sitting flat on top of it.
    c = applyFog(c, sceneDepth.sample(depthSampler, in.uv), u);
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
