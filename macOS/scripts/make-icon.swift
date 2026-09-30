#!/usr/bin/env swift
// Renders macOS/Resources/AppIcon.icns. Run via `make icon`.
//
// Drawn in code rather than shipped as a binary asset so the mark stays editable.

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// macOS icons sit on a squircle inset from the canvas edge.
func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let inset = size * 0.08
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237  // Apple's continuous-corner ratio
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 1.00, green: 0.45, blue: 0.30, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.22, blue: 0.45, alpha: 1),
    ])?.draw(in: rect, angle: -60)
    NSGradient(colors: [NSColor(white: 1, alpha: 0.20), NSColor(white: 1, alpha: 0)])?
        .draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // A waveform: speech turning into something you can see.
    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.46, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let g = glyph.size
        glyph.draw(in: CGRect(x: rect.midX - g.width / 2, y: rect.midY - g.height / 2,
                              width: g.width, height: g.height))
    }
    return image
}

func write(_ image: NSImage, pixels: Int, name: String) {
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return }
    bitmap.size = NSSize(width: pixels, height: pixels)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: iconset.appendingPathComponent(name))
}

for base in [16, 32, 128, 256, 512] {
    write(render(size: CGFloat(base)), pixels: base, name: "icon_\(base)x\(base).png")
    write(render(size: CGFloat(base * 2)), pixels: base * 2, name: "icon_\(base)x\(base)@2x.png")
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("macOS/Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "macOS/Resources/AppIcon.icns" : "iconutil failed")
