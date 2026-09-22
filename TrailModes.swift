import Foundation

/// How a mode turns the chosen trail colour into the colour of each fragment.
/// The raw values are the wire format of the `coloring` uniform in Trail.metal,
/// so they cannot be renumbered on their own.
enum TrailColoring: UInt32 {
    case solid = 0
    case gradient = 1
    case rainbow = 2
}

/// What makes a mode emit particles. Movement emits along the pointer's path;
/// tripleClick waits for a burst.
enum ParticleTrigger {
    case movement
    case tripleClick
}

struct ParticleStyle {
    let trigger: ParticleTrigger
    /// Movement only: points of pointer travel between one particle and the
    /// next. Distance rather than time, so a slow drag does not carpet the
    /// screen and a flick does not leave gaps.
    let spacing: Float
    /// tripleClick only: how many particles one burst emits.
    let burstCount: Int
    let speed: ClosedRange<Float>
    /// Half-angle of the emission cone, in radians, measured off straight up.
    /// `.pi` is the whole circle.
    let spread: Float
    /// Pixels per second squared. Negative falls, because the overlay's
    /// coordinate space has y pointing up.
    let gravity: Float
    let lifetime: Float
    let size: Float
    let spin: ClosedRange<Float>
    /// 0 draws soft squares, 1 soft discs.
    let roundness: Float
    let flutter: Bool
    /// Each particle picks its own hue rather than taking the trail's colour.
    let randomHue: Bool
}

struct TrailPassStyle {
    let widthScale: Float
    let alpha: Float
    let softness: Float
}

struct TrailMode {
    let id: String
    let title: String
    let lifetime: Float
    let headWidth: Float
    let coloring: TrailColoring
    /// Gradient only: how far around the hue wheel the tail sits from the head,
    /// in turns. 0.5 is the complementary colour.
    let tailHueShift: Float
    /// Rainbow only: hue turns spanned by one trail length, and hue turns per
    /// second the whole band scrolls.
    let hueSpread: Float
    let hueSpeed: Float
    let passes: [TrailPassStyle]
    let particles: ParticleStyle?

    init(
        id: String,
        title: String,
        lifetime: Float,
        headWidth: Float,
        coloring: TrailColoring = .solid,
        tailHueShift: Float = 0,
        hueSpread: Float = 0,
        hueSpeed: Float = 0,
        passes: [TrailPassStyle],
        particles: ParticleStyle? = nil
    ) {
        self.id = id
        self.title = title
        self.lifetime = lifetime
        self.headWidth = headWidth
        self.coloring = coloring
        self.tailHueShift = tailHueShift
        self.hueSpread = hueSpread
        self.hueSpeed = hueSpeed
        self.passes = passes
        self.particles = particles
    }

    /// False when the mode generates its own hues, and the chosen colour only
    /// contributes its opacity. The menu bar says so rather than looking broken.
    var usesTrailColor: Bool {
        if coloring == .rainbow { return false }
        if let particles, particles.randomHue, passes.isEmpty { return false }
        return true
    }
}

