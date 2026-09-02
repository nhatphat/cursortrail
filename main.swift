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

@main
final class CursorTrailApp: NSObject, NSApplicationDelegate {
    private static let modeDefaultsKey = "selectedTrailMode"

    private let config = TrailConfig()
    private var currentMode = TrailModeRegistry.defaultMode
    private var overlays: [OverlayController] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var activeOverlay: OverlayController?
    private var statusItem: NSStatusItem?
    private var modeMenuItems: [String: NSMenuItem] = [:]

    static func main() {
        let app = NSApplication.shared
        let delegate = CursorTrailApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        currentMode = TrailModeRegistry.mode(id: UserDefaults.standard.string(forKey: Self.modeDefaultsKey))
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
        let quit = NSMenuItem(title: "Quit CursorTrail", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        refreshModeChecks()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let mode = TrailModeRegistry.mode(id: id)
        currentMode = mode
        UserDefaults.standard.set(mode.id, forKey: Self.modeDefaultsKey)
        overlays.forEach { $0.setMode(mode) }
        refreshModeChecks()
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
        overlays = NSScreen.screens.compactMap { OverlayController(screen: $0, config: config, mode: currentMode) }
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
