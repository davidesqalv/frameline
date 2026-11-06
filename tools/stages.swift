// The pipeline pictures in the README: one scan going through the detector,
// drawn with the detector's own functions. Built by tools/stages.sh, which
// compiles this file together with detect/main.swift minus its command-line
// part. Writes each stage (1-gray.png ... 6-frame.png) and the two strips the
// README shows (pipeline-1.png: stages 1-3, pipeline-2.png: stages 4-6) to
// <outdir>.
import AppKit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let p = Params()
var p0 = Params(); p0.inset = 0
let g = loadGray(url, longSide: p.workLongSide)!
let W = g.w, H = g.h
let names = ["L", "T", "R", "B"]

// ---------- the two passes, recomputed with the detector's functions ----------
struct Pass { var sides: [SideView]; var runs: [[Run]]; var mag: [Float]; var thr: Float; var edges: [Bool] }
func pass(_ g: Gray) -> Pass {
    let mag = gradientMagnitude(g)
    let thr = percentile(mag, p.percentile)
    let edges = mag.map { $0 > thr }
    let (c, r) = supports(edges: edges, w: g.w, h: g.h, smear: 0)
    let sides = makeSides(g, edges: edges, colR: c, rowR: r)
    return Pass(sides: sides, runs: sides.map { uniformRuns($0, p: p) }, mag: mag, thr: thr, edges: edges)
}
let outer = analyzeGray(g, params: p)
let P1 = pass(g)
var outerCopy = outer
guard let inner = peel(g, outer: &outerCopy, params: p, dump: false) else { fatalError("no peel") }
let ol = inner.dbg.outline                       // where the rebate begins, lines from the rim
let sub = crop(g, x0: ol[0], y0: ol[1], x1: W - ol[2], y1: H - ol[3])
let P2 = pass(sub)
let (det, fdbg) = finish(inner, params: p0, prior: [nil, nil, nil, nil])
guard let frame = det else { fatalError("no frame") }

// ---------- drawing helpers ----------
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func canvas() -> CGContext {
    let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(H)); c.scaleBy(x: 1, y: -1)   // y down, like the detector
    return c
}
var shots: [String: CGImage] = [:]
func write(_ img: CGImage, _ name: String) {
    let d = CGImageDestinationCreateWithURL(outDir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}
func save(_ c: CGContext, _ name: String) {
    let img = c.makeImage()!
    shots[name] = img
    write(img, name)
}
func grayImage(_ px: [Float], _ w: Int, _ h: Int, map: (Float) -> Float = { $0 }) -> CGImage {
    var b = [UInt8](repeating: 0, count: w * h)
    for i in 0..<(w * h) { b[i] = UInt8(max(0, min(255, map(px[i])))) }
    let prov = CGDataProvider(data: Data(b) as CFData)!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                   provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
// images are drawn flipped back so they appear upright in the y-down context
func drawImage(_ c: CGContext, _ img: CGImage, _ r: CGRect) {
    c.saveGState(); c.translateBy(x: r.minX, y: r.maxY); c.scaleBy(x: 1, y: -1)
    c.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height)); c.restoreGState()
}
let colorSrc = CGImageSourceCreateWithURL(url as CFURL, nil)!
let color = CGImageSourceCreateImageAtIndex(colorSrc, 0, nil)!
func rgb(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: a)
}
let amber = 0xF2A33A as UInt32, sky = 0x5CC8E8 as UInt32, rose = 0xE8607A as UInt32
let full = CGRect(x: 0, y: 0, width: W, height: H)

/// A band of lines [a, b) along side k of a w x h area placed at (ox, oy).
func band(_ k: Int, _ a: Int, _ b: Int, w: Int, h: Int, ox: Int = 0, oy: Int = 0) -> CGRect {
    switch k {
    case 0: return CGRect(x: ox + a, y: oy, width: b - a, height: h)
    case 1: return CGRect(x: ox, y: oy + a, width: w, height: b - a)
    case 2: return CGRect(x: ox + w - b, y: oy, width: b - a, height: h)
    default: return CGRect(x: ox, y: oy + h - b, width: w, height: b - a)
    }
}
/// The line at distance e from the rim on side k, as a segment across the area.
func edgeLine(_ c: CGContext, _ k: Int, _ e: Int, w: Int, h: Int, ox: Int = 0, oy: Int = 0) {
    let v = CGFloat(e) + 0.5
    switch k {
    case 0: c.move(to: CGPoint(x: CGFloat(ox) + v, y: CGFloat(oy))); c.addLine(to: CGPoint(x: CGFloat(ox) + v, y: CGFloat(oy + h)))
    case 1: c.move(to: CGPoint(x: CGFloat(ox), y: CGFloat(oy) + v)); c.addLine(to: CGPoint(x: CGFloat(ox + w), y: CGFloat(oy) + v))
    case 2: c.move(to: CGPoint(x: CGFloat(ox + w) - v, y: CGFloat(oy))); c.addLine(to: CGPoint(x: CGFloat(ox + w) - v, y: CGFloat(oy + h)))
    default: c.move(to: CGPoint(x: CGFloat(ox), y: CGFloat(oy + h) - v)); c.addLine(to: CGPoint(x: CGFloat(ox + w), y: CGFloat(oy + h) - v))
    }
}

