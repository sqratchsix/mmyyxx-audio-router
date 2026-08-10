import Foundation

enum ReverbAlgorithm: Int, CaseIterable, Codable, Identifiable {
    case smallSpace, room, hall, arena, plate, spring, echo, multiTap, reverse

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .smallSpace: return "Small Space"
        case .room:       return "Room"
        case .hall:       return "Hall"
        case .arena:      return "Arena"
        case .plate:      return "Plate"
        case .spring:     return "Spring"
        case .echo:       return "Echo"
        case .multiTap:   return "Multi Tap"
        case .reverse:    return "Reverse"
        }
    }

    /// How far the delay network is stretched. Bigger means longer modal
    /// spacing, which is what makes a hall sound larger than a room even at the
    /// same decay time.
    var sizeScale: Float {
        switch self {
        case .smallSpace: return 0.32
        case .room:       return 0.62
        case .hall:       return 1.15
        case .arena:      return 1.70
        case .plate:      return 0.55
        case .spring:     return 0.28
        default:          return 0.8
        }
    }

    /// Plates and springs are far denser than a real room of the same size.
    var diffusionBias: Float {
        switch self {
        case .plate:      return 0.30
        case .spring:     return 0.22
        case .smallSpace: return 0.10
        default:          return 0
        }
    }

    var usesNetwork: Bool {
        switch self {
        case .echo, .multiTap: return false
        default: return true
        }
    }
}

/// The RV7000-style reverb. A feedback delay network with an input diffuser,
/// plus tap-based algorithms that bypass the network entirely.
///
/// Everything is allocated in `init`. `process` runs on the render thread.
final class ReverbEngine {

    private static let lineCount = 8
    private static let diffuserCount = 4

    /// Mutually non-harmonic base lengths in milliseconds. Harmonically related
    /// delays would ring on specific pitches instead of producing a flat tail.
    private static let baseDelaysMs: [Float] = [29.7, 37.1, 41.1, 43.7, 53.9, 59.3, 61.7, 67.1]
    private static let diffuserMs: [Float] = [4.77, 3.59, 12.73, 9.31]

    private var sampleRate: Float = 48_000

    private var lines: [DelayLine] = []
    private var lineLengths = [Float](repeating: 1000, count: lineCount)
    private var lineFeedback = [Float](repeating: 0, count: lineCount)
    private var lineState = [Float](repeating: 0, count: lineCount)
    private var damping = [OnePoleLowpass](repeating: OnePoleLowpass(), count: lineCount)
    private var lowCut = [OnePoleHighpass](repeating: OnePoleHighpass(), count: lineCount)

    private var diffusersLeft: [AllpassFilter] = []
    private var diffusersRight: [AllpassFilter] = []

    private let predelayLeft: DelayLine
    private let predelayRight: DelayLine
    private let echoLeft: DelayLine
    private let echoRight: DelayLine
    private let reverseBuffer: DelayLine

    private var echoFeedbackL: Float = 0
    private var echoFeedbackR: Float = 0
    private var echoDamp = OnePoleLowpass()
    private var reversePhase: Float = 0

    private var hiEQLeft = Biquad(), hiEQRight = Biquad()
    private var eqLowLeft = Biquad(), eqLowRight = Biquad()
    private var eqHighLeft = Biquad(), eqHighRight = Biquad()
    private var gateLeft = EnvelopeGate(), gateRight = EnvelopeGate()

    // Cached so coefficients are only recomputed when something actually moves.
    private var cached = FXParameters()
    private var cacheValid = false

