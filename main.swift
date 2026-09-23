import AppKit
import Carbon.HIToolbox
import Foundation
import Metal
import QuartzCore

private func envFloat(_ key: String, _ fallback: Float) -> Float {
    guard let raw = ProcessInfo.processInfo.environment[key], let v = Float(raw) else { return fallback }
    return v
}

private func envInt(_ key: String, _ fallback: Int) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[key], let v = Int(raw) else { return fallback }
    return v
}

struct TrailConfig {
    let minSampleDistance: Float = envFloat("CURSORTRAIL_SAMPLE_DISTANCE", 0.75)
    let minSampleInterval: Double = Double(envFloat("CURSORTRAIL_SAMPLE_INTERVAL", 1.0 / 120.0))
    let maxPoints: Int = min(max(envInt("CURSORTRAIL_MAX_POINTS", 256), 32), 2048)
    /// Live particles per display, for the modes that emit any. Reached only
    /// during a burst; confetti settles far below it.
    let maxParticles: Int = min(max(envInt("CURSORTRAIL_MAX_PARTICLES", 512), 32), 4096)
    /// Overrides every mode's own click gesture when set. 0 leaves each mode
    /// to ask for the number of clicks it wants.
    let burstClickOverride: Int = min(max(envInt("CURSORTRAIL_BURST_CLICKS", 0), 0), 5)
    /// 0 = follow the display's native refresh rate. Set e.g. 60 on a 120 Hz
    /// ProMotion panel to halve the render work while the trail is alive.
    let maxFPS: Int = max(envInt("CURSORTRAIL_MAX_FPS", 0), 0)
    /// Drop to half rate while the pointer is slow and while the trail fades
    /// after it stops. Set to 0 to always render at the full rate above.
    let adaptiveFPS: Bool = envInt("CURSORTRAIL_ADAPTIVE_FPS", 1) != 0
    let color: SIMD4<Float>

    init() {
        if let raw = ProcessInfo.processInfo.environment["CURSORTRAIL_COLOR"] {
            let parts = raw.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count >= 3 {
                color = SIMD4(parts[0], parts[1], parts[2], parts.count >= 4 ? parts[3] : 1.0)
                return
            }
        }
        color = SIMD4(0.35, 0.72, 1.0, 0.95)
    }
}

struct TrailColorPreset {
    let title: String
    let rgba: SIMD4<Float>
}

enum TrailColorPresets {
    // Add swatches here; the colour submenu is generated from this list.
    static let all: [TrailColorPreset] = [
        TrailColorPreset(title: "Sky", rgba: SIMD4(0.35, 0.72, 1.00, 0.95)),
        TrailColorPreset(title: "Mint", rgba: SIMD4(0.30, 0.95, 0.70, 0.95)),
        TrailColorPreset(title: "Lime", rgba: SIMD4(0.65, 0.95, 0.30, 0.95)),
        TrailColorPreset(title: "Gold", rgba: SIMD4(1.00, 0.80, 0.25, 0.95)),
        TrailColorPreset(title: "Ember", rgba: SIMD4(1.00, 0.55, 0.20, 0.95)),
        TrailColorPreset(title: "Pink", rgba: SIMD4(1.00, 0.42, 0.72, 0.95)),
        TrailColorPreset(title: "Violet", rgba: SIMD4(0.66, 0.45, 1.00, 0.95)),
        TrailColorPreset(title: "White", rgba: SIMD4(1.00, 1.00, 1.00, 0.95)),
    ]
}

@main
final class CursorTrailApp: NSObject, NSApplicationDelegate {
    private static let styleDefaultsKey = "selectedTrailStyle"
    private static let effectsDefaultsKey = "selectedTrailEffects"
    private static let legacyModeDefaultsKey = "selectedTrailMode"
    private static let colorDefaultsKey = "trailColor"
    private static let burstClicksDefaultsKey = "burstClicks"
    private static let paletteDefaultsKey = "particlePalette"
    private static let confettiAmountDefaultsKey = "confettiAmount"
    private static let confettiShapeDefaultsKey = "confettiShape"
    private static let trailFadeDefaultsKey = "trailFade"
    private static let effectFadeDefaultsKey = "effectFade"
    private static let burstClickChoices = [1, 2, 3]

