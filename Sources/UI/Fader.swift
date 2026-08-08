import SwiftUI

/// Vertical console fader. Travel is relative to where the drag started rather
/// than absolute, so grabbing the cap never makes the level jump.
struct Fader: View {
    /// Travel, 0 at the bottom and 1 at the top. Callers own the mapping from
    /// travel to whatever the fader controls, because a dB taper and a device
    /// volume scalar are not the same curve.
    @Binding var position: CGFloat
    /// Where a double-click sends it. Unity for a dB fader, full for a device volume.
    var resetPosition: CGFloat = 0.75
    var unityMark: CGFloat? = 0.25
    var onEditingChanged: (Bool) -> Void = { _ in }

    private let capHeight: CGFloat = 22
    private let capWidth: CGFloat = 30
    private let trackWidth: CGFloat = 5

    @State private var dragStartPosition: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.height - capHeight, 1)
            let capCenterY = capHeight / 2 + travel * (1 - position)

            ZStack(alignment: .top) {
                track(height: geometry.size.height, travel: travel, capCenterY: capCenterY)
                cap
                    .position(x: geometry.size.width / 2, y: capCenterY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartPosition == nil {
                            dragStartPosition = position
                            onEditingChanged(true)
                        }
                        let delta = -value.translation.height / travel
                        position = min(max((dragStartPosition ?? position) + delta, 0), 1)
                    }
                    .onEnded { _ in
                        dragStartPosition = nil
                        onEditingChanged(false)
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    position = resetPosition
                }
            }
        }
        .frame(width: capWidth)
        .accessibilityElement()
        .accessibilityLabel("Fader")
        .accessibilityValue("\(Int(position * 100)) percent of travel")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = direction == .increment ? 0.02 : -0.02
            position = min(max(position + step, 0), 1)
        }
    }

    private func track(height: CGFloat, travel: CGFloat, capCenterY: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(Theme.well)
                .overlay(Capsule().strokeBorder(.black.opacity(0.6), lineWidth: 1))
                .frame(width: trackWidth)

            // Filled travel below the cap.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Capsule()
                    .fill(
                        LinearGradient(colors: [Theme.accent.opacity(0.85), Theme.accent.opacity(0.35)],
                                       startPoint: .bottom, endPoint: .top)
                    )
                    .frame(width: trackWidth, height: max(0, height - capCenterY))
            }

            // Unity mark, where the control has a meaningful one.
            if let unityMark {
                Rectangle()
                    .fill(Theme.textTertiary.opacity(0.8))
                    .frame(width: 11, height: 1)
                    .offset(y: capHeight / 2 + travel * unityMark - 0.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cap: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.32), Color(white: 0.20), Color(white: 0.26)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .overlay(
                // Index line across the middle of the cap.
                Rectangle()
                    .fill(Theme.accent)
                    .frame(height: 2)
                    .shadow(color: Theme.accent.opacity(0.6), radius: 3)
            )
            .frame(width: capWidth, height: capHeight)
            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }
}

extension Binding where Value == Float {
    /// Present a dB value as fader travel, applying the console taper in both
    /// directions.
    var faderTravel: Binding<CGFloat> {
        Binding<CGFloat>(
            get: { LevelMath.faderPosition(forDB: wrappedValue) },
            set: { wrappedValue = LevelMath.faderDB(forPosition: $0) }
        )
    }
}
