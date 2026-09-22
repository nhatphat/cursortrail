#include <metal_stdlib>
using namespace metal;

struct TrailVertex {
    float2 center;
    float2 normal;
    float side;
    float birthTime;
};

// Field order and padding are mirrored by `Uniforms` in TrailRenderer.swift.
// The two float4s sit last so both land on their natural 16-byte alignment in
// either language; `pad` keeps the first of them there.
struct Uniforms {
    float2 viewport;
    float headWidth;
    float widthScale;
    float alphaScale;
    float glowSoftness;
    float now;
    float lifetime;
    float hueSpread;
    float hueSpeed;
    uint coloring;
    float pad;
    float4 color;
    float4 tailColor;
};

// Mirrors TrailColoring in TrailModes.swift.
constant uint kColoringSolid = 0u;
constant uint kColoringGradient = 1u;
constant uint kColoringRainbow = 2u;

struct RasterOut {
    float4 position [[position]];
    float side;
    float age01;
};

static float3 hsv2rgb(float h, float s, float v)
{
    float3 k = fract(h + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0;
    return v * mix(float3(1.0), clamp(abs(k) - 1.0, 0.0, 1.0), s);
}

vertex RasterOut trailVertex(
    uint vid [[vertex_id]],
    const device TrailVertex *vertices [[buffer(0)]],
    constant Uniforms &u [[buffer(1)]])
{
    TrailVertex v = vertices[vid];
    float age01 = clamp((u.now - v.birthTime) / max(u.lifetime, 0.001), 0.0, 1.0);
    float life = 1.0 - age01;
    float widthCurve = mix(0.16, 1.0, life * life);
    float halfWidth = 0.5 * u.headWidth * u.widthScale * widthCurve;
    float2 pixel = v.center + v.normal * v.side * halfWidth;

    float2 ndc;
    ndc.x = (pixel.x / u.viewport.x) * 2.0 - 1.0;
    ndc.y = (pixel.y / u.viewport.y) * 2.0 - 1.0;

    RasterOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.side = v.side;
    out.age01 = age01;
    return out;
}

fragment float4 trailFragment(RasterOut in [[stage_in]], constant Uniforms &u [[buffer(0)]])
{
    float life = 1.0 - in.age01;
    float temporal = life * life * (3.0 - 2.0 * life);
    float edge = abs(in.side);
    float softness = clamp(u.glowSoftness, 0.05, 1.0);
    float edgeAlpha = 1.0 - smoothstep(1.0 - softness, 1.0, edge);

    // `age01` is how far down the trail this fragment sits, so hue driven by it
    // is anchored to the pointer and scrolls with `now` rather than with the
    // pointer's position on screen.
    float3 rgb;
    float baseAlpha;
    if (u.coloring == kColoringRainbow) {
        rgb = hsv2rgb(fract(in.age01 * u.hueSpread + u.now * u.hueSpeed), 0.85, 1.0);
        baseAlpha = u.color.a;
    } else if (u.coloring == kColoringGradient) {
        float4 c = mix(u.color, u.tailColor, in.age01);
        rgb = c.rgb;
        baseAlpha = c.a;
    } else {
        rgb = u.color.rgb;
        baseAlpha = u.color.a;
    }

    float alpha = baseAlpha * u.alphaScale * temporal * edgeAlpha;
    return float4(rgb, alpha);
}
