// Draws the app icon: a pace bar on a dark rounded square, echoing the popover's PaceBar.
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

    // Background: a deep blue-grey gradient, lighter at the top.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let colors = [CGColor(red: 0.20, green: 0.23, blue: 0.30, alpha: 1),
                  CGColor(red: 0.09, green: 0.10, blue: 0.14, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: square.maxY), end: CGPoint(x: 0, y: square.minY), options: [])
    ctx.restoreGState()

    // The bar: track, fill to 62%, and the even-pace tick at 50% — "a little over pace".
    let barHeight = square.height * 0.16
    let barRect = CGRect(x: square.minX + square.width * 0.14,
                         y: square.midY - barHeight / 2,
                         width: square.width * 0.72, height: barHeight)
    let track = CGPath(roundedRect: barRect, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil)
    ctx.addPath(track)
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.14))
    ctx.fillPath()

    let fillRect = CGRect(x: barRect.minX, y: barRect.minY, width: barRect.width * 0.62, height: barHeight)
    ctx.addPath(CGPath(roundedRect: fillRect, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
    ctx.setFillColor(CGColor(red: 1.0, green: 0.36, blue: 0.32, alpha: 1))
    ctx.fillPath()

    let tickWidth = square.width * 0.03
    let tickRect = CGRect(x: barRect.minX + barRect.width * 0.5 - tickWidth / 2,
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
