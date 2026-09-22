import AppKit
import Foundation
import Metal
import QuartzCore
import simd

private struct TrailPoint {
    var p: SIMD2<Float>
    var t: Double
    /// Pointer speed when this point was sampled, already normalised to 0...1.
    var speed01: Float = 0
}

private struct TrailVertex {
    var center: SIMD2<Float>
    var normal: SIMD2<Float>
    var side: Float
    var birthTime: Float
    var speed01: Float
}

/// Mirrors `Uniforms` in Trail.metal field for field, including `pad`. Both
/// layouts put the two SIMD4s last so they land on their natural 16-byte
/// alignment without either language inserting padding of its own.
private struct Uniforms {
    var viewport: SIMD2<Float>
    var headWidth: Float
    var widthScale: Float
    var alphaScale: Float
    var glowSoftness: Float
    var now: Float
    var lifetime: Float
    var speedResponse: Float
    var hueSpread: Float
    var hueSpeed: Float
    var coloring: UInt32
    var pad: Float = 0
    var color: SIMD4<Float>
    var tailColor: SIMD4<Float>
}

/// Mirrors `ParticleVertex` in Trail.metal.
private struct ParticleVertex {
    var origin: SIMD2<Float>
    var velocity: SIMD2<Float>
    var birthTime: Float
    var hue: Float
    var size: Float
    var spin: Float
    var corner: SIMD2<Float>
    var saturation: Float
    var gravity: Float
    var lifetime: Float
    var roundness: Float
    var flutter: Float
}

/// Mirrors `RippleVertex` in Trail.metal.
private struct RippleVertex {
    var origin: SIMD2<Float>
    var corner: SIMD2<Float>
    var birthTime: Float
    var maxRadius: Float
    var thickness: Float
    var lifetime: Float
}

/// Mirrors `ParticleUniforms` in Trail.metal.
private struct ParticleUniforms {
    var viewport: SIMD2<Float>
    var now: Float
    var pad: Float = 0
    var color: SIMD4<Float>
}

/// A particle's path is fixed at spawn, so the only state worth keeping on the
/// CPU is when it was born -- enough to know when its six vertices stop being
/// worth drawing. Same shape as `RingBuffer`, and expiring is the same
/// head-advance, because particles die in the order they were created.
private final class ParticleRing {
    private var birth: [Double]
    private(set) var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        birth = Array(repeating: 0, count: max(capacity, 1))
    }

    var capacity: Int { birth.count }

    @discardableResult
    func append(birthTime: Double) -> Int {
        let index: Int
        if count < birth.count {
            index = (head + count) % birth.count
            count += 1
        } else {
            // Full: the oldest particle is overwritten mid-flight. At the
            // capacities here that only happens under a burst far larger than
            // any mode asks for, and dropping the faintest particle is the
            // least visible way to lose one.
            index = head
            head = (head + 1) % birth.count
        }
        birth[index] = birthTime
        return index
    }

    @discardableResult
    func removeExpired(before cutoff: Double) -> Bool {
        let oldHead = head
        while count > 0 && birth[head] < cutoff {
            head = (head + 1) % birth.count
            count -= 1
        }
        return head != oldHead
    }

    func removeAll() {
        head = 0
        count = 0
    }
}

/// xorshift64*, seeded per overlay. Particle spawning needs a few numbers per
/// particle on the render thread; `Float.random` reaches for the system
/// generator and a lock, which is more machinery than a confetto deserves.
private struct FastRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed | 1 }

    mutating func next01() -> Float {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let v = state &* 2685821657736338717
        return Float(v >> 40) * (1.0 / 16777216.0)
    }

    mutating func next(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + next01() * (range.upperBound - range.lowerBound)
    }
}

private final class RingBuffer {
    private var storage: [TrailPoint]
    private(set) var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = Array(repeating: TrailPoint(p: .zero, t: 0), count: capacity)
    }

    var capacity: Int { storage.count }

    @discardableResult
    func append(_ value: TrailPoint) -> Int {
        let index: Int
        if count < storage.count {
            index = (head + count) % storage.count
            storage[index] = value
            count += 1
        } else {
            index = head
            storage[index] = value
            head = (head + 1) % storage.count
        }
        return index
    }

    @discardableResult
    func removeExpired(before cutoff: Double) -> Bool {
        let oldHead = head
        while count > 0 && storage[head].t < cutoff {
            head = (head + 1) % storage.count
            count -= 1
        }
        return head != oldHead
    }

    func element(_ logicalIndex: Int) -> TrailPoint {
        storage[physicalIndex(logicalIndex)]
    }

    func physicalIndex(_ logicalIndex: Int) -> Int {
        (head + logicalIndex) % storage.count
    }

    func removeAll() {
        head = 0
        count = 0
    }
}

