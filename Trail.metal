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
    /// Width as a fraction of length. 1 is the square quad every particle used
    /// to be; below that the piece is a ribbon, and because the mask below
    /// works in the same unit square, the drawn shape narrows with it.
    float aspect;
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
    // Narrow the quad, then squash across the spin axis, then rotate, so the
    // flutter reads as the sheet turning edge-on rather than as the quad being
    // scaled -- and so a ribbon tumbles about its long axis like paper.
    c.x *= v.aspect * mix(1.0, ca, v.flutter);
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
    /// How long one wave takes to travel out to `maxRadius`.
    float waveLifetime;
    /// Gap between one wave leaving the centre and the next.
    float waveDelay;
    float waveCount;
};

struct RippleRasterOut {
    float4 position [[position]];
    float2 corner;
    /// Half-extent of the quad in pixels, so the fragment can turn its corner
    /// back into a distance from the centre.
    float extent;
    float age;
    float maxRadius;
    float thickness;
    float waveLifetime;
    float waveDelay;
    float waveCount;
};

vertex RippleRasterOut rippleVertex(
    uint vid [[vertex_id]],
    const device RippleVertex *vertices [[buffer(0)]],
    constant ParticleUniforms &u [[buffer(1)]])
{
    RippleVertex v = vertices[vid];

    // The quad does not grow. Every wave lives inside one fixed square and the
    // fragment decides where each ring is, which is what lets a single quad
    // carry a whole train of waves instead of one ring per quad.
    float extent = v.maxRadius + v.thickness;
    float2 pixel = v.origin + v.corner * extent;

    float2 ndc;
    ndc.x = (pixel.x / u.viewport.x) * 2.0 - 1.0;
    ndc.y = (pixel.y / u.viewport.y) * 2.0 - 1.0;

    RippleRasterOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.corner = v.corner;
    out.extent = extent;
    out.age = max(u.now - v.birthTime, 0.0);
    out.maxRadius = v.maxRadius;
    out.thickness = v.thickness;
    out.waveLifetime = v.waveLifetime;
    out.waveDelay = v.waveDelay;
    out.waveCount = v.waveCount;
    return out;
}

fragment float4 rippleFragment(RippleRasterOut in [[stage_in]], constant ParticleUniforms &u [[buffer(0)]])
{
    float radius = length(in.corner) * in.extent;
    float sum = 0.0;

    // Each wave is the same ring launched a little later, so they chase each
    // other outward the way a dropped stone sends them.
    int waves = int(in.waveCount);
    for (int i = 0; i < waves; ++i) {
        float age01 = (in.age - float(i) * in.waveDelay) / max(in.waveLifetime, 0.001);
        if (age01 < 0.0 || age01 > 1.0) { continue; }

        // Out fast, then easing off: a ring that expands linearly reads as a
        // growing circle rather than as something the click set off.
        float ease = 1.0 - pow(1.0 - age01, 3.0);
        float band = abs(radius - in.maxRadius * ease) / max(in.thickness, 0.001);
        float ring = 1.0 - smoothstep(0.0, 1.0, band);
        float fade = (1.0 - age01) * (1.0 - age01);

        // Later waves start fainter so the first one stays the leading edge.
        sum += ring * fade * pow(0.68, float(i));
    }

    return float4(u.color.rgb, u.color.a * min(sum, 1.0) * 0.9);
}

// ---------------------------------------------------------------------------
// Companion
//
// A cat that walks the pointer's own path. Unlike everything above it is one
// persistent thing rather than a crowd of short-lived ones, so it is a single
// quad whose uniforms the CPU rewrites each frame -- one struct of traffic --
// and the fragment draws the whole animal as a signed distance field. No
// texture, no atlas, no frames: the poses are the same handful of shapes with
// different numbers, which is what lets sitting down and lying to sleep be
// smooth blends rather than a cut between sprites.
// ---------------------------------------------------------------------------

struct CatUniforms {
    float2 viewport;
    /// Centre of the quad, in pixels, y up.
    float2 position;
    /// Half-extent of the quad in pixels.
    float size;
    /// +1 walking right, -1 walking left. Flips the local x, so the field
    /// below only ever has to draw a cat facing right.
    float facing;
    /// Stride phase in radians, advanced by distance walked rather than by
    /// time, so the legs stay in step with the ground at any speed.
    float phase;
    /// How much of the leg swing to apply: 0 standing, 1 at a full run.
    float run01;
    float sit01;
    float sleep01;
    float now;
    float pad;
    float4 color;
};

struct CatRasterOut {
    float4 position [[position]];
    float2 local;
};