    init() {
        // Sized for the worst case at 96 kHz so the sample rate can change
        // without reallocating on the audio thread.
        let maxRate: Float = 96_000
        let maxLineSamples = Int(Self.baseDelaysMs.max()! * 2.0 * maxRate / 1000) + 64
        let maxDiffuserSamples = Int(Self.diffuserMs.max()! * 2.0 * maxRate / 1000) + 64

        lines = (0..<Self.lineCount).map { _ in DelayLine(maxSamples: maxLineSamples) }
        diffusersLeft = Self.diffuserMs.map {
            AllpassFilter(maxSamples: maxDiffuserSamples, length: $0 * maxRate / 1000)
        }
        diffusersRight = Self.diffuserMs.map {
            // Offset slightly so the two channels do not diffuse identically,
            // which would collapse the tail to the centre.
            AllpassFilter(maxSamples: maxDiffuserSamples, length: $0 * 1.18 * maxRate / 1000)
        }

        predelayLeft = DelayLine(maxSamples: Int(0.5 * maxRate))
        predelayRight = DelayLine(maxSamples: Int(0.5 * maxRate))
        echoLeft = DelayLine(maxSamples: Int(2.1 * maxRate))
        echoRight = DelayLine(maxSamples: Int(2.1 * maxRate))
        reverseBuffer = DelayLine(maxSamples: Int(2.1 * maxRate))
    }

    func prepare(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        cacheValid = false
        reset()
    }

    func reset() {
        for line in lines { line.clear() }
        for index in 0..<Self.lineCount {
            lineState[index] = 0
            damping[index].reset()
            lowCut[index].reset()
        }
        for filter in diffusersLeft { filter.clear() }
        for filter in diffusersRight { filter.clear() }
        predelayLeft.clear(); predelayRight.clear()
        echoLeft.clear(); echoRight.clear(); reverseBuffer.clear()
        echoFeedbackL = 0; echoFeedbackR = 0
        echoDamp.reset(); reversePhase = 0
        hiEQLeft.reset(); hiEQRight.reset()
        eqLowLeft.reset(); eqLowRight.reset()
        eqHighLeft.reset(); eqHighRight.reset()
        gateLeft.reset(); gateRight.reset()
    }

    // MARK: - Coefficients

    private func updateCoefficients(_ parameters: FXParameters) {
        let algorithm = parameters.algorithm
        let scale = algorithm.sizeScale
        let decay = max(parameters.decaySeconds, 0.05)

        // HF Damp sweeps the feedback lowpass from wide open down into the low
        // mids, which is what shortens the tail's top end first, the way air and
        // soft furnishings do.
        let cutoff = 18_000 * pow(0.055, parameters.hfDamp)

        // Those same filters also shave a little off the midband on every pass,
        // and at tens of passes per second that compounds into a tail far shorter
        // than the Decay knob promises: measured, a 20 s setting was decaying in
        // about 3 s. Dividing the feedback gain by the filters' loss at a mid
        // reference frequency makes Decay mean RT60 again, while the top end
        // still dies away first.
        let reference: Float = 500
        let midbandLoss = lowpassMagnitude(cutoff: cutoff, at: reference, sampleRate: sampleRate)
            * highpassMagnitude(cutoff: parameters.lfDampHz, at: reference, sampleRate: sampleRate)
        let compensation = 1 / max(midbandLoss, 0.25)

        for index in 0..<Self.lineCount {
            let ms = Self.baseDelaysMs[index] * scale
            lineLengths[index] = ms * sampleRate / 1000

            // RT60: the gain that leaves this line 60 dB down after `decay`.
            let seconds = ms / 1000
            // Held just below unity so compensation can never tip the network
            // into self-oscillation, but close enough that the longest decay
            // settings are still reachable.
            lineFeedback[index] = min(pow(10, -3 * seconds / decay) * compensation, 0.99995)

            damping[index].setCutoff(cutoff, sampleRate: sampleRate)
            lowCut[index].setCutoff(parameters.lfDampHz, sampleRate: sampleRate)
        }

        let diffusion = min(max(parameters.diffusion + algorithm.diffusionBias, 0), 1)
        let coefficient = 0.35 + 0.4 * diffusion
        for index in 0..<Self.diffuserCount {
            diffusersLeft[index].coefficient = coefficient
            diffusersRight[index].coefficient = coefficient
            let base = Self.diffuserMs[index] * (0.6 + 0.9 * scale) * sampleRate / 1000
            diffusersLeft[index].setLength(base)
            diffusersRight[index].setLength(base * 1.18)
        }

        hiEQLeft.setHighShelf(frequency: 4_000, gainDB: parameters.hiEQDB, sampleRate: sampleRate)
        hiEQRight.setHighShelf(frequency: 4_000, gainDB: parameters.hiEQDB, sampleRate: sampleRate)

        eqLowLeft.setLowShelf(frequency: parameters.eqLowFrequency,
                              gainDB: parameters.eqEnabled ? parameters.eqLowGainDB : 0,
                              sampleRate: sampleRate)
        eqLowRight.setLowShelf(frequency: parameters.eqLowFrequency,
                               gainDB: parameters.eqEnabled ? parameters.eqLowGainDB : 0,
                               sampleRate: sampleRate)
        eqHighLeft.setPeaking(frequency: parameters.eqHighFrequency,
                              gainDB: parameters.eqEnabled ? parameters.eqHighGainDB : 0,
                              q: 0.9, sampleRate: sampleRate)
        eqHighRight.setPeaking(frequency: parameters.eqHighFrequency,
                               gainDB: parameters.eqEnabled ? parameters.eqHighGainDB : 0,
                               q: 0.9, sampleRate: sampleRate)

        let threshold = pow(10, parameters.gateThresholdDB / 20)
        let attack = 1 - exp(-1 / (0.002 * sampleRate))
        let release = 1 - exp(-1 / (max(parameters.gateDecayMs, 5) / 1000 * sampleRate))
        let detector = 1 - exp(-1 / (0.010 * sampleRate))
        let hold = Int(max(parameters.gateHoldMs, 0) / 1000 * sampleRate)
        gateLeft.thresholdLinear = threshold
        gateLeft.attackCoefficient = attack
        gateLeft.releaseCoefficient = release
        gateLeft.detectorCoefficient = detector
        gateLeft.holdSamples = hold
        gateRight.thresholdLinear = threshold
        gateRight.attackCoefficient = attack
        gateRight.releaseCoefficient = release
        gateRight.detectorCoefficient = detector
        gateRight.holdSamples = hold

        echoDamp.setCutoff(18_000 * pow(0.055, parameters.hfDamp), sampleRate: sampleRate)
    }

