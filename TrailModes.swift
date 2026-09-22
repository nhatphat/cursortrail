import Foundation

/// How a mode turns the chosen trail colour into the colour of each fragment.
/// The raw values are the wire format of the `coloring` uniform in Trail.metal,
/// so they cannot be renumbered on their own.
enum TrailColoring: UInt32 {
    case solid = 0
    case gradient = 1
    case rainbow = 2
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

    init(
        id: String,
        title: String,
        lifetime: Float,
        headWidth: Float,
        coloring: TrailColoring = .solid,
        tailHueShift: Float = 0,
        hueSpread: Float = 0,
        hueSpeed: Float = 0,
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
        self.passes = passes
    }

    /// False when the mode generates its own hues, and the chosen colour only
    /// contributes its opacity. The menu bar says so rather than looking broken.
    var usesTrailColor: Bool { coloring != .rainbow }
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
