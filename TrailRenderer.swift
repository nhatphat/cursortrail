import AppKit
import Foundation
import Metal
import QuartzCore
import simd

private struct TrailPoint {
    var p: SIMD2<Float>
    var t: Double
}

private struct TrailVertex {
    var center: SIMD2<Float>
    var normal: SIMD2<Float>
    var side: Float
    var birthTime: Float
}

private struct Uniforms {
    var viewport: SIMD2<Float>
    var headWidth: Float
    var widthScale: Float
    var alphaScale: Float
    var glowSoftness: Float
    var now: Float
    var lifetime: Float
    var color: SIMD4<Float>
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

    init?(screen: NSScreen, config: TrailConfig, mode: TrailMode) {
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

        guard let view = MetalOverlayView(frame: NSRect(origin: .zero, size: frame.size), device: device, screen: screen, config: config, mode: mode, nativeFPS: screen.maximumFramesPerSecond) else {
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
    private let points: RingBuffer
    private let vertexBuffer: MTLBuffer
    private let vertexPointer: UnsafeMutablePointer<TrailVertex>
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

    // Samples captured by the event monitors, consumed by the display link.
    private var pending: [TrailPoint]
    private var pendingCount = 0

    // Cached hot-path scalars so the sample gate touches no struct fields.
    private let minSampleDistanceSquared: Float
    private let minSampleInterval: Double

    init?(frame: NSRect, device: MTLDevice, screen: NSScreen, config: TrailConfig, mode: TrailMode, nativeFPS: Int) {
        let full = Float(config.maxFPS > 0 ? config.maxFPS : max(nativeFPS, 1))
        self.fullFPS = full
        // Half rate, floored at 30: below that the fade itself starts to step.
        self.reducedFPS = config.adaptiveFPS ? min(full, max(30, full * 0.5)) : full
        self.device = device
        self.config = config
        self.screen = screen
        self.mode = mode
        self.points = RingBuffer(capacity: config.maxPoints)
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

        guard let library = MetalOverlayView.loadLibrary(device: device),
              let vertex = library.makeFunction(name: "trailVertex"),
              let fragment = library.makeFunction(name: "trailFragment") else { return nil }

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

        lastPoint = p
        lastSampleTime = now
        if pendingCount < pending.count {
            pending[pendingCount] = TrailPoint(p: p, t: now)
            pendingCount += 1
        } else {
            // Absurd event rate: keep the newest sample, drop the previous one.
            pending[pending.count - 1] = TrailPoint(p: p, t: now)
        }
        requestFramesUnlocked()
        stateLock.unlock()
    }

    func setMode(_ mode: TrailMode) {
        stateLock.lock()
        self.mode = mode
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
        let left = TrailVertex(center: center, normal: normal, side: -1, birthTime: birth)
        let right = TrailVertex(center: center, normal: normal, side: 1, birthTime: birth)
        vertexPointer[pair] = left
        vertexPointer[pair + 1] = right
        vertexPointer[mirrorPair] = left
        vertexPointer[mirrorPair + 1] = right
    }

    private func renderFrame() {
        let nowAbsolute = CACurrentMediaTime()

        stateLock.lock()
        let mode = self.mode
        let headChanged = points.removeExpired(before: nowAbsolute - Double(mode.lifetime))
        let appended = drainPendingUnlocked()
        let count = points.count

        // A frame with no new sample means the pointer has stopped or is
        // crawling; let the average fall so the fade-out settles at half rate.
        if appended == 0 { pointerSpeed *= 0.7 }
        if tier == .full && pointerSpeed < MetalOverlayView.demoteSpeed {
            tier = .reduced
            applyTierUnlocked()
        }

        if count < 2 {
            // The last frame with a drawable trail had every point at the end of
            // its life, so it faded to nothing; there is no stale pixel to clear.
            wantsFrames = false
            displayLink?.isPaused = true
            stateLock.unlock()
            return
        }

        // Appending shifts tangents for the new points and their predecessor;
        // expiring (or wrapping) the head shifts the tangent of the new point 0.
        if headChanged || appended > 0 {
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

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        // The window is screen-aligned and stationary, so vertex centres -- which
        // are display-local points scaled to pixels -- are already drawable
        // coordinates. No origin to subtract, and nothing to get out of step.
        let viewport = SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height))
        for passStyle in mode.passes {
            drawPass(
                encoder: encoder,
                vertexStart: vertexStart,
                vertexCount: count * 2,
                viewport: viewport,
                now: now,
                lifetime: mode.lifetime,
                headWidth: mode.headWidth,
                widthScale: passStyle.widthScale,
                alpha: passStyle.alpha,
                softness: passStyle.softness
            )
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        attachment.texture = nil
    }

    private func drawPass(encoder: MTLRenderCommandEncoder, vertexStart: Int, vertexCount: Int, viewport: SIMD2<Float>, now: Float, lifetime: Float, headWidth: Float, widthScale: Float, alpha: Float, softness: Float) {
        var uniforms = Uniforms(
            viewport: viewport,
            headWidth: headWidth * contentScale,
            widthScale: widthScale,
            alphaScale: alpha,
            glowSoftness: softness,
            now: now,
            lifetime: lifetime,
            color: config.color
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
