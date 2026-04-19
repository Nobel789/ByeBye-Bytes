#!/usr/bin/env swift
// Generates:
//   Resources/AppIcon.iconset/   (PNGs for every macOS size, light variant only)
//   Resources/AppIcon.icns       (flat fallback — used when actool unavailable)
//   Resources/Assets.xcassets/   (AppIcon.icon bundle for Tahoe Liquid Glass)
//
// The .icon bundle provides foreground layers on transparent backgrounds;
// macOS derives light / dark / tinted / clear variants automatically.
//
// Run from the project root:  swift Scripts/generate-icon.swift

import AppKit
import CoreGraphics

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources  = projectRoot.appendingPathComponent("Resources")
let iconset    = resources.appendingPathComponent("AppIcon.iconset")
let icnsPath   = resources.appendingPathComponent("AppIcon.icns")
let xcassets   = resources.appendingPathComponent("Assets.xcassets")
let iconBundle = xcassets.appendingPathComponent("AppIcon.icon")
let layerAssets = iconBundle.appendingPathComponent("Assets")

for dir in [iconset, xcassets, iconBundle, layerAssets] {
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

// MARK: - Shared geometry

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),       ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),       ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),    ("icon_512x512@2x.png", 1024),
]

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
               | CGBitmapInfo.byteOrder32Little.rawValue

func makeContext(_ pixels: Int) -> CGContext {
    CGContext(data: nil, width: pixels, height: pixels,
              bitsPerComponent: 8, bytesPerRow: 0,
              space: colorSpace, bitmapInfo: bitmapInfo)!
}

func write(_ cg: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: cg.width, height: cg.height)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1)
    }
    try png.write(to: url)
}

func squircle(in rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Front/Mid/Back card geometry, shared between the flat icon and the .icon layers.
let cardWFactor: CGFloat = 0.56
let cardHFactor: CGFloat = 0.40
let cardCRFactor: CGFloat = 0.075
struct CardPlacement {
    let dx: CGFloat, dy: CGFloat, rotation: CGFloat
}
let placements: [String: CardPlacement] = [
    "Back":  CardPlacement(dx: -0.10, dy:  0.08, rotation: -0.18),
    "Mid":   CardPlacement(dx:  0.00, dy:  0.02, rotation:  0.04),
    "Front": CardPlacement(dx:  0.08, dy: -0.06, rotation:  0.16),
]

func drawCard(in ctx: CGContext, size s: CGFloat, placement: CardPlacement,
              fill: CGColor, shadow: CGFloat, sheen: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: s * 0.5 + placement.dx * s, y: s * 0.48 + placement.dy * s)
    ctx.rotate(by: placement.rotation)
    let rect = CGRect(x: -cardWFactor * s / 2, y: -cardHFactor * s / 2,
                      width: cardWFactor * s, height: cardHFactor * s)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                  blur: s * 0.035,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: shadow))
    ctx.addPath(squircle(in: rect, radius: cardCRFactor * s))
    ctx.setFillColor(fill)
    ctx.fillPath()
    if sheen {
        // Subtle top gradient highlight.
        ctx.saveGState()
        ctx.addPath(squircle(in: rect, radius: cardCRFactor * s))
        ctx.clip()
        let cardColors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.25),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ]
        let g = CGGradient(colorsSpace: colorSpace, colors: cardColors as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g,
                               start: CGPoint(x: 0, y: rect.maxY),
                               end: CGPoint(x: 0, y: rect.midY),
                               options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

func drawChevron(in ctx: CGContext, size s: CGFloat, placement: CardPlacement,
                 color: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: s * 0.5 + placement.dx * s, y: s * 0.48 + placement.dy * s)
    ctx.rotate(by: placement.rotation)

    let chW = s * 0.18
    let chH = s * 0.11
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: -chW / 2, y:  chH / 2))
    chevron.addLine(to: CGPoint(x: 0,      y: -chH / 2))
    chevron.addLine(to: CGPoint(x:  chW / 2, y:  chH / 2))
    ctx.addPath(chevron)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(max(1, s * 0.055))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Flat icon (full composite, used for .icns)

