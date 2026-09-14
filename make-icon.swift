#!/usr/bin/env swift
//
// Draws Tychedit's app icon straight into the asset catalog at
// Tychedit/Assets.xcassets/AppIcon.appiconset. Run with:  swift make-icon.swift
//
// A sibling of Diptych's icon -- rounded square, cream page, amber accent -- in
// the purple the editor gives mdship placeholders. The page carries a markdown
// heading mark and ruled lines; the pencil says it is an editor. It has to
// survive 16pt in the Dock and the menu bar, so the page and the # are large,
// and the finer parts (lines, pencil details) drop out at small sizes.

import AppKit
import Foundation

let backgroundTop    = NSColor(srgbRed: 0.43, green: 0.30, blue: 0.86, alpha: 1)
let backgroundBottom = NSColor(srgbRed: 0.20, green: 0.13, blue: 0.47, alpha: 1)
let page             = NSColor(srgbRed: 0.99, green: 0.98, blue: 0.95, alpha: 1)
let pageFold         = NSColor(srgbRed: 0.86, green: 0.84, blue: 0.80, alpha: 1)
let heading          = NSColor(srgbRed: 0.45, green: 0.27, blue: 0.85, alpha: 1)
let rule             = NSColor(srgbRed: 0.62, green: 0.60, blue: 0.70, alpha: 1)
let pencilBody       = NSColor(srgbRed: 0.98, green: 0.72, blue: 0.28, alpha: 1)
let pencilBand       = NSColor(srgbRed: 0.80, green: 0.52, blue: 0.16, alpha: 1)
let pencilWood       = NSColor(srgbRed: 0.96, green: 0.86, blue: 0.68, alpha: 1)
let graphite         = NSColor(srgbRed: 0.22, green: 0.20, blue: 0.26, alpha: 1)

