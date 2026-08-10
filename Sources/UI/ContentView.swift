import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            header
            sourceBar
            statusCard

            HStack(alignment: .top, spacing: 14) {
                sourceSection
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                    .padding(.vertical, 18)
                outputSection
            }
            .opacity(model.isRunning ? 1 : 0.45)
            .disabled(!model.isRunning)

            RackView()
                .opacity(model.isRunning ? 1 : 0.45)
                .disabled(!model.isRunning)

            footer
        }
        .padding(14)
        .frame(minHeight: 470)
        .background(
            LinearGradient(colors: [Theme.windowTop, Theme.windowBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .onAppear { model.onAppear() }
    }

    // MARK: - Sections

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("SOURCES")
            HStack(alignment: .top, spacing: 7) {
                ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, source in
                    // SwiftUI can render between the source list and the meter
                    // array being resized, so both still need a bounds check.
                    if index < model.sourceSettings.count {
                        SourceStrip(
                            source: source,
                            meters: model.meterModel,
                            meterIndex: index,
                            settings: $model.sourceSettings[index],
                            pairLabels: model.pairChannels,
                            externalTravel: model.isSystemStrip(source) ? model.systemVolumeTravel : nil,
                            externalReadout: model.isSystemStrip(source) ? model.systemVolumeReadout : nil,
                            externalIsSilent: model.isSystemStrip(source) && model.systemVolume <= 0.0001
                        )
                    }
                }
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("OUTPUTS")
            HStack(alignment: .top, spacing: 7) {
                ForEach(0..<SharedState.pairCount, id: \.self) { pair in
                    if pair < model.pairSettings.count {
                        ChannelStrip(
                            title: model.pairNames[pair],
                            channels: model.pairChannels[pair],
                            meters: model.meterModel,
                            pair: pair,
                            settings: $model.pairSettings[pair]
                        )
                    }
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.label(8, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 2)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("mmyyxx")
                    .font(Theme.label(17, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Every input, every output pair")
                    .font(Theme.label(10))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            devicePicker
        }
    }

    private var devicePicker: some View {
        Menu {
            ForEach(model.outputCandidates) { device in
                Button {
                    model.selectedOutputUID = device.uid
                } label: {
                    if device.uid == model.selectedOutputUID {
                        Label("\(device.name) · \(device.outputChannels) out", systemImage: "checkmark")
                    } else {
                        Text("\(device.name) · \(device.outputChannels) out")
                    }
                }
            }
            Divider()
            Button("Rescan devices") { model.refreshDevices() }
            Button("Reset mix to defaults") { model.resetSettings() }
            Button("Reveal settings file") {
                NSWorkspace.shared.activateFileViewerSelecting([model.settingsLocation])
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "hifispeaker.2.fill").font(.system(size: 10))
                Text(model.selectedOutput?.name ?? "No device")
                    .font(Theme.label(11, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var sourceBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.systemAudioIsRouted ? Theme.meterGreen : Theme.meterAmber)
                .frame(width: 7, height: 7)
                .shadow(color: (model.systemAudioIsRouted ? Theme.meterGreen : Theme.meterAmber).opacity(0.7),
                        radius: 4)

            Text(model.systemAudioIsRouted
                 ? "System audio → \(model.loopback?.name ?? "loopback")"
                 : "System audio is going somewhere else")
                .font(Theme.label(11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            Spacer()

            if !model.systemAudioIsRouted, model.loopback != nil {
                Button("Route here") { model.routeSystemAudioToLoopback() }
                    .buttonStyle(.plain)
                    .font(Theme.label(10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(WellBackground(cornerRadius: 7))
    }

    @ViewBuilder
    private var statusCard: some View {
        switch model.readiness {
        case .noLoopbackDevice:
            LoopbackSetupCard()
        case .engineFailed(let message):
            MessageCard(icon: "exclamationmark.triangle.fill",
                        tint: Theme.danger,
                        title: "Engine stopped",
                        message: message,
                        actionTitle: "Retry") { model.restartEngine() }
        case .noOutputDevice:
            MessageCard(icon: "hifispeaker.and.homepod.fill",
                        tint: Theme.textSecondary,
                        title: "No multi-output interface",
                        message: "Connect an interface with at least four output channels.",
                        actionTitle: "Rescan") { model.refreshDevices() }
        case .ready:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            statusChip(model.isRunning ? "RUNNING" : "IDLE",
                       tint: model.isRunning ? Theme.meterGreen : Theme.textTertiary)
            if model.sampleRate > 0 {
                Text(String(format: "%.1f kHz", model.sampleRate / 1000))
                Text("·")
                Text("\(model.bufferFrames) frames")
                Text("·")
                Text(String(format: "%.1f ms", Double(model.bufferFrames) / model.sampleRate * 1000))
                Text("·")
                Text("\(model.sources.count) sources")
            }
            Spacer()
        }
        .font(Theme.numeric(9, weight: .medium))
        .foregroundStyle(Theme.textTertiary)
    }

    private func statusChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Theme.label(8, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(0.14))
            )
    }
}

// MARK: - Cards

struct MessageCard: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.label(12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(Theme.label(10))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(Theme.label(10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(11)
        .background(PanelBackground(cornerRadius: 8))
    }
}

/// Shown when no loopback device is installed, since the app cannot see system
/// audio without one.
struct LoopbackSetupCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var copied = false

    private let command = "brew install --cask blackhole-2ch"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.meterAmber)
                Text("Loopback driver required")
                    .font(Theme.label(12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            Text("macOS will not hand an app its own system audio. BlackHole provides a virtual output that this app reads from. Install it, then relaunch.")
                .font(Theme.label(10))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WellBackground(cornerRadius: 5))

                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                }
                .buttonStyle(.plain)
                .font(Theme.label(10, weight: .semibold))
                .foregroundStyle(Theme.accent)

                Button("Rescan") { model.refreshDevices(); model.restartEngine() }
                    .buttonStyle(.plain)
                    .font(Theme.label(10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(11)
        .background(PanelBackground(cornerRadius: 8))
    }
}
