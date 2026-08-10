import Combine
import CoreAudio
import Foundation
import AppKit
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

    // Output pairs
    @Published var pairSettings: [PairSettings] = Array(repeating: PairSettings(),
                                                        count: SharedState.pairCount) {
        didSet {
            pushPairs()
            scheduleSave()
        }
    }
    /// Held as a plain reference, never `@Published`: this object changes 60
    /// times a second and must not invalidate anything above the meter leaves.
    let meterModel = MeterModel()

    // FX rack
    @Published var fxChain: [FXDeviceSettings] = [FXDeviceSettings(kind: .reverb)] {
        didSet {
            guard oldValue != fxChain else { return }
            engine.fx.publish(FXChainSnapshot(fxChain))
            scheduleSave()
        }
    }
    /// Which device the remote programmer is editing, and which page of it.
    @Published var fxEditDevice = 0
    /// Which page the remote programmer is showing.
    @Published var fxEditPage: FXEditPage = .reverb

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

    /// Level the System strip actually delivers, using a cubic taper.
    ///
    /// BlackHole's own curve is linear across -64...0 dB, so each of the macOS
    /// volume key's fixed 1/16 steps is a flat 4 dB no matter where you are.
    /// That is far coarser than any normal output device and is what makes the
    /// volume keys feel steppy. A cubic curve puts about 1.7 dB in the first
    /// step and opens up toward the bottom, which is how hardware behaves.
    static func systemTaperDB(_ position: Float) -> Float {
        guard position > 0.0001 else { return LevelMath.silenceDB }
        return max(LevelMath.silenceDB, 60 * log10(position))
    }

    /// Gain the mixer applies to turn BlackHole's attenuation into that curve.
    ///
    /// Derived from the dB the device reports rather than from an assumed
    /// formula, so a driver with a different taper still lands on the same
    /// curve. Compensation peaks around +14 dB near half travel and can never
    /// push the result above the source's original level, so it cannot clip.
    var systemCompensationDB: Float {
        let desired = Self.systemTaperDB(systemVolume)
        guard desired > LevelMath.silenceDB else { return LevelMath.silenceDB }
        let applied = systemVolumeDB ?? (64 * (systemVolume - 1))
        return min(max(desired - applied, -24), 24)
    }

    var systemVolumeReadout: String {
        let dB = Self.systemTaperDB(systemVolume)
        return dB <= LevelMath.silenceDB ? "−∞" : String(format: "%.1f", dB)
    }

    func setSystemVolume(_ scalar: Float) {
        guard let loopback else { return }
        systemVolume = scalar
        AudioDevices.setOutputVolume(loopback.id, channel: 0, scalar)
        systemVolumeDB = AudioDevices.outputVolumeDecibels(loopback.id)
        pushSources()
    }

    private func readSystemVolume() {
        guard let loopback else { return }
        if let scalar = AudioDevices.outputVolume(loopback.id, channel: 0) {
            systemVolume = scalar
        }
        systemVolumeDB = AudioDevices.outputVolumeDecibels(loopback.id)
        // The compensation depends on where the device volume sits, so it has
        // to be recomputed whenever anything moves it, keys included.
        pushSources()
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
        fxChain = persisted.fxChain
        engine.fx.publish(FXChainSnapshot(fxChain))
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
                                     sources: merged,
                                     fxChain: fxChain))
    }

    func resetSettings() {
        storedSourceSettings = [:]
        fxChain = [FXDeviceSettings(kind: .reverb)]
        pairSettings = Array(repeating: PairSettings(), count: SharedState.pairCount)
        rebuildSources(preservingCurrent: false)
        saveNow()
    }

    var settingsLocation: URL { store.location }

    // MARK: - Rack

    var rackIsFull: Bool { fxChain.count >= FXChainSnapshot.maxDevices }

    func addDevice(_ kind: FXDeviceKind) {
        guard !rackIsFull else { return }
        fxChain.append(FXDeviceSettings(kind: kind))
        fxEditDevice = fxChain.count - 1
    }

    func removeDevice(at index: Int) {
        guard fxChain.indices.contains(index) else { return }
        fxChain.remove(at: index)
        fxEditDevice = min(fxEditDevice, max(fxChain.count - 1, 0))
    }

    func moveDevice(at index: Int, by offset: Int) {
        let destination = index + offset
        guard fxChain.indices.contains(index), fxChain.indices.contains(destination) else { return }
        fxChain.swapAt(index, destination)
        fxEditDevice = destination
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
        meterModel.resizeSources(count: rebuilt.count)
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
                ? LevelMath.linear(fromDB: systemCompensationDB)
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

            engine.fx.sourceSend[index].value = settings.fxSend
        }
    }

    private func pushPairs() {
        for pair in 0..<min(SharedState.pairCount, pairSettings.count) {
            engine.shared.pairGain[pair].value = LevelMath.linear(fromDB: pairSettings[pair].gainDB)
            engine.shared.pairMuted[pair].value = pairSettings[pair].muted
            engine.fx.pairSend[pair].value = pairSettings[pair].fxSend
            engine.fx.pairReturn[pair].value = pairSettings[pair].fxReturn
        }
    }

    // MARK: - Metering

    /// 30 Hz rather than 60. Peak ballistics are time-based so they behave
    /// identically, the bars are indistinguishable in motion, and it halves the
    /// cost of the only thing in this app that runs continuously.
    private static let meterHz: Double = 30

    /// Keep the render thread's peak cells from saturating while we are not
    /// drawing, so the meters are correct the instant the window reappears.
    private func drainMetersWithoutPublishing() {
        for channel in 0..<SharedState.outputChannelCount {
            _ = engine.shared.channelPeak[channel].drain()
        }
        for index in 0..<sources.count {
            _ = engine.shared.sources[index].peak[0].drain()
            _ = engine.shared.sources[index].peak[1].drain()
        }
        _ = engine.fx.outputPeak[0].drain()
        _ = engine.fx.outputPeak[1].drain()
        lastTick = Date()
    }

    private func startDisplayTimer() {
        let timer = Timer(timeInterval: 1.0 / Self.meterHz, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func tick() {
        // Nothing to draw when the window is hidden behind something or the app
        // is in the background, and this is the only continuous work we do.
        guard NSApp?.occlusionState.contains(.visible) ?? true else {
            drainMetersWithoutPublishing()
            return
        }

        let now = Date()
        let delta = min(now.timeIntervalSince(lastTick), 0.1)
        lastTick = now

        meterModel.update(shared: engine.shared, fxState: engine.fx,
                          sourceCount: sources.count, delta: delta)

        slowTickCounter += 1
        if slowTickCounter >= Int(Self.meterHz / 2) {      // twice a second
            slowTickCounter = 0
            let current = AudioDevices.systemDefaultOutput()
            if current?.uid != systemOutput?.uid { systemOutput = current }
            if loopback == nil || outputCandidates.isEmpty { refreshDevices() }
        }
    }
}
