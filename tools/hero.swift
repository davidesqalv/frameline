// Renders the README headline (docs/hero.jpg): a camera scan with Frameline's
// crop drawn on it -> the cropped, straightened frame, as the plug-in would
// leave it in Lightroom with its default settings (Thin border, 35mm 3:2,
// straighten on; see FLFrame.cropFor).
//
// usage: hero [--bare] <scan.jpg> <csv line from `frameline-detect <dir> --inset 0`> <out.jpg> [tag]
//   swiftc -O tools/hero.swift -o /tmp/hero
//   ./frameline.lrplugin/frameline-detect ~/scans --inset 0 | grep DSC09488
//   /tmp/hero ~/scans/DSC09488.jpg "<that line>" docs/hero.jpg
// (docs/hero.jpg is the author's scan DSC09488, docs/budapest.jpg DSC01431 turned upright.)
// --bare leaves out the title and tagline and fits the canvas to the two
// panels (docs/hero-2.jpg). A scan stored sideways (Lightroom shows it
// rotated) is rotated first, e.g. `sips -r 90 in.jpg --out up/in.jpg`, and
// the detector run on the rotated copy, as the plug-in sees the photo as
// displayed. The tag, when given, is printed in the top-right corner (for
// comparing options).
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let bare = CommandLine.arguments.contains("--bare")
let args = CommandLine.arguments.filter { $0 != "--bare" }
guard args.count >= 4 else {
    print("usage: hero [--bare] <scan.jpg> <detector csv line, --inset 0> <out.jpg> [tag]"); exit(1)
}
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
// name,left,top,right,bottom,status,sides,angle,avail(l/t/r/b),film
let f = args[2].split(separator: ",").map(String.init)
let edge = (l: Double(f[1])!, t: Double(f[2])!, r: Double(f[3])!, b: Double(f[4])!)
let tiltDeg = Double(f[7])!
let av = f[8].split(separator: "/").map { Double($0)! }
let avail = (l: av[0], t: av[1], r: av[2], b: av[3])
let outPath = args[3]
let tag = args.count > 4 ? args[4] : nil

// ---- the plug-in's crop (FLFrame.cropFor, no sprockets) ----
let border = 0.5                 // percent: the default "Thin border"
let MIN_VISIBLE_BORDER = 0.4, HOLDER_TOLERANCE = 0.4
let fallback = [avail.l, avail.t, avail.r, avail.b].filter { $0 > 0 }.min()
func most(_ a: Double) -> Double? {
    guard let v = a > 0 ? a : fallback else { return nil }
    return max(0, v * 100 - 0.3)
}
func stretch(_ a: Double, _ inset: Double) -> Double? {
    guard let v = a > 0 ? a : fallback else { return nil }
    return max(0, min(v * 100 + HOLDER_TOLERANCE, inset * 100) - 0.3)
}
func axisBorder(_ a1: Double, _ a2: Double, _ i1: Double, _ i2: Double, _ want: Double) -> Double {
    guard want > 0 else { return want }
    var allowed = want
    if let m1 = most(a1) { allowed = min(allowed, m1) }
    if let m2 = most(a2) { allowed = min(allowed, m2) }
    if allowed < MIN_VISIBLE_BORDER {
        var more = want
        if let s1 = stretch(a1, i1) { more = min(more, s1) }
        if let s2 = stretch(a2, i2) { more = min(more, s2) }
        allowed = max(allowed, more)
    }
    return min(want, allowed)
}
func m(_ v: Double, _ b: Double) -> Double { max(0, min(0.45, v - b / 100)) }
let bx = axisBorder(avail.l, avail.r, edge.l, edge.r, border)
let by = axisBorder(avail.t, avail.b, edge.t, edge.b, border)
let L = m(edge.l, bx), T = m(edge.t, by), R = m(edge.r, bx), B = m(edge.b, by)

let iw = Double(img.width), ih = Double(img.height)
// crop box in image pixels, y up; the 3:2 rule trims the too-long axis, centred
var bw = iw * (1 - L - R), bh = ih * (1 - T - B)
let A = iw >= ih ? 1.5 : 1 / 1.5
if bw > bh * A { bw = bh * A } else if bh > bw / A { bh = bw / A }
let c = CGPoint(x: iw * (L + (1 - L - R) / 2), y: ih * (1 - (T + (1 - T - B) / 2)))
// the detector's tilt is clockwise-on-screen positive; in y-up radians the frame sits at -tilt
let tilt = abs(tiltDeg) < 0.05 ? 0 : tiltDeg * .pi / 180
let frameRot = -tilt

// ---- layout: the two panels share a height, the row is centred ----
let gap = 210.0, maxRow = 2560.0 - 2 * 140, bandH = bare ? 900.0 : 735.0, bandY = 150.0
let rb = iw / ih, ra = bw / bh
let panelH = min(bandH, (maxRow - gap) / (rb + ra))
let beforeW = panelH * rb, afterW = panelH * ra
let rowW = beforeW + gap + afterW

// ---- canvas: 2:1 with the header (doubles as GitHub's social preview), else fitted to the row ----
let W = bare ? (rowW + 2 * 140).rounded() : 2560.0
let H = bare ? bandY + bandH + 110 : 1280.0
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func rgb(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255, alpha: alpha)
}
let bg = rgb(0x151311), ink = rgb(0xEEE9E1), muted = rgb(0x8E877D), rule = rgb(0x3A3631)

ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0x221F1B), rgb(0x151311)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W * 0.55, y: H * 0.42), startRadius: 0,
                       endCenter: CGPoint(x: W * 0.55, y: H * 0.42), endRadius: W * 0.62, options: [])

