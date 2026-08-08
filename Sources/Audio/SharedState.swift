import Foundation
import Synchronization

/// Lock-free `Float` cell. The render thread must never block, so every value
/// crossing between the UI and the IOProc goes through one of these rather than
/// a lock or a `@Published` property.
///
/// `Atomic` is non-copyable, which rules out putting it in an array directly, so
/// each cell is a class and the arrays hold references.
final class AtomicFloat: @unchecked Sendable {
    private let bits: Atomic<UInt32>

    init(_ value: Float = 0) {
        bits = Atomic(value.bitPattern)
    }

    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    /// Raise the stored value if `candidate` is larger. Only the render thread
    /// calls this, so a plain load/store is sufficient; the UI's reset can at
    /// worst drop one frame of peak, which is invisible on a meter.
    func raise(to candidate: Float) {
        if candidate > value { value = candidate }
    }

    /// Read and clear, giving the UI max-since-last-read semantics.
    func drain() -> Float {
        let current = value
        value = 0
        return current
    }
}

final class AtomicBool: @unchecked Sendable {
    private let flag: Atomic<Bool>

    init(_ value: Bool = false) { flag = Atomic(value) }

    var value: Bool {
        get { flag.load(ordering: .relaxed) }
        set { flag.store(newValue, ordering: .relaxed) }
    }
}

/// Per-source mixer parameters. One instance per slot, allocated up front so the
/// render thread never sees the array change shape.
final class SourceState: @unchecked Sendable {
    /// Linear gain, converted from dB by the UI.
    let gain = AtomicFloat(1)
    /// Constant-power pan coefficients, precomputed so the render thread does
    /// no trigonometry.
    let panLeft = AtomicFloat(1)
    let panRight = AtomicFloat(1)
    let muted = AtomicBool(false)
    /// Whether this source feeds each output pair.
    let sends: [AtomicBool]
    /// Pre-fader peak per side, so a source still meters with its fader down.
    let peak: [AtomicFloat]

    init() {
        sends = (0..<SharedState.pairCount).map { _ in AtomicBool(true) }
        peak = [AtomicFloat(0), AtomicFloat(0)]
    }
}

/// Everything the UI and the render thread share, and nothing else.
///
/// The render thread reads these through class references. That costs a retain
/// and release per access, which is lock-free and allocation-free, so it cannot
/// block the callback; the references are hoisted out of the per-frame loops
/// regardless.
final class SharedState: @unchecked Sendable {
    static let outputChannelCount = 4
    static let pairCount = 2
    static let maxSources = 8

    let sources: [SourceState]

    /// Linear gain per output pair, already converted from dB by the UI.
    let pairGain: [AtomicFloat]
    let pairMuted: [AtomicBool]

    /// Peak magnitude per output channel since the UI last drained it.
    let channelPeak: [AtomicFloat]

    /// Set by the render thread when it detects the input side is delivering
    /// nothing but digital silence, so the UI can distinguish "quiet" from
    /// "system audio isn't actually routed here".
    let inputIsSilent = AtomicBool(true)

    init() {
        sources = (0..<Self.maxSources).map { _ in SourceState() }
        pairGain = (0..<Self.pairCount).map { _ in AtomicFloat(1.0) }
        pairMuted = (0..<Self.pairCount).map { _ in AtomicBool(false) }
        channelPeak = (0..<Self.outputChannelCount).map { _ in AtomicFloat(0) }
    }

    /// Constant-power pan law. Centre sits at -3 dB on both sides so a mono
    /// source keeps the same apparent loudness as it moves across the image.
    static func panCoefficients(_ pan: Float) -> (left: Float, right: Float) {
        let clamped = min(max(pan, -1), 1)
        let angle = (clamped + 1) * 0.25 * .pi
        return (cos(angle), sin(angle))
    }
}
