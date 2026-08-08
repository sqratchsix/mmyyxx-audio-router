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
            .fill(
                LinearGradient(colors: [Theme.panelRaised, Theme.panel],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}
