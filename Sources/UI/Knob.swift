import SwiftUI

/// Rotary knob. Vertical drag, because pointer-chasing rotation is miserable
/// with a mouse; hold Shift for fine adjustment.
struct Knob: View {
    @Binding var value: Double          // 0...1
    var diameter: CGFloat = 30
    var resetValue: Double?
    var isActive: Bool = true
    /// Rotation limits, matching a real pot's ~300 degrees of travel.
    private let sweep: Double = 300

    @State private var dragStart: Double?

    var body: some View {
        let angle = Angle(degrees: -sweep / 2 + sweep * min(max(value, 0), 1))

        ZStack {
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

            // Pointer.
            Capsule()
                .fill(isActive ? Color(white: 0.93) : Color(white: 0.42))
                .frame(width: 2, height: diameter * 0.34)
                .offset(y: -diameter * 0.24)
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

/// Small labelled horizontal control for the send amounts on the channel strips,
/// where a full knob would not fit.
struct MiniSlider: View {
    let label: String
    @Binding var value: Float           // 0...1
    var tint: Color = Theme.accent
    var trackWidth: CGFloat = 62

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Text(label)
                    .font(Theme.label(7, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 2)
                Text(value <= 0.001 ? "off" : "\(Int(value * 100))")
                    .font(Theme.numeric(7, weight: .medium))
                    .foregroundStyle(value <= 0.001 ? Theme.textTertiary : tint)
            }
            // Fixed width rather than a GeometryReader: these sit inside
            // fixed-width strips, and a GeometryReader here costs a layout pass
            // every time the meters tick.
            let width = trackWidth
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.well)
                    .frame(width: width, height: 4)
                    .overlay(Capsule().strokeBorder(.black.opacity(0.55), lineWidth: 1))
                Capsule()
                    .fill(tint.opacity(0.8))
                    .frame(width: max(0, CGFloat(value) * width), height: 4)
                Circle()
                    .fill(
                        LinearGradient(colors: [Color(white: 0.86), Color(white: 0.60)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 8, height: 8)
                    .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                    .offset(x: max(0, CGFloat(value) * width - 4))
            }
            .frame(width: width, height: 9)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        value = Float(min(max(drag.location.x / width, 0), 1))
                    }
            )
            .onTapGesture(count: 2) { value = 0 }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}