final class OverlayController {
    let screen: NSScreen
    private let config: TrailConfig
    private var mode: TrailMode
    private let window: NSWindow
    private let view: MetalOverlayView

    init?(screen: NSScreen, config: TrailConfig, mode: TrailMode, color: SIMD4<Float>) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.screen = screen
        self.config = config
        self.mode = mode

        // The overlay covers its whole display and then never moves or resizes.
        //
        // A smaller box that chases the cursor is tempting -- it is less to
        // clear and less for the compositor to blend -- but it cannot be made
        // correct. The shader places every vertex relative to the window's
        // origin, so a frame is only right if it reaches the screen in the same
        // refresh as the `setFrame` it was drawn for. Window geometry travels
        // to the window server on the CoreAnimation commit; a drawable travels
        // on the Metal present. Nothing lines the two up, and a CATransaction
        // around both does not group them either. Every frame still in the
        // present queue when the window moves is a frame drawn for an origin
        // that is no longer current, and each one paints the trail up to a
        // ladder step away from the pointer -- one visible ghost per drawable
        // in flight. A stationary window makes the origin a constant, which is
        // the only way the mismatch stops existing.
        let frame = screen.frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        guard let view = MetalOverlayView(frame: NSRect(origin: .zero, size: frame.size), device: device, screen: screen, config: config, mode: mode, color: color, nativeFPS: screen.maximumFramesPerSecond) else {
            return nil
        }
        window.contentView = view
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()

        self.window = window
        self.view = view
    }

    func beginAt(globalPoint: CGPoint) { view.beginAt(localPoint(globalPoint)) }
    func add(globalPoint: CGPoint, force: Bool = false) { view.record(localPoint(globalPoint), force: force) }

    func setMode(_ mode: TrailMode) {
        self.mode = mode
        view.setMode(mode)
    }

    func setColor(_ color: SIMD4<Float>) { view.setColor(color) }

    func setPalette(_ palette: ParticlePalette) { view.setPalette(palette) }

    func burst(globalPoint: CGPoint, clickCount: Int, wantedClicks: Int) {
        view.burst(at: localPoint(globalPoint), clickCount: clickCount, wantedClicks: wantedClicks)
    }

    func shutdown() {
        view.shutdown()
        window.orderOut(nil)
    }

    private func localPoint(_ global: CGPoint) -> SIMD2<Float> {
        SIMD2(Float(global.x - screen.frame.minX), Float(global.y - screen.frame.minY))
    }
}

