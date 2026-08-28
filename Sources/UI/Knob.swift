import SwiftUI

/// Rotary knob. Vertical drag, because pointer-chasing rotation is miserable
/// with a mouse; hold Shift for fine adjustment.
struct Knob: View {
    @Binding var value: Double          // 0...1
    var diameter: CGFloat = 30
    var resetValue: Double?
    var isActive: Bool = true
    /// When set, the knob wears a value arc in this colour and the body shrinks
    /// to make room for it. The rack's knobs leave it nil and keep the plain
    /// engraved look.
    var tint: Color?
    /// Rotation limits, matching a real pot's ~300 degrees of travel.
    private let sweep: Double = 300

    @State private var dragStart: Double?

    var body: some View {
        let angle = Angle(degrees: -sweep / 2 + sweep * min(max(value, 0), 1))

        ZStack {
            if let tint {
                // Track, then the travelled part of it. Drawn from the same
                // sweep the pointer uses, so the two can never disagree.
                Circle()
                    .trim(from: 0, to: CGFloat(sweep / 360))
                    .stroke(Color.black.opacity(0.45),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90 - sweep / 2))
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(value, 0), 1) * sweep / 360))
                    .stroke(isActive ? tint : tint.opacity(0.35),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90 - sweep / 2))
                    .shadow(color: isActive ? tint.opacity(0.5) : .clear, radius: 3)
            }

            // Body: dark metal with a light source above.
            Circle()
                .fill(
                    LinearGradient(colors: [Color(white: 0.30), Color(white: 0.11)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    Circle().strokeBorder(Color.black.opacity(0.75), lineWidth: 1)
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                        .padding(1)
                )
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                .padding(tint == nil ? 0 : 4)

            // Pointer.
            Capsule()
                .fill(isActive ? Color(white: 0.93) : Color(white: 0.42))
                .frame(width: 2, height: diameter * (tint == nil ? 0.34 : 0.26))
                .offset(y: -diameter * (tint == nil ? 0.24 : 0.20))
                .rotationEffect(angle)
        }
        .frame(width: diameter, height: diameter)
        .opacity(isActive ? 1 : 0.45)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if dragStart == nil { dragStart = value }
                    let fine = NSEvent.modifierFlags.contains(.shift)
                    let range: Double = fine ? 600 : 160
                    let delta = Double(-drag.translation.height) / range
                    value = min(max((dragStart ?? value) + delta, 0), 1)
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) {
            if let resetValue { value = resetValue }
        }
        .accessibilityElement()
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in
            value = min(max(value + (direction == .increment ? 0.02 : -0.02), 0), 1)
        }
    }
}

/// A send or return on a channel strip: knob, value, label. Sized to whatever
/// column it is put in, so three of them fit an output strip and one fills a
/// source strip.
struct StripKnob: View {
    let label: String
    @Binding var value: Float           // 0...1
    var tint: Color = Theme.accent
    var diameter: CGFloat = 26
    /// Where a double-click sends it. A send falls to nothing, a return and the
    /// dry path go back to unity.
    var resetValue: Double = 0

    var body: some View {
        VStack(spacing: 1) {
            Knob(value: Binding(get: { Double(value) },
                                set: { value = Float(min(max($0, 0), 1)) }),
                 diameter: diameter,
                 resetValue: resetValue,
                 isActive: value > 0.001,
                 tint: tint)
            Text(value <= 0.001 ? "off" : "\(Int((value * 100).rounded()))")
                .font(Theme.numeric(7, weight: .medium))
                .foregroundStyle(value <= 0.001 ? Theme.textTertiary : tint)
            Text(label)
                .font(Theme.label(7, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}
