import Foundation

/// How a mode turns the chosen trail colour into the colour of each fragment.
/// The raw values are the wire format of the `coloring` uniform in Trail.metal,
/// so they cannot be renumbered on their own.
enum TrailColoring: UInt32 {
    case solid = 0
    case gradient = 1
    case rainbow = 2
}

/// What makes an emitter fire. Movement emits along the pointer's path; click
/// waits for a gesture of `burstClicks` clicks.
enum ParticleTrigger {
    case movement
    case click
}

/// One emitter. A mode may carry several, which is how a single mode throws
/// confetti as the pointer moves *and* sets off a firework when it is clicked.
struct ParticleStyle {
    let trigger: ParticleTrigger
    /// Movement only: points of pointer travel between one particle and the
    /// next. Distance rather than time, so a slow drag does not carpet the
    /// screen and a flick does not leave gaps.
    let spacing: Float
    /// Click only: how many particles one burst emits, and how many clicks
    /// within the system double-click interval set it off.
    let burstCount: Int
    let burstClicks: Int
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

/// The look of the trail itself. Exactly one is active at a time.
struct TrailStyle {
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
    /// 0...1: how much of the trail's width follows pointer speed.
    let speedResponse: Float
    let passes: [TrailPassStyle]

    init(
        id: String,
        title: String,
        lifetime: Float,
        headWidth: Float,
        coloring: TrailColoring = .solid,
        tailHueShift: Float = 0,
        hueSpread: Float = 0,
        hueSpeed: Float = 0,
        speedResponse: Float = 0.7,
        passes: [TrailPassStyle]
    ) {
        self.id = id
        self.title = title
        self.lifetime = lifetime
        self.headWidth = headWidth
        self.coloring = coloring
        self.tailHueShift = tailHueShift
        self.hueSpread = hueSpread
        self.hueSpeed = hueSpeed
        self.speedResponse = speedResponse
        self.passes = passes
    }
}

/// A train of rings expanding out of a click, each launched a little after the
/// one before, like a stone dropped in water.
struct RippleStyle {
    let maxRadius: Float
    let thickness: Float
    /// How long one wave takes to reach `maxRadius`.
    let waveLifetime: Float
    /// Gap between successive waves leaving the centre.
    let waveDelay: Float
    let waveCount: Int

    /// The last wave leaves after `waveCount - 1` delays and still needs a full
    /// `waveLifetime` to finish, so the ripple as a whole outlives one wave.
    var totalLifetime: Float {
        waveLifetime + Float(max(waveCount - 1, 0)) * waveDelay
    }
}

/// An effect that can be switched on independently of the trail's look,
/// and independently of every other effect. The menu bar lists these as checks
/// rather than as a choice, so any combination is reachable.
struct TrailEffect {
    let id: String
    let title: String
    let particles: ParticleStyle?
    let ripple: RippleStyle?

    init(id: String, title: String, particles: ParticleStyle? = nil, ripple: RippleStyle? = nil) {
        self.id = id
        self.title = title
        self.particles = particles
        self.ripple = ripple
    }
}

/// What the renderer actually draws: one style, plus however many effects are
/// switched on. The forwarding properties keep the renderer talking to a single
/// value rather than reaching into the parts.
struct TrailMode {
    let style: TrailStyle
    let effects: [TrailEffect]

    var id: String { style.id }
    var title: String { style.title }
    var lifetime: Float { style.lifetime }
    var headWidth: Float { style.headWidth }
    var coloring: TrailColoring { style.coloring }
    var tailHueShift: Float { style.tailHueShift }
    var hueSpread: Float { style.hueSpread }
    var hueSpeed: Float { style.hueSpeed }
    var speedResponse: Float { style.speedResponse }
    var passes: [TrailPassStyle] { style.passes }

    var emitters: [ParticleStyle] { effects.compactMap(\.particles) }
    var ripples: [RippleStyle] { effects.compactMap(\.ripple) }

    /// False when the style generates its own hues, and the chosen colour only
    /// contributes its opacity. The menu bar says so rather than looking broken.
    var usesTrailColor: Bool { style.coloring != .rainbow }

