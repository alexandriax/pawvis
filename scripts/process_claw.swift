#!/usr/bin/env swift
// Derives every one of Pawvis's icon assets from the hand-made claw mark
// (claw.png, white-shape-on-black). Deterministic — no AI generation:
//   Resources/menubar-claw.png  128px  black glyph + alpha (menu bar template
//                                      + overlay cursor), flipped horizontally
//   Resources/claw-closed.png   128px  retracted claw (button-held cursor)
//   Resources/icon_1024.png    1024px  app icon: sky→violet gradient + cream
//                                      claw (same flipped orientation)
//   Resources/AppIcon.icns             the bundle icon, built from icon_1024
// Run: swift scripts/process_claw.swift   (from the repo root)

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("cannot load \(path)")
    }
    return image
}

func writePNG(_ image: CGImage, to path: String, quiet: Bool = false) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot create \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(path)") }
    if !quiet { print("wrote \(path) (\(image.width)x\(image.height))") }
}

/// Square downscale with high-quality resampling.
func scaled(_ image: CGImage, to size: Int) -> CGImage {
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("cannot create \(size)x\(size) context")
    }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let out = ctx.makeImage() else { fail("cannot scale to \(size)x\(size)") }
    return out
}

/// Builds the .icns from the 1024px master via a temporary .iconset.
///
/// `iconutil` stays the producer on purpose: CGImageDestination can emit
/// `com.apple.icns` directly, but it infers representation types from pixel
/// dimensions, where iconutil takes them from Apple's `@2x` naming convention.
/// The resizing is done here rather than by `sips` so the whole pipeline uses
/// one resampler.
func writeICNS(from master: CGImage, to path: String) {
    let specs = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    let fm = FileManager.default
    let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("Pawvis-\(ProcessInfo.processInfo.processIdentifier).iconset")
    try? fm.removeItem(at: iconset)
    do {
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    } catch {
        fail("cannot create \(iconset.path): \(error)")
    }
    defer { try? fm.removeItem(at: iconset) }

    for (name, px) in specs {
        writePNG(scaled(master, to: px),
                 to: iconset.appendingPathComponent("\(name).png").path,
                 quiet: true)
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", path]
    do {
        try iconutil.run()
    } catch {
        fail("cannot run iconutil: \(error)")
    }
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        fail("iconutil exited \(iconutil.terminationStatus)")
    }

    let bytes = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
    print("wrote \(path) (\(bytes) bytes, \(specs.count) representations)")
}

func rgbaPixels(of image: CGImage) -> (data: [UInt8], width: Int, height: Int) {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(
        data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (data, w, h)
}

/// White-on-black artwork → black glyph with alpha = luminance, cropped to
/// content and flipped horizontally.
func makeGlyph(from image: CGImage) -> CGImage {
    let (pixels, w, h) = rgbaPixels(of: image)
    var out = [UInt8](repeating: 0, count: w * h * 4)
    var minX = w, maxX = 0, minY = h, maxY = 0

    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            let luminance = max(pixels[i], max(pixels[i + 1], pixels[i + 2]))
            // Premultiplied black: RGB stays 0, alpha carries the shape.
            out[i + 3] = luminance
            if luminance > 12 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard minX < maxX, minY < maxY else { fail("no glyph content found") }

    let ctx = CGContext(
        data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let full = ctx.makeImage()!
    let cropped = full.cropping(
        to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

    // Flip horizontally (claws point the other way).
    let fw = cropped.width, fh = cropped.height
    let flipCtx = CGContext(
        data: nil, width: fw, height: fh, bitsPerComponent: 8, bytesPerRow: fw * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    flipCtx.translateBy(x: CGFloat(fw), y: 0)
    flipCtx.scaleBy(x: -1, y: 1)
    flipCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: fw, height: fh))
    return flipCtx.makeImage()!
}

/// Fit `glyph` into a square canvas with a margin fraction, centered.
func fitRect(glyph: CGImage, canvas: CGFloat, margin: CGFloat) -> CGRect {
    let avail = canvas * (1 - 2 * margin)
    let gw = CGFloat(glyph.width), gh = CGFloat(glyph.height)
    let scale = min(avail / gw, avail / gh)
    let w = gw * scale, h = gh * scale
    return CGRect(x: (canvas - w) / 2, y: (canvas - h) / 2, width: w, height: h)
}

/// "Closed" cursor variant: the paw pad with the claws retracted. The split
/// point is the minimum-coverage row between the (narrow) claw region and the
/// (wide) pad blob; the pad is whichever side has the wider rows.
func makeClosedGlyph(_ glyph: CGImage) -> CGImage {
    let (pixels, w, h) = rgbaPixels(of: glyph)
    var coverage = [Int](repeating: 0, count: h)
    for y in 0..<h {
        for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 12 {
            coverage[y] += 1
        }
    }
    let lo = Int(Double(h) * 0.25), hi = Int(Double(h) * 0.75)
    var gapRow = lo
    var best = Int.max
    for y in lo..<hi where coverage[y] < best {
        best = coverage[y]
        gapRow = y
    }
    let maxAbove = coverage[..<gapRow].max() ?? 0
    let maxBelow = coverage[gapRow...].max() ?? 0
    let rect = maxBelow >= maxAbove
        ? CGRect(x: 0, y: gapRow, width: w, height: h - gapRow)
        : CGRect(x: 0, y: 0, width: w, height: gapRow)
    guard let pad = glyph.cropping(to: rect) else { fail("closed-glyph crop failed") }

    let size = 128
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(pad, in: fitRect(glyph: pad, canvas: 128, margin: 0.10))
    return ctx.makeImage()!
}

func makeMenubarGlyph(_ glyph: CGImage) -> CGImage {
    let size = 128
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(glyph, in: fitRect(glyph: glyph, canvas: 128, margin: 0.06))
    return ctx.makeImage()!
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func makeAppIcon(_ glyph: CGImage) -> CGImage {
    let size = 1024
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // Brand gradient: sky-500 → violet-500, diagonal.
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [color(0x0EA5E9), color(0x8B5CF6)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: CGFloat(size)),
        end: CGPoint(x: CGFloat(size), y: 0),
        options: [])

    // Cream claw, pre-tinted so the drop shadow applies to the glyph shape.
    let tinted: CGImage = {
        let t = CGContext(
            data: nil, width: glyph.width, height: glyph.height, bitsPerComponent: 8,
            bytesPerRow: glyph.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: glyph.width, height: glyph.height)
        t.clip(to: rect, mask: glyph)
        t.setFillColor(color(0xF5EDE0))
        t.fill(rect)
        return t.makeImage()!
    }()

    ctx.setShadow(
        offset: CGSize(width: 0, height: -16), blur: 44,
        color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.32))
    ctx.draw(tinted, in: fitRect(glyph: glyph, canvas: 1024, margin: 0.17))
    return ctx.makeImage()!
}

// MARK: - Main

let repo = FileManager.default.currentDirectoryPath
let sourcePath = repo + "/claw.png"
guard FileManager.default.fileExists(atPath: sourcePath) else {
    fail("claw.png not found in \(repo) — run from the repo root")
}

let glyph = makeGlyph(from: loadImage(sourcePath))
writePNG(makeMenubarGlyph(glyph), to: repo + "/Resources/menubar-claw.png")
writePNG(makeClosedGlyph(glyph), to: repo + "/Resources/claw-closed.png")

let appIcon = makeAppIcon(glyph)
writePNG(appIcon, to: repo + "/Resources/icon_1024.png")
writeICNS(from: appIcon, to: repo + "/Resources/AppIcon.icns")
print("done")
