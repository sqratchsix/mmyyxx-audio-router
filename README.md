# mmyyxx

A small macOS mixer that drives **every** output pair on a multi-output audio
interface at once, instead of just the first stereo pair macOS is willing to use.
System audio and the interface's own hardware inputs each get a channel strip,
and each strip can be sent to either output pair independently.

Built for a MOTU M4 (Main Out 1–2, Line Out 3–4, four analog inputs), but any
interface with four or more outputs appears in the device menu.

<img src="docs/mmyyxx.png" alt="mmyyxx: five source strips and two output pairs above a 19-inch FX rack holding an RV7000 reverb" width="880">

Five input strips feed two output pairs, and both can send to the rack below.
The RV7000 here is running Multi Tap, which is why the display is drawing 15
discrete taps rather than a decay envelope.

## Why this is needed

macOS only ever sends system audio to channels 1–2 of the selected output device.
Audio MIDI Setup cannot work around it: a Multi-Output Device aggregates
*separate devices*, so it has no way to split one device's channel pairs. Setting
the interface to a quadraphonic speaker layout does not help either, because
stereo content still lands on the front pair.

## How it works

```
System audio ──▶ BlackHole 2ch ─┐
                                ├─▶ private aggregate ─▶ mmyyxx mixer ─┬─▶ M4 out 1–2
   MOTU M4 inputs + outputs ────┘        (one IOProc)                  └─▶ M4 out 3–4
        (clock master)
```

BlackHole is a virtual output driver: point macOS at it and system audio becomes
readable as an input. The app then wraps BlackHole and the interface in a
**private aggregate device**, which is the part that makes this reliable. The two
devices have independent clocks, so servicing them from separate callbacks would
need a ring buffer and a resampler to absorb drift. Inside one aggregate,
CoreAudio does that work: the interface is clock master, BlackHole gets drift
compensation, and a single IOProc receives every input and output channel already
sample-aligned. The aggregate is marked private, so it stays out of Audio MIDI
Setup and the Sound menu.

Sub-device ordering matters. The interface is listed first, so its inputs occupy
the low aggregate channel indices and BlackHole's follow — on an M4 that puts
In 1–4 at 0–3 and system audio at 8–9.

### Signal flow

```
sources ──(fx send, post-fader)──┐
                                 ├──▶ FX bus ──▶ RV7000 ──▶ return ──┐
pair bus ──(fx send)─────────────┘        (tapped pre-return)        │
    │                                                                │
    └────────────────────────────────┬───────────────────────────────┘
                                     └──▶ pair fader ──▶ output
```

The render callback runs in passes:

1. Each source applies its own smoothed gain and pan, meters itself **pre-fader**
   so a channel still shows signal with the fader down, and sums into whichever
   output pairs its send buttons select, plus the FX bus.
2. Each output pair can also feed the FX bus. That tap happens **before** the
   return is summed back in, which is what stops a pair that both sends to and
   receives from the reverb from closing a feedback loop.
3. Each output pair applies its master fader and meters **post-fader**, so the
   output strips show what is actually leaving the interface.

FX sends default to zero, so nothing is heard until a send is raised.

Gain smoothing advances once per frame regardless of how many pairs a source
feeds, so slew rate does not depend on routing.

The callback allocates nothing and takes no locks. Parameters cross from the UI
through atomics, meter peaks cross back with max-since-last-read semantics, and
fader moves slew over ~20 ms so they do not zipper.

### Two things that bite

**Loopback channels are excluded.** The M4 exposes `Loopback 1–2` and
`Loopback Mix 1–2` alongside its analog inputs. Those return what the computer is
sending to the interface, which is exactly what this app writes, so routing one
into the mix would close a feedback loop. Sources whose driver-supplied channel
name contains "loopback" are filtered out.

**Output volume is claimed at unity.** Interfaces typically expose a software
volume control only on their "preferred stereo pair", because that is the pair
the macOS volume slider drives. On the M4 that means channels 1–2 carry a volume
control and 3–4 do not, so the two pairs can sit 30 dB apart with no visible
cause. On start the app forces every settable output volume to unity and restores
the original values on quit, leaving its own faders as the only attenuation.

**The macOS volume slider moves to the wrong end of the chain.** Once system
output points at BlackHole, that slider stops being the last stage before the
speakers and becomes the first stage before the mixer, attenuating digitally
before anything is summed.

