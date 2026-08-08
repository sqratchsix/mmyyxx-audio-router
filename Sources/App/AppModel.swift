import Combine
import CoreAudio
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {

    enum Readiness: Equatable {
        case ready
        case noLoopbackDevice
        case noOutputDevice
        case engineFailed(String)
    }

    // Discovery
    @Published private(set) var outputCandidates: [AudioDeviceInfo] = []
    @Published private(set) var loopback: AudioDeviceInfo?
    @Published private(set) var systemOutput: AudioDeviceInfo?
    @Published var selectedOutputUID: String? {
        didSet {
            guard !isDiscovering, oldValue != selectedOutputUID else { return }
            restartEngine()
        }
    }

    // Engine
    @Published private(set) var readiness: Readiness = .noOutputDevice
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var bufferFrames: Int = 0

    // Sources
    @Published private(set) var sources: [MixerSource] = []
    @Published var sourceGainDB: [Float] = [] { didSet { pushSources() } }
    @Published var sourcePan: [Float] = [] { didSet { pushSources() } }
    @Published var sourceMuted: [Bool] = [] { didSet { pushSources() } }
    /// `sourceSends[source][pair]`
    @Published var sourceSends: [[Bool]] = [] { didSet { pushSources() } }
    /// Two entries per source: left, right.
    @Published private(set) var sourceMeters: [MeterBallistics] = []

    // Output pairs
    @Published var pairGainDB: [Float] = [0, 0] { didSet { pushPairs() } }
    @Published var pairMuted: [Bool] = [false, false] { didSet { pushPairs() } }
    @Published private(set) var meters: [MeterBallistics] = Array(repeating: MeterBallistics(),
                                                                  count: SharedState.outputChannelCount)

    var selectedOutput: AudioDeviceInfo? {
        outputCandidates.first { $0.uid == selectedOutputUID }
    }

    var systemAudioIsRouted: Bool {
        guard let loopback, let systemOutput else { return false }
        return systemOutput.uid == loopback.uid
    }

    var isRunning: Bool {
        if case .ready = readiness { return true }
        return false
    }

    let pairNames = ["MAIN OUT", "LINE OUT"]
    let pairChannels = ["1–2", "3–4"]

    private let engine = RouterEngine()
    private var displayTimer: Timer?
    private var lastTick = Date()
    private var slowTickCounter = 0
    private var previousSystemOutputUID: String?
    private var isDiscovering = false
    private var isRebuildingSources = false

    // MARK: - Lifecycle

    func onAppear() {
        refreshDevices()
        previousSystemOutputUID = AudioDevices.systemDefaultOutput()?.uid
        startEngine()
        startDisplayTimer()
    }

    func onTerminate() {
        engine.stop()
        displayTimer?.invalidate()
        // Leave the user's sound output the way we found it.
        if let previousSystemOutputUID,
           previousSystemOutputUID != loopback?.uid,
           let device = AudioDevices.device(uid: previousSystemOutputUID) {
            AudioDevices.setSystemDefaultOutput(device)
        }
    }

    // MARK: - Devices

    func refreshDevices() {
        isDiscovering = true
        defer { isDiscovering = false }

        let previousSelection = selectedOutputUID
        outputCandidates = AudioDevices.multiOutputCandidates()
        loopback = AudioDevices.loopbackDevice()
        systemOutput = AudioDevices.systemDefaultOutput()

        if selectedOutputUID == nil || !outputCandidates.contains(where: { $0.uid == selectedOutputUID }) {
            // Prefer a MOTU interface, otherwise the first device with enough outputs.
            let preferred = outputCandidates.first { $0.name.localizedCaseInsensitiveContains("m4") }
                ?? outputCandidates.first
            selectedOutputUID = preferred?.uid
        }

        rebuildSources()

        // A rescan that lands on a different device still needs a restart, but
        // only once the engine is already up; the initial start is `onAppear`'s job.
        if isRunning, selectedOutputUID != previousSelection {
            Task { @MainActor in self.restartEngine() }
        }
    }

    /// Rebuild the source list, preserving the fader and routing state of any
    /// source that survives the change so a device rescan does not reset the mix.
    private func rebuildSources() {
        let previous = sources
        let previousGain = sourceGainDB, previousPan = sourcePan
        let previousMuted = sourceMuted, previousSends = sourceSends

        let rebuilt = MixerSourceDiscovery.sources(loopbackDevice: loopback, interface: selectedOutput)

        var gain: [Float] = [], pan: [Float] = [], muted: [Bool] = [], sends: [[Bool]] = []
        for source in rebuilt {
            if let index = previous.firstIndex(where: { $0.id == source.id }), index < previousGain.count {
                gain.append(previousGain[index])
                pan.append(previousPan[index])
                muted.append(previousMuted[index])
                sends.append(previousSends[index])
            } else {
                // New sources start silent except system audio, so plugging in a
                // live microphone never surprises anyone through the speakers.
                gain.append(source.id == "system" ? 0 : LevelMath.silenceDB)
                pan.append(0)
                muted.append(source.id != "system")
                sends.append(Array(repeating: true, count: SharedState.pairCount))
            }
        }

        // The parallel arrays are only consistent with each other once all of
        // them have been assigned, and every assignment fires a `didSet`. Hold
        // the pushes off until the set is coherent.
        isRebuildingSources = true
        sources = rebuilt
        sourceGainDB = gain
        sourcePan = pan
        sourceMuted = muted
        sourceSends = sends
        sourceMeters = Array(repeating: MeterBallistics(), count: rebuilt.count * 2)
        isRebuildingSources = false

        pushSources()
    }

    /// Point macOS system audio at the loopback device so it reaches this app.
    func routeSystemAudioToLoopback() {
        guard let loopback else { return }
        if previousSystemOutputUID == nil || previousSystemOutputUID == loopback.uid {
            previousSystemOutputUID = systemOutput?.uid
        }
        AudioDevices.setSystemDefaultOutput(loopback)
        systemOutput = AudioDevices.systemDefaultOutput()
    }

    // MARK: - Engine

    private func startEngine() {
        guard let output = selectedOutput else {
            readiness = .noOutputDevice
            return
        }
        guard let loopback else {
            readiness = .noLoopbackDevice
            return
        }

        engine.start(output: output, loopback: loopback, sources: sources)

        switch engine.state {
        case .running(let rate, let frames):
            sampleRate = rate
            bufferFrames = frames
            readiness = .ready
            pushSources()
            pushPairs()
        case .failed(let message):
            readiness = .engineFailed(message)
        case .stopped:
            readiness = .engineFailed("The engine did not start.")
        }
    }

    func restartEngine() {
        engine.stop()
        startEngine()
    }

    private func pushSources() {
        guard !isRebuildingSources else { return }
        // Never trust the arrays to agree; a short read here is a crash.
        let count = min(sources.count, SharedState.maxSources,
                        sourceGainDB.count, sourcePan.count,
                        sourceMuted.count, sourceSends.count)
        for index in 0..<count {
            let state = engine.shared.sources[index]
            state.gain.value = LevelMath.linear(fromDB: sourceGainDB[index])
            state.muted.value = sourceMuted[index]

            // Stereo sources stay at unity on both sides; the pan law is for
            // placing a mono input, not for skewing an already-balanced pair.
            if sources[index].isStereo {
                state.panLeft.value = 1
                state.panRight.value = 1
            } else {
                let coefficients = SharedState.panCoefficients(sourcePan[index])
                state.panLeft.value = coefficients.left
                state.panRight.value = coefficients.right
            }

            for pair in 0..<SharedState.pairCount {
                state.sends[pair].value = sourceSends[index][pair]
            }
        }
    }

    private func pushPairs() {
        for pair in 0..<SharedState.pairCount {
            engine.shared.pairGain[pair].value = LevelMath.linear(fromDB: pairGainDB[pair])
            engine.shared.pairMuted[pair].value = pairMuted[pair]
        }
    }

    // MARK: - Metering

    private func startDisplayTimer() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func tick() {
        let now = Date()
        let delta = min(now.timeIntervalSince(lastTick), 0.1)
        lastTick = now

        var updatedOutputs = meters
        for channel in 0..<SharedState.outputChannelCount {
            updatedOutputs[channel].update(peakLinear: engine.shared.channelPeak[channel].drain(),
                                           delta: delta)
        }
        meters = updatedOutputs

        if sourceMeters.count == sources.count * 2 {
            var updatedSources = sourceMeters
            for index in 0..<sources.count {
                let state = engine.shared.sources[index]
                updatedSources[index * 2].update(peakLinear: state.peak[0].drain(), delta: delta)
                updatedSources[index * 2 + 1].update(peakLinear: state.peak[1].drain(), delta: delta)
            }
            sourceMeters = updatedSources
        }

        slowTickCounter += 1
        if slowTickCounter >= 30 {          // twice a second
            slowTickCounter = 0
            let current = AudioDevices.systemDefaultOutput()
            if current?.uid != systemOutput?.uid { systemOutput = current }
            if loopback == nil || outputCandidates.isEmpty { refreshDevices() }
        }
    }
}
