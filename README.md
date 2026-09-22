# CursorTrail

A tiny, native macOS cursor-trail utility focused on low overhead, smooth rendering, and easily extensible visual modes.

- Swift + AppKit + Metal
- No Xcode project
- No third-party dependencies
- `CADisplayLink` synced to the display instead of a fixed timer
- Fixed-capacity ring buffer for trail samples
- Shared Metal vertex buffer; no per-frame trail arrays
- Native menu bar mode and colour pickers, both persistent
- Five built-in modes: **Comet**, **Line**, **Rainbow Road**, **Gradient**, **Blur**
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

| Mode | Look | Passes | Colour |
|---|---|---:|---|
| **Comet** | the original Ghostty-like glowing trail | 3 | your colour |
| **Line** | a thin, understated line along the pointer path | 1 | your colour |
| **Rainbow Road** | hues sweep down the trail and scroll over time | 3 | its own |
| **Gradient** | your colour at the head, fading into a hue-rotated tail | 2 | your colour |
| **Blur** | a wide, diffuse smudge with no hard edge | 5 | your colour |

**Blur** has no separate blur pass. Stacking wide, fully soft, nearly transparent strips over each other sums to the same falloff, and each extra pass is one more `drawPrimitives` on a vertex buffer that is already bound — no second render target, no read-back.

**Rainbow Road** picks its hue from how far down the trail a fragment sits, so the pattern is anchored to the pointer and scrolls with time rather than with position on screen. **Gradient** derives its tail colour by rotating your chosen colour's hue; pick a near-grey and it lifts the saturation so the tail is still a visibly different colour.

### Adding another mode

Modes are declared in `TrailModes.swift`. Add one `TrailMode` entry to `TrailModeRegistry.all`; the menu bar is generated automatically. A mode controls its lifetime, width, its colouring (`.solid`, `.gradient`, `.rainbow`), and one-or-more GPU passes. The mouse monitoring, ring buffer, display-link lifecycle, and overlay code do not need to change.

A genuinely new *kind* of colouring needs one more branch in `trailFragment` and one more case in `TrailColoring`. That enum's raw values are the wire format of the `coloring` uniform, so they cannot be renumbered on their own.

## Trail colour

The menu bar icon has a **Trail Color** submenu: eight preset swatches, plus **Custom...** which opens the standard macOS colour panel with the alpha slider enabled. The trail recolours live while a swatch is dragged in that panel.

The chosen colour is stored in `UserDefaults` and restored on the next launch. `CURSORTRAIL_COLOR` is the *initial* value only — once a colour has been picked from the menu, that choice wins.

While **Rainbow Road** is active the submenu says so, because that mode generates its own hues and takes only the opacity from your colour.

## Tuning

Global low-level settings remain available as environment variables when running in the foreground.

```sh
CURSORTRAIL_COLOR=0.35,0.72,1.0,0.95 \
./run.sh
```

Available options:

| Variable | Default | Meaning |
|---|---:|---|
| `CURSORTRAIL_SAMPLE_DISTANCE` | `0.75` | Minimum movement, in points, before a new sample |
| `CURSORTRAIL_SAMPLE_INTERVAL` | `0.00833` | Minimum time, in seconds, between samples (120 Hz) |
| `CURSORTRAIL_MAX_POINTS` | `256` | Fixed ring-buffer capacity |
| `CURSORTRAIL_COLOR` | `0.35,0.72,1.0,0.95` | Initial RGBA components, each 0...1; the menu bar picker overrides it once used |
| `CURSORTRAIL_MAX_FPS` | `0` | Cap the render rate; `0` follows the display |
| `CURSORTRAIL_ADAPTIVE_FPS` | `1` | Halve the render rate while the pointer is slow or the trail is fading; `0` always renders at the full rate |

Both frame-rate variables are described under [Render rate](#render-rate).

## Performance design

### Idle

There is no fixed 90/120 Hz timer. Mouse events wake the relevant renderer. Once the final trail sample expires, its `CADisplayLink` is stopped.

The idle process still has AppKit windows and global mouse monitoring, but it does no continuous Metal rendering.

### Active

Each active display uses a fixed-size trail ring buffer and one preallocated shared Metal vertex buffer. A mouse sample only updates the newest one or two vertex pairs; fade age is computed in the shader, so no frame rebuilds the trail. Metal renders the pass list declared by the active mode - **Comet** uses three tiny triangle-strip passes (outer glow, middle glow, bright core), **Line** uses a single thin pass, **Blur** uses five - and every pass of every mode reuses the same vertex buffer. Colouring is a uniform and a branch in the fragment shader, so **Rainbow Road** and **Gradient** cost no extra geometry, no extra draw call, and no per-frame CPU work; the gradient's tail colour is derived once, when the colour or the mode changes. There are no per-segment CoreGraphics stroke calls.

Mouse events do no geometry work of their own. The monitors only gate the sample and stash it; the ring update and vertex writes are coalesced into the next display-link frame, on the render thread. Samples keep their own timestamps, so coalescing costs no fidelity.

### Render rate

Putting a frame on screen costs about a millisecond of CPU inside CoreAnimation and Metal regardless of how little it draws, so the cheapest frame is the one that is never presented. The display link runs at the display's full rate only while the pointer is moving fast enough for consecutive frames to land visibly apart; below 400 pt/s, and through the fade after the pointer stops, it drops to half rate (floored at 30). Crossing back above 700 pt/s promotes it from the sampling path rather than the next frame, so the start of a flick is never the frame that goes missing.

Sampling is untouched by this - points still arrive at up to 120 Hz and still land in the ring - so the shape of the trail is identical either way. Only how often that shape is presented changes. `CURSORTRAIL_ADAPTIVE_FPS=0` pins the full rate; `CURSORTRAIL_MAX_FPS` caps it.

### Multi-display

Each display owns its own transparent overlay and display link. The overlay covers its whole display and never moves or resizes - a smaller box that chases the cursor cannot be kept in step with the frames already in the present queue, and each stale frame paints a visible ghost. Moving onto another display starts its renderer while the old display is allowed to finish fading. Displays with no trail remain stopped.

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
TrailRenderer.swift  overlays, ring buffer, CADisplayLink, Metal renderer
Trail.metal          editable Metal shader source
build.sh             embeds Trail.metal, then builds one native executable with swiftc
run.sh               foreground run
install.sh           LaunchAgent install
uninstall.sh         uninstall
```
