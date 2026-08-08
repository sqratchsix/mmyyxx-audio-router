import SwiftUI

/// An input channel strip: pre-fader meter, level, pan, mute, and a send button
/// per output pair.
struct SourceStrip: View {
    let source: MixerSource
    let leftMeter: MeterBallistics
    let rightMeter: MeterBallistics
    @Binding var settings: SourceSettings
    let pairLabels: [String]

    private var muted: Bool { settings.muted }

    /// Whether this source actually reaches an output right now. All three of
    /// these block it, and each one is easy to leave set by accident.
    private var isPassing: Bool {
        !settings.muted
            && settings.gainDB > LevelMath.silenceDB
            && settings.sends.contains(true)
    }

    var body: some View {
        VStack(spacing: 8) {
            header

            HStack(alignment: .center, spacing: 5) {
                HStack(spacing: 3) {
                    LevelMeter(displayDB: leftMeter.displayDB, holdDB: leftMeter.holdDB,
                               width: source.isStereo ? 8 : 11, isPassing: isPassing)
                    if source.isStereo {
                        LevelMeter(displayDB: rightMeter.displayDB, holdDB: rightMeter.holdDB,
                                   width: 8, isPassing: isPassing)
                    }
                }
                Fader(dB: $settings.gainDB)
            }
            .frame(height: 172)

            Text(LevelMath.format(dB: settings.gainDB))
                .font(Theme.numeric(10))
                .foregroundStyle(muted ? Theme.textTertiary : Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(WellBackground(cornerRadius: 4))

            if source.isStereo {
                // Nothing to pan: the pair already carries its own image.
                Text("STEREO")
                    .font(Theme.label(7, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(height: 16)
            } else {
                PanSlider(pan: $settings.pan)
                    .frame(height: 16)
            }

            Button { settings.muted.toggle() } label: {
                Text("MUTE")
                    .font(Theme.label(8, weight: .bold))
                    .tracking(0.5)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(ToggleChipStyle(isOn: muted, tint: Theme.danger))

            VStack(spacing: 3) {
                Text("SEND")
                    .font(Theme.label(7, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.textTertiary)
                HStack(spacing: 3) {
                    ForEach(0..<min(settings.sends.count, pairLabels.count), id: \.self) { pair in
                        Button { settings.sends[pair].toggle() } label: {
                            Text(pairLabels[pair])
                                .font(Theme.numeric(8, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(ToggleChipStyle(isOn: settings.sends[pair], tint: Theme.accent))
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(width: 78)
        .background(PanelBackground())
    }

    /// When a source is blocked, the subtitle says why instead of repeating the
    /// device name. Signal on a pre-fader meter that goes nowhere is the single
    /// most confusing state this app can be in.
    private var blockedReason: String? {
        if settings.muted { return "MUTED" }
        if settings.gainDB <= LevelMath.silenceDB { return "FADER DOWN" }
        if !settings.sends.contains(true) { return "NO SEND" }
        return nil
    }

    private var header: some View {
        VStack(spacing: 1) {
            Text(source.name)
                .font(Theme.label(11, weight: .bold))
                .foregroundStyle(isPassing ? Theme.textPrimary : Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(blockedReason ?? source.detail)
                .font(Theme.label(7, weight: blockedReason == nil ? .medium : .bold))
                .tracking(blockedReason == nil ? 0 : 0.5)
                .foregroundStyle(blockedReason == nil ? Theme.textTertiary : Theme.meterAmber)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(height: 24)
    }
}

/// Horizontal pan control with a centre detent. Snaps to centre within a few
/// percent, because "almost centred" is never what anyone means.
struct PanSlider: View {
    @Binding var pan: Float

    private static let detent: Float = 0.06

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let midX = width / 2
            let knobX = midX + CGFloat(pan) * (width / 2 - 5)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.well)
                    .frame(height: 4)
                    .overlay(Capsule().strokeBorder(.black.opacity(0.55), lineWidth: 1))

                // Fill from centre toward the knob.
                Capsule()
                    .fill(Theme.accent.opacity(0.65))
                    .frame(width: abs(knobX - midX), height: 4)
                    .offset(x: min(knobX, midX))

                Rectangle()
                    .fill(Theme.textTertiary.opacity(0.7))
                    .frame(width: 1, height: 8)
                    .offset(x: midX - 0.5)

                Circle()
                    .fill(
                        LinearGradient(colors: [Color(white: 0.85), Color(white: 0.62)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(x: knobX - 5)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let raw = Float((value.location.x - midX) / (width / 2 - 5))
                        let clamped = min(max(raw, -1), 1)
                        pan = abs(clamped) < Self.detent ? 0 : clamped
                    }
            )
            .onTapGesture(count: 2) { pan = 0 }
        }
        .accessibilityElement()
        .accessibilityLabel("Pan")
        .accessibilityValue(panDescription)
    }

    private var panDescription: String {
        if pan == 0 { return "centre" }
        return "\(pan < 0 ? "left" : "right") \(Int(abs(pan) * 100)) percent"
    }
}
