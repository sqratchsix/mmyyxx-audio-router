import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    /// Margin around everything in the window.
    private static let contentInset: CGFloat = 14

    /// Width the strip row has to divide up, taken from the window.
    @State private var rowWidth: CGFloat = 0
    /// Height the content wants, which is the height the window is given.
    @State private var contentHeight: CGFloat = 0
    /// The pinned footer's height. It sits outside the scrolling content, so it
    /// has to be measured separately or the window comes up a footer short.
    @State private var footerHeight: CGFloat = 0
    /// The window this view is in, so the fit button can resize it.
    @State private var window: NSWindow?
    /// Height of the title bar, so the scrim under it can match. Read from the
    /// window, since the value is AppKit's rather than the layout's.
    @State private var titleBarHeight: CGFloat = 28
    /// Whether the launch-time fit has run. macOS restores the frame the window
    /// had last time, which is usually the wrong height for what is in it now.
    @State private var hasFittedOnLaunch = false

    var body: some View {
        // The scroll view insets its content for the title bar twice over: once
        // as safe area, once as its own automatic content inset. Dropping the
        // safe area leaves exactly one, so the header sits under the title bar
        // instead of a band of empty window.
        // Vertical only. The window cannot be narrower than the rack's minimum,
        // so there is never anything to scroll to sideways — and a horizontal
        // scroll view sizes its content to the content's own width, which left
        // the layout sitting in the middle of a widened window instead of
        // growing into it.
        ScrollView(.vertical) {
            content
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: ContentHeightKey.self,
                                               value: geometry.size.height)
                    }
                )
        }
        // The scroll view keeps the title bar's safe area, so neither the
        // content nor its scroller ever runs underneath it.
        .contentMargins(.top, 0, for: .scrollContent)
        // Pinned rather than scrolled: the engine's state is the one thing that
        // should be readable without going looking for it.
        .safeAreaInset(edge: .bottom, spacing: 0) { footerBar }
        // The title bar is glass and content passes behind it, so it gets the
        // same scrim the footer has.
        .overlay(alignment: .top) {
            BarBackground()
                .frame(height: titleBarHeight)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
        .onPreferenceChange(ContentHeightKey.self) {
            contentHeight = $0
            fitOnLaunch()
        }
        // Height follows the content rather than the other way round, so the
        // window fits what is in it: hiding the analyser or adding a rack device
        // resizes the window instead of leaving dead space. Asking the scroll
        // view itself to size to its content collapses it to nothing, hence the
        // measurement. The cap keeps a tall rack from pushing the window off
        // the screen, and the scroll view takes over from there.
        // Width is stated as a range and height as a value, which is what
        // `.contentSize` resizability reads to decide what the window can do:
        // drag the sides, but never end up with dead space below the rack.
        // Width is the rack's, and fixed: nothing in the mixer wants to be
        // wider than a 19-inch rack. Height is free above a floor, and opens at
        // whatever the content measured, so the window still fits its contents
        // the first time it is shown.
        .frame(width: Rack.minimumWidth + 28)
        .frame(minHeight: 420, idealHeight: fittedHeight, maxHeight: .infinity)
        // Measured out here rather than on the strip row itself: the row's width
        // is derived from this number, so measuring the row would be circular
        // and could never settle after the window narrowed.
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: RowWidthKey.self, value: geometry.size.width)
            }
        )
        .onPreferenceChange(RowWidthKey.self) { rowWidth = max($0 - Self.contentInset * 2, 0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: fitWindowToContent) {
                    Image(systemName: "rectangle.compress.vertical")
                }
                .help("Fit the window to its contents")
                .disabled(contentHeight <= 0)
            }
        }
        .background(WindowReader { resolved in
            guard let resolved else { return }
            if window !== resolved {
                window = resolved
                fitOnLaunch()
            }
            let chrome = resolved.frame.height - resolved.contentLayoutRect.height
            if chrome > 0, abs(chrome - titleBarHeight) > 0.5 { titleBarHeight = chrome }
            // Adding a toolbar puts an opaque backing behind the window again,
            // which leaves the glass with nothing to see through. Set both
            // unconditionally: the window can be non-opaque and still be
            // painting an opaque background colour, which looks the same.
            resolved.isOpaque = false
            resolved.backgroundColor = .clear
        })

        .background(GlassBackground().ignoresSafeArea())
        .onAppear { model.onAppear() }
    }

    /// Everything the window has to hold: the scrolling mix plus the bar
    /// pinned under it.
    private var wantedHeight: CGFloat { contentHeight + footerHeight }

    /// What the window should be, once the content has been measured. Nil until
    /// then, so the first layout pass is free to settle at its natural size.
    private var fittedHeight: CGFloat? {
        guard contentHeight > 0 else { return nil }
        let room = (NSScreen.main?.visibleFrame.height ?? 900) - 48
        return min(wantedHeight, room)
    }

    /// Fit once at launch, as soon as there is both a window and a measurement.
    ///
    /// Then once more a moment later: device discovery and the engine starting
    /// both change what is on screen just after the first layout, and the
    /// window should end up around the finished contents, not the first draft.
    private func fitOnLaunch() {
        guard !hasFittedOnLaunch, window != nil, contentHeight > 0 else { return }
        hasFittedOnLaunch = true
        fitWindowToContent()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { fitWindowToContent() }
    }

    /// Trim the window to exactly what is in it, keeping the top edge where it
    /// is so the window appears to grow and shrink from the bottom.
    ///
    /// Works from `contentLayoutRect` rather than the frame, so it does not have
    /// to know how tall the title bar is or whether the content runs under it.
    private func fitWindowToContent() {
        guard let window, contentHeight > 0 else { return }
        let wanted = wantedHeight
        let room = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? contentHeight
        let chrome = window.frame.height - window.contentLayoutRect.height
        let target = min(wanted, room - chrome)
        let delta = target - window.contentLayoutRect.height
        guard abs(delta) > 0.5 else { return }

        var frame = window.frame
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: true)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceBar
            statusCard

            if model.spectrumSettings.isVisible {
                SpectrumView()
            } else {
                showAnalyserBar
            }

            stripRow
                .opacity(model.isRunning ? 1 : 0.45)
                .disabled(!model.isRunning)

            RackView()
                .opacity(model.isRunning ? 1 : 0.45)
                .disabled(!model.isRunning)
        }
        .padding(Self.contentInset)
        .frame(minWidth: Rack.minimumWidth, maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sections

    /// Every strip in one row, with the sections divided proportionally: an
    /// output strip carries a dB scale and a stereo meter, a source strip
    /// carries neither, so sources are drawn narrower. The row takes the full
    /// width and hands each strip an exact width, which is what keeps its edges
    /// on the analyser's and the rack's.
    private var stripRow: some View {
        let width = stripWidths
        return HStack(alignment: .top, spacing: Strip.gap) {
            // The settings binding is bounds-checked, so no guard is needed
            // here even while the source list is being rebuilt.
            ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, source in
                column(label: index == 0 ? "SOURCES" : nil) {
                    SourceStrip(
                        source: source,
                        meters: model.meterModel,
                        meterIndex: index,
                        width: width.source,
                        settings: model.sourceBinding(index),
                        pairLabels: model.pairChannels,
                        externalTravel: model.isSystemStrip(source) ? model.systemVolumeTravel : nil,
                        externalReadout: model.isSystemStrip(source) ? model.systemVolumeReadout : nil,
                        externalIsSilent: model.isSystemStrip(source) && model.systemVolume <= 0.0001
                    )
                }
            }

            Rectangle()
                .fill(Theme.hairline)
                .frame(width: Strip.separatorWidth)
                .padding(.vertical, 18)

            ForEach(0..<SharedState.pairCount, id: \.self) { pair in
                column(label: pair == 0 ? "OUTPUTS" : nil) {
                    ChannelStrip(
                        title: model.pairNames[pair],
                        channels: model.pairChannels[pair],
                        meters: model.meterModel,
                        pair: pair,
                        width: width.output,
                        settings: model.pairBinding(pair)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One strip with its section label above it. The label is an overlay so a
    /// long one cannot widen the column it names.
    private func column<Content: View>(label: String?,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .frame(height: 10)
                .overlay(alignment: .leading) {
                    if let label { sectionLabel(label) }
                }
            content()
        }
    }

    /// Split the row between the two sections, keeping sources at a fixed
    /// fraction of an output's width. Falls back to the minimums until the
    /// first layout pass has reported a width.
    private var stripWidths: (source: CGFloat, output: CGFloat) {
        let sources = CGFloat(model.sources.count)
        let outputs = CGFloat(SharedState.pairCount)
        // One gap per item, since the separator is an item of its own; that is
        // what makes the join read as a double gap.
        let gaps = (sources + outputs) * Strip.gap + Strip.separatorWidth
        let available = rowWidth - gaps
        let units = sources * Strip.sourceRatio + outputs
        guard units > 0, available > 0 else {
            return (Strip.minimumSourceWidth, Strip.minimumOutputWidth)
        }
        let output = available / units
        return (max((output * Strip.sourceRatio).rounded(.down), Strip.minimumSourceWidth),
                max(output.rounded(.down), Strip.minimumOutputWidth))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.label(8, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Theme.textSecondary)
            .padding(.leading, 2)
    }

    // MARK: - Chrome

    /// The interface this app drives, and the app's own settings menu.
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
            Toggle("Hold outputs silent until audio plays", isOn: $model.safetyMuteEnabled)
            Toggle("Show spectrum analyser", isOn: $model.spectrumSettings.isVisible)
            Divider()
            Button("Rescan devices") { model.refreshDevices() }
            Button("Reset mix to defaults") { model.resetSettings() }
            Button("Reveal settings file") {
                NSWorkspace.shared.activateFileViewerSelecting([model.settingsLocation])
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "hifispeaker.2.fill").font(.system(size: 9))
                Text(model.selectedOutput?.name ?? "No device")
                    .font(Theme.label(10, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
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

            safetyPill
            systemOutputPicker

            // Where macOS sends audio, then where this app sends it. The rule
            // keeps the two from reading as one control.
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1, height: 16)

            devicePicker
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(WellBackground(cornerRadius: 7))
    }

    /// The macOS sound output, chosen here rather than in System Settings.
    /// This is the same default-output device the Sound menu sets, so whatever
    /// is picked is what every other app follows too.
    private var systemOutputPicker: some View {
        Menu {
            if let loopback = model.loopback {
                Button {
                    model.routeSystemAudioToLoopback()
                } label: {
                    Label("\(loopback.name)  ·  into this mixer",
                          systemImage: model.systemAudioIsRouted ? "checkmark" : "arrow.triangle.branch")
                }
                Divider()
            }
            ForEach(model.systemOutputCandidates.filter { $0.uid != model.loopback?.uid }) { device in
                Button {
                    model.setSystemOutput(device)
                } label: {
                    if device.uid == model.systemOutput?.uid {
                        Label("\(device.name) · \(device.outputChannels) out", systemImage: "checkmark")
                    } else {
                        Text("\(device.name) · \(device.outputChannels) out")
                    }
                }
            }
            Divider()
            Button("Rescan devices") { model.refreshDevices() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 9))
                Text(model.systemOutput?.name ?? "Unknown")
                    .font(Theme.label(10, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where macOS sends system audio")
    }

    /// Shown only while the engine is holding the outputs down, so the silence
    /// after an interface reconnects is explained rather than mysterious. It sits
    /// beside the device picker as a pill rather than a full-width bar: the state
    /// is transient, and a banner that wide reads as an error the user has to fix.
    /// Clicking it opens the outputs, which is what the old "Open now" button did.
    @ViewBuilder
    private var safetyPill: some View {
        if model.isSafetyMuted {
            Button { model.releaseSafetyMute() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "speaker.slash.fill").font(.system(size: 9))
                    Text("Held silent")
                        .font(Theme.label(10, weight: .semibold))
                }
                .foregroundStyle(Theme.meterAmber)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Theme.meterAmber.opacity(0.12))
                )
                .overlay(
                    Capsule().strokeBorder(Theme.meterAmber.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Waiting for system audio before opening the outputs, so a reconnected "
                + "interface cannot ring the room. Click to open them now.")
            .transition(.opacity)
        }
    }

    private var showAnalyserBar: some View {
        HStack(spacing: 6) {
            Button {
                model.spectrumSettings.isVisible = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "waveform").font(.system(size: 10))
                    Text("Show spectrum analyser")
                        .font(Theme.label(10, weight: .semibold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
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

    private var footerBar: some View {
        footer
            .padding(.horizontal, Self.contentInset)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BarBackground())
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: FooterHeightKey.self, value: geometry.size.height)
                }
            )
            .onPreferenceChange(FooterHeightKey.self) { footerHeight = $0 }
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

/// Hands back the `NSWindow` the view ends up in. SwiftUI has no environment
/// value for it on macOS, and resizing a window is an AppKit job.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(view.window) }
    }
}

/// Carries the pinned footer's height up, so the fit can allow for it.
private struct FooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Carries the content's measured height back up so the window can match it.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Carries the strip row's measured width back up so it can be divided.
private struct RowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
    /// Margin around everything in the window.
    private static let contentInset: CGFloat = 14

    /// Width the strip row has to divide up, taken from the window.
    @State private var rowWidth: CGFloat = 0
    /// Height the content wants, which is the height the window is given.
    @State private var contentHeight: CGFloat = 0
    /// The pinned footer's height. It sits outside the scrolling content, so it
    /// has to be measured separately or the window comes up a footer short.
    @State private var footerHeight: CGFloat = 0
    /// The window this view is in, so the fit button can resize it.
    @State private var window: NSWindow?
    /// Height of the title bar, so the scrim under it can match. Read from the
    /// window, since the value is AppKit's rather than the layout's.
    @State private var titleBarHeight: CGFloat = 28
    /// Whether the launch-time fit has run. macOS restores the frame the window
    /// had last time, which is usually the wrong height for what is in it now.
    @State private var hasFittedOnLaunch = false
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
