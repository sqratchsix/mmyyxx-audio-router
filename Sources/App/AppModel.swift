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
            scheduleSave()
            restartEngine()
        }
    }

    // Engine
    @Published private(set) var readiness: Readiness = .noOutputDevice
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var bufferFrames: Int = 0

    // Sources. One settings value per source, index-aligned with `sources`.
    @Published private(set) var sources: [MixerSource] = []
    @Published var sourceSettings: [SourceSettings] = [] {
        didSet {
            guard !isRebuildingSources else { return }
            pushSources()
            scheduleSave()
        }
    }
    /// Two entries per source: left, right. Display state, not persisted.
    @Published private(set) var sourceMeters: [MeterBallistics] = []

    // Output pairs
    @Published var pairSettings: [PairSettings] = Array(repeating: PairSettings(),
                                                        count: SharedState.pairCount) {
        didSet {
            pushPairs()
            scheduleSave()
        }
    }
    @Published private(set) var meters: [MeterBallistics] = Array(repeating: MeterBallistics(),
                                                                  count: SharedState.outputChannelCount)

    /// The loopback device's master volume, which is exactly what the macOS
    /// volume keys drive once system output points at it. The System strip's
    /// fader reads and writes this rather than keeping a second, independent
    /// gain of its own, so the two can never disagree.
    @Published private(set) var systemVolume: Float = 1
    @Published private(set) var systemVolumeDB: Float?
    @Published private(set) var systemVolumeIsLinked = false

    /// Fader travel for the System strip. Travel maps straight to the device
    /// scalar, so the strip sits exactly where the macOS slider does.
    var systemVolumeTravel: Binding<CGFloat> {
        Binding<CGFloat>(
            get: { CGFloat(self.systemVolume) },
            set: { self.setSystemVolume(Float(min(max($0, 0), 1))) }
        )
    }

    /// True for the strip whose fader is the macOS system volume.
    func isSystemStrip(_ source: MixerSource) -> Bool {
        systemVolumeIsLinked && source.id == "system"
    }

    /// The driver's reported level. BlackHole maps its slider linearly onto a
    /// -64...0 dB range, so this is read from the device rather than derived.
    var systemVolumeReadout: String {
        if let dB = systemVolumeDB, dB.isFinite {
            return systemVolume <= 0.0001 ? "−∞" : String(format: "%.0f", dB)
        }
        return "\(Int(systemVolume * 100))%"
    }

    func setSystemVolume(_ scalar: Float) {
        guard let loopback else { return }
        systemVolume = scalar
        AudioDevices.setOutputVolume(loopback.id, channel: 0, scalar)
        systemVolumeDB = AudioDevices.outputVolumeDecibels(loopback.id)
    }

    private func readSystemVolume() {
        guard let loopback else { return }
        if let scalar = AudioDevices.outputVolume(loopback.id, channel: 0) {
            systemVolume = scalar
        }
        systemVolumeDB = AudioDevices.outputVolumeDecibels(loopback.id)
    }

    private func startSystemVolumeObserver() {
        stopSystemVolumeObserver()
        guard let loopback else { return }
        systemVolumeIsLinked = AudioDevices.hasSettableOutputVolume(loopback.id)
        guard systemVolumeIsLinked else { return }
        readSystemVolume()
        volumeObserverDevice = loopback.id
        volumeObserver = AudioDevices.observeOutputVolume(loopback.id) { [weak self] in
            Task { @MainActor in self?.readSystemVolume() }
        }
    }

    private func stopSystemVolumeObserver() {
        if let device = volumeObserverDevice, let block = volumeObserver {
            AudioDevices.stopObservingOutputVolume(device, block: block)
        }
        volumeObserver = nil
        volumeObserverDevice = nil
    }

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
    private let store = SettingsStore()
    private var displayTimer: Timer?
    private var saveTimer: Timer?
    private var lastTick = Date()
    private var slowTickCounter = 0
    private var previousSystemOutputUID: String?
    private var isDiscovering = false
    private var isRebuildingSources = false
    private var hasLoaded = false
    private var volumeObserver: AudioObjectPropertyListenerBlock?
    private var volumeObserverDevice: AudioObjectID?
    /// Settings for sources that are not currently present, kept so unplugging
    /// and reconnecting an interface does not discard its mix.
    private var storedSourceSettings: [String: SourceSettings] = [:]

    // MARK: - Lifecycle

    func onAppear() {
        loadSettings()
        refreshDevices()
        previousSystemOutputUID = AudioDevices.systemDefaultOutput()?.uid
        startSystemVolumeObserver()
        startEngine()
        startDisplayTimer()
        // Materialise the file on first run so it always exists to be inspected
        // or hand-edited, and so a crash before the first fader move still
        // leaves a valid document behind.
        saveNow()
    }

    func onTerminate() {
        stopSystemVolumeObserver()
        saveTimer?.invalidate()
        saveNow()
        engine.stop()
        displayTimer?.invalidate()
        // Leave the user's sound output the way we found it.
        if let previousSystemOutputUID,
           previousSystemOutputUID != loopback?.uid,
           let device = AudioDevices.device(uid: previousSystemOutputUID) {
            AudioDevices.setSystemDefaultOutput(device)
        }
    }

    // MARK: - Persistence

    private func loadSettings() {
        let persisted = store.load()
        storedSourceSettings = persisted.sources
        pairSettings = persisted.pairs
        isDiscovering = true              // suppress the restarts in `didSet`
        selectedOutputUID = persisted.selectedOutputUID
        isDiscovering = false
        hasLoaded = true
        Diagnostics.log("settings loaded from \(store.location.path): "
            + "\(persisted.sources.count) stored sources, "
            + "pairs \(persisted.pairs.map { String(format: "%.1f%@", $0.gainDB, $0.muted ? "M" : "") })")
    }

    /// Faders emit a change per drag frame, so writing on every one would mean
    /// hundreds of file writes per gesture. Coalesce into one write shortly after
    /// the last change.
    private func scheduleSave() {
        guard hasLoaded else { return }
        saveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.75, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.saveNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    private func saveNow() {
        guard hasLoaded else { return }
        var merged = storedSourceSettings
        for (index, source) in sources.enumerated() where index < sourceSettings.count {
            merged[source.id] = sourceSettings[index]
        }
        storedSourceSettings = merged
        store.save(PersistedSettings(selectedOutputUID: selectedOutputUID,
                                     pairs: pairSettings,
                                     sources: merged))
    }

    func resetSettings() {
        storedSourceSettings = [:]
        pairSettings = Array(repeating: PairSettings(), count: SharedState.pairCount)
        rebuildSources(preservingCurrent: false)
        saveNow()
    }

    var settingsLocation: URL { store.location }

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

    /// Rebuild the source list. A source that survives keeps its live settings;
    /// one that returns after being away is restored from disk; anything genuinely
    /// new gets sensible defaults.
    private func rebuildSources(preservingCurrent: Bool = true) {
        let previousSources = sources
        let previousSettings = sourceSettings

        let rebuilt = MixerSourceDiscovery.sources(loopbackDevice: loopback, interface: selectedOutput)

        let settings: [SourceSettings] = rebuilt.map { source in
            if preservingCurrent,
               let index = previousSources.firstIndex(where: { $0.id == source.id }),
               index < previousSettings.count {
                return previousSettings[index]
            }
            if preservingCurrent, let stored = storedSourceSettings[source.id] {
                return stored
            }
            return .standard(for: source)
        }

        isRebuildingSources = true
        sources = rebuilt
        sourceSettings = settings
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
        let count = min(sources.count, sourceSettings.count, SharedState.maxSources)
        for index in 0..<count {
            let settings = sourceSettings[index]
            let state = engine.shared.sources[index]
            // When a strip's fader drives the device volume, the attenuation has
            // already happened upstream. Applying the stored dB here as well
            // would be a second, invisible gain stage.
            state.gain.value = isSystemStrip(sources[index])
                ? 1
                : LevelMath.linear(fromDB: settings.gainDB)
            state.muted.value = settings.muted

            // Stereo sources stay at unity on both sides; the pan law is for
            // placing a mono input, not for skewing an already-balanced pair.
            if sources[index].isStereo {
                state.panLeft.value = 1
                state.panRight.value = 1
            } else {
                let coefficients = SharedState.panCoefficients(settings.pan)
                state.panLeft.value = coefficients.left
                state.panRight.value = coefficients.right
            }

            for pair in 0..<min(SharedState.pairCount, settings.sends.count) {
                state.sends[pair].value = settings.sends[pair]
            }
        }
    }

    private func pushPairs() {
        for pair in 0..<min(SharedState.pairCount, pairSettings.count) {
            engine.shared.pairGain[pair].value = LevelMath.linear(fromDB: pairSettings[pair].gainDB)
            engine.shared.pairMuted[pair].value = pairSettings[pair].muted
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
