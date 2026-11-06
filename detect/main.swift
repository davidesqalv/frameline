// frameline-detect
//
// Finds the film frame inside a camera-scanned negative or positive and writes
// normalized crop margins to results.csv. Zero dependencies: JPEG decoding is
// done by macOS ImageIO, everything else is plain Swift.
//
// Usage:
//   frameline-detect <folder> [--preview [outdir]] [--debug] [--inset -0.005]
//                    [--tol 14] [--max-border 0.18] [--percentile 95] [--min-area 0.30]
//
// Reads every *.jpg / *.jpeg in <folder> (sorted by name) and writes
// <folder>/results.csv with one line per image:
//
//   index,left,top,right,bottom,status
//
// index is the file name without extension; left/top/right/bottom are 0-1
// margins measured inward from each image edge; status is "ok" or "skip".
// Exit code is 0 when results.csv was written.
//
// --preview writes a copy of each image with the detected crop drawn on it
// (green box, border dimmed; red frame = skipped) into <folder>/_previews or
// the given outdir. --debug prints the per-side detection details.
//
// How it works
//   Scans always show, from the outside in: the holder (if visible), the
//   film border, then the picture. The border is unexposed film, so it is the
//   most extreme tone in the image: black on converted positives, bright on
//   unconverted negatives; the holder is the opposite extreme.
//   1. Grayscale at 900px long side. For each side, walk inward line by
//      line (columns for left/right, rows for top/bottom) and split the lines
//      into runs that are uniform (most pixels within a tolerance of the
//      line median) and extreme-toned.
//   2. The border is the innermost such run that starts near the rim; the
//      polarity (dark/bright) is decided by a vote across the four sides so
//      one confused side cannot pick the holder.
//   3. The edge is where that run ends, snapped to the strongest nearby line
//      of gradient-edge pixels (top 5% of gradient magnitudes), preferring
//      the innermost strong one so a glow strip between border and picture
//      is excluded. Sides with no border run at the rim are already cropped
//      and get no margin; a run wider than max-border is treated as unknown.

import Foundation
import CoreGraphics
import ImageIO

// MARK: - Tunables

struct Params {
    var workLongSide = 900          // analysis size (long side, px)
    var percentile = 95.0           // gradient-magnitude percentile that defines "edge" pixels
    var inset = -0.005              // crop offset from the detected edge: negative shows that much border, positive cuts inside
    var minArea = 0.30              // reject if the crop keeps < 30% of the image
    var borderTol: Float = 14       // a line is uniform when most pixels sit within this of its median
    var uniformMin: Float = 0.8     // ...and "most" means this fraction
    var jumpTol: Float = 10         // a median drift larger than this starts a new run
    var levelTol: Float = 15        // runs within this of the border tone count as border
    var flatMax: Float = 3          // a border run's first lines vary at most this many levels
    var toneMargin: Float = 5       // a later run replaces an outer one only when this much closer to the border tone
    var minRun = 3                  // runs shorter than this many lines are noise
    var gapMax = 6                  // same-toned runs this close are bridged (ragged film edge)
    var partialSegments = 12        // segments per side for the partial-edge fallback
    var partialAgree = 3            // segments within this many lines of each other agree
    var subtleRef = 6               // border lines used to measure its own noise
    var subtleWindow = 4            // lines averaged on each side of a candidate step
    var subtleMinStep: Float = 2    // a step must be at least this many levels...
    var subtleSigmas: Float = 4     // ...and this many times the border noise
    var subtleNoiseFloor: Float = 0.4
    var refineFraction: Float = 0.4 // an edge sits where the line mean has gone this far from border tone to picture tone
    var refineOut = 6               // ...looked for this many lines outside the edge as found...
    var refineIn = 8                // ...and this many inside
    var refineMinContrast: Float = 10 // ...only when picture and border differ by at least this much
    var splitMin: Float = 0.35      // an edge line this strong ends a run (border meeting same-toned content)
    var borderStart = 0.10          // the border run must begin within this outer fraction
    var maxBorder = 0.22            // and end within this one, else the side is left uncropped
    var plausibleBorder = 0.12      // a soft edge further in than this is not a border
    var peelPlausibleBorder = 0.20  // ...measured from the film outline inside a full-border scan (sprocket sides run to ~16%)
    var snapMin: Float = 0.15       // minimum edge-pixel fraction for a line to snap to
    var aspect = 1.5                // film frame aspect (long/short side); 0 disables geometry
    var aspectTol = 0.02            // flag the photo when the crop aspect is further off than this
    var inferredInset = 0.0         // extra offset on a side placed by geometry
    var inferOutMax = 0.012         // geometry may move a measured side outward by at most this fraction
    var ratioSlop = 0.005           // a shape residual up to this fraction of the axis (or 4 lines) is measurement slop: shared equally
    var strongSnap: Float = 0.4     // a seen edge whose edge line is at least this strong outranks a weaker one when the shape is off
    var placedMin = 0.01            // a side the shape rule moves by more than this fraction of the axis (or 8 lines) counts as placed, not seen
    var priorMin = 3                // sides seen firmly on at least this many photos form the batch prior
    var angleWindow = 10            // lines either side of the edge searched for the edge line (a 1 degree tilt spans 8 lines over 900)
    var angleMinSupport: Float = 0.15 // the edge line needs at least this fraction of the side length in edge pixels
    var angleMax = 3.0              // larger tilts are not trusted and reported as 0
    var angleAgree = 0.35           // sides within this many degrees of each other agree on the tilt
    var angleAloneQuality = 0.8     // a single side may set the tilt when its edge line has at least this many inlier px per px of length
    var angleLongSideWeight = 2.0   // the frame's long sides count this much more in the tilt vote
    var angleMinBorder = 0.010      // a side with less border than this (fraction) fits the tilt badly
    var sprocketUniMax: Float = 0.7 // a line through the sprocket holes is at most this uniform
    var peelInset = 3               // lines skipped inside the film outline before the second pass
    var peelBand = 4                // lines sampled just inside the outline to see the rebate ring
    var peelBandUni: Float = 0.6    // ...which may carry edge printing and frame numbers, so this uniform is enough
    var peelSkipMax = 25            // lines of soft holder edge (a ramp, uneven under a vignette) skipped before the band
    var peelKeptMax = 0.65          // a first-pass frame keeping less of the scan than this may be a film outline (flag when unconfirmed)
    var peelInterior = 0.15         // the picture sampled inside the outline, inset by this fraction
    var peelOutside = 0.02          // at most this fraction of the picture may lie beyond the rebate tone
    var borders = 0.0               // previews only: draw the film-borders rectangle of this ratio (0 = off)
}

struct Detection {
    var l: Double, t: Double, r: Double, b: Double
}

struct SideDebug {
    var edge: Int? = nil
    var method = "none"             // run | soft | inferred | too wide | no border
    var snap: Float = 0
    var runs = ""
    var avail: Double = 0           // border width available outside the edge, fraction of the image
    var film: Double = 0            // how far the film itself continues outside the edge (sprockets and all), fraction
    var filmEnd: Int? = nil         // the line (from the rim) where the film ends; nil = not known
    var runStart = 0                // where the border run began (from the rim), to re-measure avail
}

struct DebugInfo {
    var w = 0, h = 0
    var threshold: Float = 0
    var dark = true
    var level: Float = -1
    var aspect = 0.0
    var angle = 0.0                 // frame tilt in degrees, clockwise on screen positive
    var sideAngles: [Double?] = []
    var angleNote = ""
    var check: [String] = []
    var sides: [SideDebug] = []     // L, T, R, B
    var kept: Double = 0
    var reason = ""
    var dump = ""
    var peeled = false              // the frame was found inside the film's outline (second pass)
    var outline: [Int] = []         // that outline, L/T/R/B lines from the rim (0 = the scan's edge)
    var peelNote = ""               // why the second pass was not taken, when a rebate ring was seen
    var peelTrace = ""              // why no rebate ring was seen (diagnostic only)
}

// MARK: - Image loading

struct Gray {
    let w: Int
    let h: Int
    let px: [Float]
}

/// Decode the image, convert to 8-bit gray and downscale so the long side is
/// `longSide` px (never upscale). Bitmap-context rows come out top-to-bottom.
func loadGray(_ url: URL, longSide: Int) -> Gray? {
    let opts = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
          let img = CGImageSourceCreateImageAtIndex(src, 0, opts) else { return nil }
    let w0 = img.width, h0 = img.height
    guard w0 > 0, h0 > 0 else { return nil }
    let scale = Double(longSide) / Double(max(w0, h0))
    var w = w0, h = h0
    if scale < 1.0 {
        w = max(1, Int((Double(w0) * scale).rounded()))
        h = max(1, Int((Double(h0) * scale).rounded()))
    }
    var buf = [UInt8](repeating: 0, count: w * h)
    let drawn: Bool = buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drawn else { return nil }
    return Gray(w: w, h: h, px: buf.map { Float($0) })
}

// MARK: - Edge map

