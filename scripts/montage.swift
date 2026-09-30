import AppKit
// Usage: montage.swift out.png columns cellWidth img1 img2 ...  (tiles images into a labeled grid)
let args = CommandLine.arguments
let out = args[1], cols = Int(args[2])!, cellW = CGFloat(Double(args[3])!)
let images = args.dropFirst(4).compactMap { p -> (String, NSImage)? in NSImage(contentsOfFile: p).map { ((p as NSString).lastPathComponent, $0) } }
let cellH = images.map { cellW * $0.1.size.height / $0.1.size.width }.max() ?? 100
let rows = (images.count + cols - 1) / cols
let size = NSSize(width: CGFloat(cols) * cellW, height: CGFloat(rows) * (cellH + 18))
let canvas = NSImage(size: size)
canvas.lockFocus()
NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
for (i, (name, img)) in images.enumerated() {
    let c = i % cols, r = i / cols
    let h = cellW * img.size.height / img.size.width
    let y = size.height - CGFloat(r + 1) * (cellH + 18)
    img.draw(in: NSRect(x: CGFloat(c) * cellW, y: y, width: cellW, height: h))
    (name as NSString).draw(at: NSPoint(x: CGFloat(c) * cellW + 4, y: y + cellH + 3), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
}
canvas.unlockFocus()
let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
