// Draws the app icon into an .iconset folder: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.21, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.10, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius), angle: -90)

    // Three stacked session panes, the middle one highlighted.
    let paneW = body.width * 0.62, paneH = body.height * 0.15, gap = body.height * 0.065
    let colors: [NSColor] = [.systemGreen, .systemOrange, .systemPurple]
    for i in 0..<3 {
        let y = body.midY + (CGFloat(1 - i) * (paneH + gap)) - paneH / 2
        let pane = NSRect(x: body.minX + body.width * 0.25, y: y, width: paneW, height: paneH)
        (i == 1 ? NSColor(white: 1, alpha: 0.20) : NSColor(white: 1, alpha: 0.09)).setFill()
        NSBezierPath(roundedRect: pane, xRadius: paneH * 0.3, yRadius: paneH * 0.3).fill()
        colors[i].setFill()
        let d = paneH * 0.42
        NSBezierPath(ovalIn: NSRect(x: body.minX + body.width * 0.13, y: pane.midY - d / 2, width: d, height: d)).fill()
        NSColor(white: 1, alpha: i == 1 ? 0.9 : 0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: pane.minX + paneH * 0.35, y: pane.midY - paneH * 0.08,
                                         width: paneW * (i == 1 ? 0.55 : 0.4), height: paneH * 0.16),
                     xRadius: paneH * 0.08, yRadius: paneH * 0.08).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(size: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(size: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
