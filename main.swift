import AppKit
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
    private static let modeDefaultsKey = "selectedTrailMode"
    private static let colorDefaultsKey = "trailColor"

    private let config = TrailConfig()
    private var currentMode = TrailModeRegistry.defaultMode
    private var currentColor = SIMD4<Float>(0, 0, 0, 0)
    private var overlays: [OverlayController] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var activeOverlay: OverlayController?
    private var statusItem: NSStatusItem?
    private var modeMenuItems: [String: NSMenuItem] = [:]
    private var colorMenuItems: [NSMenuItem] = []
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
        currentMode = TrailModeRegistry.mode(id: UserDefaults.standard.string(forKey: Self.modeDefaultsKey))
        // The environment variable is the default, not an override: a colour
        // picked from the menu bar has been chosen more deliberately.
        currentColor = Self.decodeColor(UserDefaults.standard.string(forKey: Self.colorDefaultsKey)) ?? config.color
        setupStatusItem()
        rebuildOverlays()
        installMouseMonitors()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
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
        let header = NSMenuItem(title: "Trail Mode", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for mode in TrailModeRegistry.all {
            let modeItem = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            modeItem.target = self
            modeItem.representedObject = mode.id
            menu.addItem(modeItem)
            modeMenuItems[mode.id] = modeItem
        }

        menu.addItem(.separator())
        let colorItem = NSMenuItem(title: "Trail Color", action: nil, keyEquivalent: "")
        colorItem.submenu = buildColorMenu()
        menu.addItem(colorItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit CursorTrail", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        refreshModeChecks()
        refreshColorChecks()
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
        colorNoteItem?.title = "\(currentMode.title) picks its own colors"
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

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let mode = TrailModeRegistry.mode(id: id)
        currentMode = mode
        UserDefaults.standard.set(mode.id, forKey: Self.modeDefaultsKey)
        overlays.forEach { $0.setMode(mode) }
        refreshModeChecks()
        refreshColorChecks()
    }

    private func refreshModeChecks() {
        for (id, item) in modeMenuItems {
            item.state = (id == currentMode.id) ? .on : .off
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func rebuildOverlays() {
        overlays.forEach { $0.shutdown() }
        overlays = NSScreen.screens.compactMap { OverlayController(screen: $0, config: config, mode: currentMode, color: currentColor) }
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

        sampleMouse(force: true)
    }

    private func sampleMouse(force: Bool = false) {
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