/// np.gradient-style magnitude: central differences inside, one-sided at the borders.
func gradientMagnitude(_ g: Gray) -> [Float] {
    let w = g.w, h = g.h
    var mag = [Float](repeating: 0, count: w * h)
    g.px.withUnsafeBufferPointer { p in
        mag.withUnsafeMutableBufferPointer { m in
            for y in 0..<h {
                let ym = y == 0 ? 0 : y - 1
                let yp = y == h - 1 ? h - 1 : y + 1
                let dy: Float = (y == 0 || y == h - 1) ? 1 : 2
                let row = y * w
                for x in 0..<w {
                    let xm = x == 0 ? 0 : x - 1
                    let xp = x == w - 1 ? w - 1 : x + 1
                    let dx: Float = (x == 0 || x == w - 1) ? 1 : 2
                    let gy = (p[yp * w + x] - p[ym * w + x]) / dy
                    let gx = (p[row + xp] - p[row + xm]) / dx
                    m[row + x] = (gx * gx + gy * gy).squareRoot()
                }
            }
        }
    }
    return mag
}

/// np.percentile with linear interpolation.
func percentile(_ values: [Float], _ p: Double) -> Float {
    let n = values.count
    if n == 0 { return 0 }
    let s = values.sorted()
    let rank = p / 100.0 * Double(n - 1)
    let lo = Int(rank.rounded(.down))
    let hi = min(lo + 1, n - 1)
    let frac = Float(rank - Double(lo))
    return s[lo] + (s[hi] - s[lo]) * frac
}

/// col[x] = fraction of rows in which an edge pixel lies within `k` px of column x.
/// row[y] = fraction of columns in which an edge pixel lies within `k` px of row y.
func supports(edges: [Bool], w: Int, h: Int, smear k: Int) -> (col: [Float], row: [Float]) {
    var colCount = [Int32](repeating: 0, count: w)
    var rowCount = [Int32](repeating: 0, count: h)
    var line = [Bool](repeating: false, count: max(w, h))

    for y in 0..<h {
        for i in 0..<w { line[i] = false }
        let base = y * w
        for x in 0..<w where edges[base + x] {
            for xx in max(0, x - k)...min(w - 1, x + k) { line[xx] = true }
        }
        for x in 0..<w where line[x] { colCount[x] += 1 }
    }
    for x in 0..<w {
        for i in 0..<h { line[i] = false }
        for y in 0..<h where edges[y * w + x] {
            for yy in max(0, y - k)...min(h - 1, y + k) { line[yy] = true }
        }
        for y in 0..<h where line[y] { rowCount[y] += 1 }
    }
    return (colCount.map { Float($0) / Float(h) }, rowCount.map { Float($0) / Float(w) })
}

// MARK: - Per-side search

/// One side of the image seen in "distance from the edge" coordinates:
/// line i = 0 is the outermost column (or row), i grows inward.
struct SideView {
    let n: Int                      // number of lines (image width for left/right, height for top/bottom)
    let len: Int                    // pixels per line
    let raw: [Float]                // edge-pixel fraction per line
    let lum: (Int, Int) -> Float    // (line, position) -> luminance
    let edge: (Int, Int) -> Bool    // (line, position) -> is an edge pixel
}

func makeSides(_ g: Gray, edges: [Bool], colR: [Float], rowR: [Float]) -> [SideView] {
    let w = g.w, h = g.h, px = g.px
    let left   = SideView(n: w, len: h, raw: colR, lum: { i, j in px[j * w + i] }, edge: { i, j in edges[j * w + i] })
    let top    = SideView(n: h, len: w, raw: rowR, lum: { i, j in px[i * w + j] }, edge: { i, j in edges[i * w + j] })
    let right  = SideView(n: w, len: h, raw: Array(colR.reversed()), lum: { i, j in px[j * w + (w - 1 - i)] },
                          edge: { i, j in edges[j * w + (w - 1 - i)] })
    let bottom = SideView(n: h, len: w, raw: Array(rowR.reversed()), lum: { i, j in px[(h - 1 - i) * w + j] },
                          edge: { i, j in edges[(h - 1 - i) * w + j] })
    return [left, top, right, bottom]
}

/// Tilt of one side's frame edge: the straight line through the most edge
/// pixels in a narrow band around the detected edge. The frame edge is the
/// longest straight line there; picture that matches the border tone simply
/// contributes no edge pixels, and a side with no visible edge returns nil
/// rather than a guess. Slope is in lines per pixel along the side.
/// Returns the slope and a quality: inlier edge pixels per unit of side
/// length (a clean full-length edge scores well above 1).
func sideSlope(_ s: SideView, e: Int, availLines: Int, p: Params) -> (slope: Double, quality: Double)? {
    // never reach outward into the ragged holder edge, a long straight line at
    // the scan's own angle, not the film's
    let out = availLines > 0 ? min(p.angleWindow, max(2, availLines - 3)) : p.angleWindow
    let lo = max(0, e - out), hi = min(s.n - 1, e + p.angleWindow)
    var px: [(Double, Double)] = []
    for i in lo...hi {
        for j in 0..<s.len where s.edge(i, j) { px.append((Double(j), Double(i))) }
    }
    guard px.count >= 20 else { return nil }
    let half = Double(s.len) / 2
    let maxTan = tan(p.angleMax * .pi / 180)
    let steps = Int(2 * p.angleMax / 0.05) + 1
    var best = (count: 0, b: 0.0, i0: 0.0)
    for k in 0..<steps {
        let b = -maxTan + 2 * maxTan * Double(k) / Double(steps - 1)
        var bins: [Int: Int] = [:]
        for (j, i) in px {
            let bin = Int(((i - b * (j - half)) * 2).rounded())
            bins[bin, default: 0] += 1
        }
        if let top = bins.max(by: { $0.value < $1.value }), top.value > best.count {
            best = (top.value, b, Double(top.key) / 2)
        }
    }
    let inl = px.filter { abs($0.1 - (best.i0 + best.b * ($0.0 - half))) <= 1.0 }
    guard inl.count >= max(20, Int(p.angleMinSupport * Float(s.len))) else { return nil }
    let jmin = inl.map { $0.0 }.min()!, jmax = inl.map { $0.0 }.max()!
    guard jmax - jmin >= 0.4 * Double(s.len) else { return nil }
    let mj = inl.map { $0.0 }.reduce(0, +) / Double(inl.count)
    let mi = inl.map { $0.1 }.reduce(0, +) / Double(inl.count)
    var num = 0.0, den = 0.0
    for (j, i) in inl { num += (j - mj) * (i - mi); den += (j - mj) * (j - mj) }
    guard den > 0 else { return nil }
    if ProcessInfo.processInfo.environment["FRAMELINE_TILT_DEBUG"] != nil {
        stderrPrint(String(format: "    tilt side n=%d len=%d e=%d band=[%d..%d] edgepx=%d best=%d inliers=%d span=%.2f i0=%.1f slope=%.4f -> %.2f deg",
                           s.n, s.len, e, lo, hi, px.count, best.count, inl.count, (jmax - jmin) / Double(s.len), best.i0, num / den, atan(num / den) * 180 / .pi))
    }
    return (num / den, Double(inl.count) / Double(s.len))
}

/// Adaptive step for faint edges. Film border is extremely flat line to
/// line (its medians move by a fraction of a level), so a small but sustained
/// shift of the line median marks where clear film becomes barely exposed
/// picture: a night sky on a negative, deep shadow on a positive. The
/// threshold is a multiple of the border's own noise. Returns the first line
/// of the shift, or nil.
func subtleEdge(_ s: SideView, from start: Int, to end: Int, p: Params) -> Int? {
    let k = p.subtleRef, m = p.subtleWindow
    guard end - start >= k + 2 * m + 2 else { return nil }
    var med = [Float](repeating: 0, count: end - start)
    for i in start..<end { med[i - start] = lineProfile(s, i, tol: p.borderTol).med }
    let ref = Array(med[2..<(2 + k)])
    let refMean = ref.reduce(0, +) / Float(k)
    var varSum: Float = 0
    for v in ref { varSum += (v - refMean) * (v - refMean) }
    let sigma = max(p.subtleNoiseFloor, (varSum / Float(k)).squareRoot())
    let threshold = max(p.subtleMinStep, p.subtleSigmas * sigma)
    var i = 2 + k
    while i + m <= med.count {
        let before = med[(i - m)..<i].reduce(0, +) / Float(m)
        let after = med[i..<(i + m)].reduce(0, +) / Float(m)
        if abs(after - before) >= threshold && abs(after - refMean) >= p.subtleMinStep {
            // the line where the shift itself is steepest
            var best = i, bestJump: Float = -1
            for j in max(1, i - 1)..<min(med.count - 1, i + m) {
                let jump = abs(med[j + 1] - med[j])
                if jump > bestJump { bestJump = jump; best = j + 1 }
            }
            return start + best
        }
        i += 1
    }
    // (Texture was tried as a second cue here, the border being flat where
    // picture has grain, and dropped: picture is often just as flat right
    // at the frame edge, so the onset of texture lands inside the picture.)
    return nil
}

