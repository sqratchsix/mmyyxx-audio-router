// Generates Resources/AppIcon.icns: three faders at different positions.
//
// Rendered natively at every icon size rather than downscaled from 1024, so the
// 16pt and 32pt variants stay legible instead of turning to mush. Run via
// Tools/make-icon.sh.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Apple's icon grid: the body occupies 824 of a 1024 canvas, corner radius 185.
let bodyRatio: CGFloat = 824.0 / 1024.0
let radiusRatio: CGFloat = 185.0 / 824.0

/// Fader positions as a fraction of track travel, low to high.
let faderPositions: [CGFloat] = [0.34, 0.72, 0.52]

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func drawIcon(size: CGFloat, into context: CGContext) {
    let body = size * bodyRatio
    let origin = (size - body) / 2
    let bodyRect = CGRect(x: origin, y: origin, width: body, height: body)
    let bodyPath = CGPath(roundedRect: bodyRect,
                          cornerWidth: body * radiusRatio,
                          cornerHeight: body * radiusRatio,
                          transform: nil)

    // Body: graphite gradient, matching the app's window.
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let bodyGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(56, 62, 72), rgb(24, 27, 33), rgb(14, 16, 20)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(bodyGradient,
                               start: CGPoint(x: 0, y: bodyRect.maxY),
                               end: CGPoint(x: 0, y: bodyRect.minY),
                               options: [])
    context.restoreGState()

    // Hairline top edge, the detail that keeps it from looking flat.
    context.saveGState()
    context.addPath(bodyPath)
    context.setStrokeColor(rgb(255, 255, 255, 0.16))
    context.setLineWidth(max(1, size / 256))
    context.strokePath()
    context.restoreGState()

    // Fader geometry.
    let inset = body * 0.21
    let field = CGRect(x: bodyRect.minX + inset, y: bodyRect.minY + inset,
                       width: body - inset * 2, height: body - inset * 2)
    let slot = field.width / CGFloat(faderPositions.count)
    let trackWidth = max(size / 64, body * 0.052)
    let capWidth = slot * 0.78
    let capHeight = max(size / 20, body * 0.088)
    let travel = field.height - capHeight

    for (index, position) in faderPositions.enumerated() {
        let centerX = field.minX + slot * (CGFloat(index) + 0.5)
        let capCenterY = field.minY + capHeight / 2 + travel * position

        // Track well.
        let track = CGRect(x: centerX - trackWidth / 2, y: field.minY,
                           width: trackWidth, height: field.height)
        context.addPath(CGPath(roundedRect: track, cornerWidth: trackWidth / 2,
                               cornerHeight: trackWidth / 2, transform: nil))
        context.setFillColor(rgb(6, 8, 11))
        context.fillPath()

        // Filled travel below the cap, in the app's accent colour.
        let filled = CGRect(x: track.minX, y: track.minY,
                            width: trackWidth, height: capCenterY - track.minY)
        context.saveGState()
        context.addPath(CGPath(roundedRect: filled, cornerWidth: trackWidth / 2,
                               cornerHeight: trackWidth / 2, transform: nil))
        context.clip()
        let accent = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [rgb(52, 168, 224), rgb(120, 214, 255)] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(accent,
                                   start: CGPoint(x: 0, y: filled.minY),
                                   end: CGPoint(x: 0, y: filled.maxY),
                                   options: [])
        context.restoreGState()

        // Cap.
        let cap = CGRect(x: centerX - capWidth / 2, y: capCenterY - capHeight / 2,
                         width: capWidth, height: capHeight)
        let capRadius = min(capHeight * 0.32, capWidth * 0.2)
        let capPath = CGPath(roundedRect: cap, cornerWidth: capRadius,
                             cornerHeight: capRadius, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -size / 200),
                          blur: size / 100, color: rgb(0, 0, 0, 0.6))
        context.addPath(capPath)
        context.setFillColor(rgb(236, 239, 243))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(capPath)
        context.clip()
        let capGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [rgb(250, 251, 253), rgb(196, 203, 213)] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(capGradient,
                                   start: CGPoint(x: 0, y: cap.maxY),
                                   end: CGPoint(x: 0, y: cap.minY),
                                   options: [])
        context.restoreGState()

        // Index line across the cap. Below ~32px it closes up into noise, so
        // it only gets drawn when there are pixels to spare.
        if size >= 64 {
            let line = CGRect(x: cap.minX + capWidth * 0.14, y: capCenterY - max(1, size / 340),
                              width: capWidth * 0.72, height: max(1, size / 170))
            context.setFillColor(rgb(90, 100, 114))
            context.fill(line)
        }
    }
}

func writePNG(size: Int, to url: URL) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create bitmap context")
    }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    drawIcon(size: CGFloat(size), into: context)

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("could not encode \(url.lastPathComponent)") }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    writePNG(size: variant.size, to: outputDirectory.appendingPathComponent("\(variant.name).png"))
}
print("wrote \(variants.count) icon variants to \(outputDirectory.path)")
