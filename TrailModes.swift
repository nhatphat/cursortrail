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
    var spacing: Float
    /// Click only: how many particles one burst emits, and how many clicks
    /// within the system double-click interval set it off.
    let burstCount: Int
    let burstClicks: Int
    var speed: ClosedRange<Float>
    /// Half-angle of the emission cone, in radians, measured off straight up.
    /// `.pi` is the whole circle.
    let spread: Float
    /// Pixels per second squared. Negative falls, because the overlay's
    /// coordinate space has y pointing up.
    var gravity: Float
    var lifetime: Float
    var size: Float
    var spin: ClosedRange<Float>
    /// 0 draws soft squares, 1 soft discs.
    var roundness: Float
    /// Width as a fraction of length. 1 is a square piece; below that it is a
    /// ribbon, which the shader narrows and masks in the same unit square.
    var aspect: Float = 1
    var flutter: Bool
    /// Each particle picks its own hue rather than taking the trail's colour.
    let randomHue: Bool

    /// The same burst, played out over `scale` times as long. Dividing speed
    /// by the scale and gravity by its square puts a particle at `scale * t`
    /// exactly where it used to be at `t`, so the effect keeps the size and
    /// shape it was tuned with and only its pace changes. Stretching the
    /// lifetime alone would instead throw confetti four times as far for a
    /// doubled fade, which reads as a different effect rather than a slower one.
    func fading(by scale: Float) -> ParticleStyle {
        guard scale != 1 else { return self }
        var copy = self
        copy.lifetime *= scale
        copy.speed = (speed.lowerBound / scale)...(speed.upperBound / scale)
        copy.spin = (spin.lowerBound / scale)...(spin.upperBound / scale)
        copy.gravity /= scale * scale
        return copy
    }

    /// Density is the spacing read the other way round, because that is how it
    /// is chosen: "more confetti" is a shorter gap between pieces, and keeping
    /// it a distance means a denser setting still does not carpet the screen
    /// when the pointer crawls.
    func spaced(by amount: ConfettiAmount) -> ParticleStyle {
        guard amount.density != 1 else { return self }
        var copy = self
        copy.spacing = max(spacing / amount.density, 0.5)
        return copy
    }

    /// Shape is everything about a piece that is not its motion, so the arc a
    /// piece flies stays the one the effect was tuned with whichever shape is
    /// picked -- except for spin, which is part of how a shape reads: a disc
    /// spinning about its centre is a disc, so dots do not turn at all.
    func shaped(as shape: ConfettiShape) -> ParticleStyle {
        var copy = self
        copy.size = shape.size
        copy.roundness = shape.roundness
        copy.aspect = shape.aspect
        copy.flutter = shape.flutter
        copy.spin = shape.spin
        return copy
    }
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
    var lifetime: Float
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

    /// A copy that takes `scale` times as long to fade out. Width and colour
    /// are the style's identity, so only the lifetime moves: a longer fade is
    /// the same trail kept on screen longer, not a different-looking one.
    func fading(by scale: Float) -> TrailStyle {
        guard scale != 1 else { return self }
        var copy = self
        copy.lifetime *= scale
        return copy
    }
}

/// A train of rings expanding out of a click, each launched a little after the
/// one before, like a stone dropped in water.
struct RippleStyle {
    let maxRadius: Float
    let thickness: Float
    /// How long one wave takes to reach `maxRadius`.
    var waveLifetime: Float
    /// Gap between successive waves leaving the centre.
    var waveDelay: Float
    let waveCount: Int

    /// The last wave leaves after `waveCount - 1` delays and still needs a full
    /// `waveLifetime` to finish, so the ripple as a whole outlives one wave.
    var totalLifetime: Float {
        waveLifetime + Float(max(waveCount - 1, 0)) * waveDelay
    }

    /// Both timings scale together, so the train keeps its spacing and reaches
    /// the same radius; only how long it takes to get there changes.
    func fading(by scale: Float) -> RippleStyle {
        guard scale != 1 else { return self }
        var copy = self
        copy.waveLifetime *= scale
        copy.waveDelay *= scale
        return copy
    }
}