/// Fallback for a side whose border runs on into same-toned picture: the
/// side is cut into segments and each is walked inward on its own; where the
/// picture is not border-toned (a shoulder, a patch of sky, the frame's
/// corner) the border stops at the true edge. The edge is the outermost
/// position at least two segments agree on. Returns (edge, agreeing count).
func partialEdge(_ s: SideView, level: Float, p: Params) -> (Int, Int)? {
    let k = p.partialSegments
    let segLen = s.len / k
    guard segLen >= 8 else { return nil }
    let limit = min(s.n, max(2, Int(Double(s.n) * p.maxBorder)))
    var found: [Int] = []
    for seg in 0..<k {
        let j0 = seg * segLen, j1 = j0 + segLen
        var sawBorder = false
        for i in 0..<limit {
            var nb = 0
            for j in j0..<j1 where abs(s.lum(i, j) - level) <= p.borderTol { nb += 1 }
            let frac = Float(nb) / Float(segLen)
            if frac >= 0.7 {
                sawBorder = true
            } else if sawBorder && frac < 0.5 {
                found.append(i)
                break
            }
        }
    }
    guard found.count >= 2 else { return nil }
    found.sort()
    for (idx, t) in found.enumerated() where idx < 4 {
        let agree = found.filter { $0 >= t && $0 <= t + p.partialAgree }.count
        if agree >= 2 { return (t, agree) }
    }
    return nil
}

/// A run of consecutive lines that are uniform and share a tone: film
/// border, the holder around it, or a flat area of the picture (sky).
struct Run {
    var start: Int      // first line
    var end: Int        // one past the last line
    var level: Float    // mean of the line medians
    var level0: Float   // median of the first line; drift is measured against it
    var open: Bool      // still running at the search limit, so its end is unknown
    var hardEnd: Bool   // ended by a strong edge line; never merged across
    var levels: [Float] = []   // line medians, to tell flat film border from a ramp
}

/// Median luminance of line i, the fraction of its pixels within tol of that
/// median, and its spread (10th to 90th percentile: flat film border sits
/// within a few levels, picture has grain and detail).
func lineStats(_ s: SideView, _ i: Int, tol: Float) -> (med: Float, uni: Float, spread: Float) {
    var vals = [Float](repeating: 0, count: s.len)
    for j in 0..<s.len { vals[j] = s.lum(i, j) }
    vals.sort()
    let med = vals[vals.count / 2]
    var n = 0
    for v in vals where abs(v - med) <= tol { n += 1 }
    let spread = vals[vals.count * 9 / 10] - vals[vals.count / 10]
    return (med, Float(n) / Float(vals.count), spread)
}

func lineProfile(_ s: SideView, _ i: Int, tol: Float) -> (med: Float, uni: Float) {
    let t = lineStats(s, i, tol: tol)
    return (t.med, t.uni)
}

/// Walk inward from the rim and collect the uniform runs. A strong edge line
/// ends a run even if the tone continues (border meeting same-toned picture
/// content); small gaps (the ragged film edge) are bridged.
func uniformRuns(_ s: SideView, p: Params) -> [Run] {
    let limit = min(s.n, max(2, Int(Double(s.n) * p.maxBorder)))
    var runs: [Run] = []
    var cur: Run? = nil
    func close(_ c: Run?) {
        if let c = c, c.end - c.start >= p.minRun { runs.append(c) }
    }
    for i in 0..<limit {
        if s.raw[i] >= p.splitMin, var c = cur {
            c.hardEnd = true
            close(c)
            cur = nil
            continue
        }
        let (med, uni) = lineProfile(s, i, tol: p.borderTol)
        let film = uni >= p.uniformMin
        if film, var c = cur, abs(med - c.level0) <= p.jumpTol {
            c.level = (c.level * Float(c.end - c.start) + med) / Float(c.end - c.start + 1)
            c.end = i + 1
            c.levels.append(med)
            // the first line of a run often sits on a transition (surround to
            // rebate); once the run is four lines long its reference tone is
            // the median of lines two to four instead
            if c.levels.count == 4 { c.level0 = c.levels[1...3].sorted()[1] }
            cur = c
        } else {
            close(cur)
            cur = film ? Run(start: i, end: i + 1, level: med, level0: med, open: false, hardEnd: false, levels: [med]) : nil
        }
    }
    if var c = cur { c.open = c.end >= limit; close(c) }

    var merged: [Run] = []
    for r in runs {
        if var last = merged.last, !last.hardEnd,
           r.start - last.end <= p.gapMax, abs(r.level0 - last.level0) <= p.jumpTol {
            last.end = r.end; last.open = r.open; last.hardEnd = r.hardEnd
            last.level = (last.level + r.level) / 2
            last.levels += r.levels
            merged[merged.count - 1] = last
        } else {
            merged.append(r)
        }
    }
    return merged
}

/// The border tone: the uniform tone seen near the rim on the most sides
/// (the holder shows on fewer sides, a flat sky on one). Ties go to the tone
/// that lies inside another one, since the holder is never inside the border.
func borderLevel(runs: [[Run]], sides: [SideView], p: Params) -> Float? {
    struct Cluster { var level: Float; var count: Int; var sides: Set<Int>; var inner: Int }
    var clusters: [Cluster] = []
    for (si, (s, rs)) in zip(sides, runs).enumerated() {
        let startLimit = Int(Double(s.n) * p.borderStart)
        var k = 0
        for r in rs where r.start <= startLimit {
            var ci = clusters.firstIndex { abs($0.level - r.level) <= p.levelTol }
            if ci == nil {
                clusters.append(Cluster(level: r.level, count: 0, sides: [], inner: 0))
                ci = clusters.count - 1
            }
            var c = clusters[ci!]
            c.level = (c.level * Float(c.count) + r.level) / Float(c.count + 1)
            c.count += 1
            c.sides.insert(si)
            if k > 0 { c.inner += 1 }
            clusters[ci!] = c
            k += 1
        }
    }
    return clusters.max { a, b in (a.sides.count, a.inner) < (b.sides.count, b.inner) }?.level
}

/// Tone range over a run's first lines (the last few excluded, where the
/// picture's glow can bleed in). Film border is flat; a soft shadow from the
/// film gate ramps. Only the head is judged, because a border run can go on
/// to merge with pale picture that the faint-edge step will separate later.
func headDrift(_ r: Run) -> Float {
    let n = r.levels.count
    guard n >= 6 else { return 0 }
    let head = r.levels[0..<min(n - 3, 25)]
    return (head.max() ?? 0) - (head.min() ?? 0)
}

/// Tone of a run's first lines.
func headLevel(_ r: Run) -> Float {
    let k = min(4, r.levels.count)
    guard k > 0 else { return r.level }
    return r.levels[0..<k].reduce(0, +) / Float(k)
}

/// The border on one side: the outermost near-rim run of the border tone.
/// It is passed over only for a later run that is both clearly closer to
/// the border tone and flat: that skips the gate's shadow ramp next to the
/// holder, while a short real border that ends in a glow still beats a flat
/// patch of picture further in.
func chooseRun(_ runs: [Run], s: SideView, p: Params, level: Float) -> Run? {
    let startLimit = Int(Double(s.n) * p.borderStart)
    let cands = runs.filter { $0.start <= startLimit && abs($0.level - level) <= p.levelTol }
    guard var pick = cands.first else { return nil }
    for d in cands.dropFirst() {
        let closer = abs(headLevel(d) - level) + p.toneMargin <= abs(headLevel(pick) - level)
        if closer && headDrift(d) <= p.flatMax { pick = d }
    }
    // The border resumes after the sprocket holes: the picked run faded out
    // without an edge line, every line of the gap is the border tone with
    // holes punched out of it (still the majority, but well short of
    // uniform), and a flat run of the same tone follows that ends at a
    // strong edge line. A bright sky next to a bright border fails this on
    // both counts: its gap is nearly uniform and it ends in nothing.
    for d in runs where d.start > pick.end && d.start <= Int(Double(s.n) * p.maxBorder) {
        guard !pick.hardEnd, !pick.open, d.hardEnd, abs(headLevel(d) - headLevel(pick)) <= p.jumpTol,
              headDrift(d) <= p.flatMax, d.start - pick.end >= p.minRun else { continue }
        // every gap line keeps the border tone; nearly all are far from
        // uniform (the rows through the holes' rounded ends less so)
        var punched = true
        var tooUniform = 0
        for i in pick.end..<d.start {
            let (med, uni) = lineProfile(s, i, tol: p.borderTol)
            if abs(med - level) > p.levelTol { punched = false; break }
            if uni >= p.sprocketUniMax { tooUniform += 1 }
        }
        if tooUniform > max(2, (d.start - pick.end) / 6) { punched = false }
        if punched { pick = d } else { break }
    }
    return pick
}