    // MARK: - Render

    /// Processes the FX bus in place. `input` is the send bus; `output` receives
    /// the wet signal only, because the dry path never leaves the mixer.
    func process(inputLeft: UnsafeMutablePointer<Float>,
                 inputRight: UnsafeMutablePointer<Float>,
                 outputLeft: UnsafeMutablePointer<Float>,
                 outputRight: UnsafeMutablePointer<Float>,
                 frames: Int,
                 parameters: FXParameters) {

        if !cacheValid || parameters != cached {
            updateCoefficients(parameters)
            cached = parameters
            cacheValid = true
        }

        let predelaySamples = max(parameters.predelayMs * sampleRate / 1000, 1)
        let algorithm = parameters.algorithm

        for frame in 0..<frames {
            var left = inputLeft[frame]
            var right = inputRight[frame]
            let keyLeft = left, keyRight = right

            // Pre-delay sits ahead of everything, so it offsets the whole effect.
            predelayLeft.write(left)
            predelayRight.write(right)
            left = predelayLeft.read(predelaySamples)
            right = predelayRight.read(predelaySamples)

            var wetLeft: Float
            var wetRight: Float

            switch algorithm {
            case .echo:
                (wetLeft, wetRight) = renderEcho(left, right, parameters)
            case .multiTap:
                (wetLeft, wetRight) = renderMultiTap(left, right, parameters)
            case .reverse:
                (wetLeft, wetRight) = renderReverse(left, right, parameters)
            default:
                (wetLeft, wetRight) = renderNetwork(left, right)
            }

            // Hi EQ is part of the main panel, so it applies to every algorithm.
            wetLeft = hiEQLeft.process(wetLeft)
            wetRight = hiEQRight.process(wetRight)

            if parameters.eqEnabled {
                wetLeft = eqHighLeft.process(eqLowLeft.process(wetLeft))
                wetRight = eqHighRight.process(eqLowRight.process(wetRight))
            }

            if parameters.gateEnabled {
                // Keyed from the dry input, so the tail is cut by the source
                // stopping rather than by its own decay.
                wetLeft = gateLeft.process(wetLeft, key: keyLeft)
                wetRight = gateRight.process(wetRight, key: keyRight)
            }

            outputLeft[frame] = wetLeft
            outputRight[frame] = wetRight
        }
    }

