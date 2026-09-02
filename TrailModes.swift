import Foundation

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
    let passes: [TrailPassStyle]
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
    ]

    static let defaultMode = all[0]

    static func mode(id: String?) -> TrailMode {
        guard let id, let match = all.first(where: { $0.id == id }) else { return defaultMode }
        return match
    }
}