/// Where within its transition an edge sits. A sharp edge is one line; a
/// soft one (the gate's shadow, film not quite flat) ramps over ten, and
/// the run walk lands at the foot of the ramp on one side and mid-ramp on
/// another, so a crop centred on those edges shows unequal borders. Every
/// edge is moved to the same point of its ramp: the first line, walking
/// in, whose median (over the frame's own span, so holder or surround at
/// the line's ends do not count) has gone 40% of the way from the border's
/// tone to the picture's. A sharp edge stays put.
func refineEdge(_ s: SideView, e: Int, level: Float, span: Range<Int>, p: Params) -> Int {
    let out = max(0, e - p.refineOut), inn = min(s.n - 1, e + p.refineIn)
    guard inn - out >= 6, span.count >= 8 else { return e }
    func median(_ i: Int) -> Float {
        var vals = [Float](repeating: 0, count: span.count)
        for (k, j) in span.enumerated() { vals[k] = s.lum(i, j) }
        vals.sort()
        return vals[vals.count / 2]
    }
    let meds = (out...inn).map(median)
    let tail = meds.suffix(4)
    let picture = tail.reduce(0, +) / Float(tail.count)
    guard abs(picture - level) >= p.refineMinContrast else { return e }
    let target = level + p.refineFraction * (picture - level)
    for (k, m) in meds.enumerated() where picture > level ? m >= target : m <= target {
        return out + k
    }
    return e
}

/// Edge line for a border run: where the run ends, snapped to the strongest
/// edge line nearby (innermost of the strong ones, so a glow strip between
/// border and picture is left out).
func snapEdge(_ s: SideView, k: Int, p: Params) -> (Int, Float) {
    let lo = max(0, k - 3), hi = min(s.n - 1, k + 8)
    var best: Float = 0
    for m in lo...hi where s.raw[m] > best { best = s.raw[m] }
    if best < p.snapMin { return (k, best) }
    var e = k
    for m in lo...hi where s.raw[m] >= 0.6 * best { e = m }
    return (e, best)
}

// MARK: - Detection

/// Everything the per-image pass knows before geometry: the four sides as
/// measured, plus the debug record so far.
struct Analysis {
    var w = 0, h = 0
    var sides: [SideDebug] = []
    var dbg = DebugInfo()
    var failed: String? = nil
}

func analyze(url: URL, params: Params, dump: Bool = false) -> Analysis {
    guard let g = loadGray(url, longSide: params.workLongSide) else {
        var a = Analysis()
        a.failed = "could not decode"
        return a
    }
    var outer = analyzeGray(g, params: params, dump: dump)
    if let inner = peel(g, outer: &outer, params: params, dump: dump) { return inner }
    return outer
}

/// The image inside a rectangle, as its own Gray.
func crop(_ g: Gray, x0: Int, y0: Int, x1: Int, y1: Int) -> Gray {
    let w = x1 - x0, h = y1 - y0
    var px = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        let src = (y0 + y) * g.w + x0
        for x in 0..<w { px[y * w + x] = g.px[src + x] }
    }
    return Gray(w: w, h: h, px: px)
}

/// Median and uniformity of one line of side k (lines counted from the rim),
/// looking only at the stretch between the two neighbouring edges.
func bandProfile(_ g: Gray, side k: Int, line i: Int, x0: Int, x1: Int, y0: Int, y1: Int, tol: Float) -> (med: Float, uni: Float) {
    var vals: [Float] = []
    switch k {
    case 0: for y in y0..<y1 { vals.append(g.px[y * g.w + i]) }
    case 1: for x in x0..<x1 { vals.append(g.px[i * g.w + x]) }
    case 2: for y in y0..<y1 { vals.append(g.px[y * g.w + (g.w - 1 - i)]) }
    default: for x in x0..<x1 { vals.append(g.px[(g.h - 1 - i) * g.w + x]) }
    }
    guard !vals.isEmpty else { return (0, 0) }
    vals.sort()
    let med = vals[vals.count / 2]
    var n = 0
    for v in vals where abs(v - med) <= tol { n += 1 }
    return (med, Float(n) / Float(vals.count))
}

/// A scan that shows the whole strip has two rings: the surround (holder,
/// light table) and, inside it, the film's own rebate with its sprocket
/// holes. The rim walk finds the surround first, because on the sprocket
/// sides no line is uniform end to end (the surround shows past the strip's
/// ends), so the first pass returns the film's outline, not the frame. When
/// a band just inside that outline is a uniform tone unlike the outer one,
/// and the whole picture lies on one side of that tone (unexposed film is
/// the film's extreme tone; the picture is never both lighter and darker
/// than it), the detector runs again inside the outline. The inner frame is
/// taken only when it is seen firmly on three sides with the format's shape.
/// The distance from the frame to the outline is how much film there is
/// beyond the frame on each side, sprockets and all.
func peel(_ g: Gray, outer a: inout Analysis, params p: Params, dump: Bool) -> Analysis? {
    guard a.failed == nil, a.sides.count == 4 else { return nil }
    let seen = ["run", "soft", "subtle", "partial"]
    let measured = (0..<4).filter { seen.contains(a.sides[$0].method) && a.sides[$0].edge != nil }
    guard measured.count >= 2 else { return nil }
    let w = g.w, h = g.h
    let e = (0..<4).map { measured.contains($0) ? (a.sides[$0].edge ?? 0) : 0 }
    let x0 = e[0], y0 = e[1], x1 = w - e[2], y1 = h - e[3]
    guard x1 - x0 >= 64, y1 - y0 >= 64 else { return nil }
    // the ring just inside the outline: uniform, one tone on every measured side, unlike the outer tone
    let inset = p.peelInset
    let names = ["L", "T", "R", "B"]
    var ring: [Float] = []
    // where the rebate begins inside each measured side: the outline edge sits
    // mid-way through the holder's soft edge, which can run on for a dozen
    // lines and is uneven along its length under a vignette
    var start = [Int](repeating: 0, count: 4)
    for k in measured {
        var at = e[k] + inset
        while at < e[k] + inset + p.peelSkipMax {
            let (_, uni) = bandProfile(g, side: k, line: at, x0: x0 + inset, x1: x1 - inset, y0: y0 + inset, y1: y1 - inset, tol: p.borderTol)
            if uni >= p.peelBandUni { break }
            at += 1
        }
        start[k] = at
        var meds: [Float] = [], unis: [Float] = []
        for i in 0..<p.peelBand {
            let (med, uni) = bandProfile(g, side: k, line: at + i, x0: x0 + inset, x1: x1 - inset,
                                         y0: y0 + inset, y1: y1 - inset, tol: p.borderTol)
            meds.append(med); unis.append(uni)
        }
        guard let umin = unis.min(), umin >= p.peelBandUni,
              let hi = meds.max(), let lo = meds.min(), hi - lo <= p.jumpTol else {
            a.dbg.peelTrace = String(format: "no rebate ring: band inside %@ med %.0f-%.0f uni %.2f", names[k],
                                     meds.min() ?? 0, meds.max() ?? 0, unis.min() ?? 0)
            return nil
        }
        ring.append(meds.sorted()[meds.count / 2])
    }
    let tone = ring.reduce(0, +) / Float(ring.count)
    guard ring.allSatisfy({ abs($0 - tone) <= p.levelTol }), abs(tone - a.dbg.level) > p.levelTol else {
        a.dbg.peelTrace = String(format: "no rebate ring: band tones %@ vs border %.0f",
                                 ring.map { String(format: "%.0f", $0) }.joined(separator: "/"), a.dbg.level)
        return nil
    }
    // the picture inside lies on one side of the ring tone
    let ix0 = x0 + Int(Double(x1 - x0) * p.peelInterior), ix1 = x1 - Int(Double(x1 - x0) * p.peelInterior)
    let iy0 = y0 + Int(Double(y1 - y0) * p.peelInterior), iy1 = y1 - Int(Double(y1 - y0) * p.peelInterior)
    guard ix1 > ix0, iy1 > iy0 else { return nil }
    let step = max(1, Int((Double((ix1 - ix0) * (iy1 - iy0)) / 20000).squareRoot()))
    var above = 0, below = 0, total = 0
    for y in stride(from: iy0, to: iy1, by: step) {
        for x in stride(from: ix0, to: ix1, by: step) {
            let v = g.px[y * w + x]
            if v > tone + p.jumpTol { above += 1 } else if v < tone - p.jumpTol { below += 1 }
            total += 1
        }
    }
    guard total > 0, Double(min(above, below)) / Double(total) <= p.peelOutside else {
        a.dbg.peelTrace = String(format: "no rebate ring: picture on both sides of tone %.0f (%.2f above, %.2f below)",
                                 tone, Double(above) / Double(total), Double(below) / Double(total))
        return nil
    }
    // second pass inside the outline, from where the rebate begins (unmeasured sides run to the scan's edge)
    let sx0 = measured.contains(0) ? start[0] : 0, sy0 = measured.contains(1) ? start[1] : 0
    let sx1 = measured.contains(2) ? w - start[2] : w, sy1 = measured.contains(3) ? h - start[3] : h
    let sub = crop(g, x0: sx0, y0: sy0, x1: sx1, y1: sy1)
    var b = analyzeGray(sub, params: p, dump: dump)
    guard b.failed == nil else { return nil }
    b.dbg.peeled = true
    b.dbg.outline = [0, 0, 0, 0]          // in the sub-image the outline is its rim
    let (det, dbg) = finish(b, params: p, prior: [nil, nil, nil, nil])
    // a rebate ring was seen: say why the frame inside it was not taken
    func reject(_ why: String) -> Analysis? {
        let inner = dbg.sides.map { "\($0.edge.map(String.init) ?? "none") \($0.method) {\($0.runs)}" }.joined(separator: ", ")
        let raw = b.sides.map { "\($0.edge.map(String.init) ?? "none") \($0.method) snap \(String(format: "%.2f", $0.snap))" }.joined(separator: ", ")
        a.dbg.peelTrace = "inner border \(Int(b.dbg.level)); measured [\(raw)]; geometry: \(dbg.check.joined(separator: "; "))"
        a.dbg.peelNote = "rebate ring seen at \(e.map(String.init).joined(separator: "/")), inner \(sub.w)x\(sub.h) at \(sx0),\(sy0) not taken: \(why) [\(inner)]"
        if dump { a.dbg.dump += "  -- inside the film outline (not taken) --\n" + b.dbg.dump }
        return nil
    }
    guard det != nil else { return reject(dbg.reason) }
    // the inner frame is real when three sides were seen firmly and the shape
    // rule left them where they were measured: a fourth may have been placed
    // by it (a weak edge line at faint sprocket holes yielding to strong ones)
    var firm = 0
    for k in 0..<4 where ["run", "subtle", "agreed", "partial"].contains(dbg.sides[k].method) {
        let n = Double(k == 0 || k == 2 ? sub.w : sub.h)
        if let e0 = b.sides[k].edge, let e1 = dbg.sides[k].edge, abs(Double(e1 - e0)) <= max(4, n * p.ratioSlop) { firm += 1 }
    }
    guard firm >= 3 else { return reject("only \(firm) side(s) seen firmly and left in place by the frame's shape") }
    // back to the whole image
    let offset = [sx0, sy0, w - sx1, h - sy1]
    let nSub = [sub.w, sub.h, sub.w, sub.h], nFull = [w, h, w, h]
    for k in 0..<4 {
        if let ek = b.sides[k].edge { b.sides[k].edge = ek + offset[k] }
        b.sides[k].avail *= Double(nSub[k]) / Double(nFull[k])
        // the film ends where the rebate begins inside the outline, or at the scan's edge where none was seen
        b.sides[k].filmEnd = measured.contains(k) ? start[k] : 0
    }
    b.w = w; b.h = h
    b.dbg.w = w; b.dbg.h = h
    b.dbg.outline = (0..<4).map { measured.contains($0) ? start[$0] : 0 }
    b.dbg.dump = a.dbg.dump + (dump ? "  -- inside the film outline --\n" : "") + b.dbg.dump
    return b
}

