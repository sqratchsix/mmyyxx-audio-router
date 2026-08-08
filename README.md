# mmyyxx

A small macOS mixer that drives **every** output pair on a multi-output audio
interface at once, instead of just the first stereo pair macOS is willing to use.
System audio and the interface's own hardware inputs each get a channel strip,
and each strip can be sent to either output pair independently.

Built for a MOTU M4 (Main Out 1–2, Line Out 3–4, four analog inputs), but any
interface with four or more outputs appears in the device menu.

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

The render callback runs two passes:

1. Each source applies its own smoothed gain and pan, meters itself **pre-fader**
   so a channel still shows signal with the fader down, and sums into whichever
   output pairs its send buttons select.
2. Each output pair applies its master fader and meters **post-fader**, so the
   output strips show what is actually leaving the interface.

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

A side effect: while the app runs, the keyboard volume keys drive BlackHole,
which sits upstream of the mixer and moves both pairs together.

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

Not done yet: no settings persistence, so the mix resets on each launch. Buffer
size is whatever the aggregate negotiates rather than something the app sets.
