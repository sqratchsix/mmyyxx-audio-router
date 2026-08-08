import Foundation

/// dB conversions and the two curves the UI depends on: how a meter maps dB to
/// height, and how a fader maps travel to dB.
enum LevelMath {

    static let silenceDB: Float = -80
    static let meterFloorDB: Float = -60
    static let meterCeilingDB: Float = 6

    static func dB(fromLinear linear: Float) -> Float {
        linear <= 0 ? silenceDB : max(silenceDB, 20 * log10(linear))
    }

    static func linear(fromDB dB: Float) -> Float {
        dB <= silenceDB ? 0 : pow(10, dB / 20)
    }

    /// Meter height as 0...1. Deliberately not linear in dB: raising the value
    /// to a power above 1 gives the top of the scale more pixels, so the range
    /// that actually matters for clipping is the range you can read.
    static func meterPosition(forDB dB: Float) -> CGFloat {
        let span = meterCeilingDB - meterFloorDB
        let normalized = (min(max(dB, meterFloorDB), meterCeilingDB) - meterFloorDB) / span
        return CGFloat(pow(normalized, 1.5))
    }

    /// Fader travel to dB, using the piecewise taper of a mixing console: fine
    /// resolution around unity, coarse as it approaches the bottom.
    /// 0.75 of the travel sits at 0 dB, the top reaches +6 dB.
    static func faderDB(forPosition position: CGFloat) -> Float {
        let p = Float(min(max(position, 0), 1))
        switch p {
        case 0:            return silenceDB
        case 0.75...:      return (p - 0.75) / 0.25 * 6
        case 0.5..<0.75:   return -12 + (p - 0.5) / 0.25 * 12
        case 0.25..<0.5:   return -36 + (p - 0.25) / 0.25 * 24
        default:           return -60 + p / 0.25 * 24
        }
    }

    /// Inverse of `faderDB(forPosition:)`, so the knob can be placed from a dB value.
    static func faderPosition(forDB dB: Float) -> CGFloat {
        switch dB {
        case silenceDB...(-60):  return 0
        case -60..<(-36):        return CGFloat((dB + 60) / 24 * 0.25)
        case -36..<(-12):        return CGFloat(0.25 + (dB + 36) / 24 * 0.25)
        case -12..<0:            return CGFloat(0.5 + (dB + 12) / 12 * 0.25)
        default:                 return CGFloat(min(1, 0.75 + dB / 6 * 0.25))
        }
    }

    static func format(dB: Float) -> String {
        if dB <= silenceDB { return "−∞" }
        return String(format: dB > 0 ? "+%.1f" : "%.1f", dB)
    }
}

/// Peak meter ballistics: instant attack, timed hold, then a linear fall in dB
/// per second. Matches how a hardware peak meter behaves, and keeps transients
/// readable instead of flickering.
struct MeterBallistics {
    var displayDB: Float = LevelMath.silenceDB
    var holdDB: Float = LevelMath.silenceDB
    private var holdRemaining: TimeInterval = 0

    private static let holdDuration: TimeInterval = 1.5
    private static let fallRate: Float = 26      // dB per second
    private static let holdFallRate: Float = 12

    mutating func update(peakLinear: Float, delta: TimeInterval) {
        let incoming = LevelMath.dB(fromLinear: peakLinear)

        displayDB = incoming >= displayDB
            ? incoming
            : max(incoming, displayDB - Self.fallRate * Float(delta))

        if incoming >= holdDB {
            holdDB = incoming
            holdRemaining = Self.holdDuration
        } else if holdRemaining > 0 {
            holdRemaining -= delta
        } else {
            holdDB = max(displayDB, holdDB - Self.holdFallRate * Float(delta))
        }
    }
}