func analyzeGray(_ g: Gray, params: Params, dump: Bool = false) -> Analysis {
    var a = Analysis()
    guard g.w >= 16, g.h >= 16 else {
        a.failed = "image too small"
        return a
    }
    let w = g.w, h = g.h
    var dbg = DebugInfo()
    dbg.w = w; dbg.h = h

    let mag = gradientMagnitude(g)
    let thr = percentile(mag, params.percentile)
    dbg.threshold = thr
    let edges = mag.map { $0 > thr }
    let (colR, rowR) = supports(edges: edges, w: w, h: h, smear: 0)
    let sides = makeSides(g, edges: edges, colR: colR, rowR: rowR)

    if dump {
        for (name, s) in zip(["L", "T", "R", "B"], sides) {
            let limit = min(s.n, Int(Double(s.n) * params.maxBorder))
            var out = "  \(name): i med uni raw spread\n"
            for i in 0..<limit {
                let t = lineStats(s, i, tol: params.borderTol)
                out += String(format: "    %3d %5.0f %.2f %.2f %4.1f\n", i, t.med, t.uni, s.raw[i], t.spread)
            }
            dbg.dump += out
        }
    }

    // 1. Uniform runs per side, then the border tone across sides.
    let runs = sides.map { uniformRuns($0, p: params) }
    let level = borderLevel(runs: runs, sides: sides, p: params)
    dbg.level = level ?? -1
    dbg.dark = (level ?? 0) < percentile(g.px, 50)

    // 2. Per side: the border run of that tone, snapped to the edge line.
    var res: [SideDebug] = []
    for (s, r) in zip(sides, runs) {
        var d = SideDebug()
        d.runs = r.map { "\(Int($0.level))[\($0.start)..\($0.end)\($0.open ? "+" : "")\($0.hardEnd ? "|" : "")]" }.joined(separator: " ")
        if let lv = level, let c = chooseRun(r, s: s, p: params, level: lv) {
            let limit = c.open ? min(s.n, Int(Double(s.n) * params.maxBorder)) : c.end
            let (e0, strength) = c.open ? (c.end, Float(0)) : snapEdge(s, k: c.end, p: params)
            if !c.open && strength >= params.snapMin {
                d.edge = e0
                d.snap = strength
                d.method = "run"
                d.avail = Double(e0 - c.start) / Double(s.n)
            } else if let t = subtleEdge(s, from: c.start, to: min(s.n, limit + params.subtleWindow + 2), p: params) {
                // (the search runs a few lines past the run's end: a run that
                // stopped because the picture is textured, not because its
                // tone changed, has its step right at the end)
                d.edge = t
                d.method = "subtle"
                d.avail = Double(t - c.start) / Double(s.n)
            } else if c.open {
                if let (t, agree) = partialEdge(s, level: lv, p: params) {
                    d.edge = t
                    d.method = "partial"
                    d.snap = Float(agree)
                    d.avail = Double(t - c.start) / Double(s.n)
                } else {
                    d.method = "too wide"
                }
            } else {
                d.edge = e0
                d.snap = strength
                d.method = "soft"
                d.avail = Double(e0 - c.start) / Double(s.n)
            }
            d.runStart = c.start
            // The film goes on past the clean border run: frame numbers, edge
            // printing and sprocket holes break a line's uniformity, but such
            // a line is still mostly border tone, where a holder or light
            // table is another tone. Walk out from the run's start while that
            // holds; the film's extent is then known even where the border
            // is not clean. (A second pass inside a film outline measures it
            // exactly, see peel.)
            var k = c.start
            while k > 0 {
                let (med, _) = lineProfile(s, k - 1, tol: params.borderTol)
                if abs(med - lv) > params.levelTol { break }
                k -= 1
            }
            d.filmEnd = k
        } else {
            d.method = "no border"
        }
        res.append(d)
    }

    // 2b. Each measured edge to the same point of its transition, judged over
    //     the span between its neighbouring edges.
    if let lv = level {
        let seenEdge = { (k: Int) -> Int? in ["run", "subtle", "soft"].contains(res[k].method) ? res[k].edge : nil }
        for k in 0..<4 {
            guard let e0 = seenEdge(k) else { continue }
            let s = sides[k]
            // along a left/right side the line runs top to bottom: the span is between T and B
            let (a, b) = (k == 0 || k == 2) ? (seenEdge(1), seenEdge(3)) : (seenEdge(0), seenEdge(2))
            let lo = (a ?? 0) + 3, hi = s.len - (b ?? 0) - 3
            guard hi - lo >= 8 else { continue }
            let e1 = refineEdge(s, e: e0, level: lv, span: lo..<hi, p: params)
            if e1 != e0 {
                res[k].edge = e1
                res[k].avail = Double(max(0, e1 - res[k].runStart)) / Double(s.n)
            }
        }
    }

    // 3. Tilt: each seen side gives an angle; clockwise on screen is positive.
    //    Side coordinates run inward and along the side, so the sign differs per side.
    let signs: [Double] = [-1, 1, 1, -1]
    var sideAngles: [Double?] = [nil, nil, nil, nil]
    var sideQuality: [Double] = [0, 0, 0, 0]
    for (k, s) in sides.enumerated() where ["run", "soft", "partial", "subtle"].contains(res[k].method) {
        if let e = res[k].edge, let fit = sideSlope(s, e: e, availLines: Int(res[k].avail * Double(s.n)), p: params) {
            sideAngles[k] = signs[k] * atan(fit.slope) * 180 / .pi
            // The film is held by its long edges, and a slightly cupped strip
            // skews the short edges; the long sides carry the tilt.
            let isLong = (w >= h) ? (k == 1 || k == 3) : (k == 0 || k == 2)
            sideQuality[k] = fit.quality * (isLong ? params.angleLongSideWeight : 1)
        }
    }
    // Vote: sides that agree within angleAgree form groups; the group with
    // the most edge support (inlier density) wins and its angle is the
    // support-weighted mean. A very clean edge may vote alone; a weak lone
    // side, or sides that all disagree, means no tilt. Thin borders fit
    // badly and only vote when nothing better exists.
    var voters: [(a: Double, q: Double)] = []
    var thin: [(a: Double, q: Double)] = []
    for k in 0..<4 {
        guard let a = sideAngles[k] else { continue }
        let v = (a: a, q: sideQuality[k])
        if res[k].avail > 0 && res[k].avail < params.angleMinBorder { thin.append(v) } else { voters.append(v) }
    }
    if voters.count < 2 { voters += thin }
    var best: [(a: Double, q: Double)] = []
    var bestWeight = -1.0
    for seed in voters {
        let group = voters.filter { abs($0.a - seed.a) <= params.angleAgree }
        let weight = group.reduce(0) { $0 + $1.q }
        if weight > bestWeight { best = group; bestWeight = weight }
    }
    let strongAlone = best.count == 1 && (best.first?.q ?? 0) >= params.angleAloneQuality
    if best.count >= 2 || strongAlone {
        let m = best.reduce(0) { $0 + $1.a * $1.q } / bestWeight
        if abs(m) > params.angleMax {
            dbg.angleNote = "too large"
        } else if abs(m) >= 0.05 {
            dbg.angle = (m * 100).rounded() / 100
        }
        if best.count < voters.count { dbg.angleNote = "\(voters.count - best.count) side(s) outvoted" }
    } else if voters.count >= 2 {
        dbg.angleNote = "sides disagree"
    }
    dbg.sideAngles = sideAngles
    a.w = w; a.h = h; a.sides = res; a.dbg = dbg
    return a
}

