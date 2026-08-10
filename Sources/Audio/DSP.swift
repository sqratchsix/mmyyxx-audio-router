import Foundation

/// Real-time DSP primitives.
///
/// Every one of these allocates its storage once at init and never again, and
/// none of them lock, because they all run inside the IOProc.

/// Fixed-capacity ring buffer with fractional read, so delay times can be
/// modulated or set to non-integer sample counts without stepping.
final class DelayLine {
    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var writeIndex = 0

    init(maxSamples: Int) {
        capacity = max(maxSamples, 2)
        buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    func clear() {
        buffer.update(repeating: 0, count: capacity)
        writeIndex = 0
    }

    @inline(__always)
    func write(_ value: Float) {
        buffer[writeIndex] = value
        writeIndex += 1
        if writeIndex >= capacity { writeIndex = 0 }
    }

    /// Read `delay` samples back from the write head, interpolating between the
    /// two neighbouring samples.
    @inline(__always)
    func read(_ delay: Float) -> Float {
        let clamped = min(max(delay, 1), Float(capacity - 2))
        let whole = Int(clamped)
        let fraction = clamped - Float(whole)

        var index = writeIndex - whole
        if index < 0 { index += capacity }
        var previous = index - 1
        if previous < 0 { previous += capacity }

        return buffer[index] * (1 - fraction) + buffer[previous] * fraction
    }

    @inline(__always)
    func read(_ delay: Int) -> Float {
        var index = writeIndex - delay
        if index < 0 { index += capacity }
        return buffer[index]
    }
}

/// One-pole lowpass. Used for the damping inside reverb feedback paths, where a
/// steeper filter would colour the tail more than it controls it.
struct OnePoleLowpass {
    private var state: Float = 0
    private var coefficient: Float = 1

    mutating func setCutoff(_ hz: Float, sampleRate: Float) {
        let clamped = min(max(hz, 20), sampleRate * 0.49)
        coefficient = 1 - exp(-2 * .pi * clamped / sampleRate)
    }

    @inline(__always)
    mutating func process(_ input: Float) -> Float {
        state += (input - state) * coefficient
        return state
    }

    mutating func reset() { state = 0 }
}

struct OnePoleHighpass {
    private var lowpass = OnePoleLowpass()

    mutating func setCutoff(_ hz: Float, sampleRate: Float) {
        lowpass.setCutoff(hz, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func process(_ input: Float) -> Float {
        input - lowpass.process(input)
    }

    mutating func reset() { lowpass.reset() }
}

/// Schroeder allpass, the building block of the input diffuser. Smears a
/// transient into a dense burst without changing its magnitude spectrum.
final class AllpassFilter {
    private let delay: DelayLine
    private var length: Float
    var coefficient: Float = 0.5

    init(maxSamples: Int, length: Float) {
        delay = DelayLine(maxSamples: maxSamples)
        self.length = length
    }

    func setLength(_ samples: Float) { length = samples }
    func clear() { delay.clear() }

    @inline(__always)
    func process(_ input: Float) -> Float {
        let delayed = delay.read(length)
        let value = input + delayed * -coefficient
        delay.write(value)
        return delayed + value * coefficient
    }
}

/// Transposed direct form II biquad. Used for the shelving and peaking bands in
/// the EQ section and for the Hi EQ control.
struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0
    private var a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    @inline(__always)
    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }

    mutating func reset() { z1 = 0; z2 = 0 }

    mutating func setLowShelf(frequency: Float, gainDB: Float, sampleRate: Float) {
        let a = pow(10, gainDB / 40)
        let w = 2 * Float.pi * min(max(frequency, 20), sampleRate * 0.45) / sampleRate
        let cosw = cos(w), sinw = sin(w)
        let alpha = sinw / 2 * sqrt((a + 1 / a) * (1 / 0.9 - 1) + 2)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        normalize(
            b0: a * ((a + 1) - (a - 1) * cosw + twoSqrtAAlpha),
            b1: 2 * a * ((a - 1) - (a + 1) * cosw),
            b2: a * ((a + 1) - (a - 1) * cosw - twoSqrtAAlpha),
            a0: (a + 1) + (a - 1) * cosw + twoSqrtAAlpha,
            a1: -2 * ((a - 1) + (a + 1) * cosw),
            a2: (a + 1) + (a - 1) * cosw - twoSqrtAAlpha
        )
    }

