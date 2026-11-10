// Draws the NotchIsland app icon. Usage: swift Tools/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func gradient(_ colors: [CGColor], _ stops: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops)!
}

// The rounded square every macOS icon sits in.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

context.saveGState()
context.addPath(squircle)
context.clip()

// Background: a wallpaper-like sweep from violet down to deep indigo.
context.drawLinearGradient(gradient([color(0x8E7BFF), color(0x5B43E0), color(0x24155F)], [0, 0.45, 1]),
                           start: CGPoint(x: 300, y: 924), end: CGPoint(x: 760, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// A warm bloom low on the right and a cool one under the island.
context.drawRadialGradient(gradient([color(0xFF6FB1, 0.55), color(0xFF6FB1, 0)], [0, 1]),
                           startCenter: CGPoint(x: 860, y: 190), startRadius: 0,
                           endCenter: CGPoint(x: 860, y: 190), endRadius: 520, options: [])
context.drawRadialGradient(gradient([color(0x66E3FF, 0.50), color(0x66E3FF, 0)], [0, 1]),
                           startCenter: CGPoint(x: 512, y: 640), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 640), endRadius: 420, options: [])

// The island: hangs from the top edge, flares out where it meets it.
let island = CGRect(x: 242, y: 924 - 236, width: 540, height: 236)
let flare: CGFloat = 28
let radius: CGFloat = 104
let shape = CGMutablePath()
shape.move(to: CGPoint(x: island.minX - flare, y: island.maxY + 40))
shape.addLine(to: CGPoint(x: island.minX - flare, y: island.maxY))
shape.addQuadCurve(to: CGPoint(x: island.minX, y: island.maxY - flare), control: CGPoint(x: island.minX, y: island.maxY))
shape.addLine(to: CGPoint(x: island.minX, y: island.minY + radius))
shape.addQuadCurve(to: CGPoint(x: island.minX + radius, y: island.minY), control: CGPoint(x: island.minX, y: island.minY))
shape.addLine(to: CGPoint(x: island.maxX - radius, y: island.minY))
shape.addQuadCurve(to: CGPoint(x: island.maxX, y: island.minY + radius), control: CGPoint(x: island.maxX, y: island.minY))
shape.addLine(to: CGPoint(x: island.maxX, y: island.maxY - flare))
shape.addQuadCurve(to: CGPoint(x: island.maxX + flare, y: island.maxY), control: CGPoint(x: island.maxX, y: island.maxY))
shape.addLine(to: CGPoint(x: island.maxX + flare, y: island.maxY + 40))
shape.closeSubpath()

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 46, color: color(0x0B0630, 0.55))
context.addPath(shape)
context.setFillColor(color(0x000000))
context.fillPath()
context.restoreGState()

let middle = island.midY + 8

// Left wing: album art.
let art = CGRect(x: island.minX + 46, y: middle - 60, width: 120, height: 120)
context.saveGState()
context.addPath(CGPath(roundedRect: art, cornerWidth: 34, cornerHeight: 34, transform: nil))
context.clip()
context.drawLinearGradient(gradient([color(0xFFB25E), color(0xFF4F93)], [0, 1]),
                           start: CGPoint(x: art.minX, y: art.maxY), end: CGPoint(x: art.maxX, y: art.minY), options: [])
context.restoreGState()

// Center: the camera in the notch.
context.setFillColor(color(0x16161D))
context.fillEllipse(in: CGRect(x: 512 - 22, y: middle - 22, width: 44, height: 44))
context.setFillColor(color(0x2B3A78))
context.fillEllipse(in: CGRect(x: 512 - 10, y: middle - 10, width: 20, height: 20))
context.setFillColor(color(0x8FB0FF, 0.9))
context.fillEllipse(in: CGRect(x: 512 - 2, y: middle + 1, width: 7, height: 7))

// Right wing: sound bars.
let heights: [CGFloat] = [62, 120, 88, 46]
let barWidth: CGFloat = 24
let gap: CGFloat = 16
var x = island.maxX - 50 - (barWidth * 4 + gap * 3)
context.setFillColor(color(0xFFFFFF))
for height in heights {
    let bar = CGRect(x: x, y: middle - height / 2, width: barWidth, height: height)
    context.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    context.fillPath()
    x += barWidth + gap
}

context.restoreGState()

// A thin light rim so the icon holds its edge on dark backgrounds.
context.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
context.setStrokeColor(color(0xFFFFFF, 0.14))
context.setLineWidth(4)
context.strokePath()

let image = NSBitmapImageRep(cgImage: context.makeImage()!)
try! image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
