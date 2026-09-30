import AppKit

// Draws Murmur's app icon: a dark squircle with a lavender glow and a white voice waveform.
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

// Soft drop shadow like Big Sur icons.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill()
squircle.fill()
ctx.restoreGState()

squircle.addClip()
let bg = NSGradient(colors: [NSColor(srgbRed: 0.09, green: 0.08, blue: 0.11, alpha: 1), NSColor(srgbRed: 0.20, green: 0.15, blue: 0.36, alpha: 1)])!
bg.draw(in: rect, angle: -60)
let glow = NSGradient(colors: [NSColor(srgbRed: 0.66, green: 0.55, blue: 1.0, alpha: 0.55), NSColor(srgbRed: 0.66, green: 0.55, blue: 1.0, alpha: 0)])!
glow.draw(fromCenter: CGPoint(x: 512, y: 470), radius: 0, toCenter: CGPoint(x: 512, y: 470), radius: 420, options: [])

let heights: [CGFloat] = [150, 300, 440, 260, 360, 190, 110]
let barWidth: CGFloat = 58
let spacing: CGFloat = 34
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
var x = (CGFloat(size) - total) / 2
for h in heights {
    let bar = NSBezierPath(roundedRect: CGRect(x: x, y: 512 - h / 2, width: barWidth, height: h), xRadius: barWidth / 2, yRadius: barWidth / 2)
    NSColor.white.setFill()
    bar.fill()
    x += barWidth + spacing
}
// Subtle top highlight.
let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
highlight.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: 90)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
