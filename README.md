# CursorTrail

A tiny, native macOS cursor-trail utility focused on low overhead, smooth rendering, and easily extensible visual modes.

- Swift + AppKit + Metal
- No Xcode project
- No third-party dependencies
- `CADisplayLink` synced to the display instead of a fixed timer
- Fixed-capacity ring buffer for trail samples
- Shared Metal vertex buffer; no per-frame trail arrays
- Native menu bar mode and colour pickers, both persistent
- Trail style and particle effects are independent: pick one style, tick any effects
- Pointer speed drives trail width; global hotkey to pause
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

## Trail styles and effects

Choose them from the menu bar icon. Selections are stored in `UserDefaults` and restored on the next launch.

CursorTrail has two independent axes, and the menu bar reflects that: **Trail Style** is a single choice, **Effects** are checks. Any style combines with any set of effects — including **None**, which draws no trail at all and leaves you with only the effects you switched on.

Styles:

| Style | Look | Passes | Colour |
|---|---|---:|---|
| **Comet** | the original Ghostty-like glowing trail | 3 | your colour |
| **Line** | a thin, understated line along the pointer path | 1 | your colour |
| **Rainbow Road** | hues sweep down the trail and scroll over time | 3 | its own |
| **Gradient** | your colour at the head, fading into a hue-rotated tail | 2 | your colour |
| **Blur** | a wide, diffuse smudge with no hard edge | 5 | your colour |
| **None** | no trail; only the checked effects are drawn | 0 | — |

Effects:

| Effect | Fires on | What it does |
|---|---|---|
| **Confetti** | movement | paper thrown off the pointer, fluttering down |
| **Firework** | a click | 72 sparks radially from the click |
| **Click Ripple** | a click | a train of rings spreading out and fading |
| **Cat** | movement | a cat that walks the path you took, then sits, then sleeps |

**Blur** has no separate blur pass. Stacking wide, fully soft, nearly transparent strips over each other sums to the same falloff, and each extra pass is one more `drawPrimitives` on a vertex buffer that is already bound — no second render target, no read-back.

**None** carries no passes, and the renderer treats that as "skip the trail" rather than drawing an empty one: the pointer is still sampled, because **Confetti** emits along its path, but a sample that throws no particle no longer wakes the display link either.

**Rainbow Road** picks its hue from how far down the trail a fragment sits, so the pattern is anchored to the pointer and scrolls with time rather than with position on screen. **Gradient** derives its tail colour by rotating your chosen colour's hue; pick a near-grey and it lifts the saturation so the tail is still a visibly different colour.

## Trail width follows pointer speed

The trail is thin where the pointer was crawling and fuller where it was flicking. The speed is recorded **per sample**, not applied per frame: a single multiplier on the whole trail would make the part drawn a second ago swell and shrink along with the pointer's current speed, which reads as breathing. A mode sets how much of its width it hands over with `speedResponse`; **Line** sets it to zero, because a hairline that swells stops reading as a line.

## Particle and ripple effects

**Confetti** emits along the pointer's path — one piece per 14 points of travel, so the spacing is a property of the path rather than of the event rate: a slow drag does not carpet the screen and a flick does not leave gaps. **Firework** throws 72 sparks radially from wherever you click. **Click Ripple** sends out three rings, each launched a little after the one before, so they chase each other outward the way a stone dropped in water sends them. Each expands quickly and then eases off, fading as it goes, and later waves start fainter so the first stays the leading edge. The quad does not grow: it is fixed at the largest radius and the fragment decides where every ring is, which is what lets one quad carry a whole train of waves instead of one ring each.

Confetti's density and shape are chosen from the menu bar — see [Confetti amount and shape](#confetti-amount-and-shape).

