import Foundation
import Synchronization

/// A lock-free window onto the mixed output, so the analyser can look at what
/// the speakers are actually being sent.
///
/// The render thread appends into a power-of-two ring and publishes a monotonic
/// write cursor; the UI reads the most recent `count` samples back out. Nothing
/// blocks in either direction, and a torn read is impossible in practice: the
/// ring holds two thirds of a second at 48 kHz, while the analyser asks for at
/// most 8192 samples sixty times a second.
final class SpectrumTap: @unchecked Sendable {

    /// Power of two, so the wrap is a mask rather than a modulo.
    static let capacity = 32_768
    private static let mask = UInt64(capacity - 1)

    private let buffer: UnsafeMutablePointer<Float>
    private let cursor = Atomic<UInt64>(0)

    init() {
        buffer = .allocate(capacity: Self.capacity)
        buffer.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        buffer.deinitialize(count: Self.capacity)
        buffer.deallocate()
    }

    /// Render thread. Appends `count` frames of mono material.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var index = cursor.load(ordering: .relaxed)
        for frame in 0..<count {
            buffer[Int(index & Self.mask)] = samples[frame]
            index &+= 1
        }
        // Released after the samples land, so a reader that sees the new cursor
        // also sees the data behind it.
        cursor.store(index, ordering: .releasing)
    }

    /// Render thread. Appends the mono sum of a stereo bus, which is what an
    /// analyser wants to look at.
    func writeMix(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var index = cursor.load(ordering: .relaxed)
        for frame in 0..<count {
            buffer[Int(index & Self.mask)] = (left[frame] + right[frame]) * 0.5
            index &+= 1
        }
        cursor.store(index, ordering: .releasing)
    }

    /// Render thread. Keeps the cursor advancing while nothing is routed here,
    /// so the analyser reads silence rather than a stale loop of old audio.
    func writeSilence(count: Int) {
        guard count > 0 else { return }
        var index = cursor.load(ordering: .relaxed)
        for _ in 0..<count {
            buffer[Int(index & Self.mask)] = 0
            index &+= 1
        }
        cursor.store(index, ordering: .releasing)
    }

    /// UI thread. Copies the newest `count` samples in chronological order.
    /// Returns false until the ring has been filled once.
    @discardableResult
    func snapshot(into destination: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        guard count > 0, count <= Self.capacity else { return false }
        let end = cursor.load(ordering: .acquiring)
        guard end >= UInt64(count) else { return false }
        let start = end &- UInt64(count)
        for offset in 0..<count {
            destination[offset] = buffer[Int((start &+ UInt64(offset)) & Self.mask)]
        }
        return true
    }
}