func median(_ values: [Double]) -> Double? {
    if values.isEmpty { return nil }
    let s = values.sorted()
    let m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
}

/// 3. Geometry and verdict. `prior` holds, per side, the batch's typical
///    border width (fraction of the image) from photos where that side was
///    seen firmly: in one scanning session the film sits in the same place
///    frame after frame, so it fills sides that this photo cannot show.
func finish(_ a: Analysis, params: Params, prior: [Double?]) -> (Detection?, DebugInfo) {
    var dbg = a.dbg
    if let f = a.failed {
        dbg.reason = f
        return (nil, dbg)
    }
    var res = a.sides
    let w = a.w, h = a.h
    var check: [String] = []
    if params.aspect > 0 {
        let A = w >= h ? params.aspect : 1 / params.aspect
        let names = ["L", "T", "R", "B"]
        let nOf = { (i: Int) -> Double in Double(i == 0 || i == 2 ? w : h) }
        // a soft edge deep inside the image is picture, not border; inside a
        // film outline the sprocket sides are wide, so the limit is larger
        // and counted from the outline
        let plausible = dbg.peeled ? params.peelPlausibleBorder : params.plausibleBorder
        for i in 0..<4 where res[i].method == "soft" {
            let base = dbg.peeled && dbg.outline.count == 4 ? dbg.outline[i] : 0
            if Double((res[i].edge ?? 0) - base) > nOf(i) * plausible {
                res[i].method = "too wide"
                res[i].edge = nil
                res[i].avail = 0
            }
        }
        // a partial edge must fit the frame's shape when the other three sides
        // are firm; otherwise it was a transition inside the picture
        for i in 0..<4 where res[i].method == "partial" {
            let others = (0..<4).filter { $0 != i }
            if others.allSatisfy({ res[$0].method == "run" || res[$0].method == "subtle" }) {
                let e = res.map { $0.edge ?? 0 }
                let fw = Double(w - e[0] - e[2]), fh = Double(h - e[1] - e[3])
                if fh > 0 && abs((fw / fh) / A - 1) > params.aspectTol {
                    res[i].method = "too wide"
                    res[i].edge = nil
                    res[i].avail = 0
                }
            }
        }
        // geometry can place one unseen side; any further ones come from the batch
        var unseen = (0..<4).filter { res[$0].method == "too wide" }
        while unseen.count > 1 {
            let i = unseen.removeLast()
            if let p = prior[i] {
                res[i].edge = Int((p * nOf(i)).rounded())
                res[i].method = "batch"
                res[i].avail = 0
                check.append("\(names[i]) from batch")
            }
        }
        // Inside Lightroom the preview is the whole scan, so a side that shows
        // no border tone at all is far more likely a detection miss than a
        // pre-cropped scan; when it breaks the frame's shape, geometry places it.
        for i in 0..<4 where res[i].method == "no border" {
            let others = (0..<4).filter { $0 != i }
            if others.allSatisfy({ ["run", "soft", "batch", "partial", "subtle"].contains(res[$0].method) }) {
                let e = res.map { $0.edge ?? 0 }
                let fw = Double(w - e[0] - e[2]), fh = Double(h - e[1] - e[3])
                if fh > 0 && abs((fw / fh) / A - 1) > params.aspectTol {
                    res[i].method = "too wide"
                    res[i].edge = nil
                    res[i].avail = 0
                }
            }
        }
        let known = { (i: Int) -> Bool in ["run", "soft", "batch", "partial", "subtle", "agreed"].contains(res[i].method) }
        var target: Int? = (0..<4).first { res[$0].method == "too wide" }
        if target == nil {
            target = (0..<4).filter { res[$0].method == "soft" }.min { res[$0].snap < res[$1].snap }
        }
        if let i = target, (0..<4).filter({ $0 != i }).allSatisfy(known) {
            let e = res.map { $0.edge ?? 0 }
            let v: Double
            if i == 0 || i == 2 {
                v = Double(w) - Double(h - e[1] - e[3]) * A - Double(e[i == 0 ? 2 : 0])
            } else {
                v = Double(h) - Double(w - e[0] - e[2]) / A - Double(e[i == 1 ? 3 : 1])
            }
            // A measured side may be nudged outward by the slop of a faint edge,
            // never further: a frame the film cut short (no border on one
            // side) must not grow into the border or holder to reach its
            // shape. The shape rule then trims the other axis instead. A
            // soft side is not a measurement, only where a border run faded
            // out (into picture of the border's tone, as far as it likes):
            // three firm sides and the frame's shape place it wherever they
            // say.
            let slop = max(4.0, nOf(i) * params.ratioSlop)
            if let m = res[i].edge, res[i].method == "soft", abs(v - Double(m)) <= slop {
                // a soft edge that agrees with the other three sides to within
                // measurement slop stands, confirmed; the residual is shared out below
                res[i].method = "agreed"
            } else if let m = res[i].edge, res[i].method != "soft", v < Double(m) - nOf(i) * params.inferOutMax {
                check.append("\(names[i]) kept (frame cut short)")
            } else if v >= 0 && v <= nOf(i) * params.maxBorder {
                // a measured-but-soft side keeps its border width, less
                // whatever the move outward took off it (the run's start
                // stays where it was); a side with no measurement at all has
                // none to keep
                if res[i].method != "soft" {
                    res[i].avail = 0
                } else if let m = res[i].edge {
                    res[i].avail = max(0, res[i].avail + (v - Double(m)) / nOf(i))
                }
                res[i].edge = Int(v.rounded())
                res[i].method = "inferred"
                if (0..<4).contains(where: { $0 != i && (res[$0].method == "soft" || res[$0].method == "batch") }) {
                    check.append("\(names[i]) inferred from a weak side")
                }
            } else {
                check.append("\(names[i]) cannot be inferred")
            }
        }
        // Both sides of one axis weak: geometry cannot place either alone, but
        // weak edges err outward, so when the frame is too wide (or tall) for
        // its shape, pull that pair in equally.
        do {
            let firmNow = res.map { ["run", "partial", "subtle", "agreed", "inferred", "batch"].contains($0.method) }
            let e = res.map { $0.edge ?? 0 }
            let fw = Double(w - e[0] - e[2]), fh = Double(h - e[1] - e[3])
            let weakX = !firmNow[0] && !firmNow[2], weakY = !firmNow[1] && !firmNow[3]
            if fh > 0 && weakX && firmNow[1] && firmNow[3] && fw > fh * A * (1 + params.aspectTol) {
                let excess = fw - fh * A
                res[0].edge = e[0] + Int((excess / 2).rounded())
                res[2].edge = e[2] + Int((excess / 2).rounded())
                res[0].method = "squeezed"; res[2].method = "squeezed"
                res[0].avail = 0; res[2].avail = 0
                check.append("width pulled in to the frame's shape")
            } else if fw > 0 && weakY && firmNow[0] && firmNow[2] && fh > fw / A * (1 + params.aspectTol) {
                let excess = fh - fw / A
                res[1].edge = e[1] + Int((excess / 2).rounded())
                res[3].edge = e[3] + Int((excess / 2).rounded())
                res[1].method = "squeezed"; res[3].method = "squeezed"
                res[1].avail = 0; res[3].avail = 0
                check.append("height pulled in to the frame's shape")
            }
        }
        for i in 0..<4 where res[i].method == "soft" || res[i].method == "too wide" {
            check.append("\(names[i]) \(res[i].method)")
        }
        let e = res.map { $0.edge ?? 0 }
        let fw = Double(w - e[0] - e[2]), fh = Double(h - e[1] - e[3])
        if fh > 0 {
            dbg.aspect = fw / fh
            if abs(dbg.aspect / A - 1) > params.aspectTol {
                check.append(String(format: "aspect %.3f", dbg.aspect))
            }
        }
        // Hard rule: the frame has the format's shape. Whatever is left over
        // is taken from the axis that is too long, mostly from the less
        // trusted of its two sides. Weak edges err outward, so this only
        // ever moves inward.
        if fh > 0 && fw > 0 {
            // a seen edge with a strong edge line is an anchor; a seen edge
            // whose edge line is weak (picture of the border's tone along
            // it, faint sprocket holes read as border) yields to it
            let trust = res.map { s -> Double in
                switch s.method {
                case "run", "partial": return s.snap >= params.strongSnap ? 3.5 : 3
                case "subtle", "agreed": return 2
                case "inferred", "batch", "soft": return 1
                default: return 0.5
                }
            }
            // A small residual is measurement slop, or a gate that is not
            // exactly 3:2: both sides share it, so the crop stays centred on
            // the frame. A large one is a missed edge: the less trusted side
            // takes it all; only equals split it.
            func split(_ excess: Double, _ i: Int, _ j: Int) {
                let slop = max(4.0, nOf(i) * params.ratioSlop)
                let small = excess <= slop
                let wi: Double = small ? 0.5 : (trust[i] < trust[j] ? 1 : (trust[i] > trust[j] ? 0 : 0.5))
                let wj = 1 - wi
                // a side moved a long way was not really seen: it is placed
                // from the frame's shape, and says so (a few lines is a soft
                // ramp or a snap to the wrong line, still the seen edge)
                for (k, wk) in [(i, wi), (j, wj)] {
                    let move = excess * wk
                    res[k].edge = (res[k].edge ?? 0) + Int(move.rounded())
                    if move > max(8.0, nOf(i) * params.placedMin) {
                        res[k].method = "inferred"
                        res[k].avail = 0
                        // placed from three firm sides it is as good as seen; from
                        // weaker company it is worth a look
                        let others = (0..<4).filter { $0 != k }
                        if !others.allSatisfy({ ["run", "partial", "subtle", "agreed"].contains(res[$0].method) }) {
                            check.append("\(names[k]) placed from the frame's shape next to a weak side")
                        }
                    }
                }
            }
            if fw > fh * A + 0.5 {
                split(fw - fh * A, 0, 2)
            } else if fh > fw / A + 0.5 {
                split(fh - fw / A, 1, 3)
            }
        }
    }
    // how far the film goes on outside each edge, measured from the edge as
    // finally placed; a side placed without any measurement has no film known
    for i in 0..<4 {
        if let fe = res[i].filmEnd, let ed = res[i].edge, ["run", "soft", "subtle", "agreed", "partial", "inferred", "squeezed"].contains(res[i].method) {
            res[i].film = max(0, Double(ed - fe) / Double(i == 0 || i == 2 ? w : h))
        } else {
            res[i].film = 0
        }
    }
    // a rebate ring seen but no frame confirmed inside it matters when the
    // first pass kept little of the scan (the film's outline on a full-border
    // scan); a frame that fills the scan is the frame
    if !dbg.peelNote.isEmpty {
        let ek = res.map { Double($0.edge ?? 0) }
        let keptEst = (1 - (ek[0] + ek[2]) / Double(w)) * (1 - (ek[1] + ek[3]) / Double(h))
        if keptEst < params.peelKeptMax { check.append("frame inside the film outline not confirmed") }
    }
    dbg.sides = res
    dbg.check = check

    // With fewer than two sides actually seen there is no frame to
    // reconstruct: the frame runs off the scan, or nothing in it differs
    // from the border. Better an honest skip than a crop of the whole scan.
    let seen = res.filter { ["run", "partial", "subtle", "agreed", "soft"].contains($0.method) }.count
    if seen < 2 {
        dbg.reason = "frame edges not found on \(4 - seen) sides (frame runs off the scan?)"
        return (nil, dbg)
    }

    let inferredExtra = { (m: String) -> Double in m == "inferred" ? params.inferredInset : 0 }
    // a side without a border (already cropped) never gets a negative margin
    let l = max(0, Double(res[0].edge ?? 0) / Double(w) + params.inset + inferredExtra(res[0].method))
    let t = max(0, Double(res[1].edge ?? 0) / Double(h) + params.inset + inferredExtra(res[1].method))
    let r = max(0, Double(res[2].edge ?? 0) / Double(w) + params.inset + inferredExtra(res[2].method))
    let b = max(0, Double(res[3].edge ?? 0) / Double(h) + params.inset + inferredExtra(res[3].method))
    let kw = 1 - l - r
    let kh = 1 - t - b
    dbg.kept = kw * kh
    if kw <= 0 || kh <= 0 || kw * kh < params.minArea {
        dbg.reason = String(format: "crop keeps %.0f%% of the image (< %.0f%%)", kw * kh * 100, params.minArea * 100)
        return (nil, dbg)
    }
    func r5(_ v: Double) -> Double { (v * 100000).rounded() / 100000 }
    return (Detection(l: r5(l), t: r5(t), r: r5(r), b: r5(b)), dbg)
}

