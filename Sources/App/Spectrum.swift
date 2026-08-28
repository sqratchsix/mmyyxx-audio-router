import Accelerate
import AppKit
import Foundation
import SwiftUI

/// How the analyser draws.
enum SpectrumStyle: String, Codable, CaseIterable, Identifiable {
    case bars, columns, area, line, mirror

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bars: return "Bars"
        case .columns: return "LED columns"
        case .area: return "Filled curve"
        case .line: return "Curve"
        case .mirror: return "Mirrored"
        }
    }
}

/// Colour scheme. Each is a ramp across the frequency axis; level modulates
/// brightness on top of it.
enum SpectrumPalette: String, Codable, CaseIterable, Identifiable {
    case aurora, ember, meter, ice, mono, sunset

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aurora: return "Aurora"
        case .ember: return "Ember"
        case .meter: return "Meter"
        case .ice: return "Ice"
        case .mono: return "Mono"
        case .sunset: return "Sunset"
        }
    }

    /// `position` runs 0 (low frequencies) to 1 (high).
    func color(position: Double) -> Color {
        let p = min(max(position, 0), 1)
        switch self {
        case .aurora:
            return Self.blend([Color(red: 0.20, green: 0.95, blue: 0.75),
                               Color(red: 0.29, green: 0.75, blue: 1.00),
                               Color(red: 0.62, green: 0.45, blue: 1.00)], p)
        case .ember:
            return Self.blend([Color(red: 1.00, green: 0.86, blue: 0.42),
                               Color(red: 1.00, green: 0.56, blue: 0.20),
                               Color(red: 0.94, green: 0.24, blue: 0.30)], p)
        case .meter:
            return Self.blend([Theme.meterGreen, Theme.meterLime,
                               Theme.meterAmber, Theme.meterRed], p)
        case .ice:
            return Self.blend([Color(red: 0.88, green: 0.96, blue: 1.00),
                               Color(red: 0.45, green: 0.78, blue: 1.00),
                               Color(red: 0.20, green: 0.42, blue: 0.92)], p)
        case .mono:
            return Color(white: 0.60 + 0.32 * p)
        case .sunset:
            return Self.blend([Color(red: 1.00, green: 0.42, blue: 0.62),
                               Color(red: 0.98, green: 0.62, blue: 0.35),
                               Color(red: 0.55, green: 0.40, blue: 0.98)], p)
        }
    }

    var gradientStops: [Color] {
        stride(from: 0.0, through: 1.0, by: 0.125).map { color(position: $0) }
    }

    private static func blend(_ colors: [Color], _ position: Double) -> Color {
        guard colors.count > 1 else { return colors[0] }
        let scaled = position * Double(colors.count - 1)
        let index = min(Int(scaled), colors.count - 2)
        return colors[index].mixed(with: colors[index + 1], amount: scaled - Double(index))
    }
}

extension Color {
    /// Linear interpolation in sRGB. Good enough for a ramp, and it avoids
    /// pulling in a colour-space dependency for the sake of a gradient.
    func mixed(with other: Color, amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        let t = CGFloat(min(max(amount, 0), 1))
        return Color(red: Double(a.redComponent + (b.redComponent - a.redComponent) * t),
                     green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * t),
                     blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * t))
    }
}

/// Everything adjustable about the analyser. Persisted alongside the mix.
struct SpectrumSettings: Codable, Equatable {
    var isVisible = true
    /// Folded to its header, keeping the panel and its controls to hand without
    /// the trace. Separate from `isVisible`, which removes it altogether.
    var isCollapsed = false
    /// Points per transform. Larger resolves the bass, at the cost of smearing
    /// transients across a longer window.
    var fftSize = 4096
    var bandCount = 72
    var minHz: Float = 20
    var maxHz: Float = 20_000
    var floorDB: Float = -78
    var ceilingDB: Float = 3
    /// Tilt applied per octave above 1 kHz, which is what makes music look
    /// roughly flat rather than falling off a cliff above 2 kHz.
    var slopeDBPerOctave: Float = 3
    var attackMS: Float = 25
    var releaseMS: Float = 300
    var refreshHz: Double = 60
    var style: SpectrumStyle = .bars
    var palette: SpectrumPalette = .aurora
    var showPeaks = true
    var peakHoldSeconds: Float = 1.1
    var peakFallDBPerSecond: Float = 20
    var showGrid = true
    var showLabels = true
    /// 0 draws each band raw; higher averages across neighbours for a smoother
    /// envelope at the cost of resolution.
    var neighbourSmoothing = 1
    var glow: Float = 0.5
    var barGap: Float = 0.22
    var height: Double = 128