static float smin(float a, float b, float k)
{
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

/// Exact for circles, close enough everywhere else at this size: the field is
/// only ever thresholded at zero, never marched along.
static float sdEllipse(float2 p, float2 c, float2 r)
{
    // Floored rather than trusted: a pose that blends a part down to nothing
    // would otherwise divide by zero, and one NaN takes the whole field --
    // and with it the whole cat -- down with it.
    r = max(r, float2(1e-3));
    float2 q = (p - c) / r;
    return (length(q) - 1.0) * min(r.x, r.y);
}

static float sdCapsule(float2 p, float2 a, float2 b, float ra, float rb)
{
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-5), 0.0, 1.0);
    return length(pa - ba * h) - mix(ra, rb, h);
}

static float sdTriangle(float2 p, float2 p0, float2 p1, float2 p2)
{
    float2 e0 = p1 - p0, e1 = p2 - p1, e2 = p0 - p2;
    float2 v0 = p - p0, v1 = p - p1, v2 = p - p2;
    float2 pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
    float2 pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
    float2 pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
    float s = sign(e0.x * e2.y - e0.y * e2.x);
    float2 d = min(min(float2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
                       float2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))),
                       float2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)));
    return -sqrt(d.x) * sign(d.y);
}

static float2 rotateAbout(float2 p, float2 pivot, float angle)
{
    float c = cos(angle), s = sin(angle);
    float2 q = p - pivot;
    return pivot + float2(q.x * c - q.y * s, q.x * s + q.y * c);
}

constant float2 kCatQuad[6] = {
    float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
    float2(-1.0,  1.0), float2(1.0, -1.0), float2( 1.0, 1.0),
};

vertex CatRasterOut catVertex(uint vid [[vertex_id]], constant CatUniforms &u [[buffer(1)]])
{
    float2 c = kCatQuad[vid];
    float2 pixel = u.position + c * u.size;

    float2 ndc;
    ndc.x = (pixel.x / u.viewport.x) * 2.0 - 1.0;
    ndc.y = (pixel.y / u.viewport.y) * 2.0 - 1.0;

    CatRasterOut out;
    out.position = float4(ndc, 0.0, 1.0);
    // Mirror the field rather than the geometry, so facing costs nothing.
    out.local = float2(c.x * u.facing, c.y);
    return out;
}