    var hasBurstEffect: Bool {
        emitters.contains { $0.trigger == .click } || !ripples.isEmpty
    }

    var maxRippleLifetime: Float { ripples.map(\.totalLifetime).max() ?? 0 }

    /// The ring reclaims a particle's slot by birth order, which is only in
    /// death order when every emitter agrees on a lifetime. Expiring against
    /// the longest one keeps that true; a particle past its own lifetime has
    /// already faded to nothing, so the extra slots cost pixels, not looks.
    var maxParticleLifetime: Float {
        emitters.map(\.lifetime).max() ?? 0
    }
}

enum TrailStyleRegistry {
    // Add future styles here. The menu bar is generated automatically.
    static let all: [TrailStyle] = [
        TrailStyle(
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
        TrailStyle(
            id: "line",
            title: "Line",
            lifetime: 0.34,
            headWidth: 3.0,
            // A hairline that swells stops reading as a line.
            speedResponse: 0.0,
            passes: [
                TrailPassStyle(widthScale: 1.0, alpha: 0.82, softness: 0.72),
            ]
        ),
        TrailStyle(
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
        TrailStyle(
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
        TrailStyle(
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
    ]

    static let defaultStyle = all[0]

    static func style(id: String?) -> TrailStyle {
        guard let id, let match = all.first(where: { $0.id == id }) else { return defaultStyle }
        return match
    }
}

enum TrailEffectRegistry {
    // Add future effects here. They are independent of the style and of each
    // other, so a new one needs no combination entry anywhere.
    static let all: [TrailEffect] = [
        TrailEffect(
            id: "confetti",
            title: "Confetti",
            particles: ParticleStyle(
                trigger: .movement,
                spacing: 14.0,
                burstCount: 0,
                burstClicks: 0,
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
        TrailEffect(
            id: "firework",
            title: "Firework",
            particles: ParticleStyle(
                trigger: .click,
                spacing: 0,
                burstCount: 72,
                burstClicks: 1,
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
        rippleEffect,
    ]

    static let rippleEffect = TrailEffect(
        id: "ripple",
        title: "Click Ripple",
        ripple: RippleStyle(
            maxRadius: 130,
            thickness: 6,
            waveLifetime: 0.70,
            waveDelay: 0.12,
            waveCount: 3
        )
    )

    static func effects(ids: Set<String>) -> [TrailEffect] {
        all.filter { ids.contains($0.id) }
    }
}

/// Where particles get their colour. A palette is chosen once, in the menu bar,
/// and applies to every effect -- the effects describe motion, not colour.
struct ParticlePalette {
    let id: String
    let title: String
    /// First hue of the band, in turns.
    let hueStart: Float
    /// How far around the wheel the band runs. A full turn is every hue.
    let hueSpan: Float
    let saturation: Float
    /// When true the hue fields are ignored and particles take the trail colour.
    let usesTrailColor: Bool

    init(id: String, title: String, hueStart: Float = 0, hueSpan: Float = 1, saturation: Float = 0.8, usesTrailColor: Bool = false) {
        self.id = id
        self.title = title
        self.hueStart = hueStart
        self.hueSpan = hueSpan
        self.saturation = saturation
        self.usesTrailColor = usesTrailColor
    }
}

enum ParticlePaletteRegistry {
    static let all: [ParticlePalette] = [
        ParticlePalette(id: "rainbow", title: "Rainbow"),
        // Narrow bands read as a deliberate scheme rather than as confetti from
        // a party shop; they are the reason this setting exists.
        ParticlePalette(id: "warm", title: "Warm", hueStart: 0.92, hueSpan: 0.22, saturation: 0.85),
        ParticlePalette(id: "cool", title: "Cool", hueStart: 0.45, hueSpan: 0.26, saturation: 0.80),
        ParticlePalette(id: "pastel", title: "Pastel", hueStart: 0, hueSpan: 1, saturation: 0.35),
        ParticlePalette(id: "trail", title: "Trail Color", usesTrailColor: true),
    ]

    static let defaultPalette = all[0]

    static func palette(id: String?) -> ParticlePalette {
        guard let id, let match = all.first(where: { $0.id == id }) else { return defaultPalette }
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