// MARK: - Preview rendering

/// The film-borders rectangle for a detection, in the same margin form: the
/// frame's long side kept, the short one grown until the rectangle has the
/// ratio, centred on the frame. nil when the film does not go that far on
/// both of the sides that would grow. (Previews only; the plug-in does the
/// same with the crop edge and tilt in.)
func bordersRect(_ d: Detection, film: [Double], ratio: Double, w: Int, h: Int)
    -> (rect: Detection?, need: Double, have: (Double, Double)) {
    // a hair clear of the ragged film edge, none where the film runs off the scan
    func hair(_ inset: Double, _ f: Double) -> Double { f >= inset - 0.0005 ? 0 : 0.003 }
    let fw = (1 - d.l - d.r) * Double(w), fh = (1 - d.t - d.b) * Double(h)
    guard fw > 0, fh > 0, film.count == 4 else { return (nil, 0, (0, 0)) }
    if fw >= fh {
        let grow = (fw / ratio - fh) / 2 / Double(h)
        let ok = grow + hair(d.t, film[1]) <= film[1] && grow + hair(d.b, film[3]) <= film[3]
        return (ok ? Detection(l: d.l, t: d.t - grow, r: d.r, b: d.b - grow) : nil, grow, (film[1], film[3]))
    } else {
        let grow = (fh / ratio - fw) / 2 / Double(w)
        let ok = grow + hair(d.l, film[0]) <= film[0] && grow + hair(d.r, film[2]) <= film[2]
        return (ok ? Detection(l: d.l - grow, t: d.t, r: d.r - grow, b: d.b) : nil, grow, (film[0], film[2]))
    }
}

func writePreview(src: URL, dst: URL, det: Detection?, borders: Detection? = nil, maxSide: Int = 2000) {
    guard let s = CGImageSourceCreateWithURL(src as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return }
    // previews are for eyeballing, so cap them at maxSide px on the long side
    let scale = min(1.0, Double(maxSide) / Double(max(img.width, img.height)))
    let w = max(1, Int((Double(img.width) * scale).rounded()))
    let h = max(1, Int((Double(img.height) * scale).rounded()))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    let full = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.interpolationQuality = .high
    ctx.draw(img, in: full)
    let lw = max(3.0, Double(max(w, h)) / 400.0)
    ctx.setLineWidth(lw)
    if let d = det {
        // CG origin is bottom-left, so the y offset is the bottom margin.
        let rect = CGRect(x: d.l * Double(w), y: d.b * Double(h),
                          width: (1 - d.l - d.r) * Double(w), height: (1 - d.t - d.b) * Double(h))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.45))
        ctx.addRect(full); ctx.addRect(rect)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(CGColor(red: 0.1, green: 1.0, blue: 0.3, alpha: 1))
        ctx.stroke(rect)
        if let fb = borders {
            let frect = CGRect(x: fb.l * Double(w), y: fb.b * Double(h),
                               width: (1 - fb.l - fb.r) * Double(w), height: (1 - fb.t - fb.b) * Double(h))
            ctx.setStrokeColor(CGColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 1))
            ctx.setLineWidth(lw * 0.7)
            ctx.stroke(frect)
        }
    } else {
        ctx.setStrokeColor(CGColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 1))
        ctx.stroke(full.insetBy(dx: lw * 1.5, dy: lw * 1.5), width: lw * 3)
    }
    guard let out = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(dst as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

/// A 2x2 sheet of the four crop corners at 100%, crop lines drawn through
/// them, for checking placement to the pixel.
func writeCorners(src: URL, dst: URL, det: Detection, tile: Int = 480) {
    guard let s = CGImageSourceCreateWithURL(src as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return }
    let W = img.width, H = img.height
    let xs = [det.l * Double(W), (1 - det.r) * Double(W)]
    let ys = [det.t * Double(H), (1 - det.b) * Double(H)]
    let size = tile * 2
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let half = tile / 2
    let corners = [(xs[0], ys[0]), (xs[1], ys[0]), (xs[0], ys[1]), (xs[1], ys[1])]
    for (qi, (cx, cy)) in corners.enumerated() {
        let x0 = max(0, min(W - tile, Int(cx) - half))
        let y0 = max(0, min(H - tile, Int(cy) - half))
        guard let sub = img.cropping(to: CGRect(x: x0, y: y0, width: tile, height: tile)) else { continue }
        let tx = (qi % 2) * tile
        let ty = qi < 2 ? tile : 0
        ctx.draw(sub, in: CGRect(x: tx, y: ty, width: tile, height: tile))
        let lx = Double(tx) + (cx - Double(x0))
        let ly = Double(ty) + Double(tile) - (cy - Double(y0))
        ctx.setStrokeColor(CGColor(red: 0.1, green: 1.0, blue: 0.3, alpha: 1))
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: lx, y: Double(ty))); ctx.addLine(to: CGPoint(x: lx, y: Double(ty + tile))); ctx.strokePath()
        ctx.move(to: CGPoint(x: Double(tx), y: ly)); ctx.addLine(to: CGPoint(x: Double(tx + tile), y: ly)); ctx.strokePath()
    }
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(4)
    ctx.move(to: CGPoint(x: tile, y: 0)); ctx.addLine(to: CGPoint(x: tile, y: size)); ctx.strokePath()
    ctx.move(to: CGPoint(x: 0, y: tile)); ctx.addLine(to: CGPoint(x: size, y: tile)); ctx.strokePath()
    guard let out = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(dst as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

// MARK: - CLI

func stderrPrint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func usage(_ code: Int32) -> Never {
    stderrPrint("""
    usage: frameline-detect <folder> [--preview [outdir]] [--debug] [--inset -0.005]
                            [--tol 14] [--max-border 0.18] [--percentile 95] [--min-area 0.30]
                            [--borders 1.125]  (previews: draw the film-borders rectangle when it fits)
    Writes <folder>/results.csv: index,left,top,right,bottom,status,sides,angle,avail,film
    """)
    exit(code)
}

var argv = Array(CommandLine.arguments.dropFirst())
var folderArg: String? = nil
var previewArg: String? = nil
var debug = false
var dump = false
var corners = false
var params = Params()

func takeNumber(_ i: inout Int, _ flag: String) -> Double {
    i += 1
    guard i < argv.count, let v = Double(argv[i]) else {
        stderrPrint("\(flag) needs a number"); usage(2)
    }
    return v
}

var ai = 0
while ai < argv.count {
    let a = argv[ai]
    switch a {
    case "-h", "--help": usage(0)
    case "--debug": debug = true
    case "--dump": dump = true; debug = true
    case "--corners": corners = true; if previewArg == nil { previewArg = "" }
    case "--preview":
        if ai + 1 < argv.count, !argv[ai + 1].hasPrefix("-") { previewArg = argv[ai + 1]; ai += 1 } else { previewArg = "" }
    case "--percentile": params.percentile = takeNumber(&ai, a)
    case "--inset": params.inset = takeNumber(&ai, a)
    case "--min-area": params.minArea = takeNumber(&ai, a)
    case "--tol": params.borderTol = Float(takeNumber(&ai, a))
    case "--max-border": params.maxBorder = takeNumber(&ai, a)
    case "--border-start": params.borderStart = takeNumber(&ai, a)
    case "--aspect": params.aspect = takeNumber(&ai, a)
    case "--level-tol": params.levelTol = Float(takeNumber(&ai, a))
    case "--borders": params.borders = takeNumber(&ai, a)
    default:
        if a.hasPrefix("-") { stderrPrint("unknown option \(a)"); usage(2) }
        if folderArg != nil { stderrPrint("only one folder expected"); usage(2) }
        folderArg = a
    }
    ai += 1
}

guard let folder = folderArg else { usage(2) }
let fm = FileManager.default
var isDir: ObjCBool = false
guard fm.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
    stderrPrint("not a folder: \(folder)"); exit(1)
}
let folderURL = URL(fileURLWithPath: folder)

