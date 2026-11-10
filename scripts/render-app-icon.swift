// Renders the app icon: a sheet of paper with an ink margin rule and a few lines of text.
// Run: swift scripts/render-app-icon.swift Apps/macOS/Assets.xcassets/AppIcon.appiconset
//      swift scripts/render-app-icon.swift --ios Apps/iOS/Assets.xcassets/AppIcon.appiconset
// The Mac icon is a sheet with its own shadow; iOS wants a full square that the system rounds.
import AppKit

let arguments = CommandLine.arguments.dropFirst()
let isIOS = arguments.contains("--ios")
let output = URL(fileURLWithPath: arguments.first { $0 != "--ios" } ?? ".")
let size: CGFloat = 1024

func render(dark: Bool, fullBleed: Bool = false) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let sheet = NSRect(x: 100, y: 100, width: 824, height: 824)
    if fullBleed {
        // Draw the same sheet scaled up so it fills the square.
        let transform = NSAffineTransform()
        transform.scale(by: size / sheet.width)
        transform.translateX(by: -sheet.minX, yBy: -sheet.minY)
        transform.concat()
    }
    let path = fullBleed ? NSBezierPath(rect: sheet) : NSBezierPath(roundedRect: sheet, xRadius: 185, yRadius: 185)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState()
    if !fullBleed { shadow.set() }
    NSColor(white: dark ? 0.09 : 0.985, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: NSColor(white: dark ? 0.13 : 1, alpha: 1), ending: NSColor(white: dark ? 0.07 : 0.93, alpha: 1))!
        .draw(in: sheet, angle: -90)
    let ink = NSColor(white: dark ? 0.94 : 0.12, alpha: 1)
    // The margin rule.
    ink.setFill()
    NSBezierPath(roundedRect: NSRect(x: 318, y: 100, width: 18, height: 824), xRadius: 9, yRadius: 9).fill()
    // Lines of writing, the first one darker like a subject.
    let lines: [(CGFloat, CGFloat, CGFloat)] = [(650, 430, 0.9), (560, 470, 0.35), (480, 400, 0.35), (400, 450, 0.35), (320, 260, 0.35)]
    for (y, width, alpha) in lines {
        ink.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: 396, y: y, width: width, height: 34), xRadius: 17, yRadius: 17).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    if !fullBleed {
        NSColor(white: dark ? 1 : 0, alpha: 0.08).setStroke()
        path.lineWidth = 3
        path.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// iOS icons must be opaque: the same pixels without an alpha channel.
func opaque(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
    let context = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    return NSBitmapImageRep(cgImage: context.makeImage()!)
}

if isIOS {
    // One 1024 image for every size, plus the dark-appearance variant.
    try! opaque(render(dark: false, fullBleed: true)).representation(using: .png, properties: [:])!.write(to: output.appending(path: "icon-ios.png"))
    try! opaque(render(dark: true, fullBleed: true)).representation(using: .png, properties: [:])!.write(to: output.appending(path: "icon-ios-dark.png"))
    let images: [[String: Any]] = [
        ["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-ios.png"],
        ["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-ios-dark.png",
         "appearances": [["appearance": "luminosity", "value": "dark"]]],
    ]
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appending(path: "Contents.json"))
    exit(0)
}

let base = render(dark: false)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let resized = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
        NSGraphicsContext.current?.imageInterpolation = .high
        base.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        try! resized.representation(using: .png, properties: [:])!.write(to: output.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appending(path: "Contents.json"))
