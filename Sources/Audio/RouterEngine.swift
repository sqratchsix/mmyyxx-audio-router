import CoreAudio
import Foundation

/// Where a single channel lives inside an `AudioBufferList`.
///
/// Aggregate devices hand back a mix of layouts: each sub-device contributes its
/// own buffers, some mono and non-interleaved, some interleaved stereo. Resolving
/// a global channel index to a base pointer plus a stride covers both.
private struct ChannelRef {
    var base: UnsafeMutablePointer<Float>?
    var stride: Int

    static let none = ChannelRef(base: nil, stride: 1)
}

/// A source's resolved position in the aggregate's input scope.
private struct SourceRoute {
    var inputChannel: Int
    var channelCount: Int
}

/// Owns the aggregate device and the IOProc. Not actor-isolated: the render
/// callback runs on CoreAudio's thread and reaches directly into the fields
/// below, which are only written while the engine is stopped.
final class RouterEngine: @unchecked Sendable {

    enum State: Equatable {
        case stopped
        case running(sampleRate: Double, bufferFrames: Int)
        case failed(String)
    }

    let shared = SharedState()
    let fx = FXState()
    private(set) var state: State = .stopped
    private let fxRack = FXChain()

    private var aggregate: AggregateDevice?
    private var procID: AudioDeviceIOProcID?

    // Resolved once at start, read by the render thread.
    private var routes: [SourceRoute] = []
    private var outputBase = 0

    // One-pole smoothed gains, owned exclusively by the render thread.
    private var smoothedSourceGain = [Float](repeating: 1, count: SharedState.maxSources)
    private var smoothedPairGain = [Float](repeating: 1, count: SharedState.pairCount)
    private var smoothingCoefficient: Float = 0.001

    // Device volume controls we forced to unity, and what they were before.
    private var borrowedVolumes: [(device: AudioObjectID, uid: String,
                                   channel: UInt32, original: Float)] = []
    /// Listeners that put a claimed control back if anything moves it.
    private var volumeGuards: [(device: AudioObjectID, channel: UInt32,
                                block: AudioObjectPropertyListenerBlock)] = []

    /// The originals, keyed so they can be persisted and recovered after a crash.
    /// Held in memory alone, an unclean exit loses the user's real level and the
    /// next launch captures unity as if it were their setting.
    var borrowedVolumeRecord: [String: Float] {
        var record: [String: Float] = [:]
        for entry in borrowedVolumes {
            record["\(entry.uid)#\(entry.channel)"] = entry.original
        }
        return record
    }

    /// Scratch space for the render thread's resolved output channels, allocated
    /// once. Building this as a Swift array inside the callback would allocate.
    private static let destinationCount = SharedState.pairCount * 2
    private let destinations = UnsafeMutablePointer<ChannelRef>.allocate(capacity: destinationCount)