    static let fftSizes = [1024, 2048, 4096, 8192]
    static let refreshRates: [Double] = [15, 30, 60]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        fftSize = try c.decodeIfPresent(Int.self, forKey: .fftSize) ?? 4096
        bandCount = try c.decodeIfPresent(Int.self, forKey: .bandCount) ?? 72
        minHz = try c.decodeIfPresent(Float.self, forKey: .minHz) ?? 20
        maxHz = try c.decodeIfPresent(Float.self, forKey: .maxHz) ?? 20_000
        floorDB = try c.decodeIfPresent(Float.self, forKey: .floorDB) ?? -78
        ceilingDB = try c.decodeIfPresent(Float.self, forKey: .ceilingDB) ?? 3
        slopeDBPerOctave = try c.decodeIfPresent(Float.self, forKey: .slopeDBPerOctave) ?? 3
        attackMS = try c.decodeIfPresent(Float.self, forKey: .attackMS) ?? 25
        releaseMS = try c.decodeIfPresent(Float.self, forKey: .releaseMS) ?? 300
        refreshHz = try c.decodeIfPresent(Double.self, forKey: .refreshHz) ?? 60
        style = try c.decodeIfPresent(SpectrumStyle.self, forKey: .style) ?? .bars
        palette = try c.decodeIfPresent(SpectrumPalette.self, forKey: .palette) ?? .aurora
        showPeaks = try c.decodeIfPresent(Bool.self, forKey: .showPeaks) ?? true
        peakHoldSeconds = try c.decodeIfPresent(Float.self, forKey: .peakHoldSeconds) ?? 1.1
        peakFallDBPerSecond = try c.decodeIfPresent(Float.self, forKey: .peakFallDBPerSecond) ?? 20
        showGrid = try c.decodeIfPresent(Bool.self, forKey: .showGrid) ?? true
        showLabels = try c.decodeIfPresent(Bool.self, forKey: .showLabels) ?? true
        neighbourSmoothing = try c.decodeIfPresent(Int.self, forKey: .neighbourSmoothing) ?? 1
        glow = try c.decodeIfPresent(Float.self, forKey: .glow) ?? 0.5
        barGap = try c.decodeIfPresent(Float.self, forKey: .barGap) ?? 0.22
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 128
    }

    /// Repair anything hand-edited or written by a future version, so the
    /// analyser can never be asked for a transform it cannot perform.
    func normalized() -> SpectrumSettings {
        var copy = self
        copy.fftSize = Self.fftSizes.contains(fftSize) ? fftSize : 4096
        copy.bandCount = min(max(bandCount, 8), 160)
        copy.minHz = min(max(minHz.isFinite ? minHz : 20, 10), 200)
        copy.maxHz = min(max(maxHz.isFinite ? maxHz : 20_000, 2_000), 24_000)
        copy.floorDB = min(max(floorDB.isFinite ? floorDB : -78, -120), -30)
        copy.ceilingDB = min(max(ceilingDB.isFinite ? ceilingDB : 3, -12), 12)
        copy.slopeDBPerOctave = min(max(slopeDBPerOctave.isFinite ? slopeDBPerOctave : 3, 0), 9)
        copy.attackMS = min(max(attackMS.isFinite ? attackMS : 25, 1), 400)
        copy.releaseMS = min(max(releaseMS.isFinite ? releaseMS : 300, 20), 3_000)
        copy.refreshHz = Self.refreshRates.contains(refreshHz) ? refreshHz : 60
        copy.peakHoldSeconds = min(max(peakHoldSeconds.isFinite ? peakHoldSeconds : 1.1, 0), 6)
        copy.peakFallDBPerSecond = min(max(peakFallDBPerSecond.isFinite ? peakFallDBPerSecond : 20, 2), 120)
        copy.neighbourSmoothing = min(max(neighbourSmoothing, 0), 4)
        copy.glow = min(max(glow.isFinite ? glow : 0.5, 0), 1)
        copy.barGap = min(max(barGap.isFinite ? barGap : 0.22, 0), 0.7)
        copy.height = min(max(height.isFinite ? height : 128, 70), 320)
        return copy
    }
}