    @inline(__always)
    private func renderNetwork(_ left: Float, _ right: Float) -> (Float, Float) {
        var diffusedLeft = left
        var diffusedRight = right
        for index in 0..<Self.diffuserCount {
            diffusedLeft = diffusersLeft[index].process(diffusedLeft)
            diffusedRight = diffusersRight[index].process(diffusedRight)
        }

        // Read the network's current state.
        for index in 0..<Self.lineCount {
            lineState[index] = lines[index].read(lineLengths[index])
        }

        // Householder reflection: orthogonal, so it redistributes energy between
        // lines without adding or removing any. Decay is set solely by the
        // per-line feedback gains, which keeps RT60 predictable.
        var sum: Float = 0
        for index in 0..<Self.lineCount { sum += lineState[index] }
        let correction = sum * (2.0 / Float(Self.lineCount))

        for index in 0..<Self.lineCount {
            var value = lineState[index] - correction
            value *= lineFeedback[index]
            value = damping[index].process(value)
            value = lowCut[index].process(value)
            value += (index < Self.lineCount / 2) ? diffusedLeft : diffusedRight
            lines[index].write(value)
        }

        // Interleaved taps keep the two outputs decorrelated.
        let outLeft = lineState[0] + lineState[2] - lineState[5] + lineState[7]
        let outRight = lineState[1] - lineState[3] + lineState[4] + lineState[6]
        return (outLeft * 0.35, outRight * 0.35)
    }

    @inline(__always)
    private func renderEcho(_ left: Float, _ right: Float,
                            _ parameters: FXParameters) -> (Float, Float) {
        let samples = max(parameters.echoTimeMs * sampleRate / 1000, 1)
        let tapLeft = echoLeft.read(samples)
        // Offsetting the right tap turns a mono echo into a ping-pong.
        let tapRight = echoRight.read(samples * 1.5)

        let feedback = min(max(parameters.echoFeedback, 0), 0.95)
        echoLeft.write(left + echoDamp.process(tapRight) * feedback)
        echoRight.write(right + tapLeft * feedback)
        return (tapLeft, tapRight)
    }

    @inline(__always)
    private func renderMultiTap(_ left: Float, _ right: Float,
                                _ parameters: FXParameters) -> (Float, Float) {
        echoLeft.write(left)
        echoRight.write(right)

        var outLeft: Float = 0
        var outRight: Float = 0
        let count = max(min(parameters.tapCount, 8), 1)
        let spacing = max(parameters.echoTimeMs, 10) * sampleRate / 1000

        for tap in 0..<count {
            let position = spacing * Float(tap + 1)
            let falloff = pow(min(max(parameters.echoFeedback, 0), 0.95), Float(tap))
            // Alternate the taps across the image so the pattern spreads.
            let pan = (tap % 2 == 0) ? Float(0.8) : Float(0.2)
            let sample = (echoLeft.read(position) + echoRight.read(position)) * 0.5 * falloff
            outLeft += sample * pan
            outRight += sample * (1 - pan)
        }
        return (outLeft, outRight)
    }

    @inline(__always)
    private func renderReverse(_ left: Float, _ right: Float,
                               _ parameters: FXParameters) -> (Float, Float) {
        let window = max(parameters.echoTimeMs * sampleRate / 1000, 128)
        reverseBuffer.write((left + right) * 0.5)

        // Two grains half a window apart, each reading backwards, crossfaded so
        // the seam where a grain restarts is not audible as a click.
        reversePhase += 1
        if reversePhase >= window { reversePhase -= window }
        let second = reversePhase + window * 0.5 >= window
            ? reversePhase - window * 0.5
            : reversePhase + window * 0.5

        let grainA = reverseBuffer.read(window - reversePhase)
        let grainB = reverseBuffer.read(window - second)
        let fade = reversePhase / window
        let shaped = grainA * sin(.pi * fade) + grainB * sin(.pi * (1 - fade))

        // Feed the reversed swell through the network so it blooms.
        return renderNetwork(shaped * 0.7, shaped * 0.7)
    }
}
