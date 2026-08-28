import Foundation

/// One band of the EQ. Which filter it drives is fixed by its position in
/// `EQParameters`: the outer two are shelves, the inner three are bells.
struct EQBand: Equatable, Codable {
    var enabled = true
    var frequency: Float = 1_000
    var gainDB: Float = 0
    /// Ignored by the shelves, which have a fixed slope.
    var q: Float = 0.9

    init(enabled: Bool = true, frequency: Float = 1_000, gainDB: Float = 0, q: Float = 0.9) {
        self.enabled = enabled
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        frequency = try c.decodeIfPresent(Float.self, forKey: .frequency) ?? 1_000
        gainDB = try c.decodeIfPresent(Float.self, forKey: .gainDB) ?? 0
        q = try c.decodeIfPresent(Float.self, forKey: .q) ?? 0.9
    }

    func normalized() -> EQBand {
        EQBand(enabled: enabled,
               frequency: min(max(frequency.isFinite ? frequency : 1_000, 20), 20_000),
               gainDB: min(max(gainDB.isFinite ? gainDB : 0, -18), 18),
               q: min(max(q.isFinite ? q : 0.9, 0.2), 8))
    }
}

/// Which filter each band position drives.
enum EQBandKind {
    case lowShelf, peak, highShelf
}

/// The EQ5's settings.
///
/// Five bands as five stored properties rather than an array, for the same
/// reason `FXChainSnapshot` avoids one: this struct is copied on the audio
/// thread, and copying an array would retain and release a heap buffer there.
struct EQParameters: Equatable, Codable {
    static let bandCount = 5

    var band0 = EQBand(frequency: 100, gainDB: 0)
    var band1 = EQBand(frequency: 300, gainDB: 0)
    var band2 = EQBand(frequency: 1_000, gainDB: 0)
    var band3 = EQBand(frequency: 3_500, gainDB: 0)
    var band4 = EQBand(frequency: 8_000, gainDB: 0)
    /// Make-up trim, since a boosted curve needs taking back down.
    var outputDB: Float = 0
    /// The preset these bands came from, or `.custom` once anything is moved.
    var preset: EQPreset = .flat

    static let labels = ["LOW", "LO-MID", "MID", "HI-MID", "HIGH"]
    static let kinds: [EQBandKind] = [.lowShelf, .peak, .peak, .peak, .highShelf]

    subscript(index: Int) -> EQBand {
        get {
            switch index {
            case 0: return band0
            case 1: return band1
            case 2: return band2
            case 3: return band3
            default: return band4
            }
        }
        set {
            switch index {
            case 0: band0 = newValue
            case 1: band1 = newValue
            case 2: band2 = newValue
            case 3: band3 = newValue
            default: band4 = newValue
            }
        }
    }

    static func kind(_ index: Int) -> EQBandKind {
        kinds.indices.contains(index) ? kinds[index] : .peak
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        band0 = try c.decodeIfPresent(EQBand.self, forKey: .band0) ?? EQBand(frequency: 100)
        band1 = try c.decodeIfPresent(EQBand.self, forKey: .band1) ?? EQBand(frequency: 300)
        band2 = try c.decodeIfPresent(EQBand.self, forKey: .band2) ?? EQBand(frequency: 1_000)
        band3 = try c.decodeIfPresent(EQBand.self, forKey: .band3) ?? EQBand(frequency: 3_500)
        band4 = try c.decodeIfPresent(EQBand.self, forKey: .band4) ?? EQBand(frequency: 8_000)
        outputDB = try c.decodeIfPresent(Float.self, forKey: .outputDB) ?? 0
        preset = try c.decodeIfPresent(EQPreset.self, forKey: .preset) ?? .custom
    }

    func normalized() -> EQParameters {
        var copy = self
        for index in 0..<Self.bandCount { copy[index] = self[index].normalized() }
        copy.outputDB = min(max(outputDB.isFinite ? outputDB : 0, -12), 12)
        return copy
    }

    /// True when nothing would change the signal, so the chain can skip it.
    var isFlat: Bool {
        for index in 0..<Self.bandCount {
            let band = self[index]
            if band.enabled && band.gainDB != 0 { return false }
        }
        return outputDB != 0 ? false : true
    }
}