func text(_ s: String, _ font: NSFont, _ color: CGColor, kern: Double = 0) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: kern])
}
let titleText = text("Frameline", NSFont.systemFont(ofSize: 118, weight: .semibold), ink, kern: -2.5)
let tagline = text("Finds the film frame in camera scans and crops it in Lightroom Classic.",
                   NSFont.systemFont(ofSize: 42, weight: .regular), muted)
let labelFont = NSFont.systemFont(ofSize: 25, weight: .semibold)

let x0 = (W - rowW) / 2
let panelY = bandY + (bandH - panelH) / 2
let before = CGRect(x: x0, y: panelY, width: beforeW, height: panelH)
let after = CGRect(x: x0 + beforeW + gap, y: panelY, width: afterW, height: panelH)
// the header lines up with the row, unless the row is too narrow for the tagline
let headerX = min(x0, W - 150 - tagline.size().width)

func shadow(_ r: CGRect) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(0x000000, 0.55))
    ctx.setFillColor(rgb(0x000000)); ctx.fill(r)
    ctx.restoreGState()
}

// BEFORE: the scan, the outside of the crop dimmed, the crop outline with corner handles
shadow(before)
ctx.draw(img, in: before)
let k = beforeW / iw
let pc = CGPoint(x: before.minX + c.x * k, y: before.minY + c.y * k)
let hw = bw * k / 2, hh = bh * k / 2
func rotated(_ dx: Double, _ dy: Double) -> CGPoint {
    CGPoint(x: pc.x + dx * cos(frameRot) - dy * sin(frameRot), y: pc.y + dx * sin(frameRot) + dy * cos(frameRot))
}
let corners = [rotated(-hw, -hh), rotated(hw, -hh), rotated(hw, hh), rotated(-hw, hh)]
let cropPath = CGMutablePath(); cropPath.addLines(between: corners); cropPath.closeSubpath()
ctx.saveGState()
ctx.addRect(before); ctx.addPath(cropPath)
ctx.setFillColor(rgb(0x000000, 0.52)); ctx.fillPath(using: .evenOdd)
ctx.addPath(cropPath); ctx.setStrokeColor(rgb(0xFFFFFF, 0.9)); ctx.setLineWidth(2); ctx.strokePath()
let hl = 34.0 * min(1, panelH / bandH)
ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(6); ctx.setLineCap(.square)
for (i, p) in corners.enumerated() {
    let next = corners[(i + 1) % 4], prev = corners[(i + 3) % 4]
    func toward(_ q: CGPoint) -> CGPoint {
        let d = hypot(q.x - p.x, q.y - p.y); return CGPoint(x: p.x + (q.x - p.x) / d * hl, y: p.y + (q.y - p.y) / d * hl)
    }
    ctx.move(to: toward(prev)); ctx.addLine(to: p); ctx.addLine(to: toward(next))
}
ctx.strokePath()
ctx.restoreGState()

// AFTER: the crop, straightened
shadow(after)
ctx.saveGState()
ctx.clip(to: after)
ctx.translateBy(x: after.midX, y: after.midY)
ctx.scaleBy(x: panelH / bh, y: panelH / bh)
ctx.rotate(by: -frameRot)
ctx.translateBy(x: -c.x, y: -c.y)
ctx.draw(img, in: CGRect(x: 0, y: 0, width: iw, height: ih))
ctx.restoreGState()

// arrow between the panels
let ay = panelY + panelH / 2, ax0 = before.maxX + 62, ax1 = after.minX - 62
ctx.saveGState()
ctx.setStrokeColor(muted); ctx.setLineWidth(4); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: ax0, y: ay)); ctx.addLine(to: CGPoint(x: ax1, y: ay))
ctx.move(to: CGPoint(x: ax1 - 22, y: ay + 22)); ctx.addLine(to: CGPoint(x: ax1, y: ay)); ctx.addLine(to: CGPoint(x: ax1 - 22, y: ay - 22))
ctx.strokePath()
ctx.restoreGState()

// header, labels and a thin rule between them
if !bare {
    titleText.draw(at: CGPoint(x: headerX - 6, y: H - 230))
    tagline.draw(at: CGPoint(x: headerX, y: H - 296))
    let ruleRight = max(x0 + rowW, headerX + tagline.size().width)
    ctx.setFillColor(rule)
    ctx.fill(CGRect(x: min(headerX, x0), y: 943, width: ruleRight - min(headerX, x0), height: 2))
}
text("CAMERA SCAN", labelFont, muted, kern: 3.5).draw(at: CGPoint(x: before.minX, y: panelY - 62))
text(tilt == 0 ? "CROPPED" : "CROPPED AND STRAIGHTENED", labelFont, muted, kern: 3.5)
    .draw(at: CGPoint(x: after.minX, y: panelY - 62))
if let tag {
    let t = text(tag, NSFont.monospacedSystemFont(ofSize: 34, weight: .medium), rgb(0xE8B04A))
    t.draw(at: CGPoint(x: W - 70 - t.size().width, y: H - 90))
}

NSGraphicsContext.current = nil
let out = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)  border x \(bx)% y \(by)%  crop \(Int(bw))x\(Int(bh))  tilt \(tiltDeg)")
