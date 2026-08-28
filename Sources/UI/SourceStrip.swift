import SwiftUI

/// An input channel strip: pre-fader meter, level, pan, mute, and a send button
/// per output pair.
struct SourceStrip: View {
    let source: MixerSource
    /// Plain `let`, not `@ObservedObject`: only the meter leaf subscribes.
    let meters: MeterModel
    let meterIndex: Int
    /// Set by the row, which divides the available width between the sections.
    let width: CGFloat
    @Binding var settings: SourceSettings
    let pairLabels: [String]
    /// When set, this strip's fader drives an external control instead of the
    /// app's own gain. Used by the System strip, whose level *is* the macOS
    /// system volume rather than a second gain stage behind it.
    var externalTravel: Binding<CGFloat>?
    var externalReadout: String?
    var externalIsSilent = false

    private var muted: Bool { settings.muted }

    private var trackWidth: CGFloat { width - Strip.horizontalPadding * 2 }

    /// Whether this source actually reaches an output right now. All three of
    /// these block it, and each one is easy to leave set by accident.
    private var isPassing: Bool {
        guard !settings.muted, settings.sends.contains(true) else { return false }
        return externalTravel == nil ? settings.gainDB > LevelMath.silenceDB : !externalIsSilent
    }

    var body: some View {
        VStack(spacing: 8) {
            header

            HStack(alignment: .center, spacing: 5) {
                SourceMeterPair(meters: meters, index: meterIndex,
                                isStereo: source.isStereo, isPassing: isPassing)
                if let externalTravel {
                    Fader(position: externalTravel, resetPosition: 1, unityMark: nil)
                } else {
                    Fader(position: $settings.gainDB.faderTravel)
                }
            }
            .frame(height: Strip.faderHeight)

            Text(externalReadout ?? LevelMath.format(dB: settings.gainDB))
                .font(Theme.numeric(10))
                .foregroundStyle(muted ? Theme.textTertiary : Theme.textPrimary)
                .frame(maxWidth: .infinity,
                       minHeight: Strip.readoutHeight, maxHeight: Strip.readoutHeight)
                .background(WellBackground(cornerRadius: 4))

            if source.isStereo {
                // Nothing to pan: the pair already carries its own image.
                Text("STEREO")
                    .font(Theme.label(7, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(height: Strip.utilityRowHeight)
            } else {
                PanSlider(pan: $settings.pan)
                    .frame(height: Strip.utilityRowHeight)
            }

            Button { settings.muted.toggle() } label: {
                Text("MUTE")
                    .font(Theme.label(8, weight: .bold))
                    .tracking(0.5)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(ToggleChipStyle(isOn: muted, tint: Theme.danger))

            StripKnob(label: "FX", value: $settings.fxSend, tint: Rack.sendTint)

            // Directly under the send knob, which puts it on the same line as
            // the output strips' SPEC button: both strips carry the same rows
            // above this one, so neither has to be padded to agree with the
            // other. The heading is gone with the spacer; the pair numbers and
            // the tooltip say what these are.
            HStack(spacing: 3) {
                ForEach(0..<min(settings.sends.count, pairLabels.count), id: \.self) { pair in
                    Button { settings.sends[pair].toggle() } label: {
                        Text(pairLabels[pair])
                            .font(Theme.numeric(8, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(ToggleChipStyle(isOn: settings.sends[pair], tint: Theme.accent))
                    .help("Send this source to \(pairLabels[pair])")
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, Strip.horizontalPadding)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PanelBackground())
    }

    /// When a source is blocked, the subtitle says why instead of repeating the
    /// device name. Signal on a pre-fader meter that goes nowhere is the single
    /// most confusing state this app can be in.
    private var blockedReason: String? {
        if settings.muted { return "MUTED" }
        if externalTravel == nil, settings.gainDB <= LevelMath.silenceDB { return "FADER DOWN" }
        if externalTravel != nil, externalIsSilent { return "VOLUME AT ZERO" }
        if !settings.sends.contains(true) { return "NO SEND" }
        return nil
    }

    /// Device on top, channel name below, in the same two sizes the output
    /// strips use. That puts every channel name in the row on one line.
    private var header: some View {
        VStack(spacing: 1) {
            Text(blockedReason ?? source.detail)
                .font(Theme.label(8, weight: blockedReason == nil ? .semibold : .bold))
                .tracking(blockedReason == nil ? 0.9 : 0.5)
                .foregroundStyle(blockedReason == nil ? Theme.textSecondary : Theme.meterAmber)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(source.name)
                .font(Theme.label(13, weight: .bold))
                .foregroundStyle(isPassing ? Theme.textPrimary : Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(height: Strip.headerHeight)
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