/// Named curves. Applying one writes the bands, which are then free to be
/// moved by hand; the picker says `Custom` once they have been.
enum EQPreset: String, Codable, CaseIterable, Identifiable {
    case flat, loudness, vocal, warm, air, bassBoost, radio, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flat:      return "Flat"
        case .loudness:  return "Loudness"
        case .vocal:     return "Vocal"
        case .warm:      return "Warm"
        case .air:       return "Air"
        case .bassBoost: return "Bass boost"
        case .radio:     return "Radio"
        case .custom:    return "Custom"
        }
    }

    /// Everything that can be chosen. `custom` is a state, not a choice.
    static var selectable: [EQPreset] { allCases.filter { $0 != .custom } }

    /// The bands this preset sets, low to high. Frequency, gain, Q.
    private var curve: [(Float, Float, Float)] {
        switch self {
        case .flat, .custom:
            return [(100, 0, 0.9), (300, 0, 0.9), (1_000, 0, 0.9),
                    (3_500, 0, 0.9), (8_000, 0, 0.9)]
        case .loudness:
            return [(80, 5, 0.9), (300, -2, 0.8), (1_000, 0, 0.9),
                    (3_500, 1, 0.9), (9_000, 4, 0.9)]
        case .vocal:
            return [(90, -3, 0.9), (250, -3, 1.0), (1_600, 2, 0.9),
                    (4_000, 3.5, 0.9), (10_000, 2, 0.9)]
        case .warm:
            return [(120, 3, 0.9), (280, 1.5, 0.8), (1_000, 0, 0.9),
                    (3_200, -2, 0.9), (9_000, -2.5, 0.9)]
        case .air:
            return [(100, 0, 0.9), (300, -1, 0.8), (1_000, 0, 0.9),
                    (6_000, 1.5, 0.8), (12_000, 5, 0.9)]
        case .bassBoost:
            return [(70, 6, 0.9), (160, 2, 0.7), (1_000, 0, 0.9),
                    (3_500, 0, 0.9), (8_000, 0, 0.9)]
        case .radio:
            return [(200, -12, 0.9), (500, -2, 0.8), (1_500, 4, 1.2),
                    (3_000, 2, 1.0), (4_000, -12, 0.9)]
        }
    }

    /// Applied over the current settings, so the output trim survives a change
    /// of preset the way it would on a hardware unit.
    func applied(to current: EQParameters) -> EQParameters {
        var copy = current
        for (index, band) in curve.enumerated() where index < EQParameters.bandCount {
            copy[index] = EQBand(enabled: true, frequency: band.0, gainDB: band.1, q: band.2)
        }
        copy.preset = self
        return copy
    }
}

/// Five-band parametric EQ, stereo, processing in place down the FX bus.
///
/// Coefficients are recomputed only when a parameter actually moves. That keeps
/// the trigonometry off the per-buffer path while a curve is sitting still,
/// which is nearly always.
final class EQUnit {

    private var left = [Biquad](repeating: Biquad(), count: EQParameters.bandCount)
    private var right = [Biquad](repeating: Biquad(), count: EQParameters.bandCount)
    private var sampleRate: Float = 48_000
    private var current: EQParameters?

    func prepare(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        current = nil
        reset()
    }

    func reset() {
        for index in 0..<EQParameters.bandCount {
            left[index].reset()
            right[index].reset()
        }
    }

    func process(left leftBuffer: UnsafeMutablePointer<Float>,
                 right rightBuffer: UnsafeMutablePointer<Float>,
                 frames: Int,
                 parameters: EQParameters) {

        if current != parameters {
            current = parameters
            updateCoefficients(parameters)
        }

        let makeUp = parameters.outputDB == 0 ? 1 : pow(10, parameters.outputDB / 20)

        for frame in 0..<frames {
            var l = leftBuffer[frame]
            var r = rightBuffer[frame]
            for index in 0..<EQParameters.bandCount {
                let band = parameters[index]
                guard band.enabled, band.gainDB != 0 else { continue }
                l = left[index].process(l)
                r = right[index].process(r)
            }
            leftBuffer[frame] = l * makeUp
            rightBuffer[frame] = r * makeUp
        }
    }

    private func updateCoefficients(_ parameters: EQParameters) {
        for index in 0..<EQParameters.bandCount {
            let band = parameters[index]
            Self.configure(&left[index], band: band, index: index, sampleRate: sampleRate)
            Self.configure(&right[index], band: band, index: index, sampleRate: sampleRate)
        }
    }

    /// Also used by the panel to draw the response, so the curve on screen comes
    /// from the same coefficients the audio runs through.
    static func configure(_ filter: inout Biquad, band: EQBand, index: Int, sampleRate: Float) {
        switch EQParameters.kind(index) {
        case .lowShelf:
            filter.setLowShelf(frequency: band.frequency, gainDB: band.gainDB,
                               sampleRate: sampleRate)
        case .peak:
            filter.setPeaking(frequency: band.frequency, gainDB: band.gainDB,
                              q: band.q, sampleRate: sampleRate)
        case .highShelf:
            filter.setHighShelf(frequency: band.frequency, gainDB: band.gainDB,
                                sampleRate: sampleRate)
        }
    }

    /// The unit's response in dB across a log frequency sweep, for the display.
    /// Coefficients are built once for the whole sweep rather than per point.
    static func response(_ parameters: EQParameters, sampleRate: Float,
                         points: Int, minHz: Float, maxHz: Float) -> [Float] {
        var filters: [Biquad] = []
        var active: [Int] = []
        for index in 0..<EQParameters.bandCount {
            let band = parameters[index]
            guard band.enabled, band.gainDB != 0 else { continue }
            var filter = Biquad()
            configure(&filter, band: band, index: index, sampleRate: sampleRate)
            filters.append(filter)
            active.append(index)
        }

        let ratio = Double(maxHz / minHz)
        return (0..<max(points, 2)).map { step in
            let hz = minHz * Float(pow(ratio, Double(step) / Double(max(points - 1, 1))))
            var total = parameters.outputDB
            for filter in filters {
                total += 20 * log10(max(filter.magnitude(atHz: hz, sampleRate: sampleRate), 1e-6))
            }
            return total
        }
    }
}