enum TrailModeRegistry {
    // Add future modes here. The menu bar is generated automatically from this list.
    static let all: [TrailMode] = [
        TrailMode(
            id: "comet",
            title: "Comet",
            lifetime: 0.42,
            headWidth: 16.0,
            passes: [
                TrailPassStyle(widthScale: 2.6, alpha: 0.20, softness: 1.00),
                TrailPassStyle(widthScale: 1.55, alpha: 0.42, softness: 0.75),
                TrailPassStyle(widthScale: 1.00, alpha: 0.95, softness: 0.45),
            ]
        ),
        TrailMode(
            id: "line",
            title: "Line",
            lifetime: 0.34,
            headWidth: 3.0,
            passes: [
                TrailPassStyle(widthScale: 1.0, alpha: 0.82, softness: 0.72),
            ]
        ),
        TrailMode(
            id: "rainbow",
            title: "Rainbow Road",
            lifetime: 0.60,
            headWidth: 18.0,
            coloring: .rainbow,
            // Just under a full turn, so the two ends of a long trail stay
            // distinguishable instead of meeting back at the same hue.
            hueSpread: 0.85,
            hueSpeed: 0.30,
            passes: [
                TrailPassStyle(widthScale: 2.2, alpha: 0.18, softness: 1.00),
                TrailPassStyle(widthScale: 1.3, alpha: 0.40, softness: 0.70),
                TrailPassStyle(widthScale: 1.0, alpha: 0.95, softness: 0.40),
            ]
        ),
        TrailMode(
            id: "gradient",
            title: "Gradient",
            lifetime: 0.50,
            headWidth: 14.0,
            coloring: .gradient,
            // Far enough to read as a second colour, short of complementary so
            // the pair still looks deliberate whatever the head colour is.
            tailHueShift: 0.42,
            passes: [
                TrailPassStyle(widthScale: 1.9, alpha: 0.25, softness: 0.90),
                TrailPassStyle(widthScale: 1.0, alpha: 0.90, softness: 0.50),
            ]
        ),
        TrailMode(
            id: "blur",
            title: "Blur",
            lifetime: 0.55,
            headWidth: 26.0,
            // No separate blur pass: stacking wide, fully soft, nearly
            // transparent strips over each other sums to the same falloff for
            // the price of four more draw calls on the buffer already bound.
            passes: [
                TrailPassStyle(widthScale: 4.2, alpha: 0.07, softness: 1.00),
                TrailPassStyle(widthScale: 3.2, alpha: 0.09, softness: 1.00),
                TrailPassStyle(widthScale: 2.4, alpha: 0.12, softness: 1.00),
                TrailPassStyle(widthScale: 1.6, alpha: 0.16, softness: 0.95),
                TrailPassStyle(widthScale: 1.0, alpha: 0.22, softness: 0.90),
            ]
        ),
        TrailMode(
            id: "confetti",
            title: "Confetti",
            lifetime: 0.34,
            headWidth: 10.0,
            // A quieter trail than Comet's: the paper is the subject here, and
            // a bright core behind it just muddies the colours.
            passes: [
                TrailPassStyle(widthScale: 1.8, alpha: 0.14, softness: 0.95),
                TrailPassStyle(widthScale: 1.0, alpha: 0.55, softness: 0.55),
            ],
            particles: ParticleStyle(
                trigger: .movement,
                spacing: 14.0,
                burstCount: 0,
                speed: 70...200,
                // Biased upward rather than radial, so the paper is thrown off
                // the pointer and then falls, instead of spraying evenly.
                spread: 1.15,
                // Well under real gravity. At anything like 900 the paper drops
                // roughly 600 points inside its lifetime -- more than half a
                // display -- and reads as being sucked downward rather than
                // fluttering. This falls about 200.
                gravity: -260,
                lifetime: 1.25,
                size: 4.5,
                spin: 6...16,
                roundness: 0.15,
                flutter: true,
                randomHue: true
            )
        ),
        TrailMode(
            id: "firework",
            title: "Firework",
            lifetime: 0.40,
            headWidth: 13.0,
            passes: [
                TrailPassStyle(widthScale: 2.2, alpha: 0.16, softness: 1.00),
                TrailPassStyle(widthScale: 1.0, alpha: 0.70, softness: 0.50),
            ],
            particles: ParticleStyle(
                trigger: .tripleClick,
                spacing: 0,
                burstCount: 72,
                speed: 200...460,
                spread: .pi,
                // Enough droop to arc the burst without collapsing it before
                // the sparks have finished spreading.
                gravity: -520,
                lifetime: 1.00,
                size: 3.0,
                spin: 0...0,
                roundness: 1.0,
                flutter: false,
                randomHue: true
            )
        ),
    ]

    static let defaultMode = all[0]

    static func mode(id: String?) -> TrailMode {
        guard let id, let match = all.first(where: { $0.id == id }) else { return defaultMode }
        return match
    }
}

/// Hue maths for the gradient tail. Kept free of AppKit so the renderer can
/// derive a tail colour on whichever thread set the new colour.
enum TrailColorMath {
    static func rotatingHue(of rgba: SIMD4<Float>, by turns: Float) -> SIMD4<Float> {
        var (h, s, v) = hsv(r: rgba.x, g: rgba.y, b: rgba.z)
        h = (h + turns).truncatingRemainder(dividingBy: 1.0)
        if h < 0 { h += 1 }
        // A near-grey head has no hue to rotate; lift the saturation so the
        // tail is still visibly a different colour rather than the same grey.
        if s < 0.15 { s = 0.45 }
        let (r, g, b) = rgb(h: h, s: s, v: v)
        return SIMD4(r, g, b, rgba.w)
    }

    private static func hsv(r: Float, g: Float, b: Float) -> (Float, Float, Float) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        guard delta > 0.00001 else { return (0, 0, maxC) }

        var h: Float
        switch maxC {
        case r: h = (g - b) / delta
        case g: h = 2 + (b - r) / delta
        default: h = 4 + (r - g) / delta
        }
        h /= 6
        if h < 0 { h += 1 }
        return (h, maxC > 0 ? delta / maxC : 0, maxC)
    }

    private static func rgb(h: Float, s: Float, v: Float) -> (Float, Float, Float) {
        let i = floor(h * 6)
        let f = h * 6 - i
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
