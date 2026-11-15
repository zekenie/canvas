// PNGs in a grid, each labeled above, on white: grid <columns> <out.png> <a.png> <label a> <b.png> <label b> ...
// Every cell is scaled to the widest picture's width, so pictures of one board line up.
import AppKit
let a = CommandLine.arguments
let cols = Int(a[1])!, out = a[2]
var cells: [(NSImage, String)] = []
var i = 3
while i + 1 < a.count { cells.append((NSImage(contentsOfFile: a[i])!, a[i + 1])); i += 2 }
let cellW = cells.map { $0.0.size.width }.max()!
let scaled = cells.map { (img, label) -> (NSImage, String, NSSize) in
    let s = cellW / img.size.width
    return (img, label, NSSize(width: cellW, height: img.size.height * s))
}
let rows = (cells.count + cols - 1) / cols
let gap: CGFloat = 40, head: CGFloat = 64
var rowH: [CGFloat] = []
for r in 0..<rows { rowH.append(scaled[(r * cols)..<min(cells.count, r * cols + cols)].map { $0.2.height }.max()!) }
let size = NSSize(width: CGFloat(cols) * cellW + CGFloat(cols + 1) * gap, height: rowH.reduce(0, +) + CGFloat(rows) * (head + gap) + gap)
let img = NSImage(size: size)
img.lockFocus()
NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.black]
var top = size.height - gap
for r in 0..<rows {
    for c in 0..<cols {
        let k = r * cols + c
        if k >= cells.count { break }
        let (pic, label, s) = scaled[k]
        let x = gap + CGFloat(c) * (cellW + gap)
        (label as NSString).draw(at: NSPoint(x: x, y: top - head + 14), withAttributes: attrs)
        pic.draw(in: NSRect(x: x, y: top - head - s.height, width: s.width, height: s.height))
        NSColor(white: 0.85, alpha: 1).setStroke()
        NSBezierPath(rect: NSRect(x: x, y: top - head - s.height, width: s.width, height: s.height)).stroke()
    }
    top -= head + rowH[r] + gap
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
