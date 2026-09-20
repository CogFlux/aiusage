// Draws the app icon: the website's favicon at Dock scale — a pace bar on a near-black
// rounded square, filled green and short of the even-pace tick ("under budget").
// Usage: swift scripts/make-icon.swift <output.png>   (1024×1024, then see scripts/make-icon.sh)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

    // Apple's icon grid: the shape fills ~80% of the canvas, corner radius ≈ 22.4% of its side.
    let inset = size * 0.1
    let square = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = CGPath(roundedRect: square, cornerWidth: square.width * 0.224, cornerHeight: square.width * 0.224, transform: nil)

    // Soft drop shadow under the shape, as the system icons have.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: #111 like the favicon, with a faint top-to-bottom falloff so it reads as a
    // surface rather than a flat hole in the Dock.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let colors = [CGColor(gray: 0.13, alpha: 1),
                  CGColor(gray: 0.055, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: square.maxY), end: CGPoint(x: 0, y: square.minY), options: [])
    ctx.restoreGState()

    // The bar, in the favicon's proportions: track, green fill to 45%, tick at 56% — under pace.
    let barHeight = square.height * 0.16
    let barRect = CGRect(x: square.minX + square.width * 0.14,
                         y: square.midY - barHeight / 2,
                         width: square.width * 0.72, height: barHeight)
    let track = CGPath(roundedRect: barRect, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil)
    ctx.addPath(track)
    ctx.setFillColor(CGColor(gray: 0.27, alpha: 1))
    ctx.fillPath()

    let fillRect = CGRect(x: barRect.minX, y: barRect.minY, width: barRect.width * 0.45, height: barHeight)
    ctx.addPath(CGPath(roundedRect: fillRect, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
    ctx.setFillColor(CGColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1))   // #34c759
    ctx.fillPath()

    let tickWidth = square.width * 0.03
    let tickRect = CGRect(x: barRect.minX + barRect.width * 0.56 - tickWidth / 2,
                          y: barRect.minY - barHeight * 0.45,
                          width: tickWidth, height: barHeight * 1.9)
    ctx.addPath(CGPath(roundedRect: tickRect, cornerWidth: tickWidth / 2, cornerHeight: tickWidth / 2, transform: nil))
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
    ctx.fillPath()
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("could not render icon\n", stderr)
    exit(1)
}
// NSImage renders at the screen's scale; resample to exactly 1024 px.
let ci = CIImage(data: png)!
let scale = size / ci.extent.width
let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
let outRep = NSCIImageRep(ciImage: scaled)
let final = NSImage(size: NSSize(width: size, height: size))
final.addRepresentation(outRep)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
final.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