    private let config = TrailConfig()
    private var currentStyle = TrailStyleRegistry.defaultStyle
    private var currentEffectIDs: Set<String> = []
    /// The two fades are separate settings on purpose: the trail and the
    /// effects are independent axes everywhere else in the menu, and one
    /// shared slider would force a compromise on whichever of them you were
    /// not adjusting.
    private var currentTrailFade = TrailFadeRegistry.defaultFade
    private var currentEffectFade = TrailFadeRegistry.defaultFade
    private var currentConfettiAmount = ConfettiAmountRegistry.defaultAmount
    private var currentConfettiShape = ConfettiShapeRegistry.defaultShape
    /// Shape before fade: the fade stretches spin along with the rest of the
    /// motion, and it is the shape's spin that should be stretched.
    private var currentMode: TrailMode {
        TrailMode(
            style: currentStyle.fading(by: currentTrailFade.scale),
            effects: TrailEffectRegistry.effects(ids: currentEffectIDs)
                .map { $0.withConfetti(amount: currentConfettiAmount, shape: currentConfettiShape) }
                .map { $0.fading(by: currentEffectFade.scale) }
        )
    }
    private var currentColor = SIMD4<Float>(0, 0, 0, 0)
    private var overlays: [OverlayController] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var activeOverlay: OverlayController?
    private var statusItem: NSStatusItem?
    private var styleMenuItems: [String: NSMenuItem] = [:]
    private var effectMenuItems: [String: NSMenuItem] = [:]
    private var colorMenuItems: [NSMenuItem] = []
    private var burstClicksMenuItems: [NSMenuItem] = []
    private var burstNoteItem: NSMenuItem?
    private var paletteMenuItems: [String: NSMenuItem] = [:]
    private var confettiAmountMenuItems: [String: NSMenuItem] = [:]
    private var confettiShapeMenuItems: [String: NSMenuItem] = [:]
    private var confettiAmountNoteItem: NSMenuItem?
    private var confettiShapeNoteItem: NSMenuItem?
    private var trailFadeMenuItems: [String: NSMenuItem] = [:]
    private var effectFadeMenuItems: [String: NSMenuItem] = [:]
    private var trailFadeNoteItem: NSMenuItem?
    private var effectFadeNoteItem: NSMenuItem?
    private var pauseMenuItem: NSMenuItem?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    /// Paused means "stop feeding the overlays". Nothing is torn down and
    /// nothing is cleared by force: whatever is on screen expires on its own
    /// within a second and the existing stop path parks the display link. A
    /// hard clear would have to paint one empty frame first, and fading out is
    /// what you want from a key you hit mid-presentation anyway.
    private var trailEnabled = true
    private var currentPalette = ParticlePaletteRegistry.defaultPalette
    private var currentBurstClicks = 1
    /// Shown only while the active mode generates its own hues, so the swatches
    /// having no visible effect reads as intended rather than broken.
    private var colorNoteItem: NSMenuItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = CursorTrailApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        restoreSelection()
        // The environment variable is the default, not an override: a colour
        // picked from the menu bar has been chosen more deliberately.
        currentColor = Self.decodeColor(UserDefaults.standard.string(forKey: Self.colorDefaultsKey)) ?? config.color
        currentPalette = ParticlePaletteRegistry.palette(id: UserDefaults.standard.string(forKey: Self.paletteDefaultsKey))
        currentConfettiAmount = ConfettiAmountRegistry.amount(id: UserDefaults.standard.string(forKey: Self.confettiAmountDefaultsKey))
        currentConfettiShape = ConfettiShapeRegistry.shape(id: UserDefaults.standard.string(forKey: Self.confettiShapeDefaultsKey))
        currentTrailFade = TrailFadeRegistry.fade(id: UserDefaults.standard.string(forKey: Self.trailFadeDefaultsKey))
        currentEffectFade = TrailFadeRegistry.fade(id: UserDefaults.standard.string(forKey: Self.effectFadeDefaultsKey))
        let storedClicks = UserDefaults.standard.integer(forKey: Self.burstClicksDefaultsKey)
        currentBurstClicks = Self.burstClickChoices.contains(storedClicks)
            ? storedClicks
            : (config.burstClickOverride > 0 ? config.burstClickOverride : 1)
        setupStatusItem()
        rebuildOverlays()
        installMouseMonitors()
        installHotKey()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Styles and effects used to be one list of fixed combinations, so a
    /// stored "confetti" or "party" has to be split back into the two axes it
    /// was always made of.
    private func restoreSelection() {
        let defaults = UserDefaults.standard
        if let styleID = defaults.string(forKey: Self.styleDefaultsKey) {
            currentStyle = TrailStyleRegistry.style(id: styleID)
            let stored = defaults.stringArray(forKey: Self.effectsDefaultsKey) ?? []
            currentEffectIDs = Set(stored).intersection(TrailEffectRegistry.all.map(\.id))
            return
        }

        switch defaults.string(forKey: Self.legacyModeDefaultsKey) {
        case "confetti": currentStyle = TrailStyleRegistry.style(id: "comet"); currentEffectIDs = ["confetti"]
        case "firework": currentStyle = TrailStyleRegistry.style(id: "comet"); currentEffectIDs = ["firework"]
        case "party": currentStyle = TrailStyleRegistry.style(id: "comet"); currentEffectIDs = ["confetti", "firework"]
        case let other: currentStyle = TrailStyleRegistry.style(id: other)
        }
        persistSelection()
    }