A particle's whole path is decided the moment it spawns, so its six vertices are written once and never touched again; position, rotation and fade are evaluated from the vertex's age in the vertex shader. This is the same trick the trail uses for its fade, for the same reason — the CPU does no per-frame particle work, and a frame drawing hundreds of particles is one draw call with no buffer traffic. Ripples work the same way and share the particle uniforms. Motion is ballistic with no drag term: drag has no closed form this cheap, and at these speeds nobody can tell it is missing.

Physics rides on the particle rather than in the uniforms, which is what lets several effects with different lifetimes, gravity and shape be drawn together in one call.

Gravity is well under the real thing. At anything like a realistic value the confetti drops some 600 points inside its lifetime — more than half a display — and reads as being sucked downward rather than fluttering.

## Confetti amount and shape

Two more submenus, both confetti's own. **Confetti Amount** runs **Very Sparse**, **Sparse**, **Normal**, **Dense**, **Very Dense** — a 0.33x to 3.3x multiplier on density, which the emitter reads back as a shorter gap between pieces. Density rather than a piece count, because emission is per point of pointer travel: a denser setting still does not carpet the screen when the pointer crawls. Past **Dense** a fast flick can out-run the 512-particle ring, which then reclaims the oldest piece still in the air — a denser stream at the pointer, a shorter one behind it.

**Confetti Shape** offers **Paper** (the original: near-square, fluttering), **Dots**, **Ribbons** and **Bubbles**. A shape is four numbers on the particle — size, roundness, aspect and flutter — plus the spin that goes with it, so none of them is a new geometry path in the shader. **Ribbons** narrows the quad to roughly a quarter of its length; the fragment masks the same unit square either way, so the drawn piece narrows with the geometry, and the flutter turning it edge-on as it tumbles is most of what sells it. **Dots** and **Bubbles** do not spin at all, because a disc rotating about its centre is still the same disc.

Both settings reach the movement emitters only. A firework is sparks, and sparks stay the points their own effect asked for.

## The cat

**Cat** is not a particle effect. Everything else here is thrown, fades and is
forgotten; the cat is one persistent thing with a position, a pose and a memory
of where the pointer has been. It walks the path the pointer actually took
rather than the straight line to it, which is the whole point of it — the
pointer's own route is the thing it is chasing.

Waypoints are laid down as the pointer moves, thinned to nine points of travel
apart so a slow drag does not queue hundreds a second, and the cat eats them
from the front. How much path is left sets the pace: an ordinary trot at 460
points a second, sprinting up to 1500 when the pointer has got a long way ahead,
so it never strands itself a screen away. Past 512 waypoints the oldest are
dropped, and the cat picks the path up further along instead of falling further
behind for ever.

It is drawn 34 points to the right of the path rather than on it. It still
walks exactly where the pointer walked — only the drawing is offset — but
sitting on the hotspot puts a cat between you and whatever you were about to
click.

Standing still for 0.9 s sits it down; five seconds lies it down asleep; any
movement stands it back up. The three poses are blends, not states — the shader
is handed a cat that is 40% of the way to sitting and draws exactly that, so it
folds itself up instead of cutting between drawings.

There is one cat per pointer, not per display: crossing to another screen takes
it with you. Pausing with **⌃⌥⌘T** sends it away too, because unlike everything
else on screen it would otherwise sit through your whole screen share.

### How it is drawn

One quad, no texture, no sprite sheet. The fragment shader is a signed distance
field of the whole animal — body, haunch, four legs, a three-joint tail, head,
two ears and an eye punched out as a hole in the silhouette — and a pose is the
same shapes at different numbers. That is what makes sitting down a blend rather
than an animation to author, and it is why the cat is drawn in your trail colour
like everything else.

The CPU rewrites one uniform struct per frame, which is all the traffic the
effect costs. A sleeping cat still breathes, so the display link cannot park
while it is on screen; a third frame tier runs it at 10 fps instead, and an
otherwise idle machine measures the same as with no cat at all.

## Fade duration

