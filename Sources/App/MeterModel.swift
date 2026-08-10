import Foundation
import SwiftUI

/// Metering lives in its own observable object, separate from `AppModel`.
///
/// It changes 60 times a second. If it shared an object with the mixer state,
/// every tick would invalidate the whole view tree, and SwiftUI would rebuild
/// every gradient, shadow and rack panel in the window for the sake of a few
/// moving bars. Keeping it separate means only the leaf views that actually
/// draw a meter subscribe to it.
///
/// Views that merely *pass this along* must hold it as a plain `let`. Declaring
/// it `@ObservedObject` anywhere above a meter leaf reintroduces the problem.
@MainActor
final class MeterModel: ObservableObject {
    @Published private(set) var output: [MeterBallistics]
    @Published private(set) var sources: [MeterBallistics]
    @Published private(set) var fx: [MeterBallistics]

    init() {
        output = Array(repeating: MeterBallistics(), count: SharedState.outputChannelCount)
        sources = []
        fx = [MeterBallistics(), MeterBallistics()]
    }

    func resizeSources(count: Int) {
        guard sources.count != count * 2 else { return }
        sources = Array(repeating: MeterBallistics(), count: count * 2)
    }

    func update(shared: SharedState, fxState: FXState, sourceCount: Int, delta: TimeInterval) {
        var nextOutput = output
        for channel in 0..<SharedState.outputChannelCount {
            nextOutput[channel].update(peakLinear: shared.channelPeak[channel].drain(), delta: delta)
        }
        output = nextOutput

        if sources.count == sourceCount * 2 {
            var nextSources = sources
            for index in 0..<sourceCount {
                let state = shared.sources[index]
                nextSources[index * 2].update(peakLinear: state.peak[0].drain(), delta: delta)
                nextSources[index * 2 + 1].update(peakLinear: state.peak[1].drain(), delta: delta)
            }
            sources = nextSources
        }

        var nextFX = fx
        nextFX[0].update(peakLinear: fxState.outputPeak[0].drain(), delta: delta)
        nextFX[1].update(peakLinear: fxState.outputPeak[1].drain(), delta: delta)
        fx = nextFX
    }

    func clear() {
        output = Array(repeating: MeterBallistics(), count: SharedState.outputChannelCount)
        sources = Array(repeating: MeterBallistics(), count: sources.count)
        fx = [MeterBallistics(), MeterBallistics()]
    }

    // MARK: Safe accessors, since the arrays resize when devices change.

    func outputMeter(_ index: Int) -> MeterBallistics {
        index < output.count ? output[index] : MeterBallistics()
    }

    func sourceMeter(_ index: Int) -> MeterBallistics {
        index < sources.count ? sources[index] : MeterBallistics()
    }

    func fxMeter(_ index: Int) -> MeterBallistics {
        index < fx.count ? fx[index] : MeterBallistics()
    }
}

// MARK: - Leaf views
//
// Each of these subscribes to `MeterModel` on its own, and each draws its whole
// group in a single fixed-size `Canvas`.
//
// The one Canvas matters as much as the isolation. Profiling the first version,
// which built each bar and each scale tick as its own view, showed the cost was
// almost entirely SwiftUI layout rather than drawing: a meter tick made the
// engine re-solve `sizeThatFits` and `explicitAlignment` across every nested
// stack in the window. A Canvas with an explicit frame is one layout node no
// matter how much is drawn inside it.

/// Shared bar rendering, so the strips and the rack ladders look identical.
enum MeterDrawing {
    static let ramp: [(dB: Float, color: Color)] = [
        (-60, Theme.meterGreen), (-20, Theme.meterGreen), (-12, Theme.meterLime),
        (-5, Theme.meterAmber), (-1, Theme.meterRed), (6, Theme.meterRed),
    ]
    static let blockedRamp: [(dB: Float, color: Color)] = [
        (-60, Color(white: 0.42)), (6, Color(white: 0.52)),
    ]

    static func gradient(isPassing: Bool) -> Gradient {
        Gradient(stops: (isPassing ? ramp : blockedRamp).map {
            .init(color: $0.color, location: LevelMath.meterPosition(forDB: $0.dB))
        })
    }

    static func bar(_ context: inout GraphicsContext, rect: CGRect,
                    meter: MeterBallistics, isPassing: Bool) {
        let radius = rect.width / 2
        let track = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        context.fill(track, with: .color(Theme.well))
        context.stroke(track, with: .color(.black.opacity(0.6)), lineWidth: 1)

        let level = LevelMath.meterPosition(forDB: meter.displayDB)
        if level > 0.001 {
            var barContext = context
            barContext.clip(to: track)
            let height = rect.height * level
            let barRect = CGRect(x: rect.minX, y: rect.maxY - height,
                                 width: rect.width, height: height)
            barContext.fill(Path(barRect),
                            with: .linearGradient(gradient(isPassing: isPassing),
                                                  startPoint: CGPoint(x: 0, y: rect.maxY),
                                                  endPoint: CGPoint(x: 0, y: rect.minY)))
            barContext.fill(
                Path(CGRect(x: rect.minX, y: barRect.minY,
                            width: rect.width * 0.34, height: height)),
                with: .color(.white.opacity(0.13)))
        }

        let hold = LevelMath.meterPosition(forDB: meter.holdDB)
        if hold > 0.004 {
            var tickContext = context
            tickContext.clip(to: track)
            let y = rect.maxY - rect.height * hold
            let color: Color = isPassing
                ? (meter.holdDB >= -1 ? Theme.meterRed : Color.white.opacity(0.85))
                : Color.white.opacity(0.35)
            tickContext.fill(Path(CGRect(x: rect.minX, y: max(rect.minY, y - 1),
                                         width: rect.width, height: 2)),
                             with: .color(color))
        }
    }

