import SwiftUI

/// An output pair's master strip: post-fader stereo meter, master level, mute.
struct ChannelStrip: View {
    let title: String
    let channels: String
    let meters: MeterModel
    let pair: Int
    @Binding var settings: PairSettings

    private var muted: Bool { settings.muted }

    var body: some View {
        VStack(spacing: 8) {
            header

            HStack(alignment: .center, spacing: 6) {
                OutputMeterPair(meters: meters, pair: pair)
                Fader(position: $settings.gainDB.faderTravel)
            }
            .frame(height: 172)

            Text(LevelMath.format(dB: settings.gainDB))
                .font(Theme.numeric(11))
                .foregroundStyle(muted ? Theme.textTertiary : Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(WellBackground(cornerRadius: 4))
                .overlay(alignment: .trailing) {
                    Text("dB")
                        .font(Theme.label(7))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.trailing, 5)
                }

            ClipIndicator(meters: meters, pair: pair)

            VStack(spacing: 4) {
                MiniSlider(label: "FX SEND", value: $settings.fxSend, tint: Rack.sendTint, trackWidth: 88)
                MiniSlider(label: "FX RET", value: $settings.fxReturn, tint: Theme.meterGreen, trackWidth: 88)
            }

            Button { settings.muted.toggle() } label: {
                Text("MUTE")
                    .font(Theme.label(8, weight: .bold))
                    .tracking(0.5)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(ToggleChipStyle(isOn: muted, tint: Theme.danger))

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(width: 104)
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
        .frame(height: 24)
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