/// Turns the engine's output tap into band levels for the analyser view.
///
/// Kept out of `AppModel` for the same reason the meters are: it republishes
/// every frame, and anything observing it is rebuilt every frame with it.
@MainActor
final class SpectrumAnalyzer: ObservableObject {

    /// Smoothed band levels in dBFS, low frequency first.
    @Published private(set) var bands: [Float] = []
    /// Held peaks, same indexing. Empty when peak hold is off.
    @Published private(set) var peaks: [Float] = []
    /// Loudest band, for the readout in the header.
    @Published private(set) var peakFrequency: Float = 0
    @Published private(set) var peakLevelDB: Float = -200
    /// False when nothing is reaching the tap, so the view can dim itself.
    @Published private(set) var isLive = false

    /// Stands in for -infinity, far below any floor the display offers.
    static let silentDB: Float = -200

    /// Band centre frequencies, for the grid labels.
    private(set) var centres: [Float] = []

    // Analysis state, rebuilt only when the shape changes.
    private var fftSetup: FFTSetup?
    private var log2n: vDSP_Length = 0
    private var pointCount = 0
    private var sampleRate: Double = 0
    private var window: [Float] = []
    private var windowSum: Float = 1
    private var samples: [Float] = []
    private var windowed: [Float] = []
    private var real: [Float] = []
    private var imaginary: [Float] = []
    private var magnitudes: [Float] = []
    private var binRanges: [(lower: Int, upper: Int)] = []
    private var rawDB: [Float] = []
    private var holdRemaining: [TimeInterval] = []
    private var shapeKey = ""

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func clear() {
        guard !bands.isEmpty else { return }
        bands = Array(repeating: Self.silentDB, count: bands.count)
        peaks = Array(repeating: Self.silentDB, count: peaks.count)
        peakLevelDB = Self.silentDB
        peakFrequency = 0
        isLive = false
    }

    /// One analysis frame. `delta` drives every time constant, so the display
    /// behaves the same at 15 Hz as at 60.
    func update(tap: SpectrumTap, settings: SpectrumSettings,
                sampleRate: Double, delta: TimeInterval) {
        guard sampleRate > 0 else { return }
        configure(settings: settings, sampleRate: sampleRate)
        guard let fftSetup, pointCount > 0 else { return }

        let captured = samples.withUnsafeMutableBufferPointer {
            tap.snapshot(into: $0.baseAddress!, count: pointCount)
        }
        guard captured else { return }

        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(pointCount))