    private func persistSelection() {
        UserDefaults.standard.set(currentStyle.id, forKey: Self.styleDefaultsKey)
        UserDefaults.standard.set(Array(currentEffectIDs).sorted(), forKey: Self.effectsDefaultsKey)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }

    @objc private func screensChanged() {
        rebuildOverlays()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "CursorTrail")
            if button.image == nil { button.title = "CT" }
        }

        let menu = NSMenu()
        let styleHeader = NSMenuItem(title: "Trail Style", action: nil, keyEquivalent: "")
        styleHeader.isEnabled = false
        menu.addItem(styleHeader)

        for style in TrailStyleRegistry.all {
            let item = NSMenuItem(title: style.title, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.id
            menu.addItem(item)
            styleMenuItems[style.id] = item
        }

        menu.addItem(.separator())
        let effectHeader = NSMenuItem(title: "Effects", action: nil, keyEquivalent: "")
        effectHeader.isEnabled = false
        menu.addItem(effectHeader)

        // Checks, not a choice: every combination of these is reachable, and
        // combining them with any style above is the whole point.
        for effect in TrailEffectRegistry.all {
            let item = NSMenuItem(title: effect.title, action: #selector(toggleEffect(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = effect.id
            menu.addItem(item)
            effectMenuItems[effect.id] = item
        }

        menu.addItem(.separator())
        let colorItem = NSMenuItem(title: "Trail Color", action: nil, keyEquivalent: "")
        colorItem.submenu = buildColorMenu()
        menu.addItem(colorItem)

        let paletteItem = NSMenuItem(title: "Particle Colors", action: nil, keyEquivalent: "")
        paletteItem.submenu = buildPaletteMenu()
        menu.addItem(paletteItem)

        let confettiAmountItem = NSMenuItem(title: "Confetti Amount", action: nil, keyEquivalent: "")
        confettiAmountItem.submenu = buildConfettiAmountMenu()
        menu.addItem(confettiAmountItem)

        let confettiShapeItem = NSMenuItem(title: "Confetti Shape", action: nil, keyEquivalent: "")
        confettiShapeItem.submenu = buildConfettiShapeMenu()
        menu.addItem(confettiShapeItem)

        let burstItem = NSMenuItem(title: "Firework Clicks", action: nil, keyEquivalent: "")
        burstItem.submenu = buildBurstMenu()
        menu.addItem(burstItem)

        let trailFadeItem = NSMenuItem(title: "Trail Fade", action: nil, keyEquivalent: "")
        trailFadeItem.submenu = buildTrailFadeMenu()
        menu.addItem(trailFadeItem)

        let effectFadeItem = NSMenuItem(title: "Effect Fade", action: nil, keyEquivalent: "")
        effectFadeItem.submenu = buildEffectFadeMenu()
        menu.addItem(effectFadeItem)

        menu.addItem(.separator())
        let pause = NSMenuItem(title: "Pause Trail", action: #selector(togglePause), keyEquivalent: "t")
        pause.keyEquivalentModifierMask = [.control, .option, .command]
        pause.target = self
        menu.addItem(pause)
        pauseMenuItem = pause

        let quit = NSMenuItem(title: "Quit CursorTrail", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        refreshModeChecks()
        refreshColorChecks()
        refreshBurstChecks()
        refreshPaletteChecks()
        refreshFadeChecks()
        refreshConfettiChecks()
    }

    private func buildConfettiAmountMenu() -> NSMenu {
        let menu = NSMenu()

        let note = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        note.isEnabled = false
        note.isHidden = true
        menu.addItem(note)
        confettiAmountNoteItem = note

        for amount in ConfettiAmountRegistry.all {
            let item = NSMenuItem(title: amount.title, action: #selector(selectConfettiAmount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = amount.id
            menu.addItem(item)
            confettiAmountMenuItems[amount.id] = item
        }
        return menu
    }

    private func buildConfettiShapeMenu() -> NSMenu {
        let menu = NSMenu()

        let note = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        note.isEnabled = false
        note.isHidden = true
        menu.addItem(note)
        confettiShapeNoteItem = note

        for shape in ConfettiShapeRegistry.all {
            let item = NSMenuItem(title: shape.title, action: #selector(selectConfettiShape(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shape.id
            menu.addItem(item)
            confettiShapeMenuItems[shape.id] = item
        }
        return menu
    }

    @objc private func selectConfettiAmount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        currentConfettiAmount = ConfettiAmountRegistry.amount(id: id)
        UserDefaults.standard.set(currentConfettiAmount.id, forKey: Self.confettiAmountDefaultsKey)
        applySelection()
    }

    @objc private func selectConfettiShape(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        currentConfettiShape = ConfettiShapeRegistry.shape(id: id)
        UserDefaults.standard.set(currentConfettiShape.id, forKey: Self.confettiShapeDefaultsKey)
        applySelection()
    }

    private func refreshConfettiChecks() {
        for (id, item) in confettiAmountMenuItems {
            item.state = (id == currentConfettiAmount.id) ? .on : .off
        }
        for (id, item) in confettiShapeMenuItems {
            item.state = (id == currentConfettiShape.id) ? .on : .off
        }
        let hasConfetti = currentEffectIDs.contains("confetti")
        for note in [confettiAmountNoteItem, confettiShapeNoteItem] {
            note?.isHidden = hasConfetti
            note?.title = "Turn on Confetti to use this"
        }
    }

    private func buildTrailFadeMenu() -> NSMenu {
        let menu = NSMenu()

        let note = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        note.isEnabled = false
        note.isHidden = true
        menu.addItem(note)
        trailFadeNoteItem = note

        for fade in TrailFadeRegistry.all {
            let item = NSMenuItem(title: fade.title, action: #selector(selectTrailFade(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = fade.id
            menu.addItem(item)
            trailFadeMenuItems[fade.id] = item
        }
        return menu
    }

    private func buildEffectFadeMenu() -> NSMenu {
        let menu = NSMenu()

        let note = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        note.isEnabled = false
        note.isHidden = true
        menu.addItem(note)
        effectFadeNoteItem = note

        for fade in TrailFadeRegistry.all {
            let item = NSMenuItem(title: fade.title, action: #selector(selectEffectFade(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = fade.id
            menu.addItem(item)
            effectFadeMenuItems[fade.id] = item
        }
        return menu
    }

    @objc private func selectTrailFade(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        currentTrailFade = TrailFadeRegistry.fade(id: id)
        UserDefaults.standard.set(currentTrailFade.id, forKey: Self.trailFadeDefaultsKey)
        applySelection()
    }

    @objc private func selectEffectFade(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        currentEffectFade = TrailFadeRegistry.fade(id: id)
        UserDefaults.standard.set(currentEffectFade.id, forKey: Self.effectFadeDefaultsKey)
        applySelection()
    }

    private func refreshFadeChecks() {
        for (id, item) in trailFadeMenuItems {
            item.state = (id == currentTrailFade.id) ? .on : .off
        }
        for (id, item) in effectFadeMenuItems {
            item.state = (id == currentEffectFade.id) ? .on : .off
        }
        // Same courtesy the colour and firework submenus pay: say why the
        // setting is doing nothing rather than letting it look broken.
        trailFadeNoteItem?.isHidden = currentMode.drawsTrail
        trailFadeNoteItem?.title = "Trail Style is None"
        effectFadeNoteItem?.isHidden = !currentEffectIDs.isEmpty
        effectFadeNoteItem?.title = "Turn on an effect to use this"
    }

    private func buildPaletteMenu() -> NSMenu {
        let menu = NSMenu()
        for palette in ParticlePaletteRegistry.all {
            let item = NSMenuItem(title: palette.title, action: #selector(selectPalette(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = palette.id
            menu.addItem(item)
            paletteMenuItems[palette.id] = item
        }
        return menu
    }

    @objc private func selectPalette(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        currentPalette = ParticlePaletteRegistry.palette(id: id)
        UserDefaults.standard.set(currentPalette.id, forKey: Self.paletteDefaultsKey)
        overlays.forEach { $0.setPalette(currentPalette) }
        refreshPaletteChecks()
    }

    private func refreshPaletteChecks() {
        for (id, item) in paletteMenuItems {
            item.state = (id == currentPalette.id) ? .on : .off
        }
    }

    private func buildBurstMenu() -> NSMenu {
        let menu = NSMenu()

        let note = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        note.isEnabled = false
        note.isHidden = true
        menu.addItem(note)
        burstNoteItem = note

        for clicks in Self.burstClickChoices {
            let title = clicks == 1 ? "Single Click" : "\(clicks) Clicks"
            let item = NSMenuItem(title: title, action: #selector(selectBurstClicks(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = clicks
            menu.addItem(item)
            burstClicksMenuItems.append(item)
        }

        return menu
    }

    @objc private func selectBurstClicks(_ sender: NSMenuItem) {
        guard let clicks = sender.representedObject as? Int else { return }
        currentBurstClicks = clicks
        UserDefaults.standard.set(clicks, forKey: Self.burstClicksDefaultsKey)
        refreshBurstChecks()
    }

    private func refreshBurstChecks() {
        for item in burstClicksMenuItems {
            guard let clicks = item.representedObject as? Int else { continue }
            item.state = (clicks == currentBurstClicks) ? .on : .off
        }
        let modeBursts = currentMode.hasBurstEffect
        burstNoteItem?.isHidden = modeBursts
        burstNoteItem?.title = "Turn on Firework to use this"
    }

    private func buildColorMenu() -> NSMenu {
        let menu = NSMenu()

        let note = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        note.isEnabled = false
        note.isHidden = true
        menu.addItem(note)
        colorNoteItem = note

        for preset in TrailColorPresets.all {
            let item = NSMenuItem(title: preset.title, action: #selector(selectPresetColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rgba
            item.image = Self.swatch(for: preset.rgba)
            menu.addItem(item)
            colorMenuItems.append(item)
        }

        menu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom...", action: #selector(chooseCustomColor), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)

        return menu
    }

    @objc private func selectPresetColor(_ sender: NSMenuItem) {
        guard let rgba = sender.representedObject as? SIMD4<Float> else { return }
        applyColor(rgba)
    }

    @objc private func chooseCustomColor() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.color = NSColor(
            srgbRed: CGFloat(currentColor.x),
            green: CGFloat(currentColor.y),
            blue: CGFloat(currentColor.z),
            alpha: CGFloat(currentColor.w)
        )
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        // An .accessory app owns no menu bar of its own, so the panel arrives
        // behind whatever is frontmost unless the app is activated first.
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        applyColor(SIMD4(
            Float(c.redComponent),
            Float(c.greenComponent),
            Float(c.blueComponent),
            Float(c.alphaComponent)
        ))
    }

    /// The panel calls back continuously while a swatch is dragged, so this runs
    /// often; everything it touches is a cheap assignment plus one lock per
    /// overlay, and the trail recolours under the pointer as the user drags.
    private func applyColor(_ rgba: SIMD4<Float>) {
        currentColor = rgba
        UserDefaults.standard.set(Self.encodeColor(rgba), forKey: Self.colorDefaultsKey)
        overlays.forEach { $0.setColor(rgba) }
        refreshColorChecks()
    }

    private func refreshColorChecks() {
        for item in colorMenuItems {
            guard let rgba = item.representedObject as? SIMD4<Float> else { continue }
            item.state = Self.colorsMatch(rgba, currentColor) ? .on : .off
        }
        colorNoteItem?.isHidden = currentMode.usesTrailColor
        colorNoteItem?.title = "\(currentStyle.title) picks its own colors"
    }

    private static func colorsMatch(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
        abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 && abs(a.z - b.z) < 0.01 && abs(a.w - b.w) < 0.01
    }

    private static func swatch(for rgba: SIMD4<Float>) -> NSImage {
        let size = NSSize(width: 13, height: 13)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: CGFloat(rgba.x), green: CGFloat(rgba.y), blue: CGFloat(rgba.z), alpha: 1).setFill()
            let body = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
            body.fill()
            // A white swatch on a light menu would otherwise be an empty gap.
            NSColor.separatorColor.setStroke()
            body.lineWidth = 1
            body.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func encodeColor(_ rgba: SIMD4<Float>) -> String {
        "\(rgba.x),\(rgba.y),\(rgba.z),\(rgba.w)"
    }

    private static func decodeColor(_ raw: String?) -> SIMD4<Float>? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        return SIMD4(parts[0], parts[1], parts[2], parts[3])
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        currentStyle = TrailStyleRegistry.style(id: id)
        applySelection()
    }

    @objc private func toggleEffect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if currentEffectIDs.contains(id) {
            currentEffectIDs.remove(id)
        } else {
            currentEffectIDs.insert(id)
        }
        applySelection()
    }

    private func applySelection() {
        persistSelection()
        let mode = currentMode
        overlays.forEach { $0.setMode(mode) }
        refreshModeChecks()
        refreshColorChecks()
        refreshBurstChecks()
        refreshPaletteChecks()
        refreshFadeChecks()
        refreshConfettiChecks()
    }

    private func refreshModeChecks() {
        for (id, item) in styleMenuItems {
            item.state = (id == currentStyle.id) ? .on : .off
        }
        for (id, item) in effectMenuItems {
            item.state = currentEffectIDs.contains(id) ? .on : .off
        }
    }

    /// Carbon rather than an NSEvent key monitor: a global monitor for key
    /// events needs Accessibility permission, and a hotkey registration does
    /// not. The handler takes no captured state, which is what lets it be a
    /// plain C function pointer.
    private func installHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<CursorTrailApp>.fromOpaque(userData).takeUnretainedValue().setPaused(toggle: true)
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )

        let id = EventHotKeyID(signature: OSType(0x43545241), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(controlKey | optionKey | cmdKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    @objc private func togglePause() { setPaused(toggle: true) }

    /// Reached from the hotkey handler, which is not on any particular thread.
    fileprivate func setPaused(toggle: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if toggle { self.trailEnabled.toggle() }
            self.pauseMenuItem?.title = self.trailEnabled ? "Pause Trail" : "Resume Trail"
            if !self.trailEnabled { self.activeOverlay = nil }
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func rebuildOverlays() {
        overlays.forEach { $0.shutdown() }
        let mode = currentMode
        overlays = NSScreen.screens.compactMap { OverlayController(screen: $0, config: config, mode: mode, color: currentColor) }
        overlays.forEach { $0.setPalette(currentPalette) }
        activeOverlay = nil
    }

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.sampleMouse()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.sampleMouse()
            return event
        }

        // AppKit already counts multi-clicks against the user's double-click
        // interval, so `clickCount` is the whole gesture detector. Both monitors
        // only observe -- the click still reaches whatever was under it.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleClick(event)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleClick(event)
            return event
        }

        sampleMouse(force: true)
    }

    private func handleClick(_ event: NSEvent) {
        guard trailEnabled else { return }
        // Which counts matter is the active mode's business, not this monitor's.
        let clicks = event.clickCount
        guard clicks > 0 else { return }
        let global = NSEvent.mouseLocation
        if let active = activeOverlay, NSMouseInRect(global, active.screen.frame, false) {
            active.burst(globalPoint: global, clickCount: clicks, wantedClicks: currentBurstClicks)
            return
        }
        overlays.first(where: { NSMouseInRect(global, $0.screen.frame, false) })?
            .burst(globalPoint: global, clickCount: clicks, wantedClicks: currentBurstClicks)
    }

    private func sampleMouse(force: Bool = false) {
        guard trailEnabled else { return }
        let global = NSEvent.mouseLocation

        // The pointer almost always stays on the display it was on last frame,
        // so skip the screen search in the common case.
        if let active = activeOverlay, NSMouseInRect(global, active.screen.frame, false) {
            active.add(globalPoint: global, force: force)
            return
        }

        guard let overlay = overlays.first(where: { NSMouseInRect(global, $0.screen.frame, false) }) else { return }
        activeOverlay = overlay
        overlay.beginAt(globalPoint: global)
    }
}