Rather than fight that, the System strip's fader *is* that control. It reads and
writes the loopback device's volume directly, so the strip, the macOS slider and
the keyboard volume keys are all the same value and can never disagree. A
CoreAudio property listener keeps the fader in sync when the volume changes from
outside the app. The System source's gain inside the mixer stays pinned at unity,
so there is exactly one gain stage rather than two.

**BlackHole's volume taper is linear, and the mixer corrects for it.** Measured
on the device, its curve is exactly `dB = 64 x (scalar - 1)`. Because the macOS
volume keys always move in fixed 1/16 steps, that makes every key press a flat
4 dB regardless of position, which is far coarser than any normal output device
and is what makes the keys feel steppy.

The mixer imposes a cubic taper instead, applying the difference between what
the device reports it is doing and what the curve calls for:

| Key step | BlackHole alone | With correction |
|---|---|---|
| 16/16 | 0.0 dB | 0.0 dB |
| 15/16 | -4.0 dB | -1.7 dB |
| 14/16 | -8.0 dB | -3.5 dB |
| 12/16 | -16.0 dB | -7.5 dB |
| 8/16 | -32.0 dB | -18.1 dB |
| 4/16 | -36.1 dB | -36.1 dB |

The correction is derived from the dB the device reports rather than from a
hardcoded formula, so a loopback driver with a different curve lands on the same
result. It peaks near +14 dB around half travel and can never raise the signal
above its original level, so it cannot clip.

Hold Option-Shift with the volume keys for quarter steps if you want finer
control still.

> Restore-on-quit only runs on a graceful quit. If the app is force-quit or
> crashes, the borrowed volume controls stay at unity until the next clean exit.

## Requirements

- macOS 15 or later
- Command Line Tools 16.4+ (`swift --version` should report 6.1 or newer)
- [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole): `brew install --cask blackhole-2ch`

After installing BlackHole, `sudo killall coreaudiod` makes it visible without a
reboot.

## Build and run

```sh
./build.sh              # release build, produces build/mmyyxx.app
open build/mmyyxx.app
```

`./build.sh debug` for a debug build. The bundle is ad-hoc signed so macOS
remembers the audio-input permission between launches.

There is no Xcode project file. The package builds with Command Line Tools alone;
Xcode 16.4 can open `Package.swift` directly if you want previews and Instruments.
Note that Xcode 26 requires macOS 26, so 16.4 is the last version that runs on
macOS 15.

The icon is generated rather than checked in as an opaque asset:

```sh
./Tools/make-icon.sh    # rewrites Resources/AppIcon.icns
```

## First run

1. Install BlackHole, then `sudo killall coreaudiod`.
2. Launch the app and click **Route here** in the source bar. That points macOS
   system output at BlackHole, and the app restores your previous output device
   on quit.
3. Turn your monitors down first. Pinning channels 1–2 to unity can be a large
   jump from wherever the system slider left them.

Hardware inputs start muted and at −∞, so plugging in a live microphone never
surprises anyone through the speakers. Unmute and raise the fader to use one.

## Controls

| Control | Behaviour |
|---|---|
| Fader | Console taper: unity at 75% of travel, +6 dB at the top. Double-click resets to 0 dB. |
| Pan | Constant-power, with a centre detent. Mono sources only. Double-click recentres. |
| SEND 1–2 / 3–4 | Which output pairs this source feeds. |
| MUTE | Per source and per output pair. |
| CLIP | Latches while a pair's post-fader peak hold sits at 0 dBFS. |

## The rack

The FX send feeds a 19-inch rack with mounting rails that holds up to four
devices chained in series. Device panels are a whole number of rack units and
never stretch, so a 1U panel stays 1U at any window size.

| Device | Height | |
|---|---|---|
| RV7000 Advanced Reverb | 3U | main panel plus Remote Programmer |
| DL1 Delay Line | 1U | stereo delay, damped feedback, ping-pong |

Each device is fastened by full-height mounting ears with a screw top and bottom,
and the rack is exactly as tall as what is mounted in it. The window's minimum
width is the rack's, because a 19-inch rack that has to squeeze is not a 19-inch
rack; below that the window scrolls rather than clipping.

Hover a device for its power, reorder and remove controls. Each slot owns both a
reverb and a delay from the moment the app starts: adding a device at runtime
must never make the audio thread allocate a delay line, so the units are pooled
and a slot simply uses whichever its current kind calls for. Changing a slot's
device type clears that unit, which is a buffer memset rather than an allocation.