// 1. the scan as the detector reads it: gray, at most 900 px on the long side
do { let c = canvas(); drawImage(c, grayImage(g.px, W, H), full); save(c, "1-gray.png") }

// 2. gradient magnitude, and the strongest 5 % as edge pixels
do {
    let c = canvas()
    let thr = P1.thr
    drawImage(c, grayImage(P1.mag, W, H) { min(150, $0 / thr * 90) }, full)
    c.setFillColor(rgb(amber))
    for y in 0..<H { for x in 0..<W where P1.edges[y * W + x] { c.fill(CGRect(x: x, y: y, width: 1, height: 1)) } }
    save(c, "2-edges.png")
}

// 3. pass 1: uniform runs walking in from each side; the light table is the outer tone
func drawRuns(_ c: CGContext, _ P: Pass, level: Float, w: Int, h: Int, ox: Int, oy: Int) {
    for k in 0..<4 {
        for r in P.runs[k] {
            let isBorder = abs(r.level - level) <= p.levelTol
            c.setFillColor(rgb(isBorder ? amber : sky, 0.42))
            c.fill(band(k, r.start, r.end, w: w, h: h, ox: ox, oy: oy))
        }
    }
}
do {
    let c = canvas()
    drawImage(c, grayImage(g.px, W, H) { $0 * 0.55 }, full)
    drawRuns(c, P1, level: outer.dbg.level, w: W, h: H, ox: 0, oy: 0)
    c.setStrokeColor(rgb(0xFFFFFF)); c.setLineWidth(2); c.setLineDash(phase: 0, lengths: [6, 4])
    for k in 0..<4 { if let e = outer.sides[k].edge, e > 0 { edgeLine(c, k, e, w: W, h: H) } }
    c.strokePath()
    save(c, "3-pass1.png")
}

// 4. the rebate ring just inside the outline, and where pass 2 will run
let measured = (0..<4).filter { ["run", "soft", "subtle", "partial"].contains(outer.sides[$0].method) && outer.sides[$0].edge != nil }
do {
    let c = canvas()
    drawImage(c, color, full)
    c.setFillColor(rgb(0x000000, 0.45)); c.fill(full)
    let sx0 = ol[0], sy0 = ol[1], sw = W - ol[0] - ol[2], sh = H - ol[1] - ol[3]
    c.setFillColor(rgb(amber, 0.85))
    for k in measured { c.fill(band(k, ol[k], ol[k] + p.peelBand, w: W, h: H)) }
    c.setStrokeColor(rgb(0xFFFFFF)); c.setLineWidth(2); c.setLineDash(phase: 0, lengths: [6, 4])
    c.stroke(CGRect(x: sx0, y: sy0, width: sw, height: sh).insetBy(dx: 1, dy: 1))
    save(c, "4-ring.png")
}

// 5. pass 2 inside the outline: runs of the rebate tone, and the frame edges found
do {
    let c = canvas()
    drawImage(c, grayImage(g.px, W, H) { $0 * 0.3 }, full)
    let r = CGRect(x: ol[0], y: ol[1], width: sub.w, height: sub.h)
    drawImage(c, grayImage(sub.px, sub.w, sub.h) { $0 * 0.6 }, r)
    drawRuns(c, P2, level: inner.dbg.level, w: sub.w, h: sub.h, ox: ol[0], oy: ol[1])
    c.setLineWidth(3)
    for k in 0..<4 {
        guard let e = inner.sides[k].edge else { continue }
        let subtle = inner.sides[k].method == "subtle"
        c.setStrokeColor(rgb(subtle ? rose : 0xFFFFFF))
        c.setLineDash(phase: 0, lengths: subtle ? [8, 5] : [])
        edgeLine(c, k, e, w: W, h: H)
        c.strokePath()
    }
    save(c, "5-pass2.png")
}

