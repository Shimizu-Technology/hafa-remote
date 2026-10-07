#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Original Hafa Remote vector artwork, authored for Shimizu Technology.
// This file is the canonical source. All geometry uses a 1024-point canvas.
// No brand artwork, fonts, stock assets, gradients, or raster input are used.
private enum Icon {
    static let teal: UInt32 = 0x12685D
    static let ivory: UInt32 = 0xF7F5EF
    static let mint: UInt32 = 0x78D5BF
    static let graphite: UInt32 = 0x192927

    static func draw(in context: CGContext) {
        fill(context, teal, CGRect(x: 0, y: 0, width: 1024, height: 1024))
        roundedRect(context, ivory, CGRect(x: 268, y: 132, width: 488, height: 760), radius: 200)

        // The top slot and lower keys read as a remote even at home-screen size.
        roundedRect(context, teal, CGRect(x: 448, y: 232, width: 128, height: 28), radius: 14)
        roundedRect(context, teal, CGRect(x: 348, y: 340, width: 328, height: 328), radius: 112)
        circle(context, mint, center: CGPoint(x: 512, y: 504), radius: 53)

        // Four original directional wedges share a quiet, rounded-stroke treatment.
        context.setStrokeColor(color(ivory))
        context.setLineWidth(18)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        chevron(context, [CGPoint(x: 487, y: 409), CGPoint(x: 512, y: 384), CGPoint(x: 537, y: 409)])
        chevron(context, [CGPoint(x: 487, y: 599), CGPoint(x: 512, y: 624), CGPoint(x: 537, y: 599)])
        chevron(context, [CGPoint(x: 417, y: 479), CGPoint(x: 392, y: 504), CGPoint(x: 417, y: 529)])
        chevron(context, [CGPoint(x: 607, y: 479), CGPoint(x: 632, y: 504), CGPoint(x: 607, y: 529)])

        roundedRect(context, graphite, CGRect(x: 388, y: 744, width: 104, height: 40), radius: 20)
        roundedRect(context, graphite, CGRect(x: 532, y: 744, width: 104, height: 40), radius: 20)
    }

    private static func color(_ hex: UInt32) -> CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [
                CGFloat((hex >> 16) & 0xFF) / 255,
                CGFloat((hex >> 8) & 0xFF) / 255,
                CGFloat(hex & 0xFF) / 255,
                1,
            ]
        )!
    }

    private static func fill(_ context: CGContext, _ hex: UInt32, _ rect: CGRect) {
        context.setFillColor(color(hex))
        context.fill(rect)
    }

    private static func roundedRect(_ context: CGContext, _ hex: UInt32, _ rect: CGRect, radius: CGFloat) {
        context.setFillColor(color(hex))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    private static func circle(_ context: CGContext, _ hex: UInt32, center: CGPoint, radius: CGFloat) {
        context.setFillColor(color(hex))
        context.fillEllipse(
            in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func chevron(_ context: CGContext, _ points: [CGPoint]) {
        context.beginPath()
        context.move(to: points[0])
        for point in points.dropFirst() { context.addLine(to: point) }
        context.strokePath()
    }
}

private func render(size: Int, to url: URL) throws {
    // An RGB canvas with no alpha makes the App Store icon fully opaque.
    guard
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    else { throw IconError.render }
    let scale = CGFloat(size) / 1024
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: scale, y: -scale)
    context.setShouldAntialias(true)
    Icon.draw(in: context)
    guard let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw IconError.render }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.write }
}

private enum IconError: Error { case usage, render, write }

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
var output = root.appendingPathComponent(
    "HafaRemote/Resources/Assets.xcassets/AppIcon.appiconset/HafaRemoteAppIcon.png")
var previewDirectory: URL?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--output":
        guard let value = arguments.next() else { throw IconError.usage }
        output = URL(fileURLWithPath: value)
    case "--preview-dir":
        guard let value = arguments.next() else { throw IconError.usage }
        previewDirectory = URL(fileURLWithPath: value, isDirectory: true)
    default:
        throw IconError.usage
    }
}
try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try render(size: 1024, to: output)
if let previewDirectory {
    try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
    for size in [20, 40, 60, 120, 180] {
        try render(size: size, to: previewDirectory.appendingPathComponent("hafa-icon-\(size).png"))
    }
}
print("Generated original opaque 1024px Hafa Remote icon")