The chain snapshot handed to the render thread is deliberately not an `Array`.
It is a fixed-capacity plain-old-data struct, so copying it is a memcpy; an array
would retain and release a heap buffer, and dropping the last reference would
call `free` on the audio thread.

## The reverb

Modelled on Reason's RV7000: a main panel with the headline controls and a
Remote Programmer below carrying the rest on a red LCD.

Six of the algorithms are a feedback delay network — eight delay lines with
mutually non-harmonic lengths, a four-stage allpass diffuser on the input, and a
Householder feedback matrix. The matrix is orthogonal, so it redistributes energy
between lines without adding or removing any; decay is set purely by the per-line
feedback gains, which keeps RT60 predictable. Small Space through Arena differ by
how far the delay set is stretched; Plate and Spring add diffusion density. Echo
and Multi Tap bypass the network for a tap-based path, and Reverse plays
crossfaded grains backwards into it.

Multi Tap fans the delay line out up to 16 times.

**Decay compensation.** The damping filters inside the feedback path shave a
little off the midband on every pass, and at tens of passes per second that
compounds. Measured with an impulse test, a 20 s Decay setting was decaying in
about 3 s. The feedback gain is now divided by the filters' measured loss at
500 Hz, so Decay means RT60 again while the top end still dies away first.

**Switching without a pop.** Changing algorithm moves every delay-line read
position and every filter coefficient at once, which is a step discontinuity and
audible as a click. The wet output ramps to silence over ~12 ms, the new settings
are applied at the zero crossing, and it ramps back up. Delay times are handled
differently: they glide rather than crossfade, because sliding a read position
bends the pitch briefly instead of stepping, which is what a delay is expected to
do when you turn the time knob. Measured across every algorithm pair, the worst
sample-to-sample delta during a switch is now *smaller* than the signal's normal
slew.

## Performance

Metering is the only thing that runs continuously, and it needs care.

The first working version idled at **98% of a core**. Profiling showed the cost
was almost entirely SwiftUI *layout*, not drawing and not DSP: `AppModel` was one
`ObservableObject`, so a meter tick invalidated the whole view tree and the engine
re-solved `sizeThatFits` across every nested stack in the window. The reverb
itself measured 0.2%.

Three changes took it to roughly 13% visible and 0.5% hidden:

- Metering moved into its own `MeterModel`, so only the leaf views that draw a
  meter subscribe to it. Anything that merely passes it along holds it as a plain
  `let`; making it `@ObservedObject` higher up brings the problem straight back.
- Each meter group draws in a single fixed-size `Canvas` instead of a view per bar
  and per scale tick. One layout node regardless of what is inside it.
- 30 Hz instead of 60, and metering pauses entirely when the window is occluded.

## Settings

Every fader, pan, mute and send is persisted to:

```
~/Library/Application Support/com.jaredsimon.mmyyxx/settings.json
```

Sources are keyed by a stable id (`system`, or `<device-uid>#<channel>`) rather
than by position, so unplugging an interface and reconnecting it restores that
strip's mix instead of resetting it. Settings for absent devices are kept in the
file rather than pruned.

Writes are debounced by 0.75 s, because a fader drag emits a change per frame and
each one would otherwise be a file write. Writes are atomic, so a crash mid-save
leaves the previous file intact rather than a truncated one. Anything loaded from
disk is range-checked before it reaches the render path, so a hand-edited or
stale file cannot crash the engine.

The device menu has **Reset mix to defaults** and **Reveal settings file**.

## Layout

```
Sources/Audio/   CoreAudio layer: device discovery, aggregate device, mixer callback, level math
Sources/UI/      SwiftUI views: meters, faders, channel strips, theme
Sources/App/     App entry point and the observable model bridging UI to engine
Bundle/          Info.plist and entitlements consumed by build.sh
Tools/           Icon generator
```

## Status

Working: system audio and all four M4 analog inputs as independent sources, each
with gain, pan, mute and per-pair sends; two output pairs with master faders,
mutes and clip indicators; peak metering with hold throughout; device selection;
system-output routing with restore on quit.

Also working: the full mix persists across launches and across device
reconnects.

Not done yet: buffer size is whatever the aggregate negotiates rather than
something the app sets. There is no menu bar item, so the window is the only
way to reach the controls.
