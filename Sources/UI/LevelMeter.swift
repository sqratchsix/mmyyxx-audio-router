import SwiftUI

/// A vertical peak meter with a hold tick. Drawn in a `Canvas` so the segments,
/// the gradient and the hold marker stay crisp at any height without stacking
/// half a dozen overlapping views.
struct LevelMeter: View {
    let displayDB: Float
    let holdDB: Float
    var width: CGFloat = 9

    /// Colour ramp keyed to dB rather than to bar height, so the amber and red
    /// zones sit at the same levels no matter how tall the meter is drawn.
    private static let ramp: [(dB: Float, color: Color)] = [
        (-60, Theme.meterGreen),
        (-20, Theme.meterGreen),
        (-12, Theme.meterLime),
        (-5,  Theme.meterAmber),
        (-1,  Theme.meterRed),
        (6,   Theme.meterRed),
    ]

    private var gradient: Gradient {
        Gradient(stops: Self.ramp.map {
            .init(color: $0.color, location: LevelMath.meterPosition(forDB: $0.dB))
        })
    }

    var body: some View {
        Canvas { context, size in
            let radius = width / 2
            let track = Path(roundedRect: CGRect(origin: .zero, size: size),
                             cornerRadius: radius, style: .continuous)

            context.fill(track, with: .color(Theme.well))
            context.stroke(track, with: .color(.black.opacity(0.6)), lineWidth: 1)

            // Bar. Clipped to the track so the rounded ends are preserved.
            let level = LevelMath.meterPosition(forDB: displayDB)
            if level > 0.001 {
                var barContext = context
                barContext.clip(to: track)
                let barHeight = size.height * level
                barContext.fill(
                    Path(CGRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight)),
                    with: .linearGradient(gradient,
                                          startPoint: CGPoint(x: 0, y: size.height),
                                          endPoint: CGPoint(x: 0, y: 0))
                )
                // Specular highlight down the left edge sells the glass look.
                barContext.fill(
                    Path(CGRect(x: 0, y: size.height - barHeight, width: size.width * 0.34, height: barHeight)),
                    with: .color(.white.opacity(0.13))
                )
            }

            // Peak hold tick.
            let hold = LevelMath.meterPosition(forDB: holdDB)
            if hold > 0.004 {
                let y = size.height - size.height * hold
                var tickContext = context
                tickContext.clip(to: track)
                tickContext.fill(
                    Path(CGRect(x: 0, y: max(0, y - 1), width: size.width, height: 2)),
                    with: .color(holdDB >= -1 ? Theme.meterRed : Color.white.opacity(0.85))
                )
            }
        }
        .frame(width: width)
        .accessibilityLabel("Level")
        .accessibilityValue(LevelMath.format(dB: displayDB) + " decibels")
    }
}

/// Shared dB gridline labels sitting beside a meter pair.
struct MeterScale: View {
    private static let marks: [Float] = [0, -6, -12, -20, -30, -45, -60]

    var body: some View {
        GeometryReader { geometry in
            ForEach(Self.marks, id: \.self) { mark in
                let y = geometry.size.height * (1 - LevelMath.meterPosition(forDB: mark))
                HStack(spacing: 3) {
                    Text(mark == 0 ? "0" : "\(Int(mark))")
                        .font(Theme.numeric(8, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    Rectangle()
                        .fill(Theme.textTertiary.opacity(0.35))
                        .frame(width: 3, height: 1)
                }
                .frame(width: 22, alignment: .trailing)
                .position(x: 11, y: y)
            }
        }
        .frame(width: 22)
    }
}
