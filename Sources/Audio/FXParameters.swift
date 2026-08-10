import Foundation
import Synchronization

/// Everything the reverb needs to render a block. Read once per callback rather
/// than per sample, so the render thread sees a coherent set even if the UI
/// moves several controls at once.
struct FXParameters: Equatable, Codable {
    /// Multi Tap fans the delay line out this many times.
    static let maxTaps = 16

    var enabled = true
    var algorithm: ReverbAlgorithm = .hall

    // Main panel
    var decaySeconds: Float = 2.6
    var hfDamp: Float = 0.35
    var hiEQDB: Float = 0
    var dryWet: Float = 1.0

    // Remote programmer, reverb page
    var diffusion: Float = 0.62
    var lfDampHz: Float = 60
    var predelayMs: Float = 20

    // Tap-based algorithms
    var echoTimeMs: Float = 350
    var echoFeedback: Float = 0.45
    var tapCount: Int = 6

    // EQ page
    var eqEnabled = false
    var eqLowFrequency: Float = 180
    var eqLowGainDB: Float = 0
    var eqHighFrequency: Float = 4_000
    var eqHighGainDB: Float = 0

    // Gate page
    var gateEnabled = false
    var gateThresholdDB: Float = -30
    var gateDecayMs: Float = 320
    var gateHoldMs: Float = 120

    init() {}

    // Tolerant of missing keys, so adding a control later cannot invalidate a
    // saved patch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func f(_ key: CodingKeys, _ fallback: Float) throws -> Float {
            let value = try c.decodeIfPresent(Float.self, forKey: key) ?? fallback
            return value.isFinite ? value : fallback
        }
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        algorithm = try c.decodeIfPresent(ReverbAlgorithm.self, forKey: .algorithm) ?? .hall
        decaySeconds = try f(.decaySeconds, 2.6)
        hfDamp = try f(.hfDamp, 0.35)
        hiEQDB = try f(.hiEQDB, 0)
        dryWet = try f(.dryWet, 1.0)
        diffusion = try f(.diffusion, 0.62)
        lfDampHz = try f(.lfDampHz, 60)
        predelayMs = try f(.predelayMs, 20)
        echoTimeMs = try f(.echoTimeMs, 350)
        echoFeedback = try f(.echoFeedback, 0.45)
        tapCount = try c.decodeIfPresent(Int.self, forKey: .tapCount) ?? 6
        eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? false
        eqLowFrequency = try f(.eqLowFrequency, 180)
        eqLowGainDB = try f(.eqLowGainDB, 0)
        eqHighFrequency = try f(.eqHighFrequency, 4_000)
        eqHighGainDB = try f(.eqHighGainDB, 0)
        gateEnabled = try c.decodeIfPresent(Bool.self, forKey: .gateEnabled) ?? false
        gateThresholdDB = try f(.gateThresholdDB, -30)
        gateDecayMs = try f(.gateDecayMs, 320)
        gateHoldMs = try f(.gateHoldMs, 120)
    }

    /// Clamp everything into range before it can reach the render thread. A
    /// decay of zero or a NaN frequency would blow up the filter coefficients.
    func normalized() -> FXParameters {
        var copy = self
        copy.decaySeconds = min(max(decaySeconds, 0.1), 60)
        copy.hfDamp = min(max(hfDamp, 0), 1)
        copy.hiEQDB = min(max(hiEQDB, -18), 18)
        copy.dryWet = min(max(dryWet, 0), 1)
        copy.diffusion = min(max(diffusion, 0), 1)
        copy.lfDampHz = min(max(lfDampHz, 20), 1_000)
        copy.predelayMs = min(max(predelayMs, 0), 250)
        copy.echoTimeMs = min(max(echoTimeMs, 10), 2_000)
        copy.echoFeedback = min(max(echoFeedback, 0), 0.95)
        copy.tapCount = min(max(tapCount, 1), Self.maxTaps)
        copy.eqLowFrequency = min(max(eqLowFrequency, 20), 2_000)
        copy.eqLowGainDB = min(max(eqLowGainDB, -18), 18)
        copy.eqHighFrequency = min(max(eqHighFrequency, 200), 18_000)
        copy.eqHighGainDB = min(max(eqHighGainDB, -18), 18)
        copy.gateThresholdDB = min(max(gateThresholdDB, -60), 0)
        copy.gateDecayMs = min(max(gateDecayMs, 5), 4_000)
        copy.gateHoldMs = min(max(gateHoldMs, 0), 2_000)
        return copy
    }
}

/// Lock-free handoff of the whole rack.
///
/// Rather than one atomic per field, the snapshot is versioned: the UI writes a
/// copy and bumps a counter, and the render thread only re-reads when the
/// counter moves. `FXChainSnapshot` is plain-old-data, so that read is a memcpy
/// with no retain, release or free on the audio thread.
final class FXState: @unchecked Sendable {
    private let version = Atomic<UInt64>(0)
    private var storage = FXChainSnapshot()
    private let storageLock = NSLock()

    /// Only the render thread touches these, and only when `version` has moved.
    private var renderCache = FXChainSnapshot()
    private var renderVersion: UInt64 = 0

    /// Per-source and per-pair send levels, which change independently of the
    /// reverb's own settings.
    let sourceSend: [AtomicFloat]
    let pairSend: [AtomicFloat]
    let pairReturn: [AtomicFloat]

    /// Post-reverb output level, metered by the UI.
    let outputPeak: [AtomicFloat]

    init() {
        sourceSend = (0..<SharedState.maxSources).map { _ in AtomicFloat(0) }
        pairSend = (0..<SharedState.pairCount).map { _ in AtomicFloat(0) }
        pairReturn = (0..<SharedState.pairCount).map { _ in AtomicFloat(1) }
        outputPeak = [AtomicFloat(0), AtomicFloat(0)]
    }

    func publish(_ chain: FXChainSnapshot) {
        storageLock.lock()
        storage = chain
        storageLock.unlock()
        version.wrappingAdd(1, ordering: .releasing)
    }

    /// Render-thread read. Takes the lock only on the rare block where something
    /// changed, and `try` means it never blocks: if the UI happens to hold the
    /// lock right now, the previous snapshot is used for one more block.
    func snapshot() -> FXChainSnapshot {
        let current = version.load(ordering: .acquiring)
        if current != renderVersion {
            if storageLock.try() {
                renderCache = storage
                renderVersion = current
                storageLock.unlock()
            }
        }
        return renderCache
    }
}
