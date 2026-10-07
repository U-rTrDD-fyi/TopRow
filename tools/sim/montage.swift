// montage.swift <out.png> <cropTopFraction> <scale> <in1.png> [in2.png ...]
// Crops each screenshot to its bottom part (keyboard) and places them side by side.
import AppKit
let args = CommandLine.arguments
let out = args[1], cropTop = Double(args[2])!, scale = Double(args[3])!
let images = args.dropFirst(4).compactMap { NSImage(contentsOfFile: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
let crops = images.map { img -> CGImage in
    let y = Int(Double(img.height) * cropTop)
    return img.cropping(to: CGRect(x: 0, y: y, width: img.width, height: img.height - y))!
}
let w = Int(Double(crops.map { $0.width }.reduce(0, +)) * scale) + 8 * (crops.count - 1)
let h = Int(Double(crops.map { $0.height }.max()!) * scale)
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
var x = 0
for c in crops {
    let cw = Int(Double(c.width) * scale), ch = Int(Double(c.height) * scale)
    ctx.draw(c, in: CGRect(x: x, y: h - ch, width: cw, height: ch)); x += cw + 8
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
