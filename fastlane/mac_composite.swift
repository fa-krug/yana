#!/usr/bin/env swift
//
// Composites a Mac Settings-window capture over the main-window capture and writes a PNG at
// exactly the Mac App Store's 2880x1800.
//
// Usage: xcrun swift fastlane/mac_composite.swift <base.png> <overlay.png> <out.png>
//
// CoreGraphics only, on purpose: `sips` cannot composite, and ImageMagick/Pillow would add a
// Homebrew/pip dependency the repo does not otherwise need.

import AppKit
import CoreGraphics
import Foundation

let canvas = CGSize(width: 2880, height: 1800)
/// Fraction of canvas width the overlay window occupies. The Settings window is 720pt wide
/// against a 1440pt main window, so half — preserved here so the composite matches what the user
/// would actually see.
let overlayWidthFraction: CGFloat = 0.5
/// Maximum fraction of canvas height the overlay may occupy. Clamps tall overlays so they fit
/// within the canvas and drop shadow remains visible; prevents silent clipping of shipped screenshots.
let overlayMaxHeightFraction: CGFloat = 0.85

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mac_composite: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 3 else {
    fail("usage: mac_composite.swift <base.png> <overlay.png> <out.png>")
}
let (basePath, overlayPath, outPath) = (args[0], args[1], args[2])

func loadImage(_ path: String) -> CGImage {
    guard let data = FileManager.default.contents(atPath: path) as CFData?,
          let source = CGImageSourceCreateWithData(data, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("could not read image at \(path)") }
    return image
}

let base = loadImage(basePath)
let overlay = loadImage(overlayPath)

guard let context = CGContext(
    data: nil,
    width: Int(canvas.width),
    height: Int(canvas.height),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fail("could not create the drawing context") }

context.interpolationQuality = .high

// Base fills the canvas. Scaling here is what makes a non-Retina host still produce a valid
// (if upscaled) App Store image instead of a wrong-sized one.
context.draw(base, in: CGRect(origin: .zero, size: canvas))

// Overlay, centred, scaled to a fixed fraction of the canvas so both Settings shots line up
// even if the window's natural height differs between panes. Clamp scale to fit within both
// width and height constraints, preserving aspect ratio.
let overlayWidth = canvas.width * overlayWidthFraction
let widthScale = overlayWidth / CGFloat(overlay.width)
let maxOverlayHeight = canvas.height * overlayMaxHeightFraction
let heightScale = maxOverlayHeight / CGFloat(overlay.height)
let overlayScale = min(widthScale, heightScale)
let overlaySize = CGSize(width: CGFloat(overlay.width) * overlayScale, height: CGFloat(overlay.height) * overlayScale)
let overlayRect = CGRect(
    x: (canvas.width - overlaySize.width) / 2,
    y: (canvas.height - overlaySize.height) / 2,
    width: overlaySize.width,
    height: overlaySize.height
)

// Drop shadow so the floating window reads as floating rather than pasted on.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18),
                  blur: 48,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
context.draw(overlay, in: overlayRect)
context.restoreGState()

guard let output = context.makeImage() else { fail("could not render the composite") }
guard output.width == Int(canvas.width), output.height == Int(canvas.height) else {
    fail("composite is \(output.width)x\(output.height), expected 2880x1800")
}

let outURL = URL(fileURLWithPath: outPath)
guard let destination = CGImageDestinationCreateWithURL(
    outURL as CFURL, "public.png" as CFString, 1, nil
) else { fail("could not create the output destination at \(outPath)") }
CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else { fail("could not write \(outPath)") }