private final class MetalOverlayView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    private static let maxPendingSamples = 24

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let metalLayer: CAMetalLayer
    private let config: TrailConfig
    private let screen: NSScreen
    private var mode: TrailMode
    /// The colour chosen in the menu bar, plus the tail colour the gradient
    /// mode derives from it. Both are recomputed whenever either the colour or
    /// the mode changes, so the render thread never does hue maths per frame.
    private var trailColor: SIMD4<Float>
    private var tailColor: SIMD4<Float>
    private var palette = ParticlePaletteRegistry.defaultPalette
    private let points: RingBuffer
    private let vertexBuffer: MTLBuffer
    private let vertexPointer: UnsafeMutablePointer<TrailVertex>
    private let particlePipeline: MTLRenderPipelineState
    private let ripplePipeline: MTLRenderPipelineState
    /// Ripples are one per click, so a handful is plenty; the same ring and
    /// mirrored-buffer scheme as particles, at a much smaller capacity.
    private let ripples: ParticleRing
    private let rippleBuffer: MTLBuffer
    private let ripplePointer: UnsafeMutablePointer<RippleVertex>
    private var pendingRipples: [SIMD2<Float>] = []
    private static let maxRipples = 24
    private let particles: ParticleRing
    private let particleBuffer: MTLBuffer
    private let particlePointer: UnsafeMutablePointer<ParticleVertex>
    /// Pointer travel since the last confetto, carried across samples so the
    /// spacing is a property of the path rather than of the event rate.
    private var emissionCarry: Float = 0
    private var pendingSpawns: [SpawnRequest] = []
    private var random: FastRandom
    private let passDescriptor = MTLRenderPassDescriptor()
    private let contentScale: Float
    private var lastPoint: SIMD2<Float>?
    private var lastSampleTime: Double = 0
    private let stateLock = NSLock()
    private let timeOrigin = CACurrentMediaTime()

    // The display link drives rendering from its own thread, so `nextDrawable`
    // blocking for the rest of a refresh interval -- which it does by design,
    // that is how vsync pacing works -- no longer holds up the main thread. The
    // mouse monitors deliver samples there, and on a 75 Hz panel a blocked main
    // thread meant samples arriving in clumps 13 ms apart instead of evenly:
    // the trail rendered fine but its shape lurched.
    private var displayLink: CADisplayLink?
    private var renderThread: Thread?
    private var wantsFrames = false

    // Presenting a drawable costs about a millisecond of CPU spread across
    // CoreAnimation's and Metal's own queues, and that price is the same
    // whether the frame draws three triangle strips or nothing at all -- a
    // bare clear-and-present loop on this machine measures the same. Drawing
    // less does not help; presenting less often is the only lever there is.
    //
    // Full refresh rate is only worth paying for while the pointer is fast
    // enough that consecutive frames land visibly apart. Below that, and
    // through the fade after the pointer stops, half rate is indistinguishable.
    // Sampling is untouched by this -- points still arrive at up to 120 Hz and
    // still land in the ring -- so the trail's *shape* is identical either way;
    // only how often that shape is put on screen changes.
    private enum FrameTier { case full, reduced }
    private var tier = FrameTier.full
    private let fullFPS: Float
    private let reducedFPS: Float
    /// Exponential average of pointer speed in points per second. Promote and
    /// demote at different speeds so a pointer hovering around the threshold
    /// does not flip the display link back and forth every frame.
    private var pointerSpeed: Float = 0
    private static let promoteSpeed: Float = 700
    private static let demoteSpeed: Float = 400
    /// Pointer speed, in points per second, that counts as "flat out" for the
    /// width response. Picked from the tier thresholds above: a touch beyond
    /// the speed that already promotes the display link to full rate.
    private static let fullWidthSpeed: Float = 1400

    // Samples captured by the event monitors, consumed by the display link.
    private var pending: [TrailPoint]
    private var pendingCount = 0

    /// Where and how many particles to spawn. The monitors decide *that* a
    /// spawn is due; the render thread decides what it looks like and writes
    /// the vertices, because it is the only thread allowed to touch the
    /// buffers the GPU is reading.
    private struct SpawnRequest {
        var p: SIMD2<Float>
        var count: Int
        var burst: Bool
        /// Which of the mode's emitters threw these.
        var emitter: Int
    }
    private static let maxPendingSpawns = 16

    // Cached hot-path scalars so the sample gate touches no struct fields.
    private let minSampleDistanceSquared: Float
    private let minSampleInterval: Double

    init?(frame: NSRect, device: MTLDevice, screen: NSScreen, config: TrailConfig, mode: TrailMode, color: SIMD4<Float>, nativeFPS: Int) {
        let full = Float(config.maxFPS > 0 ? config.maxFPS : max(nativeFPS, 1))
        self.fullFPS = full
        // Half rate, floored at 30: below that the fade itself starts to step.
        self.reducedFPS = config.adaptiveFPS ? min(full, max(30, full * 0.5)) : full
        self.device = device
        self.config = config
        self.screen = screen
        self.mode = mode
        self.trailColor = color
        self.tailColor = TrailColorMath.rotatingHue(of: color, by: mode.tailHueShift)
        self.points = RingBuffer(capacity: config.maxPoints)
        self.particles = ParticleRing(capacity: config.maxParticles)
        self.ripples = ParticleRing(capacity: MetalOverlayView.maxRipples)
        // Seeded off the screen's position so two displays do not throw
        // identical confetti. `truncatingIfNeeded` rather than `Int64(...)`:
        // that one is a checked conversion, and a display sitting at a negative
        // origin has the sign bit set in its bit pattern, which overflows Int64
        // and traps. Only ever reachable with a second display.
        let originBits = UInt64(truncatingIfNeeded: screen.frame.origin.x.bitPattern)
            &* 0x9E3779B97F4A7C15
            &+ UInt64(truncatingIfNeeded: screen.frame.origin.y.bitPattern)
        self.random = FastRandom(seed: originBits)
        self.pending = Array(repeating: TrailPoint(p: .zero, t: 0), count: MetalOverlayView.maxPendingSamples)
        self.minSampleDistanceSquared = config.minSampleDistance * config.minSampleDistance
        self.minSampleInterval = config.minSampleInterval
        self.contentScale = Float(screen.backingScaleFactor)

        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        // Double-mirrored ring: any logical trail is one contiguous triangle strip,
        // even when the ring wraps. Each physical point exists twice in this buffer.
        let maxVertices = config.maxPoints * 4
        guard let vb = device.makeBuffer(length: MemoryLayout<TrailVertex>.stride * maxVertices, options: [.storageModeShared]) else { return nil }
        self.vertexBuffer = vb
        self.vertexPointer = vb.contents().bindMemory(to: TrailVertex.self, capacity: maxVertices)

        // Six vertices per particle, doubled like the trail's so any live run
        // is one contiguous draw even when the ring wraps.
        let maxParticleVertices = config.maxParticles * 12
        guard let pb = device.makeBuffer(length: MemoryLayout<ParticleVertex>.stride * maxParticleVertices, options: [.storageModeShared]) else { return nil }
        self.particleBuffer = pb
        self.particlePointer = pb.contents().bindMemory(to: ParticleVertex.self, capacity: maxParticleVertices)

        let maxRippleVertices = MetalOverlayView.maxRipples * 12
        guard let rb = device.makeBuffer(length: MemoryLayout<RippleVertex>.stride * maxRippleVertices, options: [.storageModeShared]) else { return nil }
        self.rippleBuffer = rb
        self.ripplePointer = rb.contents().bindMemory(to: RippleVertex.self, capacity: maxRippleVertices)

        guard let library = MetalOverlayView.loadLibrary(device: device),
              let vertex = library.makeFunction(name: "trailVertex"),
              let fragment = library.makeFunction(name: "trailFragment"),
              let particleVertex = library.makeFunction(name: "particleVertex"),
              let particleFragment = library.makeFunction(name: "particleFragment"),
              let rippleVertex = library.makeFunction(name: "rippleVertex"),
              let rippleFragment = library.makeFunction(name: "rippleFragment") else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fputs("CursorTrail: pipeline creation failed: \(error)\n", stderr)
            return nil
        }

        // Same blend state, different shaders: particles are ordinary
        // source-over sprites drawn after the trail in the same pass.
        desc.vertexFunction = particleVertex
        desc.fragmentFunction = particleFragment
        do {
            self.particlePipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fputs("CursorTrail: particle pipeline creation failed: \(error)\n", stderr)
            return nil
        }

        desc.vertexFunction = rippleVertex
        desc.fragmentFunction = rippleFragment
        do {
            self.ripplePipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fputs("CursorTrail: ripple pipeline creation failed: \(error)\n", stderr)
            return nil
        }

        self.metalLayer = CAMetalLayer()
        super.init(frame: frame)

        let color = passDescriptor.colorAttachments[0]!
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = MTLClearColorMake(0, 0, 0, 0)

        wantsLayer = true
        layer = metalLayer
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = screen.backingScaleFactor
        metalLayer.drawableSize = CGSize(width: frame.width * screen.backingScaleFactor, height: frame.height * screen.backingScaleFactor)
        // Two drawables, not three: a deeper queue only buys smoothness when
        // the render thread might miss a deadline, and this one draws a handful
        // of triangles. What it costs is latency, and the trail is judged
        // against a pointer the window server draws with none.
        metalLayer.maximumDrawableCount = 2

        // Nothing below reshapes the layer. A backing-scale or resolution change
        // arrives as NSApplication.didChangeScreenParametersNotification, which
        // rebuilds every overlay from scratch -- so the render thread is the only
        // thread that ever touches the layer after this point.
        startRenderThread()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func beginAt(_ p: SIMD2<Float>) {
        let now = CACurrentMediaTime()
        stateLock.lock()
        points.removeAll()
        pendingCount = 0
        emissionCarry = 0
        pendingSpawns.removeAll(keepingCapacity: true)
        pointerSpeed = 0
        tier = .full
        applyTierUnlocked()
        lastPoint = p
        lastSampleTime = now
        let physical = points.append(TrailPoint(p: p, t: now))
        writeVertexPair(logicalIndex: 0, physicalIndex: physical)
        requestFramesUnlocked()
        stateLock.unlock()
    }

    /// Hot path: called once per mouse event. Does nothing but gate the sample,
    /// stash it, and make sure the display link is running. All geometry and
    /// vertex work is coalesced into the next `renderFrame`, on another thread.
    func record(_ p: SIMD2<Float>, force: Bool = false) {
        let now = CACurrentMediaTime()
        stateLock.lock()

        if !force, let lastPoint {
            if simd_length_squared(p - lastPoint) < minSampleDistanceSquared
                || now - lastSampleTime < minSampleInterval {
                stateLock.unlock()
                return
            }
        }

        if let lastPoint, now > lastSampleTime {
            let instant = simd_length(p - lastPoint) / Float(now - lastSampleTime)
            pointerSpeed += (instant - pointerSpeed) * 0.35
            // Promote from the sampling path, not from the next frame: at half
            // rate that frame can be 33 ms away, and the start of a flick is
            // exactly where the missing frames would show.
            if tier == .reduced && pointerSpeed >= MetalOverlayView.promoteSpeed {
                tier = .full
                applyTierUnlocked()
            }
        }

        if let style = mode.emitters.first(where: { $0.trigger == .movement }), let previous = lastPoint {
            emissionCarry += simd_length(p - previous)
            let spacing = max(style.spacing, 0.5)
            if emissionCarry >= spacing {
                let due = Int(emissionCarry / spacing)
                emissionCarry -= Float(due) * spacing
                let index = mode.emitters.firstIndex(where: { $0.trigger == .movement }) ?? 0
                queueSpawnUnlocked(SpawnRequest(p: p, count: due, burst: false, emitter: index))
            }
        }

        lastPoint = p
        lastSampleTime = now
        let speed01 = min(pointerSpeed / MetalOverlayView.fullWidthSpeed, 1)
        if pendingCount < pending.count {
            pending[pendingCount] = TrailPoint(p: p, t: now, speed01: speed01)
            pendingCount += 1
        } else {
            // Absurd event rate: keep the newest sample, drop the previous one.
            pending[pending.count - 1] = TrailPoint(p: p, t: now, speed01: speed01)
        }
        requestFramesUnlocked()
        stateLock.unlock()
    }

    /// A click landed on this display. Ignored unless the active mode has an
    /// emitter waiting for exactly this many clicks, so the monitor can stay
    /// installed for every mode.
    func burst(at p: SIMD2<Float>, clickCount: Int, wantedClicks: Int) {
        stateLock.lock()
        guard clickCount == wantedClicks else {
            stateLock.unlock()
            return
        }

        var answered = false
        if let index = mode.emitters.firstIndex(where: { $0.trigger == .click }) {
            queueSpawnUnlocked(SpawnRequest(p: p, count: mode.emitters[index].burstCount, burst: true, emitter: index))
            answered = true
        }
        if !mode.ripples.isEmpty, pendingRipples.count < MetalOverlayView.maxRipples {
            pendingRipples.append(p)
            answered = true
        }
        if answered { requestFramesUnlocked() }
        stateLock.unlock()
    }

    /// Caller must hold `stateLock`.
    private func queueSpawnUnlocked(_ request: SpawnRequest) {
        guard request.count > 0 else { return }
        if pendingSpawns.count < MetalOverlayView.maxPendingSpawns {
            pendingSpawns.append(request)
        } else {
            // The render thread has not run in a long while. Fold the newest
            // request into the last one rather than growing without bound; the
            // particles land a few pixels off where they were asked for, which
            // is invisible next to losing them.
            pendingSpawns[pendingSpawns.count - 1].count += request.count
        }
    }

    func setMode(_ mode: TrailMode) {
        stateLock.lock()
        self.mode = mode
        self.tailColor = TrailColorMath.rotatingHue(of: trailColor, by: mode.tailHueShift)
        // Confetti already in the air belongs to the mode that threw it, and
        // it would be wrong to keep drawing it with the new mode's physics.
        particles.removeAll()
        ripples.removeAll()
        emissionCarry = 0
        pendingSpawns.removeAll(keepingCapacity: true)
        pendingRipples.removeAll(keepingCapacity: true)
        stateLock.unlock()
    }

    func setPalette(_ palette: ParticlePalette) {
        stateLock.lock()
        self.palette = palette
        stateLock.unlock()
    }

    func setColor(_ color: SIMD4<Float>) {
        stateLock.lock()
        self.trailColor = color
        self.tailColor = TrailColorMath.rotatingHue(of: color, by: mode.tailHueShift)
        stateLock.unlock()
    }

    func shutdown() {
        stateLock.lock()
        wantsFrames = false
        displayLink?.isPaused = true
        stateLock.unlock()

        guard let thread = renderThread else { return }
        renderThread = nil
        thread.cancel()
        if thread.isExecuting {
            // Break the run loop out of its wait so it notices the cancel and
            // invalidates the link on the thread that scheduled it.
            perform(#selector(wakeRenderThread), on: thread, with: nil, waitUntilDone: false, modes: [RunLoop.Mode.default.rawValue])
        }
    }

    @objc private func wakeRenderThread() {}

    /// Caller must hold `stateLock`. `preferredFrameRateRange` is the supported
    /// way to ask for fewer callbacks; unlike skipping frames inside the
    /// callback it lets the system stop waking the render thread at all.
    private func applyTierUnlocked() {
        guard let displayLink else { return }
        guard tier == .reduced || config.maxFPS > 0 else {
            // Uncapped full rate: ask for nothing and let the link run on the
            // display's own cadence rather than pinning it to a number.
            displayLink.preferredFrameRateRange = .default
            return
        }
        let fps = tier == .full ? fullFPS : reducedFPS
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: max(1, fps * 0.5), maximum: fps, preferred: fps
        )
    }

    private func startRenderThread() {
        let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.isPaused = true
        displayLink = link
        stateLock.lock()
        applyTierUnlocked()
        stateLock.unlock()

        let thread = Thread { [weak self] in
            guard let self else { return }
            let runLoop = RunLoop.current
            // A run loop with no input source returns from `run` immediately,
            // which turns the loop below into a spin. This port is never
            // signalled; it exists so there is something to sleep on while the
            // display link is paused. `shutdown` wakes the thread with a
            // `perform(on:)` so the cancel is noticed without polling.
            runLoop.add(NSMachPort(), forMode: .common)
            link.add(to: runLoop, forMode: .common)

            // A sample may have landed between `displayLink` being stored and
            // the link reaching a run loop; honour it rather than sit paused.
            self.stateLock.lock()
            link.isPaused = !self.wantsFrames
            self.stateLock.unlock()

            // Runs in `.default`, never in `.common`: common is a pseudo-mode you
            // add sources *to*, and asking a run loop to run in it does nothing and
            // returns false at once. `.default` is itself a common mode, so the link
            // and the port above -- both registered against common -- fire here.
            while !Thread.current.isCancelled && runLoop.run(mode: .default, before: .distantFuture) {}
            link.invalidate()
        }
        thread.name = "com.cursortrail.render"
        thread.qualityOfService = .userInteractive
        renderThread = thread
        thread.start()
    }

    /// Caller must hold `stateLock`. Pausing and unpausing both happen under it
    /// so a sample arriving as the trail expires cannot be stranded by the
    /// render thread pausing the link a moment later.
    private func requestFramesUnlocked() {
        guard !wantsFrames else { return }
        wantsFrames = true
        tier = .full
        applyTierUnlocked()
        displayLink?.isPaused = false
    }

    @objc private func displayLinkFired(_ sender: CADisplayLink) { renderFrame() }

    /// Moves the ring forward by every sample the monitors stashed since the
    /// last frame. Returns how many points were appended.
    private func drainPendingUnlocked() -> Int {
        let n = pendingCount
        guard n > 0 else { return 0 }
        for i in 0..<n { points.append(pending[i]) }
        pendingCount = 0
        return n
    }

    /// Two triangles, wound so one `.triangle` draw covers every particle.
    private static let quadCorners: [SIMD2<Float>] = [
        SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
        SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1),
    ]

    /// Caller must hold `stateLock`; runs on the render thread. Turns each
    /// queued request into particles and writes their vertices once -- after
    /// this the GPU derives everything else from the vertex's age.
    private func drainSpawnsUnlocked(emitters: [ParticleStyle], nowAbsolute: Double) {
        guard !pendingSpawns.isEmpty else { return }
        let birth = Float(nowAbsolute - timeOrigin)

        for request in pendingSpawns {
            guard request.emitter < emitters.count else { continue }
            let style = emitters[request.emitter]
            for _ in 0..<request.count {
                // A burst goes out in every direction; movement throws the
                // paper up and off the pointer within a cone.
                let angle = request.burst
                    ? random.next01() * 2 * .pi
                    : .pi / 2 + (random.next01() * 2 - 1) * style.spread
                let speed = random.next(in: style.speed)
                let velocity = SIMD2(cos(angle), sin(angle)) * speed * contentScale

                let spin: Float
                if style.spin.lowerBound >= style.spin.upperBound {
                    spin = 0
                } else {
                    let magnitude = random.next(in: style.spin)
                    spin = random.next01() < 0.5 ? -magnitude : magnitude
                }

                let physical = particles.append(birthTime: nowAbsolute)
                let vertex = ParticleVertex(
                    origin: request.p * contentScale,
                    velocity: velocity,
                    birthTime: birth,
                    // `randomHue` says the effect wants a colour of its own;
                    // the palette says which. A palette of the trail colour is
                    // the -1 sentinel the shader already understood.
                    hue: (style.randomHue && !palette.usesTrailColor)
                        ? (palette.hueStart + random.next01() * palette.hueSpan)
                            .truncatingRemainder(dividingBy: 1)
                        : -1,
                    // Vary the size a little: identical confetti reads as a
                    // texture rather than as separate pieces of paper.
                    size: style.size * contentScale * (0.7 + 0.6 * random.next01()),
                    spin: spin,
                    corner: .zero,
                    saturation: palette.saturation,
                    gravity: style.gravity * contentScale,
                    lifetime: style.lifetime,
                    roundness: style.roundness,
                    flutter: style.flutter ? 1 : 0
                )

                let base = physical * 6
                let mirror = (physical + config.maxParticles) * 6
                for i in 0..<6 {
                    var v = vertex
                    v.corner = MetalOverlayView.quadCorners[i]
                    particlePointer[base + i] = v
                    particlePointer[mirror + i] = v
                }
            }
        }
        pendingSpawns.removeAll(keepingCapacity: true)
    }

    /// Caller must hold `stateLock`; runs on the render thread.
    private func drainRipplesUnlocked(style: RippleStyle, nowAbsolute: Double) {
        guard !pendingRipples.isEmpty else { return }
        let birth = Float(nowAbsolute - timeOrigin)

        for origin in pendingRipples {
            let physical = ripples.append(birthTime: nowAbsolute)
            let vertex = RippleVertex(
                origin: origin * contentScale,
                corner: .zero,
                birthTime: birth,
                maxRadius: style.maxRadius * contentScale,
                thickness: style.thickness * contentScale,
                lifetime: style.lifetime
            )
            let base = physical * 6
            let mirror = (physical + MetalOverlayView.maxRipples) * 6
            for i in 0..<6 {
                var v = vertex
                v.corner = MetalOverlayView.quadCorners[i]
                ripplePointer[base + i] = v
                ripplePointer[mirror + i] = v
            }
        }
        pendingRipples.removeAll(keepingCapacity: true)
    }

    private func writeVertexPair(logicalIndex: Int, physicalIndex explicitPhysical: Int? = nil) {
        guard logicalIndex >= 0, logicalIndex < points.count else { return }
        let physical = explicitPhysical ?? points.physicalIndex(logicalIndex)
        let current = points.element(logicalIndex)
        let prev = points.element(max(logicalIndex - 1, 0)).p
        let next = points.element(min(logicalIndex + 1, points.count - 1)).p
        var tangent = next - prev
        let len = simd_length(tangent)
        if len > 0.0001 { tangent /= len } else { tangent = SIMD2(1, 0) }
        let normal = SIMD2(-tangent.y, tangent.x)
        let birth = Float(current.t - timeOrigin)

        let center = current.p * contentScale
        let pair = physical * 2
        let mirrorPair = (physical + config.maxPoints) * 2
        let left = TrailVertex(center: center, normal: normal, side: -1, birthTime: birth, speed01: current.speed01)
        let right = TrailVertex(center: center, normal: normal, side: 1, birthTime: birth, speed01: current.speed01)
        vertexPointer[pair] = left
        vertexPointer[pair + 1] = right
        vertexPointer[mirrorPair] = left
        vertexPointer[mirrorPair + 1] = right
    }

    private func renderFrame() {
        let nowAbsolute = CACurrentMediaTime()

        stateLock.lock()
        let mode = self.mode
        let color = self.trailColor
        let tail = self.tailColor
        let headChanged = points.removeExpired(before: nowAbsolute - Double(mode.lifetime))
        let appended = drainPendingUnlocked()
        let count = points.count

        if !mode.emitters.isEmpty {
            particles.removeExpired(before: nowAbsolute - Double(mode.maxParticleLifetime))
            drainSpawnsUnlocked(emitters: mode.emitters, nowAbsolute: nowAbsolute)
        } else if particles.count > 0 {
            particles.removeAll()
        }
        if let style = mode.ripples.first {
            ripples.removeExpired(before: nowAbsolute - Double(mode.maxRippleLifetime))
            drainRipplesUnlocked(style: style, nowAbsolute: nowAbsolute)
        } else if ripples.count > 0 {
            ripples.removeAll()
        }

        let particleCount = particles.count
        let particleStart = particles.head * 6
        let rippleCount = ripples.count
        let rippleStart = ripples.head * 6

        // A frame with no new sample means the pointer has stopped or is
        // crawling; let the average fall so the fade-out settles at half rate.
        if appended == 0 { pointerSpeed *= 0.7 }
        if particleCount > 0 || rippleCount > 0 {
            // Particles are the one thing on screen that moves independently of
            // the pointer, and sparks cross a display far faster than a pointer
            // ever does. Half rate would strobe them, so hold full rate until
            // the last one dies -- a cost only the particle modes pay.
            if tier == .reduced {
                tier = .full
                applyTierUnlocked()
            }
        } else if tier == .full && pointerSpeed < MetalOverlayView.demoteSpeed {
            tier = .reduced
            applyTierUnlocked()
        }

        let drawTrail = count >= 2
        if !drawTrail && particleCount == 0 && rippleCount == 0 {
            // The last frame with a drawable trail had every point at the end of
            // its life, so it faded to nothing; there is no stale pixel to clear.
            wantsFrames = false
            displayLink?.isPaused = true
            stateLock.unlock()
            return
        }

        // Appending shifts tangents for the new points and their predecessor;
        // expiring (or wrapping) the head shifts the tangent of the new point 0.
        if drawTrail && (headChanged || appended > 0) {
            writeVertexPair(logicalIndex: 0)
            var i = max(1, count - appended - 1)
            while i < count {
                writeVertexPair(logicalIndex: i)
                i += 1
            }
        }
        let vertexStart = points.head * 2
        let now = Float(nowAbsolute - timeOrigin)
        stateLock.unlock()

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else { return }
        let attachment = passDescriptor.colorAttachments[0]!
        attachment.texture = drawable.texture
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            attachment.texture = nil
            return
        }

        // The window is screen-aligned and stationary, so vertex centres -- which
        // are display-local points scaled to pixels -- are already drawable
        // coordinates. No origin to subtract, and nothing to get out of step.
        let viewport = SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height))

        if drawTrail {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            for passStyle in mode.passes {
                drawPass(
                    encoder: encoder,
                    vertexStart: vertexStart,
                    vertexCount: count * 2,
                    viewport: viewport,
                    now: now,
                    mode: mode,
                    color: color,
                    tailColor: tail,
                    widthScale: passStyle.widthScale,
                    alpha: passStyle.alpha,
                    softness: passStyle.softness
                )
            }
        }

        if particleCount > 0 {
            var uniforms = ParticleUniforms(viewport: viewport, now: now, color: color)
            encoder.setRenderPipelineState(particlePipeline)
            encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: particleStart, vertexCount: particleCount * 6)
        }

        if rippleCount > 0 {
            var uniforms = ParticleUniforms(viewport: viewport, now: now, color: color)
            encoder.setRenderPipelineState(ripplePipeline)
            encoder.setVertexBuffer(rippleBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: rippleStart, vertexCount: rippleCount * 6)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        attachment.texture = nil
    }

    private func drawPass(encoder: MTLRenderCommandEncoder, vertexStart: Int, vertexCount: Int, viewport: SIMD2<Float>, now: Float, mode: TrailMode, color: SIMD4<Float>, tailColor: SIMD4<Float>, widthScale: Float, alpha: Float, softness: Float) {
        var uniforms = Uniforms(
            viewport: viewport,
            headWidth: mode.headWidth * contentScale,
            widthScale: widthScale,
            alphaScale: alpha,
            glowSoftness: softness,
            now: now,
            lifetime: mode.lifetime,
            speedResponse: mode.speedResponse,
            hueSpread: mode.hueSpread,
            hueSpeed: mode.hueSpeed,
            coloring: mode.coloring.rawValue,
            color: color,
            tailColor: tailColor
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: vertexStart, vertexCount: vertexCount)
    }

    private static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
        do {
            return try device.makeLibrary(source: EmbeddedShader.source, options: nil)
        } catch {
            fputs("CursorTrail: failed to compile embedded Metal shader: \(error)\n", stderr)
            return nil
        }
    }
}
