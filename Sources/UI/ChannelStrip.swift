import SwiftUI

/// An output pair's master strip: post-fader stereo meter, master level, mute.
struct ChannelStrip: View {
    let title: String
    let channels: String
    let leftMeter: MeterBallistics
    let rightMeter: MeterBallistics
    @Binding var settings: PairSettings

    private var muted: Bool { settings.muted }

    private var isClipping: Bool {
        leftMeter.holdDB >= -0.1 || rightMeter.holdDB >= -0.1
    }

    var body: some View {
        VStack(spacing: 8) {
            header

            HStack(alignment: .center, spacing: 6) {
                MeterScale()
                HStack(spacing: 3) {
                    LevelMeter(displayDB: leftMeter.displayDB, holdDB: leftMeter.holdDB)
                    LevelMeter(displayDB: rightMeter.displayDB, holdDB: rightMeter.holdDB)
                }
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

            clipIndicator

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

    private var clipIndicator: some View {
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
            .animation(.easeOut(duration: 0.12), value: isClipping)
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
