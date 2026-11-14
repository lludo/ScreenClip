import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let size = points * scale
    let context = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.addPath(
      CGPath(
        roundedRect: CGRect(x: 50, y: 50, width: 924, height: 924), cornerWidth: 210,
        cornerHeight: 210, transform: nil))
    context.setFillColor(CGColor(red: 0.97, green: 0.41, blue: 0.15, alpha: 1))
    context.fillPath()
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(52)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for (x, y, dx, dy) in [
      (270.0, 270.0, 1.0, 1.0), (754, 270, -1, 1), (270, 754, 1, -1), (754, 754, -1, -1),
    ] {
      context.move(to: CGPoint(x: x + dx * 125, y: y))
      context.addLine(to: CGPoint(x: x, y: y))
      context.addLine(to: CGPoint(x: x, y: y + dy * 125))
      context.strokePath()
    }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillEllipse(in: CGRect(x: 468, y: 468, width: 88, height: 88))
    let suffix = scale == 2 ? "@2x" : ""
    let url = directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    let output = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Icon encoding failed") }
  }
}
