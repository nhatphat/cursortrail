#include <metal_stdlib>
using namespace metal;

struct TrailVertex {
    float2 center;
    float2 normal;
    float side;
    float birthTime;
};

struct Uniforms {
    float2 viewport;
    float headWidth;
    float widthScale;
    float alphaScale;
    float glowSoftness;
    float now;
    float lifetime;
    float4 color;
};

struct RasterOut {
    float4 position [[position]];
    float side;
    float age01;
};

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
    float alpha = u.color.a * u.alphaScale * temporal * edgeAlpha;
    return float4(u.color.rgb, alpha);
}