/// Something that follows the pointer rather than being thrown by it. A
/// companion is not a particle: it is one persistent thing with a position, a
/// pose and a memory of where the pointer has been, so it walks the path the
/// pointer actually took instead of cutting the corner.
struct CompanionStyle {
    /// Points per second at an ordinary trot, and the cap it sprints to when
    /// the pointer has got a long way ahead.
    let speed: Float
    let sprintSpeed: Float
    /// Half the drawn height, in points.
    let size: Float
    /// Points to the right of the path the companion is actually drawn. It
    /// walks where the pointer walked, but sitting exactly on the hotspot puts
    /// it between you and whatever you were about to click.
    let sideOffset: Float
    /// Points of pointer travel between waypoints. The path is thinned to this
    /// on the way in, so a slow drag does not lay down hundreds of points a
    /// second for the walk to chew through.
    let waypointSpacing: Float
    /// How far ahead the pointer has to be before the sprint starts.
    let catchRadius: Float
    /// Seconds standing still before it sits, and before it lies down asleep.
    let sitDelay: Float
    let sleepDelay: Float
}

/// An effect that can be switched on independently of the trail's look,
/// and independently of every other effect. The menu bar lists these as checks
/// rather than as a choice, so any combination is reachable.
struct TrailEffect {
    let id: String
    let title: String
    let particles: ParticleStyle?
    let ripple: RippleStyle?
    let companion: CompanionStyle?

    init(id: String, title: String, particles: ParticleStyle? = nil, ripple: RippleStyle? = nil, companion: CompanionStyle? = nil) {
        self.id = id
        self.title = title
        self.particles = particles
        self.ripple = ripple
        self.companion = companion
    }

    /// Amount and shape are chosen for confetti in particular, so they reach
    /// the movement emitters only: a click burst is sparks, and sparks want to
    /// stay the points their own effect asked for.
    func withConfetti(amount: ConfettiAmount, shape: ConfettiShape) -> TrailEffect {
        guard let particles, particles.trigger == .movement else { return self }
        return TrailEffect(
            id: id,
            title: title,
            particles: particles.spaced(by: amount).shaped(as: shape),
            ripple: ripple,
            companion: companion
        )
    }