fragment float4 catFragment(CatRasterOut in [[stage_in]], constant CatUniforms &u [[buffer(0)]])
{
    float2 p = in.local;
    float s = clamp(u.sit01, 0.0, 1.0);
    float z = clamp(u.sleep01, 0.0, 1.0);
    float up = (1.0 - s) * (1.0 - z);

    // Every pose is the same parts at different numbers, so running blends
    // into sitting and sitting into sleeping: the cat visibly folds itself up
    // rather than cutting between three drawings. `mix(mix(run, sit), sleep)`
    // reads top to bottom as the order it happens in.
    float2 bodyC = mix(mix(float2(-0.06, -0.14), float2(-0.02, -0.22), s), float2(-0.06, -0.56), z);
    float2 bodyR = mix(mix(float2( 0.42,  0.17), float2( 0.25,  0.33), s), float2( 0.48,  0.20), z);
    bodyR.y += (0.008 + 0.020 * z) * sin(u.now * (2.4 - 1.2 * z));
    // The whole animal rises and falls once per stride, which is most of what
    // separates running from sliding.
    bodyC.y += 0.025 * abs(sin(u.phase)) * u.run01 * up;

    float2 headC = mix(mix(float2(0.50, 0.20), float2(0.20, 0.34), s), float2(0.48, -0.50), z);
    float headR = mix(mix(0.21, 0.22, s), 0.21, z);
    // The head bobs with the stride; a body that only slides reads as a decal.
    headC.y += 0.03 * sin(u.phase * 2.0) * u.run01 * up;

    // Diagonal gait: the near front leg swings with the far hind one, which is
    // what stops four legs reading as two pairs of scissors.
    float swingA =  0.20 * sin(u.phase) * u.run01 * up;
    float swingB = -0.20 * sin(u.phase) * u.run01 * up;
    // A foot that only slides back and forth skates. Lifting it on the half of
    // the cycle it swings forward is what makes the stride land.
    float liftA = max(0.0,  sin(u.phase)) * 0.13 * u.run01 * up;
    float liftB = max(0.0, -sin(u.phase)) * 0.13 * u.run01 * up;
    float legR = mix(mix(0.050, 0.056, s), 0.030, z);

    // Sitting folds the hind legs under the haunch and stands the front pair
    // up; sleeping walks every foot back into the body, where the capsule
    // disappears inside the ellipse instead of having to be scaled away.
    float2 fnHip  = mix(mix(float2( 0.27, -0.20), float2( 0.16, -0.14), s), bodyC + float2( 0.22, 0.0), z);
    float2 fnFoot = mix(mix(float2( 0.27 + swingA, -0.84 + liftA), float2( 0.20, -0.82), s), bodyC + float2( 0.30, -0.14), z);
    float2 ffHip  = mix(mix(float2( 0.20, -0.20), float2( 0.09, -0.14), s), bodyC + float2( 0.14, 0.0), z);
    float2 ffFoot = mix(mix(float2( 0.20 + swingB, -0.82 + liftB), float2( 0.12, -0.82), s), bodyC + float2( 0.22, -0.12), z);
    float2 hnHip  = mix(mix(float2(-0.30, -0.20), float2(-0.26, -0.38), s), bodyC + float2(-0.20, 0.0), z);
    float2 hnFoot = mix(mix(float2(-0.30 + swingB, -0.84 + liftB), float2(-0.08, -0.80), s), bodyC + float2(-0.30, -0.12), z);
    float2 hfHip  = mix(mix(float2(-0.37, -0.20), float2(-0.32, -0.38), s), bodyC + float2(-0.26, 0.0), z);
    float2 hfFoot = mix(mix(float2(-0.37 + swingA, -0.82 + liftA), float2(-0.16, -0.80), s), bodyC + float2(-0.34, -0.10), z);

    // The haunch only exists sitting: it is what makes a seated cat read as
    // folded rather than as a standing one that shrank. Out of the pose it is
    // not scaled away but parked inside the body, where it adds nothing.
    float sitOnly = s * (1.0 - z);
    float haunchR = mix(0.02, 0.29, sitOnly);
    float2 haunchC = mix(bodyC, float2(-0.22, -0.48), sitOnly);

    // Four points rather than three: two capsules meet at too sharp an angle
    // to read as a tail, and the third joint is what curves it.
    float wag = sin(u.now * 2.4 + u.phase * 0.4);
    float2 t0 = mix(mix(float2(-0.42, -0.14), float2(-0.24, -0.56), s), float2(-0.50, -0.64), z);
    float2 t1 = mix(mix(float2(-0.66, -0.06 + 0.05 * wag * up), float2(-0.42, -0.78), s), float2(-0.30, -0.84), z);
    float2 t2 = mix(mix(float2(-0.80,  0.18 + 0.09 * wag * up), float2(-0.02, -0.86), s), float2( 0.16, -0.86), z);
    float2 t3 = mix(mix(float2(-0.64,  0.40 + 0.13 * wag * up), float2( 0.32, -0.74 + 0.05 * wag), s), float2( 0.46, -0.74), z);

    float d = sdEllipse(p, bodyC, bodyR);
    d = smin(d, sdEllipse(p, haunchC, float2(haunchR, haunchR)), 0.07);
    // Far legs first, so the near pair sits on top of them in the silhouette.
    d = smin(d, sdCapsule(p, ffHip, ffFoot, legR, legR * 0.8), 0.05);
    d = smin(d, sdCapsule(p, hfHip, hfFoot, legR, legR * 0.8), 0.05);
    d = smin(d, sdCapsule(p, fnHip, fnFoot, legR, legR * 0.8), 0.05);
    d = smin(d, sdCapsule(p, hnHip, hnFoot, legR, legR * 0.8), 0.05);
    d = smin(d, sdCapsule(p, t0, t1, 0.075, 0.062), 0.05);
    d = smin(d, sdCapsule(p, t1, t2, 0.062, 0.050), 0.04);
    d = smin(d, sdCapsule(p, t2, t3, 0.050, 0.034), 0.04);
    d = smin(d, sdCapsule(p, bodyC + float2(0.24, 0.04), headC + float2(-0.06, -0.08), 0.13, 0.11), 0.07);
    d = smin(d, sdEllipse(p, headC, float2(headR * 1.05, headR * 0.95)), 0.08);

    // Ears lie back as the cat goes down, which is most of what tells a
    // sleeping cat from a sitting one at this size.
    float earTilt = mix(0.0, -0.55, z);
    float2 e0 = rotateAbout(headC + float2( 0.01,  0.12), headC, earTilt);
    float2 e1 = rotateAbout(headC + float2( 0.19,  0.05), headC, earTilt);
    float2 e2 = rotateAbout(headC + float2( 0.13,  0.37), headC, earTilt);
    float2 e3 = rotateAbout(headC + float2(-0.19,  0.05), headC, earTilt);
    float2 e4 = rotateAbout(headC + float2(-0.01,  0.12), headC, earTilt);
    float2 e5 = rotateAbout(headC + float2(-0.12,  0.35), headC, earTilt);
    d = min(d, sdTriangle(p, e0, e1, e2));
    d = min(d, sdTriangle(p, e3, e4, e5));

    // The eye is a hole in the silhouette rather than a second colour, so the
    // cat stays one flat shape in whatever colour the trail is.
    float2 eyeC = headC + float2(0.10, 0.04);
    float eyeOpen = sdEllipse(p, eyeC, float2(0.040, 0.048));
    float eyeShut = sdCapsule(p, eyeC + float2(-0.06, 0.0), eyeC + float2(0.06, 0.0), 0.015, 0.015);
    d = max(d, -mix(eyeOpen, eyeShut, z));

    float aa = max(fwidth(d), 1e-4);
    float alpha = clamp(0.5 - d / aa, 0.0, 1.0);
    return float4(u.color.rgb, u.color.a * alpha);
}
