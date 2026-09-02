# CursorTrail

A tiny, native macOS cursor-trail utility focused on low overhead, smooth rendering, and easily extensible visual modes.

- Swift + AppKit + Metal
- No Xcode project
- No third-party dependencies
- `CVDisplayLink` synced to the display instead of a fixed timer
- Fixed-capacity ring buffer for trail samples
- Shared Metal vertex buffer; no per-frame trail arrays
- Native menu bar mode picker with persistent selection
- Built-in **Comet** (Ghostty-like) and **Line** modes
- Mode registry designed so new modes can be added without changing the input/render core
- Transparent click-through overlay per display
- Only a display that currently has a fading trail renders
- Render loop stops completely after the trail expires

## Requirements

- macOS 13+ recommended
- Apple Silicon or Intel Mac with Metal support
- Xcode Command Line Tools (`xcrun`, `swiftc`) — full Xcode and the standalone `metal` compiler are not required

Check:

```sh
xcrun swiftc --version
```

## Build

```sh
./build.sh
```

Output:

```text
bin/cursortrail
```

No `.app` bundle and no `.xcodeproj` are required.


## Embedded Metal shader

`Trail.metal` stays as a normal source file in the repository. During `./build.sh`, the script base64-encodes that source and generates `bin/EmbeddedShader.swift`; `swiftc` then embeds it into `bin/cursortrail`. The generated Swift file is only a build artifact.

At process startup, CursorTrail compiles the embedded shader source once with `MTLDevice.makeLibrary(source:options:)`, creates the Metal pipeline, and reuses it for the lifetime of the process. There is no shader compilation per frame or per mouse movement.

This keeps the install self-contained: after building, `install.sh` only needs to copy `cursortrail`. No `.metal` or `.metallib` file is required at runtime, and CLT-only Macs do not need the standalone Metal compiler.

## Run

```sh
./run.sh
```

Stop it with `Ctrl-C` when running in the foreground.

## Install at login

```sh
./install.sh
```

This copies the single self-contained binary to:

```text
~/Library/Application Support/CursorTrail/
```

and installs a user LaunchAgent:

```text
~/Library/LaunchAgents/io.cursortrail.agent.plist
```

Remove it with:

```sh
./uninstall.sh
```

## Trail modes

Choose the active mode from the menu bar icon. The selection is stored in `UserDefaults` and restored on the next launch.

Built-in modes:

- **Comet** — the original Ghostty-like glowing trail, rendered as three GPU passes.
- **Line** — a thin, understated line that follows the pointer path and fades away, rendered as one GPU pass.

### Adding another mode

Modes are declared in `TrailModes.swift`. Add one `TrailMode` entry to `TrailModeRegistry.all`; the menu bar is generated automatically. A mode controls its lifetime, width, and one-or-more GPU passes. The mouse monitoring, ring buffer, display-link lifecycle, and overlay code do not need to change.

## Tuning

Global low-level settings remain available as environment variables when running in the foreground.

```sh
CURSORTRAIL_COLOR=0.35,0.72,1.0,0.95 \
./run.sh
```

Available options:

| Variable | Default | Meaning |
|---|---:|---|
| `CURSORTRAIL_SAMPLE_DISTANCE` | `0.75` | Minimum movement before a new sample |
| `CURSORTRAIL_MAX_POINTS` | `256` | Fixed ring-buffer capacity |
| `CURSORTRAIL_COLOR` | `0.35,0.72,1.0,0.95` | Linear-ish RGBA components, each 0...1 |
| `CURSORTRAIL_MAX_FPS` | `0` | Cap the render rate; `0` follows the display. See below |

## Performance design

### Idle

There is no fixed 90/120 Hz timer. Mouse events wake the relevant renderer. Once the final trail sample expires, its `CVDisplayLink` is stopped.

The idle process still has AppKit windows and global mouse monitoring, but it does no continuous Metal rendering.

### Active

Each active display uses a fixed-size trail ring buffer and one preallocated shared Metal vertex buffer. Metal renders the pass list declared by the active mode. **Comet** uses three tiny triangle-strip passes (outer glow, middle glow, bright core), while **Line** uses a single thin pass. All passes reuse the same vertex buffer. There are no per-segment CoreGraphics stroke calls.

### Multi-display

Each display owns its own transparent overlay and display link. Moving onto another display starts its renderer while the old display is allowed to finish fading. Displays with no trail remain stopped.

## Measuring it on your Mac

Use Activity Monitor, or from Terminal:

```sh
ps -o pid,%cpu,rss,command -p "$(pgrep -n cursortrail)"
```

