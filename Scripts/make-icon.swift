#!/usr/bin/env swift
import AppKit

// Generates Resources/AppIcon.icns.
//
//     swift Scripts/make-icon.swift
//
// The icon is drawn rather than shipped as a binary so it can be reviewed and
// changed in the same way as everything else here. It is deliberately plain:
// a tile in the macOS shape with a gauge on it, which reads correctly at 16 pt
// in a Finder list. Replace this file with something better whenever you like —
// nothing depends on the drawing beyond the file it produces.

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    // macOS app icons sit inside their canvas rather than filling it, and the
    // corner radius is a fixed fraction of the tile — matching those two is
    // most of what makes an icon look native rather than pasted on.
    let inset = size * 0.094
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = rect.width * 0.2237

    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.18, green: 0.47, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 0.08, green: 0.22, blue: 0.29, alpha: 1),
    ])?.draw(in: rect, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // A hairline rim, the way system icons catch light along their edge.
    NSColor.white.withAlphaComponent(0.16).setStroke()
    let rim = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.008, dy: size * 0.008),
                           xRadius: corner, yRadius: corner)
    rim.lineWidth = max(1, size * 0.012)
    rim.stroke()

    let configuration = NSImage.SymbolConfiguration(pointSize: rect.width * 0.56, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                            accessibilityDescription: "MyMac")?
        .withSymbolConfiguration(configuration) {
        let drawn = symbol.size
        let origin = NSPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2)
        NSColor.white.set()
        symbol.draw(in: NSRect(origin: origin, size: drawn),
                    from: .zero, operation: .sourceOver, fraction: 0.95)
    }

    return image
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/MyMac.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Exactly the names `iconutil` expects; anything else is silently ignored.
let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, size) in variants {
    let image = drawIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(name).png"))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else { exit(convert.terminationStatus) }

try? FileManager.default.removeItem(at: iconset)
print("wrote Resources/AppIcon.icns")