        let half = pointCount / 2
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                            imagp: imaginaryBuffer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // `vDSP_fft_zrip` returns twice the true transform, and a Hann window
        // costs another factor of the window's own sum. Both are folded in here
        // so a full-scale sine reads 0 dBFS, matching the meters.
        var scale = 1 / windowSum
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))

        var loudest: Float = Self.silentDB
        var loudestBand = 0
        for band in 0..<binRanges.count {
            let range = binRanges[band]
            var peak: Float = 0
            for bin in range.lower...range.upper where magnitudes[bin] > peak {
                peak = magnitudes[bin]
            }
            // Tilt is applied to signal only. Adding it to the silence floor
            // would lift digital silence back into view as a phantom ramp
            // climbing toward 20 kHz, which is what an untilted analyser
            // showing nothing is supposed to look like.
            let dB: Float
            if peak > 1e-7 {
                dB = 20 * log10(peak)
                    + settings.slopeDBPerOctave * log2(max(centres[band], 1) / 1000)
            } else {
                // Not `LevelMath.silenceDB`: that floor is meant for a fader,
                // and a display floor set below it would draw digital silence
                // as a flat line at -80.
                dB = Self.silentDB
            }
            rawDB[band] = max(dB, settings.floorDB - 12)
        }

        if settings.neighbourSmoothing > 0 { smoothNeighbours(settings.neighbourSmoothing) }

        let rise = 1 - exp(-Float(delta) / max(settings.attackMS / 1000, 0.001))
        let fall = 1 - exp(-Float(delta) / max(settings.releaseMS / 1000, 0.001))

        var nextBands = bands
        var nextPeaks = peaks
        for band in 0..<rawDB.count {
            let target = rawDB[band]
            let current = nextBands[band]
            nextBands[band] = current + (target - current) * (target > current ? rise : fall)

            if settings.showPeaks {
                if nextBands[band] >= nextPeaks[band] {
                    nextPeaks[band] = nextBands[band]
                    holdRemaining[band] = TimeInterval(settings.peakHoldSeconds)
                } else if holdRemaining[band] > 0 {
                    holdRemaining[band] -= delta
                } else {
                    nextPeaks[band] = max(nextBands[band],
                                          nextPeaks[band] - settings.peakFallDBPerSecond * Float(delta))
                }
            } else {
                nextPeaks[band] = Self.silentDB
            }

            if rawDB[band] > loudest {
                loudest = rawDB[band]
                loudestBand = band
            }
        }

        bands = nextBands
        peaks = nextPeaks
        // Below the floor there is no peak to report, so the level pins to the
        // floor and the frequency holds its last meaningful reading. Tracking
        // the loudest band of the noise instead makes the readout dance.
        if loudest > settings.floorDB {
            peakLevelDB = loudest
            peakFrequency = centres.isEmpty ? 0 : centres[loudestBand]
        } else {
            peakLevelDB = settings.floorDB
        }
        isLive = loudest > settings.floorDB
    }

    /// Average each band with its neighbours, weights falling off linearly.
    private func smoothNeighbours(_ radius: Int) {
        let count = rawDB.count
        guard count > radius * 2 else { return }
        var smoothed = rawDB
        for band in 0..<count {
            var total: Float = 0
            var weightSum: Float = 0
            for offset in -radius...radius {
                let index = band + offset
                guard index >= 0, index < count else { continue }
                let weight = Float(radius + 1 - abs(offset))
                total += rawDB[index] * weight
                weightSum += weight
            }
            smoothed[band] = total / weightSum
        }
        rawDB = smoothed
    }

    /// Rebuild the transform and the band map when anything about their shape
    /// changes. Everything here allocates, which is why it is kept off the
    /// per-frame path.
    private func configure(settings: SpectrumSettings, sampleRate: Double) {
        let key = "\(settings.fftSize)|\(settings.bandCount)|\(settings.minHz)|"
            + "\(settings.maxHz)|\(Int(sampleRate))"
        guard key != shapeKey else { return }
        shapeKey = key

        let n = settings.fftSize
        pointCount = n
        self.sampleRate = sampleRate
        log2n = vDSP_Length(log2(Double(n)).rounded())

        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        windowSum = max(window.reduce(0, +), 1)

        samples = [Float](repeating: 0, count: n)
        windowed = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imaginary = [Float](repeating: 0, count: n / 2)
        magnitudes = [Float](repeating: 0, count: n / 2)

        // Log-spaced bands. Below the point where a band is narrower than one
        // bin the ranges collapse onto the same bin, which is the honest answer:
        // the transform simply has no more resolution down there.
        let binHz = Float(sampleRate) / Float(n)
        let topBin = n / 2 - 1
        let ratio = Double(settings.maxHz / settings.minHz)
        var ranges: [(lower: Int, upper: Int)] = []
        var centreList: [Float] = []
        for band in 0..<settings.bandCount {
            let low = settings.minHz * Float(pow(ratio, Double(band) / Double(settings.bandCount)))
            let high = settings.minHz * Float(pow(ratio, Double(band + 1) / Double(settings.bandCount)))
            var lower = max(1, Int((low / binHz).rounded(.down)))
            var upper = min(topBin, Int((high / binHz).rounded(.up)) - 1)
            lower = min(lower, topBin)
            upper = max(upper, lower)
            ranges.append((lower, upper))
            centreList.append(sqrt(low * high))
        }
        binRanges = ranges
        centres = centreList

        rawDB = [Float](repeating: Self.silentDB, count: ranges.count)
        holdRemaining = [TimeInterval](repeating: 0, count: ranges.count)
        bands = [Float](repeating: Self.silentDB, count: ranges.count)
        peaks = [Float](repeating: Self.silentDB, count: ranges.count)
    }
}
