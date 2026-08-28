import SwiftUI

/// An output pair's master strip: post-fader stereo meter, master level, mute.
struct ChannelStrip: View {
    let title: String
    let channels: String
    let meters: MeterModel
    let pair: Int
    /// Set by the row, which divides the available width between the sections.
    let width: CGFloat
    @Binding var settings: PairSettings

    private var muted: Bool { settings.muted }

    private var trackWidth: CGFloat { width - Strip.horizontalPadding * 2 }

    var body: some View {
        VStack(spacing: 8) {
            header

            HStack(alignment: .center, spacing: 6) {
                OutputMeterPair(meters: meters, pair: pair)
                Fader(position: $settings.gainDB.faderTravel)
            }
            .frame(height: Strip.faderHeight)

            Text(LevelMath.format(dB: settings.gainDB))
                .font(Theme.numeric(11))
                .foregroundStyle(muted ? Theme.textTertiary : Theme.textPrimary)
                .frame(maxWidth: .infinity,
                       minHeight: Strip.readoutHeight, maxHeight: Strip.readoutHeight)
                .background(WellBackground(cornerRadius: 4))
                .overlay(alignment: .trailing) {
                    Text("dB")
                        .font(Theme.label(7))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.trailing, 5)
                }

            ClipIndicator(meters: meters, pair: pair)
                .frame(height: Strip.utilityRowHeight)

            Button { settings.muted.toggle() } label: {
                Text("MUTE")
                    .font(Theme.label(8, weight: .bold))
                    .tracking(0.5)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(ToggleChipStyle(isOn: muted, tint: Theme.danger))

            HStack(spacing: 2) {
                StripKnob(label: "SEND", value: $settings.fxSend, tint: Rack.sendTint)
                StripKnob(label: "RET", value: $settings.fxReturn,
                          tint: Theme.meterGreen, resetValue: 1)
                // Down with the send up, the rack stops being a parallel effect
                // and becomes an insert on this output, which is what an EQ in
                // the chain wants.
                StripKnob(label: "DRY", value: $settings.fxDry,
                          tint: Theme.accent, resetValue: 1)
            }

            // Feeds this pair's post-fader bus to the analyser above the
            // sources. Independent of mute: a muted pair has nothing to show.
            Button { settings.toSpectrum.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "waveform").font(.system(size: 7, weight: .bold))
                    Text("SPEC")
                        .font(Theme.label(8, weight: .bold))
                        .tracking(0.5)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(ToggleChipStyle(isOn: settings.toSpectrum, tint: Theme.accent))
            .help("Send this pair to the spectrum analyser")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, Strip.horizontalPadding)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PanelBackground())
    }

    private var header: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(Theme.label(8, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Theme.textSecondary)
            Text(channels)
                .font(Theme.numeric(13, weight: .bold))
                .foregroundStyle(muted ? Theme.textTertiary : Theme.textPrimary)
        }
        .frame(height: Strip.headerHeight)
    }

}

struct ToggleChipStyle: ButtonStyle {
    let isOn: Bool
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? Color.white : Theme.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn ? tint : Theme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isOn ? tint.opacity(0.9) : Theme.hairline, lineWidth: 1)
            )
            .shadow(color: isOn ? tint.opacity(0.4) : .clear, radius: 4)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: isOn)
    }
}