    static let scaleMarks: [Float] = [0, -6, -12, -20, -30, -45, -60]

    static func scale(_ context: inout GraphicsContext, rect: CGRect) {
        for mark in scaleMarks {
            let y = rect.maxY - rect.height * LevelMath.meterPosition(forDB: mark)
            context.draw(
                Text(mark == 0 ? "0" : "\(Int(mark))")
                    .font(Theme.numeric(8, weight: .medium))
                    .foregroundStyle(Theme.textTertiary),
                at: CGPoint(x: rect.maxX - 6, y: y), anchor: .trailing)
            context.fill(Path(CGRect(x: rect.maxX - 4, y: y - 0.5, width: 3, height: 1)),
                         with: .color(Theme.textTertiary.opacity(0.35)))
        }
    }
}

/// Meter group for an input strip.
struct SourceMeterPair: View {
    @ObservedObject var meters: MeterModel
    let index: Int
    let isStereo: Bool
    let isPassing: Bool
    var height: CGFloat = 172

    private var width: CGFloat { isStereo ? 19 : 11 }

    var body: some View {
        Canvas { context, size in
            if isStereo {
                MeterDrawing.bar(&context, rect: CGRect(x: 0, y: 0, width: 8, height: size.height),
                                 meter: meters.sourceMeter(index * 2), isPassing: isPassing)
                MeterDrawing.bar(&context, rect: CGRect(x: 11, y: 0, width: 8, height: size.height),
                                 meter: meters.sourceMeter(index * 2 + 1), isPassing: isPassing)
            } else {
                MeterDrawing.bar(&context, rect: CGRect(x: 0, y: 0, width: 11, height: size.height),
                                 meter: meters.sourceMeter(index * 2), isPassing: isPassing)
            }
        }
        .frame(width: width, height: height)
    }
}

/// Scale plus stereo meter for an output pair, all in one node.
struct OutputMeterPair: View {
    @ObservedObject var meters: MeterModel
    let pair: Int
    var height: CGFloat = 172

    var body: some View {
        Canvas { context, size in
            MeterDrawing.scale(&context, rect: CGRect(x: 0, y: 0, width: 22, height: size.height))
            MeterDrawing.bar(&context, rect: CGRect(x: 24, y: 0, width: 9, height: size.height),
                             meter: meters.outputMeter(pair * 2), isPassing: true)
            MeterDrawing.bar(&context, rect: CGRect(x: 36, y: 0, width: 9, height: size.height),
                             meter: meters.outputMeter(pair * 2 + 1), isPassing: true)
        }
        .frame(width: 45, height: height)
    }
}

struct ClipIndicator: View {
    @ObservedObject var meters: MeterModel
    let pair: Int

    private var isClipping: Bool {
        meters.outputMeter(pair * 2).holdDB >= -0.1 || meters.outputMeter(pair * 2 + 1).holdDB >= -0.1
    }

    var body: some View {
        Text("CLIP")
            .font(Theme.label(8, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(isClipping ? Color.white : Theme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isClipping ? Theme.danger : Theme.well)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

/// Segmented ladder on the rack panel, also a single Canvas.
struct FXLadder: View {
    @ObservedObject var meters: MeterModel
    let channels: [Int]
    var segments: Int = 10
    var segmentWidth: CGFloat = 5

    var body: some View {
        let height = CGFloat(segments) * 4 - 1
        Canvas { context, _ in
            for (column, channel) in channels.enumerated() {
                let level = Float(LevelMath.meterPosition(forDB: meters.fxMeter(channel).displayDB))
                let x = CGFloat(column) * (segmentWidth + 2)
                for segment in 0..<segments {
                    let threshold = Float(segment) / Float(segments)
                    let lit = level > threshold
                    let y = height - CGFloat(segment + 1) * 4 + 1
                    context.fill(
                        Path(CGRect(x: x, y: y, width: segmentWidth, height: 3)),
                        with: .color(lit
                                     ? (segment >= segments - 2 ? Rack.led : Rack.screenInk)
                                     : Color.black.opacity(0.5)))
                }
            }
        }
        .frame(width: CGFloat(channels.count) * (segmentWidth + 2) - 2, height: height)
    }
}