For a better CPU sample:

```sh
sudo powermetrics --samplers tasks -i 1000 -n 10 | grep -i cursortrail
```

For allocation/GPU investigation, open the executable in Instruments and use Time Profiler + Allocations + Metal System Trace.

## Prototype notes

This is deliberately a small source-first prototype, not a signed/notarized product. Because it is a raw executable rather than an app bundle, macOS security/privacy prompts can be less polished than a normal `.app`.

The global `NSEvent` monitor is used to receive mouse movement outside the process. Depending on macOS security policy/version, you may need to grant the executable/Input Monitoring-related permission if macOS asks for it.

## Files

```text
main.swift           app lifecycle + menu bar + global mouse monitoring
TrailModes.swift     extensible mode registry and GPU pass presets
TrailRenderer.swift  overlays, ring buffer, CVDisplayLink, Metal renderer
Trail.metal          editable Metal shader source
build.sh             embeds Trail.metal, then builds one native executable with swiftc
run.sh               foreground run
install.sh           LaunchAgent install
uninstall.sh         uninstall
```

## Performance notes (v3)

The renderer keeps trail geometry in a mirrored fixed-size GPU ring buffer. Mouse samples only update the newest one or two vertex pairs; fade age is calculated in the Metal shader. This avoids rebuilding every trail vertex on every display frame. Sampling is also capped to 120 Hz by default (`CURSORTRAIL_SAMPLE_INTERVAL`, seconds) while preserving display-synced fading.

## Performance v5

The Metal overlay is no longer permanently full-screen. CursorTrail keeps a small, padded drawable around the active trail and expands/repositions it only when needed. This preserves the original 3-pass Comet appearance while reducing transparent Retina surface compositing work.

## Performance v6

v5 sized the overlay to fit the trail exactly, which meant `drawableSize` changed 10-20 times a second while the cursor moved. Every change discards the `CAMetalLayer` drawable pool, so the next frame has to allocate fresh `IOSurface`s and re-register them with the render server. Profiling showed that churn, not the drawing, was the dominant cost: `-[CAMetalLayer nextDrawable]` accounted for roughly three quarters of the render-loop time.

v6 keeps the overlay on a short ladder of fixed sizes instead:

- The window is **moved** freely (cheap) but only ever **resized** to one of five sizes derived from the display, with hysteresis before it steps back down. Ordinary cursor motion stays on the smallest rung and never resizes at all; a fast flick promotes one rung, once. Measured over a fast 10 s sweep: 1 resize total, down from 11-18 per second.
- Mouse events no longer do geometry work. The event monitors only gate the sample and stash it; the ring buffer update, vertex writes, bounds and window placement are coalesced into the next display-link frame. Sample fidelity is unchanged - pending samples keep their own timestamps.
- Smaller wins: the vertex buffer pointer and the render pass descriptor are created once rather than per write/frame, the sample distance gate compares squared lengths, and trail bounds are computed over at most two contiguous runs with SIMD min/max instead of a modulo per point.

Measured on an M1 (60 Hz display, `ps` CPU-time deltas), CPU while the cursor is moving:

| | v5 | v6 |
|---|---:|---:|
| typical motion (~250 px/s) | 9% | 9% |
| fast sweep (~2000 px/s) | 14% | 9% |
| idle | 0% | 0% |

The remaining cost is close to the floor for this kind of app. About 4 points of it is the process receiving and decoding mouse-moved events at the display rate - a bare accessory app with one visible window and no drawing at all measures the same 4% - and the rest is the fixed per-frame cost of submitting and presenting one Metal frame 60 times a second. Neither shrinks by drawing less: pass count, render scale and drawable count all measured identically.

If you want to go below that, the only real lever is rendering fewer frames. `CURSORTRAIL_MAX_FPS=30` measures 7%, at the cost of a visibly choppier trail.

Trade-off worth knowing: the drawable is now sized by rung rather than fitted exactly, so a sustained fast flick holds a larger surface than v5 did - physical footprint peaks around 42 MB instead of 24 MB while that lasts, then falls back (about 20 MB during ordinary motion, 11 MB idle) once the trail shrinks and the shrink hysteresis elapses. A denser ladder was measured and rejected: it saved 4 MB at the peak but tripled the resize count and cost a point of CPU.

Trail coverage was checked rather than assumed. Over 10 s runs at both speeds, neither v5 nor v6 clipped the trail itself in any frame, and v6 clips the outer glow margin in 5 frames out of 621 where v5 clipped it in 544 out of 598 - the fixed rungs are centred and generous, where v5's exact fit let the padding fall off the edge of the drawable.