// 6. the frame, 3:2, on the colour scan
do {
    let c = canvas()
    drawImage(c, color, full)
    let fr = CGRect(x: frame.l * Double(W), y: frame.t * Double(H),
                    width: (1 - frame.l - frame.r) * Double(W), height: (1 - frame.t - frame.b) * Double(H))
    c.addRect(full); c.addRect(fr); c.setFillColor(rgb(0x000000, 0.6)); c.fillPath(using: .evenOdd)
    c.setStrokeColor(rgb(0xFFFFFF)); c.setLineWidth(2); c.stroke(fr)
    save(c, "6-frame.png")
}

print("pass 1 border tone \(Int(outer.dbg.level)), outline \(ol); pass 2 border tone \(Int(inner.dbg.level)), edges \(inner.sides.map { "\($0.edge.map(String.init) ?? "-") \($0.method)" }); frame \(frame), aspect \(fdbg.aspect)")

// ---------- the two strips the README shows: three stages each, with arrows ----------
func strip(_ heading: String, _ items: [(no: Int, shot: String, title: String, note: String)], _ name: String) {
    let SW = 2560.0, SH = 860.0
    let tw = 700.0, th = tw * Double(H) / Double(W), gap = 150.0
    let x0 = (SW - (3 * tw + 2 * gap)) / 2
    let ty = SH - 170 - th                          // thumbnails' bottom edge (y up)
    let c = CGContext(data: nil, width: Int(SW), height: Int(SH), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    let bg = rgb(0x151311), ink = rgb(0xEEE9E1), muted = rgb(0x8E877D), accent = rgb(0xF2A33A)
    c.setFillColor(bg); c.fill(CGRect(x: 0, y: 0, width: SW, height: SH))
    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: CGColor, kern: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                   .foregroundColor: NSColor(cgColor: color)!, .kern: kern])
    }
    text(heading.uppercased(), 34, .semibold, muted, kern: 4).draw(at: CGPoint(x: x0, y: SH - 100))
    for (i, it) in items.enumerated() {
        let x = x0 + Double(i) * (tw + gap)
        let r = CGRect(x: x, y: ty, width: tw, height: th)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0x000000, 0.6))
        c.setFillColor(rgb(0x000000)); c.fill(r)
        c.restoreGState()
        c.draw(shots[it.shot]!, in: r)
        // number badge on the top-left corner
        let bc = CGPoint(x: x, y: ty + th), br = 38.0
        c.setFillColor(bg); c.fillEllipse(in: CGRect(x: bc.x - br, y: bc.y - br, width: 2 * br, height: 2 * br))
        c.setStrokeColor(accent); c.setLineWidth(4)
        c.strokeEllipse(in: CGRect(x: bc.x - br, y: bc.y - br, width: 2 * br, height: 2 * br))
        let n = text("\(it.no)", 40, .bold, ink)
        n.draw(at: CGPoint(x: bc.x - n.size().width / 2, y: bc.y - n.size().height / 2))
        text(it.title, 48, .semibold, ink).draw(at: CGPoint(x: x, y: ty - 78))
        text(it.note, 38, .regular, muted).draw(at: CGPoint(x: x, y: ty - 132))
        if i < items.count - 1 {
            let ay = ty + th / 2, a0 = x + tw + 38, a1 = x + tw + gap - 38
            c.setStrokeColor(muted); c.setLineWidth(5); c.setLineCap(.round); c.setLineJoin(.round)
            c.move(to: CGPoint(x: a0, y: ay)); c.addLine(to: CGPoint(x: a1, y: ay))
            c.move(to: CGPoint(x: a1 - 22, y: ay + 22)); c.addLine(to: CGPoint(x: a1, y: ay)); c.addLine(to: CGPoint(x: a1 - 22, y: ay - 22))
            c.strokePath()
        }
    }
    NSGraphicsContext.current = nil
    write(c.makeImage()!, name)
}
let fw = Int(((1 - frame.l - frame.r) * Double(W)).rounded()), fh = Int(((1 - frame.t - frame.b) * Double(H)).rounded())
let mw = W - (inner.sides[0].edge ?? 0) - (inner.sides[2].edge ?? 0), mh = H - (inner.sides[1].edge ?? 0) - (inner.sides[3].edge ?? 0)
strip("Pass 1 · find the film strip", [
    (1, "1-gray.png", "Gray copy", "luma, at most 900 px"),
    (2, "2-edges.png", "Edge pixels", "steepest 5% of the gradient"),
    (3, "3-pass1.png", "Flat runs from each side", "light table ends: strip outline"),
], "pipeline-1.png")
strip("Pass 2 · find the frame inside it", [
    (4, "4-ring.png", "Film inside?", "one-tone ring, picture lighter"),
    (5, "5-pass2.png", "Frame edges", "edge line, or a 2-level step"),
    (6, "6-frame.png", "3:2 frame", "\(mw) × \(mh) → \(fw) × \(fh) px"),
], "pipeline-2.png")