func drawFlatIcon(pixels: Int) -> CGImage {
    let s = CGFloat(pixels)
    let ctx = makeContext(pixels)

    // Squircle background + clip.
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let radius = s * 0.225
    ctx.saveGState()
    ctx.addPath(squircle(in: bgRect, radius: radius))
    ctx.clip()

    let bg = [
        CGColor(red: 0.33, green: 0.75, blue: 0.95, alpha: 1.0),
        CGColor(red: 0.18, green: 0.45, blue: 0.90, alpha: 1.0),
        CGColor(red: 0.29, green: 0.21, blue: 0.65, alpha: 1.0),
    ]
    let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bg as CFArray,
                            locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(bgGrad,
                           start: CGPoint(x: 0, y: s),
                           end: CGPoint(x: 0, y: 0), options: [])

    let sheenColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ]
    let sheen = CGGradient(colorsSpace: colorSpace, colors: sheenColors as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(sheen,
                           startCenter: CGPoint(x: s * 0.3, y: s * 0.8),
                           startRadius: 0,
                           endCenter: CGPoint(x: s * 0.3, y: s * 0.8),
                           endRadius: s * 0.6, options: [])

    drawCard(in: ctx, size: s, placement: placements["Back"]!,
             fill: CGColor(red: 1, green: 1, blue: 1, alpha: 0.55),
             shadow: 0.18, sheen: false)
    drawCard(in: ctx, size: s, placement: placements["Mid"]!,
             fill: CGColor(red: 1, green: 1, blue: 1, alpha: 0.78),
             shadow: 0.18, sheen: false)
    drawCard(in: ctx, size: s, placement: placements["Front"]!,
             fill: CGColor(red: 1, green: 1, blue: 1, alpha: 1.00),
             shadow: 0.28, sheen: true)

    drawChevron(in: ctx, size: s, placement: placements["Front"]!,
                color: CGColor(red: 0.18, green: 0.40, blue: 0.90, alpha: 1.0))

    ctx.restoreGState()

    // Thin glass edge.
    ctx.saveGState()
    ctx.addPath(squircle(in: bgRect.insetBy(dx: 0.5, dy: 0.5),
                         radius: radius - 0.5))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - Layer PNGs for the .icon bundle (transparent backgrounds)
//
// Each layer is rendered on a transparent canvas as pure white silhouettes so
// the OS can tint/lighten/darken them for any appearance.

enum Layer: String { case back = "Back", mid = "Mid", front = "Front", chevron = "Chevron" }

func drawLayer(_ layer: Layer, pixels: Int) -> CGImage {
    let s = CGFloat(pixels)
    let ctx = makeContext(pixels)
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    switch layer {
    case .back:
        drawCard(in: ctx, size: s, placement: placements["Back"]!,
                 fill: CGColor(red: 1, green: 1, blue: 1, alpha: 1), shadow: 0, sheen: false)
    case .mid:
        drawCard(in: ctx, size: s, placement: placements["Mid"]!,
                 fill: CGColor(red: 1, green: 1, blue: 1, alpha: 1), shadow: 0, sheen: false)
    case .front:
        drawCard(in: ctx, size: s, placement: placements["Front"]!,
                 fill: CGColor(red: 1, green: 1, blue: 1, alpha: 1), shadow: 0, sheen: true)
    case .chevron:
        drawChevron(in: ctx, size: s, placement: placements["Front"]!,
                    color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    }

    return ctx.makeImage()!
}

// MARK: - Emit flat iconset + .icns

print("→ Flat iconset (light)")
for (name, pixels) in sizes {
    try write(drawFlatIcon(pixels: pixels), to: iconset.appendingPathComponent(name))
}

print("→ Running iconutil")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icnsPath.path]
try iconutil.run()
iconutil.waitUntilExit()
if iconutil.terminationStatus != 0 {
    fputs("iconutil exit \(iconutil.terminationStatus)\n", stderr)
    exit(Int32(iconutil.terminationStatus))
}

// MARK: - Emit .icon (Liquid Glass layered) inside Assets.xcassets

print("→ Liquid Glass layered bundle")
let layerPixels = 1024
for layer in [Layer.back, .mid, .front, .chevron] {
    try write(drawLayer(layer, pixels: layerPixels),
              to: layerAssets.appendingPathComponent("\(layer.rawValue).png"))
}

// icon.json — simplest valid schema for a layered macOS app icon.
// Layers are rendered top-to-bottom in the order declared here;
// macOS auto-generates light/dark/tinted/clear variants from them.
let iconJSON = """
{
  "fill" : { "automatic-gradient" : { "light" : "display-p3:0.180,0.450,0.900" } },
  "groups" : [
    {
      "layers" : [
        { "image-name" : "Chevron" },
        { "image-name" : "Front" },
        { "image-name" : "Mid" },
        { "image-name" : "Back" }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.3 }
    }
  ],
  "supported-platforms" : {
    "circles" : "off",
    "squircles" : "on"
  }
}
"""
try iconJSON.write(to: iconBundle.appendingPathComponent("icon.json"),
                   atomically: true, encoding: .utf8)

// Contents.json at the .xcassets root.
let rootContents = """
{ "info" : { "version" : 1, "author" : "byebyebytes" } }
"""
try rootContents.write(to: xcassets.appendingPathComponent("Contents.json"),
                       atomically: true, encoding: .utf8)

print("✓ \(icnsPath.path)")
print("✓ \(iconBundle.path)")
