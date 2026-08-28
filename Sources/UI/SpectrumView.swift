import SwiftUI

/// Real-time spectrum of whatever the output pairs are sending it.
///
/// The panel splits into a chrome half that only changes when a control moves,
/// and a `SpectrumCanvas` leaf that redraws every frame. Nothing above the leaf
/// observes the analyser, for the same reason nothing above a meter observes
/// `MeterModel`.
struct SpectrumView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSettings = false

    private var settings: SpectrumSettings { model.spectrumSettings }

    /// The folded trace: one line, no furniture. At 22 points tall a grid, the
    /// labels and the peak holds are noise rather than information.
    private var sparkSettings: SpectrumSettings {
        var copy = settings
        copy.showGrid = false
        copy.showLabels = false
        copy.showPeaks = false
        copy.style = .line
        copy.bandCount = min(settings.bandCount, 48)
        copy.glow = min(settings.glow, 0.4)
        return copy
    }

    var body: some View {
        VStack(spacing: 6) {
            header
            if !settings.isCollapsed {
                SpectrumCanvas(analyzer: model.spectrum, settings: settings)
                    .frame(height: settings.height)
                    .background(WellBackground(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(9)
        .background(PanelBackground(cornerRadius: 9))
        .opacity(model.isRunning ? 1 : 0.5)
        .animation(.easeOut(duration: 0.16), value: settings.isCollapsed)
    }

    /// Double-clicking anywhere on it that is not a control folds the trace
    /// away, the way the rack devices fold. The buttons keep their own clicks,
    /// so only the bare strip and the title respond.
    private var header: some View {
        HStack(spacing: 8) {
            Text("SPECTRUM")
                .font(Theme.label(8, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.textTertiary)
                .help("Double-click to fold the analyser away")

            // The same routing the SPEC buttons on the output strips drive,
            // repeated here so the analyser always says what it is looking at.
            HStack(spacing: 3) {
                ForEach(0..<SharedState.pairCount, id: \.self) { pair in
                    let binding = model.pairBinding(pair)
                    Button {
                        binding.wrappedValue.toSpectrum.toggle()
                    } label: {
                        Text(model.pairNames[pair])
                            .font(Theme.label(7, weight: .bold))
                            .tracking(0.5)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(ToggleChipStyle(isOn: binding.wrappedValue.toSpectrum,
                                                 tint: Theme.accent))
                }
            }

            if !model.pairSettings.contains(where: { $0.toSpectrum }) {
                Text("nothing routed here")
                    .font(Theme.label(9))
                    .foregroundStyle(Theme.meterAmber)
            }

            // Folded, the header is the whole panel, so the trace comes with
            // it: a line across whatever width the controls leave, which is
            // enough to see that something is playing and roughly where it
            // sits. Unfolded, this space is just a gap.
            if settings.isCollapsed {
                SpectrumCanvas(analyzer: model.spectrum, settings: sparkSettings)
                    .frame(height: 22)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 2)
            } else {
                Spacer(minLength: 4)
            }

            SpectrumReadout(analyzer: model.spectrum, floorDB: settings.floorDB)

            Button { showingSettings.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(showingSettings ? Theme.accent : Theme.textSecondary)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.panelRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                SpectrumSettingsView(settings: $model.spectrumSettings)
            }

            Button { model.spectrumSettings.isCollapsed.toggle() } label: {
                Image(systemName: settings.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help(settings.isCollapsed ? "Show the trace" : "Fold the trace away")

            Button { model.spectrumSettings.isVisible = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Hide the analyser")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.spectrumSettings.isCollapsed.toggle() }
    }
}

/// Loudest band, as a number. Its own view so the header above it is not
/// rebuilt sixty times a second.
struct SpectrumReadout: View {
    @ObservedObject var analyzer: SpectrumAnalyzer
    let floorDB: Float

    var body: some View {
        HStack(spacing: 6) {
            Text(analyzer.isLive ? SpectrumCanvas.frequencyLabel(analyzer.peakFrequency) : "—")
                .font(Theme.numeric(9, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(analyzer.isLive ? String(format: "%.1f dB", analyzer.peakLevelDB) : "")
                .font(Theme.numeric(9))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(width: 92, alignment: .trailing)
    }
}

/// The analyser proper: grid, bands, peak holds, all in one `Canvas`.
struct SpectrumCanvas: View {
    @ObservedObject var analyzer: SpectrumAnalyzer
    let settings: SpectrumSettings
    /// Overrides the palette with a single colour. Used where the trace is
    /// drawn straight onto a panel rather than into a screen, and has to read as
    /// one engraved line rather than as a spectrum of its own.
    var tint: Color?

    /// Decade and half-decade lines, which is where anyone reading a spectrum
    /// expects the gridlines to be.
    private static let gridFrequencies: [Float] = [20, 50, 100, 200, 500, 1_000,
                                                   2_000, 5_000, 10_000, 20_000]

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let plot = CGRect(x: 0, y: 2,
                              width: size.width,
                              height: size.height - (settings.showLabels ? 12 : 4))
            if settings.showGrid { drawGrid(&context, plot: plot, full: size) }
            drawBands(&context, plot: plot)
        }
        .accessibilityElement()
        .accessibilityLabel("Spectrum analyser")
    }

    // MARK: - Geometry

    private func normalized(_ dB: Float) -> CGFloat {
        let span = max(settings.ceilingDB - settings.floorDB, 1)
        return CGFloat(min(max((dB - settings.floorDB) / span, 0), 1))
    }

    /// Log frequency to horizontal position, matching how the bands are spaced.
    private func position(ofHz hz: Float) -> CGFloat {
        let ratio = Double(settings.maxHz / settings.minHz)
        guard ratio > 1 else { return 0 }
        let value = log(Double(hz / settings.minHz)) / log(ratio)
        return CGFloat(min(max(value, 0), 1))
    }

    static func frequencyLabel(_ hz: Float) -> String {
        if hz < 1_000 { return "\(Int(hz.rounded()))" }
        let k = hz / 1_000
        return k < 10 ? String(format: "%.1fk", k) : "\(Int(k.rounded()))k"
    }

    // MARK: - Drawing

    private func drawGrid(_ context: inout GraphicsContext, plot: CGRect, full: CGSize) {
        let line = GraphicsContext.Shading.color(Color.white.opacity(0.055))

        for hz in Self.gridFrequencies where hz >= settings.minHz && hz <= settings.maxHz {
            let x = plot.minX + position(ofHz: hz) * plot.width
            context.fill(Path(CGRect(x: x, y: plot.minY, width: 1, height: plot.height)),
                         with: line)
            if settings.showLabels {
                context.draw(
                    Text(Self.frequencyLabel(hz))
                        .font(Theme.numeric(7, weight: .medium))
                        .foregroundStyle(Theme.textTertiary),
                    at: CGPoint(x: min(max(x, 10), full.width - 10), y: full.height - 5),
                    anchor: .center)
            }
        }

        // Horizontal lines every 12 dB down from the ceiling.
        var dB = settings.ceilingDB - 12
        while dB > settings.floorDB {
            let y = plot.maxY - normalized(dB) * plot.height
            context.fill(Path(CGRect(x: plot.minX, y: y, width: plot.width, height: 1)), with: line)
            if settings.showLabels {
                context.draw(
                    Text("\(Int(dB))")
                        .font(Theme.numeric(7))
                        .foregroundStyle(Theme.textTertiary.opacity(0.75)),
                    at: CGPoint(x: plot.maxX - 3, y: y - 5), anchor: .trailing)
            }
            dB -= 12
        }
    }

    private func drawBands(_ context: inout GraphicsContext, plot: CGRect) {
        let bands = analyzer.bands
        guard bands.count > 1, plot.width > 1, plot.height > 1 else { return }

        // Glow is the same geometry drawn once through a blur underneath the
        // real thing. Cheap, and it is what makes the panel look lit rather
        // than printed.
        if settings.glow > 0.01 {
            var glow = context
            glow.addFilter(.blur(radius: 7))
            glow.opacity = Double(settings.glow) * 0.85
            render(&glow, plot: plot, bands: bands, isGlow: true)
        }
        render(&context, plot: plot, bands: bands, isGlow: false)

        if settings.showPeaks { drawPeaks(&context, plot: plot) }
    }

    private func render(_ context: inout GraphicsContext, plot: CGRect,
                        bands: [Float], isGlow: Bool) {
        switch settings.style {
        case .bars, .columns, .mirror:
            drawColumns(&context, plot: plot, bands: bands, isGlow: isGlow)
        case .area, .line:
            drawCurve(&context, plot: plot, bands: bands, isGlow: isGlow)
        }
    }

    private func drawColumns(_ context: inout GraphicsContext, plot: CGRect,
                             bands: [Float], isGlow: Bool) {
        let slot = plot.width / CGFloat(bands.count)
        let width = max(1, slot * CGFloat(1 - settings.barGap))
        let inset = (slot - width) / 2
        let mirrored = settings.style == .mirror
        let baseline = mirrored ? plot.midY : plot.maxY

        for (index, dB) in bands.enumerated() {
            let level = normalized(dB)
            guard level > 0.002 else { continue }
            let position = Double(index) / Double(max(bands.count - 1, 1))
            let colour = tint ?? settings.palette.color(position: position)
            let x = plot.minX + CGFloat(index) * slot + inset
            let height = (mirrored ? plot.height / 2 : plot.height) * level

            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [colour.opacity(isGlow ? 0.9 : 1),
                                  colour.opacity(isGlow ? 0.5 : 0.45)]),
                startPoint: CGPoint(x: 0, y: baseline - height),
                endPoint: CGPoint(x: 0, y: baseline))

            if settings.style == .columns {
                // Segmented, the way a hardware analyser reads.
                let segmentHeight: CGFloat = 4
                var y = baseline - segmentHeight
                while y > baseline - height {
                    context.fill(Path(CGRect(x: x, y: y, width: width, height: 3)), with: shading)
                    y -= segmentHeight
                }
            } else {
                let radius = min(width / 2, 2.5)
                context.fill(Path(roundedRect: CGRect(x: x, y: baseline - height,
                                                      width: width, height: height),
                                  cornerRadius: radius, style: .continuous),
                             with: shading)
                if mirrored {
                    let reflection = CGRect(x: x, y: baseline, width: width, height: height)
                    context.opacity = 0.45
                    context.fill(Path(roundedRect: reflection, cornerRadius: radius,
                                      style: .continuous), with: shading)
                    context.opacity = 1
                }
            }
        }
    }

    private func drawCurve(_ context: inout GraphicsContext, plot: CGRect,
                           bands: [Float], isGlow: Bool) {
        let slot = plot.width / CGFloat(bands.count)
        var points: [CGPoint] = []
        points.reserveCapacity(bands.count)
        for (index, dB) in bands.enumerated() {
            let x = plot.minX + (CGFloat(index) + 0.5) * slot
            let y = plot.maxY - normalized(dB) * plot.height
            points.append(CGPoint(x: x, y: y))
        }

        // Midpoint quadratics: smooth without the overshoot a Catmull-Rom
        // spline gives on a spectrum's steep edges.
        var path = Path()
        path.move(to: CGPoint(x: plot.minX, y: points[0].y))
        path.addLine(to: points[0])
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
        }
        path.addLine(to: CGPoint(x: plot.maxX, y: points[points.count - 1].y))

        let stops = tint.map { [$0, $0] } ?? settings.palette.gradientStops
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: stops),
            startPoint: CGPoint(x: plot.minX, y: 0),
            endPoint: CGPoint(x: plot.maxX, y: 0))

        if settings.style == .area {
            var filled = path
            filled.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            filled.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
            filled.closeSubpath()
            context.opacity = isGlow ? 0.5 : 0.28
            context.fill(filled, with: shading)
            context.opacity = 1
        }

        context.stroke(path, with: shading,
                       style: StrokeStyle(lineWidth: isGlow ? 3 : 1.6,
                                          lineCap: .round, lineJoin: .round))
    }

    private func drawPeaks(_ context: inout GraphicsContext, plot: CGRect) {
        let peaks = analyzer.peaks
        guard peaks.count > 1 else { return }
        let slot = plot.width / CGFloat(peaks.count)
        let width = settings.style == .area || settings.style == .line
            ? slot
            : max(1, slot * CGFloat(1 - settings.barGap))
        let inset = (slot - width) / 2
        let mirrored = settings.style == .mirror

        for (index, dB) in peaks.enumerated() {
            let level = normalized(dB)
            guard level > 0.006 else { continue }
            let baseline = mirrored ? plot.midY : plot.maxY
            let height = (mirrored ? plot.height / 2 : plot.height) * level
            let y = baseline - height
            let x = plot.minX + CGFloat(index) * slot + inset
            let tint: Color = dB >= -1 ? Theme.meterRed : Color.white.opacity(0.82)
            context.fill(Path(CGRect(x: x, y: max(plot.minY, y - 1.5), width: width, height: 1.5)),
                         with: .color(tint))
            if mirrored {
                context.fill(Path(CGRect(x: x, y: min(plot.maxY - 1.5, baseline + height),
                                         width: width, height: 1.5)),
                             with: .color(tint.opacity(0.45)))
            }
        }
    }
}
