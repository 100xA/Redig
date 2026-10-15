#!/usr/bin/env swift
import AppKit
import Foundation

// Deterministic fallbacks for the layered Icon Composer source. Run from the repository root.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fm = FileManager.default
let source = root.appendingPathComponent("Resources/AppIcon")
let iconset = root.appendingPathComponent("build.noindex/AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ file: String, side: Int, to output: URL) throws -> Data {
    guard let image = NSImage(contentsOf: source.appendingPathComponent(file)),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "DigUpIcons", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot render \(file)"])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "DigUpIcons", code: 2)
    }
    try data.write(to: output)
    return data
}

for side in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = side * scale
        let suffix = scale == 2 ? "@2x" : ""
        _ = try render(pixels <= 32 ? "appicon-small.svg" : "appicon.svg", side: pixels,
                       to: iconset.appendingPathComponent("icon_\(side)x\(side)\(suffix).png"))
    }
}
for name in ["tray", "tray-dim", "tray-paused"] {
    _ = try render(name + ".svg", side: 64, to: source.appendingPathComponent(name + ".png"))
}
let shell = root.appendingPathComponent("shell/src-tauri/icons")
for (name, side) in [("32x32", 32), ("128x128", 128), ("128x128@2x", 256), ("icon", 512)] {
    _ = try render("appicon.svg", side: side, to: shell.appendingPathComponent(name + ".png"))
}
_ = try render("appicon.svg", side: 256, to: root.appendingPathComponent("docs/logo.png"))
_ = try render("appicon.svg", side: 512, to: root.appendingPathComponent("shell/ui/icon.png"))

// ICO supports PNG payloads, preserving the same sharp source at every Windows icon size.
var ico = Data([0, 0, 1, 0, 5, 0])
var payload = Data()
for side in [16, 32, 48, 128, 256] {
    let png = try render("appicon.svg", side: side, to: iconset.appendingPathComponent("windows-\(side).png"))
    let offset = UInt32(6 + 16 * 5 + payload.count)
    ico.append(contentsOf: [UInt8(side == 256 ? 0 : side), UInt8(side == 256 ? 0 : side), 0, 0, 1, 0, 32, 0])
    for number in [UInt32(png.count), offset] {
        var value = number.littleEndian
        withUnsafeBytes(of: &value) { ico.append(contentsOf: $0) }
    }
    payload.append(png)
}
ico.append(payload)
try ico.write(to: shell.appendingPathComponent("icon.ico"))
print("Rendered fallback iconset, PNGs and Windows ICO. Compile AppIcon.icon with actool for macOS 26 materials.")