guard let names = try? fm.contentsOfDirectory(atPath: folder) else {
    stderrPrint("cannot list folder: \(folder)"); exit(1)
}
let jpgs = names.filter { n in
    if n.hasPrefix(".") { return false }
    let lower = n.lowercased()
    guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") else { return false }
    var d: ObjCBool = false
    return fm.fileExists(atPath: folderURL.appendingPathComponent(n).path, isDirectory: &d) && !d.boolValue
}.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }

var previewURL: URL? = nil
if let p = previewArg {
    previewURL = p.isEmpty ? folderURL.appendingPathComponent("_previews") : URL(fileURLWithPath: p)
    try? fm.createDirectory(at: previewURL!, withIntermediateDirectories: true)
}

let started = Date()
var analyses = [Analysis?](repeating: nil, count: jpgs.count)
let lock = NSLock()
DispatchQueue.concurrentPerform(iterations: jpgs.count) { i in
    let a = analyze(url: folderURL.appendingPathComponent(jpgs[i]), params: params, dump: dump)
    lock.lock(); analyses[i] = a; lock.unlock()
}

// Batch prior: the typical border width per side, from sides seen firmly.
var prior: [Double?] = [nil, nil, nil, nil]
for s in 0..<4 {
    var vals: [Double] = []
    for a in analyses.compactMap({ $0 }) where a.failed == nil && a.sides[s].method == "run" {
        vals.append(Double(a.sides[s].edge ?? 0) / Double(s == 0 || s == 2 ? a.w : a.h))
    }
    if vals.count >= params.priorMin { prior[s] = median(vals) }
}

var results: [(Detection?, DebugInfo)] = analyses.map { finish($0!, params: params, prior: prior) }

if let pv = previewURL {
    DispatchQueue.concurrentPerform(iterations: jpgs.count) { i in
        let url = folderURL.appendingPathComponent(jpgs[i])
        var fb: Detection? = nil
        if params.borders > 0, let d = results[i].0 {
            fb = bordersRect(d, film: results[i].1.sides.map { $0.film }, ratio: params.borders, w: results[i].1.w, h: results[i].1.h).rect
        }
        writePreview(src: url, dst: pv.appendingPathComponent(jpgs[i]), det: results[i].0, borders: fb)
        if corners, let d = results[i].0 {
            let stem = (jpgs[i] as NSString).deletingPathExtension
            writeCorners(src: url, dst: pv.appendingPathComponent(stem + "_corners.jpg"), det: d)
        }
    }
}

func f5(_ v: Double) -> String { String(format: "%.5f", v) }

var lines: [String] = []
for (i, name) in jpgs.enumerated() {
    let index = (name as NSString).deletingPathExtension
    let (det, dbg) = results[i]
    // 7th column: how each side was found (L/T/R/B), e.g. run/run/inferred/run
    let sides = dbg.sides.map { $0.method.replacingOccurrences(of: " ", with: "-") }.joined(separator: "/")
    // 9th column: border available outside each edge L/T/R/B, fraction of the image (0 = unknown)
    let avail = dbg.sides.map { String(format: "%.4f", $0.avail) }.joined(separator: "/")
    // 10th column: how far the film itself goes on outside each edge, L/T/R/B, fraction of the image
    let film = dbg.sides.map { String(format: "%.4f", $0.film) }.joined(separator: "/")
    let line: String
    if let d = det {
        line = "\(index),\(f5(d.l)),\(f5(d.t)),\(f5(d.r)),\(f5(d.b)),\(dbg.check.isEmpty ? "ok" : "check"),\(sides),\(String(format: "%.2f", dbg.angle)),\(avail),\(film)"
    } else {
        line = "\(index),0,0,0,0,skip,\(sides),0,0,0"
    }
    lines.append(line)
    print(line)
    if debug {
        let sa = dbg.sideAngles.map { $0.map { String(format: "%+.2f", $0) } ?? "-" }.joined(separator: " ")
        var out = "    \(dbg.w)x\(dbg.h) thr=\(String(format: "%.1f", dbg.threshold)) border=\(Int(dbg.level))(\(dbg.dark ? "dark" : "bright")) aspect=\(String(format: "%.3f", dbg.aspect)) angle=\(String(format: "%+.2f", dbg.angle)) [\(sa)]\(dbg.angleNote.isEmpty ? "" : " " + dbg.angleNote) kept=\(String(format: "%.2f", dbg.kept))"
        if !dbg.check.isEmpty { out += "  CHECK: " + dbg.check.joined(separator: ", ") }
        if !dbg.reason.isEmpty { out += "  [\(dbg.reason)]" }
        if dbg.peeled { out += "  peeled: film outline at \(dbg.outline.map(String.init).joined(separator: "/"))" }
        if !dbg.peelNote.isEmpty { out += "  PEEL: \(dbg.peelNote)" }
        if !dbg.peelTrace.isEmpty { out += "  (\(dbg.peelTrace))" }
        print(out)
        for (name, sd) in zip(["L", "T", "R", "B"], dbg.sides) {
            let e = sd.edge.map(String.init) ?? "none"
            print("      \(name)=\(e) \(sd.method) snap \(String(format: "%.2f", sd.snap)) avail \(String(format: "%.3f", sd.avail)) film \(String(format: "%.3f", sd.film))  runs: \(sd.runs)")
        }
        if params.borders > 0, let d = det {
            let fb = bordersRect(d, film: dbg.sides.map { $0.film }, ratio: params.borders, w: dbg.w, h: dbg.h)
            print(String(format: "      film borders %.3f: %@ (needs %.3f beyond the frame, has %.3f and %.3f)",
                         params.borders, fb.rect == nil ? "no room" : "fit", fb.need, fb.have.0, fb.have.1))
        }
        if dump { print(dbg.dump, terminator: "") }
    }
}

let csvURL = folderURL.appendingPathComponent("results.csv")
let text = lines.joined(separator: "\n") + "\n"
do {
    try text.write(to: csvURL, atomically: true, encoding: .utf8)
} catch {
    stderrPrint("cannot write \(csvURL.path): \(error)"); exit(1)
}
let elapsed = Date().timeIntervalSince(started)
stderrPrint(String(format: "%d image(s) in %.2fs -> %@", jpgs.count, elapsed, csvURL.path))
exit(0)
