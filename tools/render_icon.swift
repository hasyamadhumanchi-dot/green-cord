// Renders the app icon: the project's original panther silhouette on Princeton
// ISD maroon, above the green cord the programme is named after.
//
// The head path is the same one PantherShape draws in the app, so the icon and
// the in-app mark cannot drift apart.
//
//   swiftc -O tools/render_icon.swift -o .build/render_icon
//   .build/render_icon GreenCordHandbook/Assets.xcassets/AppIcon.appiconset/AppIcon.png 1024
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3, let side = Int(arguments[2]) else {
    FileHandle.standardError.write("usage: render_icon <out.png> <size>\n".data(using: .utf8)!)
    exit(2)
}
let outputPath = arguments[1]
let size = CGFloat(side)

/// The panther head, in the same 100x100 design box the SwiftUI shape uses.
func pantherPath(scale: CGFloat, offset: CGPoint) -> NSBezierPath {
    let path = NSBezierPath()
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        // The SwiftUI shape has y growing downwards; AppKit's grows upwards, so
        // flip within the design box.
        NSPoint(x: offset.x + x * scale, y: offset.y + (100 - y) * scale)
    }

    path.move(to: point(18, 54))
    path.curve(to: point(31, 27), controlPoint1: point(18, 41), controlPoint2: point(23, 32))
    path.line(to: point(24, 6))                        // left ear tip
    path.line(to: point(43, 21))
    path.curve(to: point(57, 21), controlPoint1: point(47, 19), controlPoint2: point(53, 19))
    path.line(to: point(76, 6))                        // right ear tip
    path.line(to: point(69, 27))
    path.curve(to: point(82, 54), controlPoint1: point(77, 32), controlPoint2: point(82, 41))
    path.curve(to: point(64, 82), controlPoint1: point(82, 67), controlPoint2: point(75, 76))
    path.line(to: point(50, 94))                       // chin
    path.line(to: point(36, 82))
    path.curve(to: point(18, 54), controlPoint1: point(25, 76), controlPoint2: point(18, 67))
    path.close()

    // Eyes: angled slits, which is what makes this read as a big cat.
    for mirrored in [false, true] {
        let flip: (CGFloat) -> CGFloat = { mirrored ? 100 - $0 : $0 }
        let eye = NSBezierPath()
        eye.move(to: point(flip(31), 50))
        eye.line(to: point(flip(45), 46))
        eye.line(to: point(flip(45), 54))
        eye.line(to: point(flip(33), 57))
        eye.close()
        path.append(eye)
    }

    // Muzzle notch.
    let muzzle = NSBezierPath()
    muzzle.move(to: point(50, 66))
    muzzle.line(to: point(58, 73))
    muzzle.line(to: point(50, 80))
    muzzle.line(to: point(42, 73))
    muzzle.close()
    path.append(muzzle)

    path.windingRule = .evenOdd
    return path
}

// Draw into an explicitly sized bitmap. NSImage.lockFocus would render at the
// display's backing scale and produce a 2048px file on a Retina Mac.
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else {
    FileHandle.standardError.write("could not allocate bitmap\n".data(using: .utf8)!)
    exit(1)
}
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Maroon field, #5A1115, taken from the district site's --primary-color.
NSColor(srgbRed: 0x5A / 255.0, green: 0x11 / 255.0, blue: 0x15 / 255.0, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

// The cord, draped: two strands meeting in a V, with knotted ends. An arc read
// as a smile and made the whole mark look comic.
let cordGreen = NSColor(srgbRed: 0x2E / 255.0, green: 0x8B / 255.0, blue: 0x4F / 255.0, alpha: 1)
let cord = NSBezierPath()
cord.move(to: NSPoint(x: size * 0.15, y: size * 0.29))
cord.line(to: NSPoint(x: size * 0.50, y: size * 0.11))
cord.line(to: NSPoint(x: size * 0.85, y: size * 0.29))
cord.lineWidth = size * 0.05
cord.lineCapStyle = .round
cord.lineJoinStyle = .round
cordGreen.setStroke()
cord.stroke()

cordGreen.setFill()
for x in [0.15, 0.85] {
    NSBezierPath(ovalIn: NSRect(
        x: size * CGFloat(x) - size * 0.042,
        y: size * 0.29 - size * 0.042,
        width: size * 0.084,
        height: size * 0.084
    )).fill()
}

// Panther, centred above the cord.
NSColor.white.setFill()
pantherPath(scale: size * 0.0060, offset: CGPoint(x: size * 0.20, y: size * 0.34)).fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("could not encode png\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) at \(side)x\(side)")