func icon(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context

    // macOS icons sit on a rounded square with padding around it, which is
    // what makes them line up with their neighbours in the Dock.
    let inset = s * 0.085
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)
    NSGradient(colors: [backgroundTop, backgroundBottom])?.draw(in: bodyPath, angle: -90)

    // The page, with its top right corner folded over.
    let pageWidth = body.width * 0.56
    let pageHeight = body.height * 0.70
    let pageFrame = NSRect(x: body.minX + body.width * 0.15, y: body.minY + body.height * 0.15,
                           width: pageWidth, height: pageHeight)
    let fold = pageWidth * 0.24
    let corner = max(1, pageWidth * 0.06)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.03

    let outline = NSBezierPath()
    outline.move(to: NSPoint(x: pageFrame.minX + corner, y: pageFrame.minY))
    outline.line(to: NSPoint(x: pageFrame.maxX - corner, y: pageFrame.minY))
    outline.curve(to: NSPoint(x: pageFrame.maxX, y: pageFrame.minY + corner),
                  controlPoint1: NSPoint(x: pageFrame.maxX, y: pageFrame.minY),
                  controlPoint2: NSPoint(x: pageFrame.maxX, y: pageFrame.minY))
    outline.line(to: NSPoint(x: pageFrame.maxX, y: pageFrame.maxY - fold))
    outline.line(to: NSPoint(x: pageFrame.maxX - fold, y: pageFrame.maxY))
    outline.line(to: NSPoint(x: pageFrame.minX + corner, y: pageFrame.maxY))
    outline.curve(to: NSPoint(x: pageFrame.minX, y: pageFrame.maxY - corner),
                  controlPoint1: NSPoint(x: pageFrame.minX, y: pageFrame.maxY),
                  controlPoint2: NSPoint(x: pageFrame.minX, y: pageFrame.maxY))
    outline.line(to: NSPoint(x: pageFrame.minX, y: pageFrame.minY + corner))
    outline.curve(to: NSPoint(x: pageFrame.minX + corner, y: pageFrame.minY),
                  controlPoint1: NSPoint(x: pageFrame.minX, y: pageFrame.minY),
                  controlPoint2: NSPoint(x: pageFrame.minX, y: pageFrame.minY))
    outline.close()

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    page.setFill()
    outline.fill()
    NSGraphicsContext.restoreGraphicsState()

    let flap = NSBezierPath()
    flap.move(to: NSPoint(x: pageFrame.maxX - fold, y: pageFrame.maxY))
    flap.line(to: NSPoint(x: pageFrame.maxX - fold, y: pageFrame.maxY - fold))
    flap.line(to: NSPoint(x: pageFrame.maxX, y: pageFrame.maxY - fold))
    flap.close()
    pageFold.setFill()
    flap.fill()

    // The markdown heading mark.
    // Larger where the lines are left out, so the page still reads as markdown.
    let markSize = pageWidth * (size >= 64 ? 0.46 : 0.66)
    let mark = NSAttributedString(string: "#", attributes: [
        .font: NSFont.systemFont(ofSize: markSize, weight: .heavy),
        .foregroundColor: heading,
    ])
    let markBox = mark.size()
    mark.draw(at: NSPoint(x: pageFrame.minX + pageWidth * (size >= 64 ? 0.13 : 0.08),
                          y: pageFrame.maxY - pageHeight * (size >= 64 ? 0.07 : 0.02) - markBox.height))

    // Ruled lines standing in for text; gone where they would turn to mud.
    if size >= 64 {
        let lineHeight = max(1, pageHeight * 0.045)
        let step = pageHeight * 0.12
        rule.withAlphaComponent(0.6).setFill()
        for row in 0..<3 {
            let y = pageFrame.minY + pageHeight * 0.40 - CGFloat(row) * step
            let width = pageWidth * (row == 2 ? 0.40 : 0.70)
            NSBezierPath(roundedRect: NSRect(x: pageFrame.minX + pageWidth * 0.14, y: y, width: width, height: lineHeight),
                         xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
        }
    }

    // The pencil, lying across the lower right, writing towards the page.
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: body.minX + body.width * 0.66, yBy: body.minY + body.height * 0.34)
    transform.rotate(byDegrees: 135)
    transform.concat()

    let length = body.width * 0.60
    let thickness = body.width * (size >= 64 ? 0.13 : 0.17)
    let tip = thickness * 1.15

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    pencilBody.setFill()
    NSBezierPath(roundedRect: NSRect(x: -length * 0.55, y: -thickness / 2, width: length - tip, height: thickness),
                 xRadius: thickness * 0.2, yRadius: thickness * 0.2).fill()
    NSGraphicsContext.restoreGraphicsState()

    if size >= 64 {
        // A darker stripe along the body, and the band at the far end.
        pencilBand.withAlphaComponent(0.55).setFill()
        NSRect(x: -length * 0.55, y: -thickness * 0.1, width: length - tip, height: thickness * 0.2).fill()
        pencilBand.setFill()
        NSRect(x: -length * 0.55, y: -thickness / 2, width: length * 0.09, height: thickness).fill()
    }

    let woodStart = -length * 0.55 + length - tip
    let wood = NSBezierPath()
    wood.move(to: NSPoint(x: woodStart, y: thickness / 2))
    wood.line(to: NSPoint(x: woodStart + tip, y: 0))
    wood.line(to: NSPoint(x: woodStart, y: -thickness / 2))
    wood.close()
    pencilWood.setFill()
    wood.fill()

    let lead = NSBezierPath()
    lead.move(to: NSPoint(x: woodStart + tip * 0.62, y: thickness * 0.19))
    lead.line(to: NSPoint(x: woodStart + tip, y: 0))
    lead.line(to: NSPoint(x: woodStart + tip * 0.62, y: -thickness * 0.19))
    lead.close()
    graphite.setFill()
    lead.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let catalog = URL(fileURLWithPath: "Tychedit/Assets.xcassets")
let iconset = catalog.appendingPathComponent("AppIcon.appiconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

try #"{"info":{"author":"xcode","version":1}}"#
    .write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16),    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),    ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

var entries: [String] = []
for variant in variants {
    let rep = icon(size: variant.px)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))

    // "icon_32x32@2x" -> point size 32, scale 2x.
    let scale = variant.name.hasSuffix("@2x") ? "2x" : "1x"
    let points = variant.px / (scale == "2x" ? 2 : 1)
    entries.append("""
        {"idiom":"mac","scale":"\(scale)","size":"\(points)x\(points)","filename":"\(variant.name).png"}
    """)
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {"author":"xcode","version":1}
}
"""
try contents.write(to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

print("wrote \(variants.count) images to \(iconset.path)")