    mutating func setHighShelf(frequency: Float, gainDB: Float, sampleRate: Float) {
        let a = pow(10, gainDB / 40)
        let w = 2 * Float.pi * min(max(frequency, 20), sampleRate * 0.45) / sampleRate
        let cosw = cos(w), sinw = sin(w)
        let alpha = sinw / 2 * sqrt((a + 1 / a) * (1 / 0.9 - 1) + 2)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        normalize(
            b0: a * ((a + 1) + (a - 1) * cosw + twoSqrtAAlpha),
            b1: -2 * a * ((a - 1) + (a + 1) * cosw),
            b2: a * ((a + 1) + (a - 1) * cosw - twoSqrtAAlpha),
            a0: (a + 1) - (a - 1) * cosw + twoSqrtAAlpha,
            a1: 2 * ((a - 1) - (a + 1) * cosw),
            a2: (a + 1) - (a - 1) * cosw - twoSqrtAAlpha
        )
    }

    mutating func setPeaking(frequency: Float, gainDB: Float, q: Float, sampleRate: Float) {
        let a = pow(10, gainDB / 40)
        let w = 2 * Float.pi * min(max(frequency, 20), sampleRate * 0.45) / sampleRate
        let cosw = cos(w), sinw = sin(w)
        let alpha = sinw / (2 * max(q, 0.1))
        normalize(
            b0: 1 + alpha * a,
            b1: -2 * cosw,
            b2: 1 - alpha * a,
            a0: 1 + alpha / a,
            a1: -2 * cosw,
            a2: 1 - alpha / a
        )
    }

    private mutating func normalize(b0: Float, b1: Float, b2: Float,
                                    a0: Float, a1: Float, a2: Float) {
        let inverse = 1 / a0
        self.b0 = b0 * inverse
        self.b1 = b1 * inverse
        self.b2 = b2 * inverse
        self.a1 = a1 * inverse
        self.a2 = a2 * inverse
    }
}

/// Envelope-following gate. The RV7000's gate section chops the reverb tail,
/// which is how gated-reverb drum sounds are made: a long tail that stops dead
/// instead of decaying.
struct EnvelopeGate {
    private var envelope: Float = 0
    private var gain: Float = 0
    private var holdCounter: Int = 0

    var thresholdLinear: Float = 0.01
    var attackCoefficient: Float = 0.01
    var releaseCoefficient: Float = 0.001
    var holdSamples: Int = 2400
    var detectorCoefficient: Float = 0.01

    @inline(__always)
    mutating func process(_ input: Float, key: Float) -> Float {
        let rectified = abs(key)
        envelope += (rectified - envelope) * detectorCoefficient

        if envelope > thresholdLinear {
            holdCounter = holdSamples
            gain += (1 - gain) * attackCoefficient
        } else if holdCounter > 0 {
            holdCounter -= 1
            gain += (1 - gain) * attackCoefficient
        } else {
            gain += (0 - gain) * releaseCoefficient
        }
        return input * gain
    }

    mutating func reset() { envelope = 0; gain = 0; holdCounter = 0 }
}

/// Magnitude response of the one-pole lowpass at a given frequency.
///
/// Needed so the reverb can cancel out the damping filters' midband loss when
/// it works out feedback gains; without it the Decay control reads far longer
/// than the tail actually lasts.
func lowpassMagnitude(cutoff: Float, at frequency: Float, sampleRate: Float) -> Float {
    let a = 1 - exp(-2 * .pi * min(max(cutoff, 20), sampleRate * 0.49) / sampleRate)
    let w = 2 * Float.pi * frequency / sampleRate
    let real = 1 - (1 - a) * cos(w)
    let imaginary = (1 - a) * sin(w)
    return a / sqrt(real * real + imaginary * imaginary)
}

/// Matching magnitude for the `1 - lowpass` highpass.
func highpassMagnitude(cutoff: Float, at frequency: Float, sampleRate: Float) -> Float {
    let a = 1 - exp(-2 * .pi * min(max(cutoff, 20), sampleRate * 0.49) / sampleRate)
    let w = 2 * Float.pi * frequency / sampleRate
    let real = 1 - (1 - a) * cos(w)
    let imaginary = (1 - a) * sin(w)
    let numerator = (1 - a) * 2 * abs(sin(w / 2))
    return numerator / sqrt(real * real + imaginary * imaginary)
}
