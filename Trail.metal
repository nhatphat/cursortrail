#include <metal_stdlib>
using namespace metal;

struct TrailVertex {
    float2 center;
    float2 normal;
    float side;
    float birthTime;
    /// Pointer speed when this point was sampled, normalised to 0...1. Stored
    /// per point rather than applied per frame: a global multiplier would make
    /// the whole trail -- including the part drawn seconds ago -- swell and
    /// shrink with the pointer's current speed, which reads as breathing. The
    /// trail should be thick where the pointer *was* fast.
    float speed01;
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
    /// How much of the width a mode hands over to pointer speed. 0 keeps the
    /// original constant width.
    float speedResponse;
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
    // Thin when the pointer was crawling, fuller when it was flicking.
    float speedCurve = mix(0.62, 1.5, v.speed01);
    float widthScale = u.widthScale * mix(1.0, speedCurve, clamp(u.speedResponse, 0.0, 1.0));
    float halfWidth = 0.5 * u.headWidth * widthScale * widthCurve;
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

// ---------------------------------------------------------------------------
// Particles
//
// A particle's whole path is decided when it spawns, so its six vertices are
// written once and never touched again. Position is evaluated analytically
// from the vertex's age -- the same trick the trail uses for its fade, for the
// same reason: the CPU does no per-frame work, and a frame that draws a
// thousand particles costs one draw call and no buffer traffic.
// ---------------------------------------------------------------------------

// Physics rides on the particle, not on the uniforms, so one mode can run
// several emitters -- confetti and sparks, with different lifetimes, gravity
// and shape -- and still have all of them drawn by a single call.
struct ParticleVertex {
    float2 origin;
    float2 velocity;
    float birthTime;
    /// Negative means "use the uniform colour" rather than a hue of its own.
    float hue;
    float size;
    float spin;
    /// Which corner of the quad this vertex is, in -1...1.
    float2 corner;
    float saturation;
    float gravity;
    float lifetime;
    /// 0 draws a soft square, 1 a soft disc; confetti wants paper, sparks want
    /// points.
    float roundness;
    /// Non-zero squashes the quad across its spin, so a confetto reads as a
    /// flat piece of paper flipping over rather than a badge rotating.
    float flutter;
};

struct ParticleUniforms {
    float2 viewport;
    float now;
    float pad;
    float4 color;
};

struct ParticleRasterOut {
    float4 position [[position]];
    float2 corner;
    float age01;
    float hue;
    float saturation;
    float roundness;
};

vertex ParticleRasterOut particleVertex(
    uint vid [[vertex_id]],
    const device ParticleVertex *vertices [[buffer(0)]],
    constant ParticleUniforms &u [[buffer(1)]])
{
    ParticleVertex v = vertices[vid];
    float t = max(u.now - v.birthTime, 0.0);
    float age01 = clamp(t / max(v.lifetime, 0.001), 0.0, 1.0);

    // Ballistic, with no drag term: drag has no closed form this cheap, and at
    // these speeds and lifetimes nobody can tell it is missing.
    float2 centre = v.origin + v.velocity * t + float2(0.0, 0.5 * v.gravity * t * t);

    float angle = v.spin * t;
    float ca = cos(angle);
    float sa = sin(angle);
    float2 c = v.corner;
    // Squash across the spin axis first, then rotate, so the flutter reads as
    // the sheet turning edge-on rather than as the quad being scaled.
    c.x *= mix(1.0, ca, v.flutter);
    float2 rotated = float2(c.x * ca - c.y * sa, c.x * sa + c.y * ca);

    float scale = v.size * (1.0 - 0.35 * age01);
    float2 pixel = centre + rotated * scale;

    float2 ndc;
    ndc.x = (pixel.x / u.viewport.x) * 2.0 - 1.0;
    ndc.y = (pixel.y / u.viewport.y) * 2.0 - 1.0;

    ParticleRasterOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.corner = v.corner;
    out.age01 = age01;
    out.hue = v.hue;
    out.saturation = v.saturation;
    out.roundness = v.roundness;
    return out;
}

fragment float4 particleFragment(ParticleRasterOut in [[stage_in]], constant ParticleUniforms &u [[buffer(0)]])
{
    float2 q = abs(in.corner);
    float box = max(q.x, q.y);
    float disc = length(in.corner);
    float d = mix(box, disc, clamp(in.roundness, 0.0, 1.0));
    float shape = 1.0 - smoothstep(0.72, 1.0, d);

    float life = 1.0 - in.age01;
    // Hold full brightness for the first part of the life, then fall away, so
    // a burst reads as a flash that decays rather than a slow dissolve.
    float fade = smoothstep(0.0, 0.35, life);

    float3 rgb = in.hue >= 0.0 ? hsv2rgb(in.hue, in.saturation, 1.0) : u.color.rgb;
    return float4(rgb, u.color.a * shape * fade);
}

// ---------------------------------------------------------------------------
// Ripples
//
// A ring that expands out of a click and fades. Like a particle it is written
// once and evaluated from its age, and it shares the particle uniforms; only
// the shape differs, so it gets its own pair of functions rather than another
// branch in the particle fragment.
// ---------------------------------------------------------------------------

struct RippleVertex {
    float2 origin;
    float2 corner;
    float birthTime;
    float maxRadius;
    float thickness;
    float lifetime;
};

struct RippleRasterOut {
    float4 position [[position]];
    float2 corner;
    float age01;
    /// Where the ring sits and how wide it is, both as a fraction of the quad's
    /// half-extent, so the fragment needs no pixel measurements of its own.
    float radiusRatio;
    float thicknessRatio;
};

vertex RippleRasterOut rippleVertex(
    uint vid [[vertex_id]],
    const device RippleVertex *vertices [[buffer(0)]],
    constant ParticleUniforms &u [[buffer(1)]])
{
    RippleVertex v = vertices[vid];
    float t = max(u.now - v.birthTime, 0.0);
    float age01 = clamp(t / max(v.lifetime, 0.001), 0.0, 1.0);

    // Out fast, then easing off: a ring that expands linearly reads as a
    // growing circle rather than as something the click set off.
    float ease = 1.0 - pow(1.0 - age01, 3.0);
    float radius = v.maxRadius * ease;
    float outer = max(radius + v.thickness, 0.001);

    float2 pixel = v.origin + v.corner * outer;
    float2 ndc;
    ndc.x = (pixel.x / u.viewport.x) * 2.0 - 1.0;
    ndc.y = (pixel.y / u.viewport.y) * 2.0 - 1.0;

    RippleRasterOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.corner = v.corner;
    out.age01 = age01;
    out.radiusRatio = radius / outer;
    out.thicknessRatio = v.thickness / outer;
    return out;
}

fragment float4 rippleFragment(RippleRasterOut in [[stage_in]], constant ParticleUniforms &u [[buffer(0)]])
{
    float d = length(in.corner);
    float band = abs(d - in.radiusRatio) / max(in.thicknessRatio, 0.001);
    float shape = 1.0 - smoothstep(0.0, 1.0, band);
    float life = 1.0 - in.age01;
    return float4(u.color.rgb, u.color.a * shape * life * life);
}