    /// FX bus scratch, sized for the largest buffer CoreAudio is likely to hand
    /// us. Allocated once; the render thread only ever writes into it.
    private static let maxFrames = 8192
    private let fxInputLeft = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let fxInputRight = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let fxOutputLeft = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let fxOutputRight = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)

    init() {
        destinations.initialize(repeating: .none, count: Self.destinationCount)
        for buffer in [fxInputLeft, fxInputRight, fxOutputLeft, fxOutputRight] {
            buffer.initialize(repeating: 0, count: Self.maxFrames)
        }
    }

    deinit {
        stop()
        destinations.deinitialize(count: Self.destinationCount)
        destinations.deallocate()
        for buffer in [fxInputLeft, fxInputRight, fxOutputLeft, fxOutputRight] {
            buffer.deinitialize(count: Self.maxFrames)
            buffer.deallocate()
        }
    }

    func start(output: AudioDeviceInfo,
               loopback: AudioDeviceInfo,
               sources: [MixerSource],
               recoveredVolumes: [String: Float] = [:],
               sampleRate: Double = 48_000) {
        stop()

        do {
            let device = try AggregateDevice(output: output, input: loopback)
            let rate = device.matchSampleRate(to: sampleRate, devices: [output, loopback])

            outputBase = device.outputOffsets[output.uid] ?? 0
            routes = sources.map { source in
                SourceRoute(
                    inputChannel: (device.inputOffsets[source.deviceUID] ?? 0) + source.firstChannel,
                    channelCount: source.channelCount
                )
            }

            // ~20 ms to slew a fader change; fast enough to feel immediate, slow
            // enough that no one hears a zipper.
            fxRack.prepare(sampleRate: rate)
            smoothingCoefficient = 1 - exp(-1.0 / Float(0.020 * rate))
            for index in 0..<SharedState.maxSources {
                smoothedSourceGain[index] = shared.sources[index].gain.value
            }
            for pair in 0..<SharedState.pairCount {
                smoothedPairGain[pair] = shared.pairGain[pair].value
            }

            var proc: AudioDeviceIOProcID?
            let clientData = Unmanaged.passUnretained(self).toOpaque()
            var status = AudioDeviceCreateIOProcID(device.id, Self.ioProc, clientData, &proc)
            guard status == noErr, let proc else {
                state = .failed("Could not install the audio callback (OSStatus \(status)).")
                return
            }

            status = AudioDeviceStart(device.id, proc)
            guard status == noErr else {
                AudioDeviceDestroyIOProcID(device.id, proc)
                state = .failed("Could not start the audio device (OSStatus \(status)).")
                return
            }

            claimOutputVolumes(on: output, recovered: recoveredVolumes)

            aggregate = device
            procID = proc
            state = .running(sampleRate: rate, bufferFrames: device.bufferFrameSize)

            let routeSummary = zip(sources, routes)
                .map { "\($0.name)@\($1.inputChannel)x\($1.channelCount)" }
                .joined(separator: ", ")
            Diagnostics.log("""
                engine started
                  output      \(output.name) (\(output.outputChannels) out) @ aggregate ch \(outputBase)
                  sources     \(routeSummary)
                  rate        \(rate) Hz
                  buffer      \(device.bufferFrameSize) frames
                """)
        } catch {
            Diagnostics.log("engine start failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        if let aggregate, let procID {
            AudioDeviceStop(aggregate.id, procID)
            AudioDeviceDestroyIOProcID(aggregate.id, procID)
        }
        procID = nil
        aggregate = nil          // deinit destroys the aggregate device
        releaseOutputVolumes()
        routes = []
        for peak in shared.channelPeak { peak.value = 0 }
        for source in shared.sources { for peak in source.peak { peak.value = 0 } }
        for peak in fx.outputPeak { peak.value = 0 }
        fxRack.reset()
        state = .stopped
    }

    /// Pin every settable output volume on the interface to unity so the app's
    /// faders are the only attenuation in the chain. Without this, the pairs that
    /// happen to carry a macOS volume control sit at whatever the system slider
    /// last left them at, while the pairs without one run wide open.
    /// - Parameter recovered: originals persisted by a previous run that did not
    ///   exit cleanly. When present they are trusted over the current reading,
    ///   which would otherwise be the unity value that run left behind.
    private func claimOutputVolumes(on device: AudioDeviceInfo, recovered: [String: Float]) {
        releaseOutputVolumes()
        for channel in 1...UInt32(device.outputChannels) {
            guard let live = AudioDevices.outputVolume(device.id, channel: channel) else { continue }
            let original = recovered["\(device.uid)#\(channel)"] ?? live
            guard AudioDevices.setOutputVolume(device.id, channel: channel, 1.0) else { continue }
            borrowedVolumes.append((device.id, device.uid, channel, original))
            installVolumeGuard(device: device.id, channel: channel)
            Diagnostics.log(String(format: "channel %d volume %.3f -> 1.000 (claimed, restores to %.3f)",
                                   channel, live, original))
        }
    }

    /// Hold a claimed control at unity for as long as the engine runs.
    ///
    /// Claiming once at startup was not enough: something in the system was
    /// putting the interface's channel 1-2 volume back to a remembered value
    /// afterwards, leaving the output 30 dB down with nothing in the app to show
    /// why. Nothing else contends for this control, since the interface's front
    /// panel knob is analogue and sits downstream of it.
    private func installVolumeGuard(device: AudioObjectID, channel: UInt32) {
        guard let block = AudioDevices.observeOutputVolume(device, channel: channel, handler: { [weak self] in
            guard let self, case .running = self.state else { return }
            guard let current = AudioDevices.outputVolume(device, channel: channel) else { return }
            guard current < 0.999 else { return }
            // Writing 1.0 re-enters this handler once, then settles.
            AudioDevices.setOutputVolume(device, channel: channel, 1.0)
            Diagnostics.log(String(format: "channel %d moved to %.3f, held at unity", channel, current))
        }) else { return }
        volumeGuards.append((device, channel, block))
    }

    private func releaseOutputVolumes() {
        for guardEntry in volumeGuards {
            AudioDevices.stopObservingOutputVolume(guardEntry.device,
                                                   channel: guardEntry.channel,
                                                   block: guardEntry.block)
        }
        volumeGuards.removeAll()
        for entry in borrowedVolumes {
            AudioDevices.setOutputVolume(entry.device, channel: entry.channel, entry.original)
        }
        borrowedVolumes.removeAll()
    }

    // MARK: - Render thread
    //
    // Everything below runs on a real-time thread with a hard deadline. No
    // allocation, no locks, no Swift runtime calls that could touch the heap.

    private static let ioProc: AudioDeviceIOProc = { _, _, inputData, _, outputData, _, clientData in
        guard let clientData else { return noErr }
        let engine = Unmanaged<RouterEngine>.fromOpaque(clientData).takeUnretainedValue()
        return engine.render(input: inputData, output: outputData)
    }

    /// Two passes. First every source sums into the output pairs it is sent to,
    /// then each pair's own fader scales the result. Summing first is what makes
    /// the pair faders behave like master faders rather than per-source trims.
    private func render(input: UnsafePointer<AudioBufferList>,
                        output: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let outputList = UnsafeMutableAudioBufferListPointer(output)
        guard outputList.count > 0 else { return noErr }

        let frames = Int(outputList[0].mDataByteSize) / MemoryLayout<Float>.size
            / Int(max(outputList[0].mNumberChannels, 1))
        guard frames > 0, frames <= Self.maxFrames else { return noErr }

        let fxChain = fx.snapshot()
        let fxActive = fxChain.isActive
        memset(fxInputLeft, 0, frames * MemoryLayout<Float>.size)
        memset(fxInputRight, 0, frames * MemoryLayout<Float>.size)

        // Clear every output channel before mixing. IOProc output buffers arrive
        // with undefined contents, and the aggregate also exposes the loopback
        // device's own outputs. Those feed straight back into the inputs we are
        // reading, so leaving them unwritten risks a feedback loop.
        for buffer in outputList {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        let inputList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))

        // Destination channels, resolved once into preallocated scratch space.
        for slot in 0..<Self.destinationCount {
            destinations[slot] = Self.channel(outputList, index: outputBase + slot)
        }

        // Pass 1: sources sum into their destinations.
        for index in 0..<routes.count {
            let route = routes[index]
            let source = shared.sources[index]

            let leftRef = Self.channel(inputList, index: route.inputChannel)
            let rightRef = route.channelCount >= 2
                ? Self.channel(inputList, index: route.inputChannel + 1)
                : leftRef
            guard let leftBase = leftRef.base, let rightBase = rightRef.base else { continue }

            // Send routing as a bitmask, so the per-frame loop tests a register
            // rather than walking an array of atomics.
            var sendMask: UInt32 = 0
            for pair in 0..<SharedState.pairCount where source.sends[pair].value {
                sendMask |= 1 << UInt32(pair)
            }

            let target = source.muted.value ? 0 : source.gain.value
            let fxSend = fxActive ? fx.sourceSend[index].value : 0
            let panLeft = source.panLeft.value
            let panRight = source.panRight.value
            var gain = smoothedSourceGain[index]
            let coefficient = smoothingCoefficient

            var peakLeft: Float = 0
            var peakRight: Float = 0

            for frame in 0..<frames {
                // Advances once per frame regardless of how many pairs this
                // source feeds, so the slew rate does not depend on routing.
                gain += (target - gain) * coefficient

                let rawLeft = leftBase[frame * leftRef.stride]
                let rawRight = rightBase[frame * rightRef.stride]

                // Pre-fader metering: a source still shows signal with its fader down.
                let absLeft = abs(rawLeft), absRight = abs(rawRight)
                if absLeft > peakLeft { peakLeft = absLeft }
                if absRight > peakRight { peakRight = absRight }

                let left = rawLeft * gain * panLeft
                let right = rawRight * gain * panRight

                // Post-fader send: muting a channel takes its reverb with it,
                // which is what anyone expects from a mute.
                if fxSend > 0 {
                    fxInputLeft[frame] += left * fxSend
                    fxInputRight[frame] += right * fxSend
                }

                for pair in 0..<SharedState.pairCount where sendMask & (1 << UInt32(pair)) != 0 {
                    let outLeftRef = destinations[pair * 2]
                    let outRightRef = destinations[pair * 2 + 1]
                    if let outLeft = outLeftRef.base, let outRight = outRightRef.base {
                        outLeft[frame * outLeftRef.stride] += left
                        outRight[frame * outRightRef.stride] += right
                    }
                }
            }

            smoothedSourceGain[index] = gain
            source.peak[0].raise(to: peakLeft)
            source.peak[1].raise(to: peakRight)
        }

        // Pass 1b: the output pairs can feed the FX too. Tapping here, before
        // the return is summed in below, is what stops this being a feedback
        // loop when a pair both sends to the reverb and receives from it.
        if fxActive {
            for pair in 0..<SharedState.pairCount {
                let send = fx.pairSend[pair].value
                guard send > 0 else { continue }
                let leftRef = destinations[pair * 2]
                let rightRef = destinations[pair * 2 + 1]
                guard let outLeft = leftRef.base, let outRight = rightRef.base else { continue }
                for frame in 0..<frames {
                    fxInputLeft[frame] += outLeft[frame * leftRef.stride] * send
                    fxInputRight[frame] += outRight[frame * rightRef.stride] * send
                }
            }

            // The rack works in place down the bus, so the chain's output ends
            // up in the same buffers the sends filled.
            fxRack.process(left: fxInputLeft, right: fxInputRight,
                           frames: frames, chain: fxChain)

            var fxPeakLeft: Float = 0
            var fxPeakRight: Float = 0
            for frame in 0..<frames {
                fxOutputLeft[frame] = fxInputLeft[frame]
                fxOutputRight[frame] = fxInputRight[frame]
                let l = abs(fxOutputLeft[frame]), r = abs(fxOutputRight[frame])
                if l > fxPeakLeft { fxPeakLeft = l }
                if r > fxPeakRight { fxPeakRight = r }
            }
            fx.outputPeak[0].raise(to: fxPeakLeft)
            fx.outputPeak[1].raise(to: fxPeakRight)
        }

        // Pass 2: FX return, pair faders and output metering.
        for pair in 0..<SharedState.pairCount {
            let leftRef = destinations[pair * 2]
            let rightRef = destinations[pair * 2 + 1]
            guard let outLeft = leftRef.base, let outRight = rightRef.base else { continue }

            let target = shared.pairMuted[pair].value ? 0 : shared.pairGain[pair].value
            var gain = smoothedPairGain[pair]
            let coefficient = smoothingCoefficient

            var peakLeft: Float = 0
            var peakRight: Float = 0

            // Each device sets its own wet level, so the pair return is simply
            // how much of the rack's output this pair takes.
            let returnLevel = fxActive ? fx.pairReturn[pair].value : 0

            for frame in 0..<frames {
                gain += (target - gain) * coefficient
                let wetLeft = returnLevel > 0 ? fxOutputLeft[frame] * returnLevel : 0
                let wetRight = returnLevel > 0 ? fxOutputRight[frame] * returnLevel : 0
                let left = (outLeft[frame * leftRef.stride] + wetLeft) * gain
                let right = (outRight[frame * rightRef.stride] + wetRight) * gain
                outLeft[frame * leftRef.stride] = left
                outRight[frame * rightRef.stride] = right
                let absLeft = abs(left), absRight = abs(right)
                if absLeft > peakLeft { peakLeft = absLeft }
                if absRight > peakRight { peakRight = absRight }
            }

            smoothedPairGain[pair] = gain
            shared.channelPeak[pair * 2].raise(to: peakLeft)
            shared.channelPeak[pair * 2 + 1].raise(to: peakRight)
        }

        return noErr
    }

    /// Resolve a global channel index within a buffer list. Walks at most a
    /// handful of buffers and allocates nothing.
    private static func channel(_ list: UnsafeMutableAudioBufferListPointer, index: Int) -> ChannelRef {
        var cursor = 0
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            if index < cursor + channels {
                guard let data = buffer.mData else { return .none }
                let base = data.assumingMemoryBound(to: Float.self)
                return ChannelRef(base: base.advanced(by: index - cursor), stride: channels)
            }
            cursor += channels
        }
        return .none
    }
}
