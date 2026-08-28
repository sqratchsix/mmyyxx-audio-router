import SwiftUI

enum Theme {
    static let windowTop = Color(red: 0.106, green: 0.118, blue: 0.137)
    static let windowBottom = Color(red: 0.055, green: 0.063, blue: 0.078)
    static let panel = Color(red: 0.129, green: 0.141, blue: 0.161)
    static let panelRaised = Color(red: 0.157, green: 0.172, blue: 0.196)
    static let well = Color(red: 0.035, green: 0.043, blue: 0.055)
    static let hairline = Color.white.opacity(0.07)
    static let textPrimary = Color(red: 0.910, green: 0.918, blue: 0.933)
    static let textSecondary = Color(red: 0.541, green: 0.565, blue: 0.600)
    static let textTertiary = Color(red: 0.361, green: 0.384, blue: 0.420)
    static let accent = Color(red: 0.353, green: 0.784, blue: 0.980)
    static let danger = Color(red: 1.0, green: 0.302, blue: 0.302)

    // Meter ramp, defined in dB and resolved to gradient stops by the meter view.
    static let meterGreen = Color(red: 0.239, green: 0.863, blue: 0.518)
    static let meterLime = Color(red: 0.659, green: 0.878, blue: 0.373)
    static let meterAmber = Color(red: 0.961, green: 0.773, blue: 0.259)
    static let meterRed = Color(red: 1.0, green: 0.302, blue: 0.302)

    static func label(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func numeric(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// Shared vertical rhythm for the source and output strips.
///
/// The two strips carry different controls below the fader, so left to
/// themselves their rows drift apart and the mute and send buttons sit at
/// slightly different heights. Pinning the shared rows here keeps a source strip
/// and an output strip reading as one instrument rather than two.
enum Strip {
    /// Meter-and-fader block. Identical in both strips. Kept a little short of
    /// a full console fader so the whole mixer, an open analyser and a 3U rack
    /// fit on a 1080-line screen without scrolling.
    static let faderHeight: CGFloat = 148
    /// Name and subtitle above the fader.
    static let headerHeight: CGFloat = 24
    /// Pan slider in a source, clip indicator in an output.
    static let utilityRowHeight: CGFloat = 16
    /// dB readout under the fader. The two strips set it in different sizes, so
    /// without a fixed height here the mute buttons below drift apart.
    static let readoutHeight: CGFloat = 20
    /// Gap between neighbouring strips within a section.
    static let gap: CGFloat = 15
    /// The separator between the sections sits in a gap of its own on each
    /// side, so the join reads as twice the spacing of a plain strip gap.
    static let separatorWidth: CGFloat = 1
    /// Inset inside a strip, and so the difference between a strip's width and
    /// the width its sliders are drawn to.
    static let horizontalPadding: CGFloat = 8
    /// A source strip's width as a fraction of an output strip's. Outputs carry
    /// a dB scale and a stereo meter, sources carry neither.
    static let sourceRatio: CGFloat = 0.75
    /// Narrowest each kind can be drawn before its contents start to crowd.
    static let minimumSourceWidth: CGFloat = 78
    static let minimumOutputWidth: CGFloat = 104
}

/// The window's backdrop: glass with a dark wash over it.
///
/// The wash is what keeps the mixer readable. Straight glass over an arbitrary
/// desktop puts meters and 7pt labels on top of whatever happens to be behind
/// the window, so the glass is tinted back toward the panel colours until the
/// contrast is the same as it was when the background was solid.
struct GlassBackground: View {
    var body: some View {
        // The window's own material is what samples the desktop; this is only
        // the tint over it. `glassEffect` is deliberately not used here: it
        // frosts what is behind a view *inside* the app, so over an empty
        // window background it just adds another opaque layer.
        LinearGradient(colors: [Theme.windowTop.opacity(0.16),
                                Theme.windowBottom.opacity(0.30)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// The glass strip behind the title bar and the footer.
///
/// Both sit over content that scrolls underneath them, so as well as frosting
/// what passes behind, they darken it hard. Glass alone is not enough: a meter
/// or a fader cap sliding under the footer reads straight through it and the
/// text on top stops being legible.
struct BarBackground: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.45))
    }
}

/// A recessed surface: dark fill, hairline top highlight, soft inner edge.
struct WellBackground: View {
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.well)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.55), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
                    .blendMode(.plusLighter)
                    .padding(1)
            )
    }
}

struct PanelBackground: View {
    var cornerRadius: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            // Translucent, so the glass behind the window carries through the
            // strips rather than showing only in the gaps between them. The
            // wells and meters inside stay opaque, which is where the contrast
            // actually has to hold up.
            .fill(
                LinearGradient(colors: [Theme.panelRaised.opacity(0.52),
                                        Theme.panel.opacity(0.62)],
                               startPoint: .top, endPoint: .bottom)
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}