    func fading(by scale: Float) -> TrailEffect {
        guard scale != 1 else { return self }
        return TrailEffect(
            id: id,
            title: title,
            particles: particles?.fading(by: scale),
            ripple: ripple?.fading(by: scale),
            // A cat does not fade out, so it has no fade to scale: it walks
            // off, sits down and stays until you switch it off.
            companion: companion
        )
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
    /// One at most: two companions would want the same path and stand on each
    /// other, so the first one switched on is the one that walks.
    var companion: CompanionStyle? { effects.compactMap(\.companion).first }

    /// False when the style generates its own hues, and the chosen colour only
    /// contributes its opacity. The menu bar says so rather than looking broken.
    var usesTrailColor: Bool { style.coloring != .rainbow }

    /// False for the None style, which carries no passes. The effects are
    /// chosen independently of the style, so "confetti and nothing else" has
    /// to be reachable; the renderer then skips the trail altogether rather
    /// than drawing an empty one.
    var drawsTrail: Bool { !style.passes.isEmpty && style.lifetime > 0 }

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
        // No passes means no trail: the pointer leaves nothing behind and only
        // the effects you switched on are drawn. Last in the list so the
        // default stays the first real style.
        TrailStyle(
            id: "none",
            title: "None",
            lifetime: 0,
            headWidth: 0,
            passes: []
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
        TrailEffect(
            id: "cat",
            title: "Cat",
            companion: CompanionStyle(
                // Faster than a comfortable pointer speed but slower than a
                // flick, so it is usually just behind you and occasionally has
                // to run for it.
                speed: 460,
                sprintSpeed: 1500,
                size: 26,
                // Clears the arrow and its shadow with a little daylight left,
                // without the cat looking detached from the path it is on.
                sideOffset: 34,
                waypointSpacing: 9,
                catchRadius: 34,
                sitDelay: 0.9,
                sleepDelay: 5.0
            )
        ),
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

/// How much confetti the pointer throws, as a multiplier on the density each
/// movement emitter was tuned with. Stored as density rather than as spacing
/// so the menu reads in the direction the user thinks in.
struct ConfettiAmount {
    let id: String
    let title: String
    let density: Float
}

enum ConfettiAmountRegistry {
    static let all: [ConfettiAmount] = [
        ConfettiAmount(id: "verySparse", title: "Very Sparse", density: 0.33),
        ConfettiAmount(id: "sparse", title: "Sparse", density: 0.55),
        ConfettiAmount(id: "normal", title: "Normal", density: 1.0),
        ConfettiAmount(id: "dense", title: "Dense", density: 1.8),
        // Past here a fast flick can out-run the particle ring, which then
        // reclaims the oldest piece still in the air. That is the intended
        // trade: a denser stream at the pointer, a shorter one behind it.
        ConfettiAmount(id: "veryDense", title: "Very Dense", density: 3.3),
    ]

    static let defaultAmount = all[2]

    static func amount(id: String?) -> ConfettiAmount {
        guard let id, let match = all.first(where: { $0.id == id }) else { return defaultAmount }
        return match
    }
}

/// What one piece of confetti looks like. The shader draws a rounded, possibly
/// narrowed quad, so a shape is four numbers rather than a new geometry path.
struct ConfettiShape {
    let id: String
    let title: String
    let size: Float
    let roundness: Float
    let aspect: Float
    let flutter: Bool
    let spin: ClosedRange<Float>
}

enum ConfettiShapeRegistry {
    static let all: [ConfettiShape] = [
        // Paper is the shape confetti has always had here, so it stays first
        // and stays the default: picking it changes nothing.
        ConfettiShape(id: "paper", title: "Paper", size: 4.5, roundness: 0.15, aspect: 1.0, flutter: true, spin: 6...16),
        ConfettiShape(id: "dots", title: "Dots", size: 3.8, roundness: 1.0, aspect: 1.0, flutter: false, spin: 0...0),
        // Long, thin and tumbling: the aspect makes the streamer, the flutter
        // turns it edge-on as it spins, which is most of what sells it.
        ConfettiShape(id: "ribbons", title: "Ribbons", size: 8.0, roundness: 0.55, aspect: 0.26, flutter: true, spin: 5...14),
        // Big, soft and slow: fewer, larger pieces read as bubbles rather than
        // as paper, which is a different mood for the same emitter.
        ConfettiShape(id: "bubbles", title: "Bubbles", size: 7.0, roundness: 1.0, aspect: 1.0, flutter: false, spin: 0...0),
    ]

    static let defaultShape = all[0]

    static func shape(id: String?) -> ConfettiShape {
        guard let id, let match = all.first(where: { $0.id == id }) else { return defaultShape }
        return match
    }
}

/// How long something takes to fade out, as a multiple of the timings each
/// style and effect was tuned with. The trail and the effects each pick their
/// own: a long trail with snappy confetti is a combination worth having, and
/// tying the two together would make one of them wrong at every setting.
struct TrailFade {
    let id: String
    let title: String
    let scale: Float
}

enum TrailFadeRegistry {
    static let all: [TrailFade] = [
        TrailFade(id: "veryShort", title: "Very Short", scale: 0.4),
        TrailFade(id: "short", title: "Short", scale: 0.7),
        TrailFade(id: "normal", title: "Normal", scale: 1.0),
        TrailFade(id: "long", title: "Long", scale: 1.5),
        // The trail's point ring holds 256 samples, which at the sampling rate
        // is a bit over two seconds; the longest style stays inside that even
        // here, so nothing is clipped at the tail.
        TrailFade(id: "veryLong", title: "Very Long", scale: 2.25),
    ]

    static let defaultFade = all[2]

    static func fade(id: String?) -> TrailFade {
        guard let id, let match = all.first(where: { $0.id == id }) else { return defaultFade }
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