Two submenus, **Trail Fade** and **Effect Fade**, each offer **Very Short**, **Short**, **Normal**, **Long** and **Very Long** — multipliers of 0.4x to 2.25x on the timings every style and effect was tuned with. They are separate settings because the trail and the effects are independent axes everywhere else too: a long trail with snappy confetti is a combination worth having, and one shared control would be wrong for whichever of the two you were not adjusting. Both are stored in `UserDefaults` and restored next launch.

**Trail Fade** moves the style's lifetime and nothing else — width and colour are the style's identity, so a longer fade is the same trail kept on screen longer. Even at 2.25x the longest style stays inside the 256-sample point ring, so no tail is clipped.

Shape is applied before the fade, so it is the shape's own spin that the fade stretches.

**Effect Fade** stretches time rather than lifetime alone. Dividing a particle's speed by the scale and its gravity by the square puts it at `scale * t` exactly where it used to be at `t`, so a burst keeps the size and shape it was tuned with and only its pace changes; scaling the lifetime by itself would instead throw confetti four times as far for a doubled fade, which reads as a different effect rather than a slower one. Ripples scale their wave lifetime and the delay between waves together, so the train keeps its spacing and still reaches the same radius.

## Particle colours

The **Particle Colors** submenu sets where every effect gets its hues: **Rainbow** (the whole wheel), **Warm**, **Cool**, **Pastel** (any hue, low saturation) or **Trail Color** (the colour you picked, no hue of its own). Narrow bands read as a deliberate scheme rather than as confetti from a party shop, which is the reason the setting exists.

## Pausing

**⌃⌥⌘T** pauses and resumes the trail from anywhere, and the menu bar carries the same item. Useful when you are about to share your screen.

Pausing only stops feeding the overlays. Nothing is cleared by force: whatever is on screen expires on its own within a second, and the existing stop path parks the display link. A hard clear would have to paint one empty frame first, and fading out is what you want from a key you hit mid-presentation anyway.

The hotkey is registered with Carbon's `RegisterEventHotKey` rather than an `NSEvent` key monitor, because a global monitor for key events needs Accessibility permission and a hotkey registration does not.

### Choosing the click gesture

The menu bar has a **Firework Clicks** submenu: **Single Click**, **2 Clicks** or **3 Clicks**. The choice is stored in `UserDefaults` and restored next launch, and it applies to every click-triggered effect.

Single click is the default and it means *every* click — on a button, in a menu, on a text field. That is a lot of fireworks. Two or three clicks is quieter, at the cost of overlapping real gestures: triple click selects a paragraph in most editors, so bursts will follow text selection.

Detection uses AppKit's own `clickCount`, which is already measured against your system double-click interval, so there is no separate timing threshold to tune. Note that a double click also passes through `clickCount == 1` on its way, so the single-click setting fires on the first press of any multi-click too.

### Adding another mode

Styles and effects are declared in `TrailModes.swift`. Add a `TrailStyle` to `TrailStyleRegistry.all` or a `TrailEffect` to `TrailEffectRegistry.all`; the menu bar is generated from both, and because the two axes are independent a new entry needs no combination entry anywhere. A style controls lifetime, width, colouring (`.solid`, `.gradient`, `.rainbow`), speed response and its GPU passes. An effect carries a `ParticleStyle`, a `RippleStyle`, a `CompanionStyle`, or any combination. The mouse monitoring, ring buffer, display-link lifecycle, and overlay code do not need to change.

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
| `CURSORTRAIL_MAX_PARTICLES` | `512` | Live particles per display, for the modes that emit any |
| `CURSORTRAIL_BURST_CLICKS` | `0` | Initial click gesture (1-3); `0` starts at single click. The menu bar picker overrides it once used |
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

Particles are the exception. They are the one thing on screen that moves independently of the pointer, and a spark crosses a display far faster than a pointer ever does, so half rate strobes them visibly. While any particle is alive the link is held at full rate. Only the two particle modes ever pay that, and only until the last particle dies.

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
