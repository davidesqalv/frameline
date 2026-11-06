// Generates synthetic film-scan JPEGs for testing frameline-detect, plus an
// expected.csv with the true margins. Usage: synth <outdir>
import Foundation
import CoreGraphics
import ImageIO

struct LCG: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s }
}

struct Spec {
    var name: String
    var w: Int, h: Int
    var border: (Double, Double, Double)
    var l: Double, t: Double, r: Double, b: Double   // true margins
    var tilt: Double = 0                             // degrees
    var holder: Double = 0                           // dark holder mask width (fraction), 0 = none
    var negative = false                             // picture drawn as a murky negative
    var seed: UInt64 = 1
}

func color(_ c: (Double, Double, Double)) -> CGColor { CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1) }

func render(_ s: Spec, to url: URL) {
    let w = s.w, h = s.h, bpr = w * 4
    var buf = [UInt8](repeating: 0, count: bpr * h)
    var rng = LCG(s: s.seed)
    buf.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let W = Double(w), H = Double(h)
        ctx.setFillColor(color(s.border)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        if s.tilt != 0 {
            ctx.translateBy(x: W / 2, y: H / 2); ctx.rotate(by: s.tilt * .pi / 180); ctx.translateBy(x: -W / 2, y: -H / 2)
        }
        // picture rect in CG coords (origin bottom-left): y offset is the bottom margin
        let pic = CGRect(x: s.l * W, y: s.b * H, width: (1 - s.l - s.r) * W, height: (1 - s.t - s.b) * H)
        ctx.clip(to: pic)
        // base: smooth gradient
        let cs = CGColorSpaceCreateDeviceRGB()
        let (c1, c2): (CGColor, CGColor) = s.negative
            ? (CGColor(red: 0.55, green: 0.35, blue: 0.20, alpha: 1), CGColor(red: 0.25, green: 0.18, blue: 0.12, alpha: 1))
            : (CGColor(red: 0.45, green: 0.62, blue: 0.85, alpha: 1), CGColor(red: 0.80, green: 0.75, blue: 0.60, alpha: 1))
        let grad = CGGradient(colorsSpace: cs, colors: [c1, c2] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: pic.minX, y: pic.maxY), end: CGPoint(x: pic.maxX, y: pic.minY), options: [])
        // a partial-span strong rectangle (a building / wall) and some blobs
        let bx = pic.minX + pic.width * 0.30
        ctx.setFillColor(s.negative ? CGColor(red: 0.7, green: 0.5, blue: 0.3, alpha: 1) : CGColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1))
        ctx.fill(CGRect(x: bx, y: pic.minY, width: pic.width * 0.25, height: pic.height * 0.50))
        for _ in 0..<7 {
            let rx = pic.minX + Double.random(in: 0...1, using: &rng) * pic.width
            let ry = pic.minY + Double.random(in: 0...1, using: &rng) * pic.height
            let rw = pic.width * Double.random(in: 0.05...0.25, using: &rng)
            let rh = pic.height * Double.random(in: 0.05...0.25, using: &rng)
            ctx.setFillColor(CGColor(red: Double.random(in: 0.1...0.9, using: &rng), green: Double.random(in: 0.1...0.9, using: &rng), blue: Double.random(in: 0.1...0.9, using: &rng), alpha: 0.85))
            ctx.fillEllipse(in: CGRect(x: rx - rw / 2, y: ry - rh / 2, width: rw, height: rh))
        }
        // fine texture (a bush / gravel) in the lower-left of the picture
        let tex = CGRect(x: pic.minX, y: pic.minY, width: pic.width * 0.4, height: pic.height * 0.45)
        for _ in 0..<2500 {
            let rx = tex.minX + Double.random(in: 0...1, using: &rng) * tex.width
            let ry = tex.minY + Double.random(in: 0...1, using: &rng) * tex.height
            let rr = Double.random(in: 2...9, using: &rng)
            let v = Double.random(in: 0.2...0.7, using: &rng)
            ctx.setFillColor(CGColor(red: v * 0.6, green: v, blue: v * 0.4, alpha: 0.9))
            ctx.fillEllipse(in: CGRect(x: rx - rr, y: ry - rr, width: rr * 2, height: rr * 2))
        }
        ctx.restoreGState()
        // holder mask: dark band around the outside, not tilted with the film
        if s.holder > 0 {
            ctx.setFillColor(CGColor(red: 0.03, green: 0.03, blue: 0.03, alpha: 1))
            let m = s.holder
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: m * H))
            ctx.fill(CGRect(x: 0, y: H - m * H, width: W, height: m * H))
            ctx.fill(CGRect(x: 0, y: 0, width: m * W, height: H))
            ctx.fill(CGRect(x: W - m * W, y: 0, width: m * W, height: H))
        }
    }
    // film grain: noise on every pixel
    for i in stride(from: 0, to: buf.count, by: 4) {
        let n = Int((Double.random(in: -1...1, using: &rng) + Double.random(in: -1...1, using: &rng)) * 3)
        for c in 0..<3 { buf[i + c] = UInt8(clamping: Int(buf[i + c]) + n) }
    }
    let provider = CGDataProvider(data: Data(buf) as CFData)!
    let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let orange = (0.93, 0.62, 0.30), dark = (0.05, 0.05, 0.05)
let specs: [Spec] = [
    Spec(name: "0001_neg_bright_holder", w: 2048, h: 1365, border: orange, l: 0.08, t: 0.06, r: 0.10, b: 0.12, holder: 0.025, negative: true, seed: 11),
    Spec(name: "0002_pos_dark",          w: 2048, h: 1365, border: dark,   l: 0.07, t: 0.09, r: 0.06, b: 0.05, seed: 22),
    Spec(name: "0003_pos_tilted",        w: 2048, h: 1365, border: dark,   l: 0.09, t: 0.08, r: 0.09, b: 0.08, tilt: 0.8, seed: 33),
    Spec(name: "0004_neg_portrait",      w: 1365, h: 2048, border: orange, l: 0.06, t: 0.10, r: 0.07, b: 0.09, negative: true, seed: 44),
    Spec(name: "0005_neg_tilted_holder", w: 2048, h: 1365, border: orange, l: 0.05, t: 0.04, r: 0.05, b: 0.04, tilt: -0.8, holder: 0.015, negative: true, seed: 55),
    Spec(name: "0006_wide_border",       w: 2048, h: 1365, border: dark,   l: 0.15, t: 0.12, r: 0.15, b: 0.12, seed: 66),
    Spec(name: "0007_no_border",         w: 2048, h: 1365, border: dark,   l: 0.0, t: 0.0, r: 0.0, b: 0.0, seed: 77),
]
// real frames are 3:2 (2:3 in portrait scans): derive the bottom margin from the other three
let specs32: [Spec] = specs.map { s in
    var s = s
    let a = s.w >= s.h ? 1.5 : 1.0 / 1.5
    let fw = (1 - s.l - s.r) * Double(s.w)
    s.b = 1 - s.t - (fw / a) / Double(s.h)
    return s
}
var expected = ""
for s in specs32 {
    render(s, to: out.appendingPathComponent(s.name + ".jpg"))
    expected += "\(s.name),\(s.l),\(s.t),\(s.r),\(s.b),\(s.tilt)\n"
}
try! expected.write(to: out.appendingPathComponent("expected.csv"), atomically: true, encoding: .utf8)
print("wrote \(specs.count) images to \(out.path)")
