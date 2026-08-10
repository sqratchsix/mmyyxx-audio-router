import Foundation

/// Parameters for the 1U delay line.
struct DelayParameters: Equatable, Codable {
    var timeMs: Float = 375
    var feedback: Float = 0.35
    var pingPong = true
    var dampHz: Float = 7_000
    var level: Float = 0.8
    var pan: Float = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func f(_ key: CodingKeys, _ fallback: Float) throws -> Float {
            let value = try c.decodeIfPresent(Float.self, forKey: key) ?? fallback
            return value.isFinite ? value : fallback
        }
        timeMs = try f(.timeMs, 375)
        feedback = try f(.feedback, 0.35)
        pingPong = try c.decodeIfPresent(Bool.self, forKey: .pingPong) ?? true
        dampHz = try f(.dampHz, 7_000)
        level = try f(.level, 0.8)
        pan = try f(.pan, 0)
    }

    func normalized() -> DelayParameters {
        var copy = self
        copy.timeMs = min(max(timeMs, 5), 2_000)
        copy.feedback = min(max(feedback, 0), 0.95)
        copy.dampHz = min(max(dampHz, 200), 18_000)
        copy.level = min(max(level, 0), 1)
        copy.pan = min(max(pan, -1), 1)
        return copy
    }
}

/// Stereo delay with damped feedback and an optional ping-pong cross.
///
/// Processes in place, so a chain of devices can run down the same pair of
/// buffers without needing a scratch copy per stage.
final class DelayUnit {

    private let left: DelayLine
    private let right: DelayLine
    private var dampLeft = OnePoleLowpass()
    private var dampRight = OnePoleLowpass()

    private var sampleRate: Float = 48_000
    private var glidedTime: Float = 0
    private var glideCoefficient: Float = 0.0005

    private var cached = DelayParameters()
    private var cacheValid = false

    init() {
        let maxSamples = Int(2.1 * 96_000)
        left = DelayLine(maxSamples: maxSamples)
        right = DelayLine(maxSamples: maxSamples)
    }

    func prepare(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        glideCoefficient = 1 - exp(-1 / (0.030 * self.sampleRate))
        cacheValid = false
        reset()
    }

    func reset() {
        left.clear(); right.clear()
        dampLeft.reset(); dampRight.reset()
        glidedTime = 0
    }

    func process(left buffer0: UnsafeMutablePointer<Float>,
                 right buffer1: UnsafeMutablePointer<Float>,
                 frames: Int,
                 parameters: DelayParameters) {

        if !cacheValid || parameters != cached {
            dampLeft.setCutoff(parameters.dampHz, sampleRate: sampleRate)
            dampRight.setCutoff(parameters.dampHz, sampleRate: sampleRate)
            cached = parameters
            if !cacheValid {
                glidedTime = parameters.timeMs * sampleRate / 1000
                cacheValid = true
            }
        }

        let target = max(parameters.timeMs * sampleRate / 1000, 1)
        let feedback = parameters.feedback
        let level = parameters.level
        let coefficients = SharedState.panCoefficients(parameters.pan)
        // Constant-power pan is for placing a mono source; a stereo delay just
        // needs a balance, so the centre stays at unity on both sides.
        let gainLeft = level * coefficients.left * 1.4142
        let gainRight = level * coefficients.right * 1.4142

        for frame in 0..<frames {
            // Gliding the read position bends the pitch briefly instead of
            // stepping, which is what a delay is expected to do.
            glidedTime += (target - glidedTime) * glideCoefficient

            let dryLeft = buffer0[frame]
            let dryRight = buffer1[frame]

            let tapLeft = left.read(glidedTime)
            let tapRight = right.read(glidedTime)

            if parameters.pingPong {
                left.write(dryLeft + dampLeft.process(tapRight) * feedback)
                right.write(dryRight + dampRight.process(tapLeft) * feedback)
            } else {
                left.write(dryLeft + dampLeft.process(tapLeft) * feedback)
                right.write(dryRight + dampRight.process(tapRight) * feedback)
            }

            buffer0[frame] = tapLeft * gainLeft
            buffer1[frame] = tapRight * gainRight
        }
    }
}
