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
    var viewportOrigin: SIMD2<Float>
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

    // Walks the live points as at most two contiguous runs: no per-element
    // modulo, no Double conversions, SIMD min/max only.
    func bounds() -> CGRect? {
        guard count > 0 else { return nil }
        var lo = storage[head].p
        var hi = lo
        let firstRun = min(count, storage.count - head)
        storage.withUnsafeBufferPointer { buf in
            for i in 0..<firstRun {
                let p = buf[head + i].p
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
            for i in 0..<(count - firstRun) {
                let p = buf[i].p
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
        }
        return CGRect(
            x: CGFloat(lo.x),
            y: CGFloat(lo.y),
            width: CGFloat(max(1, hi.x - lo.x)),
            height: CGFloat(max(1, hi.y - lo.y))
        )
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

        let initialSize = MetalOverlayView.sizeLadder(for: screen)[0]
        let initialRect = NSRect(
            x: screen.frame.midX - initialSize.width * 0.5,
            y: screen.frame.midY - initialSize.height * 0.5,
            width: initialSize.width,
            height: initialSize.height
        )
        let window = NSWindow(
            contentRect: initialRect,
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

        guard let view = MetalOverlayView(frame: NSRect(origin: .zero, size: initialRect.size), device: device, screen: screen, config: config, mode: mode) else {
            return nil
        }
        window.contentView = view
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

    // Moving the overlay window is cheap. *Resizing* it is not: a new
    // drawableSize throws away the CAMetalLayer's drawable pool, so the next
    // frame has to allocate fresh IOSurfaces and re-register them with the
    // render server. Doing that per sample dominated this app's CPU use.
    //
    // So the overlay only ever takes one of a few fixed sizes. Normal cursor
    // motion stays inside the smallest one and never resizes at all; only a
    // fast flick, whose trail is genuinely longer, promotes to a bigger box.
    private static let sizeSteps: [CGFloat] = [0.24, 0.40, 0.62, 0.82, 1.0]
    private static let sizeStepQuantum: CGFloat = 64
    private static let minViewportSize = CGSize(width: 384, height: 288)
    /// Frames the trail must stay comfortably inside a smaller box before we
    /// pay for a shrink. Stops a trail hovering on a boundary from thrashing.
    private static let shrinkHoldFrames = 45
    private static let shrinkMargin: CGFloat = 0.75
    private static let originQuantum: CGFloat = 64
    private static let maxPendingSamples = 24

    /// The candidate overlay sizes for a display, smallest first.
    static func sizeLadder(for screen: NSScreen) -> [CGSize] {
        let full = screen.frame.size
        let q = sizeStepQuantum
        var ladder: [CGSize] = []
        for step in sizeSteps {
            let size = CGSize(
                width: min(full.width, max(minViewportSize.width, (full.width * step / q).rounded(.up) * q)),
                height: min(full.height, max(minViewportSize.height, (full.height * step / q).rounded(.up) * q))
            )
            if ladder.last != size { ladder.append(size) }
        }
        return ladder.isEmpty ? [full] : ladder
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let metalLayer: CAMetalLayer
    private let config: TrailConfig
    private let screen: NSScreen
    private var mode: TrailMode
    private var viewportRect = CGRect.zero
    private let sizeLadder: [CGSize]
    private var sizeIndex = 0
    private var shrinkFrames = 0
    private let points: RingBuffer
    private let vertexBuffer: MTLBuffer
    private let vertexPointer: UnsafeMutablePointer<TrailVertex>
    private let passDescriptor = MTLRenderPassDescriptor()
    private var lastPoint: SIMD2<Float>?
    private var lastSampleTime: Double = 0
    private var displayLink: CADisplayLink?
    private var displayLinkScheduled = false
    private let stateLock = NSLock()
    private let timeOrigin = CACurrentMediaTime()

    // Samples captured by the event monitors, consumed by the display link.
    private var pending: [TrailPoint]
    private var pendingCount = 0

    // Cached hot-path scalars so the sample gate touches no struct fields.
    private let minSampleDistanceSquared: Float
    private let minSampleInterval: Double
    private var contentScale: Float

    init?(frame: NSRect, device: MTLDevice, screen: NSScreen, config: TrailConfig, mode: TrailMode) {
        self.device = device
        self.config = config
        self.screen = screen
        self.mode = mode
        self.points = RingBuffer(capacity: config.maxPoints)
        self.pending = Array(repeating: TrailPoint(p: .zero, t: 0), count: MetalOverlayView.maxPendingSamples)
        self.minSampleDistanceSquared = config.minSampleDistance * config.minSampleDistance
        self.minSampleInterval = config.minSampleInterval
        self.contentScale = Float(screen.backingScaleFactor)
        self.sizeLadder = MetalOverlayView.sizeLadder(for: screen)

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
        self.viewportRect = CGRect(origin: .zero, size: frame.size)

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
        metalLayer.maximumDrawableCount = 2

        setupDisplayLink(for: screen)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard let screen = window?.screen else { return }
        let scale = screen.backingScaleFactor
        if metalLayer.frame != bounds { metalLayer.frame = bounds }
        if metalLayer.contentsScale != scale {
            metalLayer.contentsScale = scale
            contentScale = Float(scale)
        }
        let drawable = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if metalLayer.drawableSize != drawable { metalLayer.drawableSize = drawable }
    }

    func beginAt(_ p: SIMD2<Float>) {
        let now = CACurrentMediaTime()
        stateLock.lock()
        points.removeAll()
        pendingCount = 0
        lastPoint = p
        lastSampleTime = now
        let physical = points.append(TrailPoint(p: p, t: now))
        writeVertexPair(logicalIndex: 0, physicalIndex: physical)
        let trailBounds = points.bounds()
        startDisplayLinkUnlocked()
        stateLock.unlock()
        if let trailBounds { updateViewport(for: trailBounds, force: true) }
    }

    /// Hot path: called once per mouse event. Does nothing but gate the sample,
    /// stash it, and make sure the display link is running. All geometry, vertex
    /// and window work is coalesced into the next `renderFrame`.
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

        lastPoint = p
        lastSampleTime = now
        if pendingCount < pending.count {
            pending[pendingCount] = TrailPoint(p: p, t: now)
            pendingCount += 1
        } else {
            // Absurd event rate: keep the newest sample, drop the previous one.
            pending[pending.count - 1] = TrailPoint(p: p, t: now)
        }
        startDisplayLinkUnlocked()
        stateLock.unlock()
    }

    func setMode(_ mode: TrailMode) {
        stateLock.lock()
        self.mode = mode
        stateLock.unlock()
    }

    func shutdown() {
        guard let link = displayLink else { return }
        if displayLinkScheduled {
            link.remove(from: .main, forMode: .common)
            displayLinkScheduled = false
        }
        link.invalidate()
        displayLink = nil
    }

    private func setupDisplayLink(for screen: NSScreen) {
        let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        if config.maxFPS > 0 {
            let fps = Float(config.maxFPS)
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: max(1, fps * 0.5), maximum: fps, preferred: fps
            )
        }
        displayLink = link
    }

    @objc private func displayLinkFired(_ sender: CADisplayLink) { renderFrame() }

    private func startDisplayLinkUnlocked() {
        guard let link = displayLink, !displayLinkScheduled else { return }
        link.add(to: .main, forMode: .common)
        displayLinkScheduled = true
    }

    private func stopDisplayLinkIfIdle() {
        guard let link = displayLink, displayLinkScheduled else { return }
        link.remove(from: .main, forMode: .common)
        displayLinkScheduled = false
    }

    /// Moves the ring forward by every sample the monitors stashed since the
    /// last frame. Returns how many points were appended.
    private func drainPendingUnlocked() -> Int {
        let n = pendingCount
        guard n > 0 else { return 0 }
        for i in 0..<n { points.append(pending[i]) }
        pendingCount = 0
        return n
    }

    private func updateViewport(for trailBounds: CGRect, force: Bool = false) {
        // The generous padding covers Comet's outer glow.
        let padding: CGFloat = max(72, CGFloat(mode.headWidth) * 4.0)
        let localScreen = CGRect(origin: .zero, size: screen.frame.size)
        let need = trailBounds.insetBy(dx: -padding, dy: -padding).intersection(localScreen)
        guard !need.isNull else { return }

        let previousIndex = sizeIndex
        if !fits(need, in: sizeLadder[sizeIndex]) {
            sizeIndex = sizeLadder.firstIndex { fits(need, in: $0) } ?? (sizeLadder.count - 1)
            shrinkFrames = 0
        } else if sizeIndex > 0 {
            let smaller = sizeLadder[sizeIndex - 1]
            let margin = Self.shrinkMargin
            if need.width <= smaller.width * margin && need.height <= smaller.height * margin {
                shrinkFrames += 1
                if shrinkFrames >= Self.shrinkHoldFrames {
                    sizeIndex -= 1
                    shrinkFrames = 0
                }
            } else {
                shrinkFrames = 0
            }
        }
        let sizeChanged = force || sizeIndex != previousIndex
        let size = sizeLadder[sizeIndex]

        // Centre the box on the trail, snapped to a coarse grid so the window
        // only moves every so often, then clamp it to this display.
        let q = Self.originQuantum
        let x = min(max(0, ((need.midX - size.width * 0.5) / q).rounded() * q), max(0, localScreen.width - size.width))
        let y = min(max(0, ((need.midY - size.height * 0.5) / q).rounded() * q), max(0, localScreen.height - size.height))
        let target = CGRect(x: x, y: y, width: size.width, height: size.height)

        if !sizeChanged {
            if target == viewportRect { return }
            // Already covered: no need to chase the cursor every frame.
            if viewportRect.contains(need) { return }
        }

        viewportRect = target
        window?.setFrame(
            CGRect(
                x: screen.frame.minX + target.minX,
                y: screen.frame.minY + target.minY,
                width: target.width, height: target.height
            ),
            display: false
        )

        // A pure move leaves the drawable pool intact; only a step change on the
        // size ladder reallocates, and that is rare by construction.
        if sizeChanged {
            frame = CGRect(origin: .zero, size: target.size)
            metalLayer.frame = CGRect(origin: .zero, size: target.size)
            let scale = metalLayer.contentsScale
            metalLayer.drawableSize = CGSize(width: target.width * scale, height: target.height * scale)
        }
    }

    private func fits(_ rect: CGRect, in size: CGSize) -> Bool {
        rect.width <= size.width && rect.height <= size.height
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

        if count < 2 {
            stateLock.unlock()
            stopDisplayLinkIfIdle()
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
        let trailBounds = points.bounds()
        let now = Float(nowAbsolute - timeOrigin)
        stateLock.unlock()

        if let trailBounds { updateViewport(for: trailBounds) }

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

        let viewport = SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height))
        let viewportOrigin = SIMD2(
            Float(viewportRect.minX * metalLayer.contentsScale),
            Float(viewportRect.minY * metalLayer.contentsScale)
        )
        for passStyle in mode.passes {
            drawPass(
                encoder: encoder,
                vertexStart: vertexStart,
                vertexCount: count * 2,
                viewport: viewport,
                viewportOrigin: viewportOrigin,
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

    private func drawPass(encoder: MTLRenderCommandEncoder, vertexStart: Int, vertexCount: Int, viewport: SIMD2<Float>, viewportOrigin: SIMD2<Float>, now: Float, lifetime: Float, headWidth: Float, widthScale: Float, alpha: Float, softness: Float) {
        var uniforms = Uniforms(
            viewport: viewport,
            viewportOrigin: viewportOrigin,
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
