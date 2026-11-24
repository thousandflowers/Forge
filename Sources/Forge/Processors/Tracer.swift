import CoreGraphics
import Foundation

/// Outlines of a picture: what is darker than half is a shape, and the rest is
/// paper. The edge is followed where the grey crosses the middle, which is
/// finer than a pixel, and drawn again with as few curves as keep to it.
enum Tracer {
  typealias Point = SIMD2<Double>

  static func svg(of image: CGImage) throws -> String {
    let width = image.width, height = image.height
    let tooLarge = ProcessingError.conversionFailed(reason: "The picture is too large to be traced.")
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { throw tooLarge }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw tooLarge }
    let paths = try loops(UnsafeBufferPointer(start: pixels, count: width * height), width, height).compactMap { loop -> String? in
      try Task.checkCancellation()
      return abs(area(loop)) < speck ? nil : drawn(loop)
    }
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">
      <path fill="#000" fill-rule="evenodd" d="\(paths.joined(separator: " "))"/>
      </svg>

      """
  }

  /// In square pixels: less than this is dirt.
  private static let speck = 3.0

  private static func area(_ loop: [Point]) -> Double {
    zip(loop, loop.dropFirst() + loop.prefix(1)).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y } / 2
  }

  private static func length(_ p: Point) -> Double { (p.x * p.x + p.y * p.y).squareRoot() }
  private static func unit(_ p: Point) -> Point { let size = length(p); return size > 1e-12 ? p / size : Point(1, 0) }
  private static func dot(_ a: Point, _ b: Point) -> Double { a.x * b.x + a.y * b.y }

  // MARK: - Following the edge

  /// Round each cell of four pixels, where the edge comes in and where it goes
  /// out, with what is dark always on the same side.
  private static func loops(_ pixels: UnsafeBufferPointer<UInt8>, _ width: Int, _ height: Int) -> [[Point]] {
    let middle = 127.5, across = width + 1
    // Round the picture there is paper.
    func grey(_ x: Int, _ y: Int) -> Double { x < 0 || y < 0 || x >= width || y >= height ? 255 : Double(pixels[y * width + x]) }
    // A crossing on the way right from a pixel, or on the way down.
    func right(_ x: Int, _ y: Int) -> Int { ((y + 1) * (across + 1) + x + 1) * 2 }
    func down(_ x: Int, _ y: Int) -> Int { right(x, y) + 1 }
    var next = [Int32](repeating: -1, count: (across + 1) * (height + 2) * 2)
    for y in -1..<height {
      for x in -1..<width {
        let a = grey(x, y) < middle, b = grey(x + 1, y) < middle, c = grey(x + 1, y + 1) < middle, d = grey(x, y + 1) < middle
        let kind = (a ? 1 : 0) | (b ? 2 : 0) | (c ? 4 : 0) | (d ? 8 : 0)
        guard kind != 0, kind != 15 else { continue }
        let top = right(x, y), bottom = right(x, y + 1), left = down(x, y), side = down(x + 1, y)
        func go(_ from: Int, _ to: Int) { next[from] = Int32(to) }
        switch kind {
        case 1: go(top, left)
        case 2: go(side, top)
        case 3: go(side, left)
        case 4: go(bottom, side)
        case 6: go(bottom, top)
        case 7: go(bottom, left)
        case 8: go(left, bottom)
        case 9: go(top, bottom)
        case 11: go(side, bottom)
        case 12: go(left, side)
        case 13: go(top, side)
        case 14: go(left, top)
        default:
          // Two that touch at a corner: one, if what is between them is dark.
          let isJoined = grey(x, y) + grey(x + 1, y) + grey(x + 1, y + 1) + grey(x, y + 1) < middle * 4
          if kind == 5 {
            if isJoined { go(top, side); go(bottom, left) } else { go(top, left); go(bottom, side) }
          } else {
            if isJoined { go(left, top); go(side, bottom) } else { go(side, top); go(left, bottom) }
          }
        }
      }
    }
    func place(_ crossing: Int) -> Point {
      let cell = crossing / 2, x = cell % (across + 1) - 1, y = cell / (across + 1) - 1
      let here = grey(x, y), there = crossing % 2 == 0 ? grey(x + 1, y) : grey(x, y + 1)
      let share = min(1, max(0, (middle - here) / (there - here)))
      return crossing % 2 == 0 ? Point(Double(x) + share + 0.5, Double(y) + 0.5) : Point(Double(x) + 0.5, Double(y) + share + 0.5)
    }
    var found: [[Point]] = []
    for start in next.indices where next[start] >= 0 {
      var loop: [Point] = [], at = start
      while next[at] >= 0 {
        loop.append(place(at))
        let to = Int(next[at])
        next[at] = -1
        at = to
      }
      if loop.count > 2 { found.append(loop) }
    }
    return found
  }

  // MARK: - Drawing it again

  /// As far as a curve may be from the edge, in pixels.
  private static let slack = 0.45
  /// What a corner is judged from: this far to either side of it, in pixels.
  private static let reach = 4.0
  /// Turned further than this, in degrees, it is a corner.
  private static let sharpest = 48.0

  private static func drawn(_ raw: [Point]) -> String {
    let loop = even(raw)
    let corners = corners(of: loop)
    var path = "", pieces: [[Point]] = []
    if corners.isEmpty {
      pieces = [loop + [loop[0]]]
    } else {
      for (index, from) in corners.enumerated() {
        let to = corners[(index + 1) % corners.count]
        var piece = from.at < to.at ? Array(loop[from.at...to.at]) : Array(loop[from.at...]) + Array(loop[...to.at])
        piece[0] = from.tip
        piece[piece.count - 1] = to.tip
        // What was cut off the corner lies behind its tip.
        while piece.count > 3, length(piece[1] - from.tip) < 1.2 { piece.remove(at: 1) }
        while piece.count > 3, length(piece[piece.count - 2] - to.tip) < 1.2 { piece.remove(at: piece.count - 2) }
        pieces.append(piece)
      }
    }
    for (index, piece) in pieces.enumerated() {
      if index == 0 { path = "M" + said(piece[0]) }
      let isRound = corners.isEmpty
      let seam = unit(loop[4 % loop.count] - loop[max(0, loop.count - 4)])
      let start = isRound ? seam : unit(piece[min(3, piece.count - 1)] - piece[0])
      let end = isRound ? -seam : unit(piece[max(0, piece.count - 4)] - piece[piece.count - 1])
      path += fitted(piece[...], start, end)
    }
    return path + "Z"
  }

  private static func said(_ p: Point) -> String { "\(Tool.text(p.x, 2)) \(Tool.text(p.y, 2))" }

  /// A point about every pixel and no nearer, so that so many points are so far.
  private static func even(_ loop: [Point]) -> [Point] {
    var out = [loop[0]]
    for point in loop.dropFirst() where length(point - out[out.count - 1]) > 0.5 { out.append(point) }
    return out.count > 5 ? out : loop
  }

  /// Where it turns, and the tip of each: where the two sides would meet.
  private static func corners(of loop: [Point]) -> [(at: Int, tip: Point)] {
    let count = loop.count, span = min(Int(reach), count / 6)
    guard span >= 2 else { return [] }
    func at(_ index: Int) -> Point { loop[(index % count + count) % count] }
    let turns = (0..<count).map { index -> Double in
      let before = unit(at(index) - at(index - span)), after = unit(at(index + span) - at(index))
      return acos(min(1, max(-1, dot(before, after)))) * 180 / .pi
    }
    let found = (0..<count).filter { index in
      turns[index] > sharpest && (1...span).allSatisfy { step in
        turns[index] > turns[(index + step) % count] && turns[index] >= turns[(index - step + count) % count]
      }
    }
    return found.map { index in
      // The sides a little way off, where the corner has not yet begun.
      let a = at(index - 2), b = at(index - 2 - span), c = at(index + 2), d = at(index + 2 + span)
      let one = a - b, two = c - d, cross = one.x * two.y - one.y * two.x
      guard abs(cross) > 1e-6 * length(one) * length(two) else { return (index, at(index)) }
      let gap = c - a, tip = a + one * ((gap.x * two.y - gap.y * two.x) / cross)
      return (index, length(tip - at(index)) < 1.5 ? tip : at(index))
    }
  }

  /// Schneider's: one curve if it keeps close enough, or else two, cut where
  /// it strays furthest.
  private static func fitted(_ points: ArraySlice<Point>, _ start: Point, _ end: Point) -> String {
    let first = points.first!, last = points.last!, count = points.count
    if count <= 2 { return "L" + said(last) }
    // A straight line is one.
    let side = unit(last - first), off = points.map { abs(side.x * ($0.y - first.y) - side.y * ($0.x - first.x)) }.max() ?? 0
    if off < slack, length(last - first) > 0.5 { return "L" + said(last) }

    var along = [0.0]
    for (a, b) in zip(points, points.dropFirst()) { along.append(along[along.count - 1] + length(b - a)) }
    guard let whole = along.last, whole > 0 else { return "L" + said(last) }
    along = along.map { $0 / whole }
    var curve = curve(points, along, start, end), worst = furthest(points, along, curve)
    var tries = 0
    while worst.far > slack * slack, worst.far < slack * slack * 16, tries < 6 {
      along = zip(points, along).map { nearer($0, $1, curve) }
      curve = Self.curve(points, along, start, end)
      worst = furthest(points, along, curve)
      tries += 1
    }
    if worst.far <= slack * slack || count <= 4 { return "C\(said(curve[1])) \(said(curve[2])) \(said(curve[3]))" }
    let cut = points.startIndex + min(max(worst.at, 1), count - 2)
    let from = max(points.startIndex, cut - 4), to = min(points.endIndex - 1, cut + 4), middle = unit(points[from] - points[to])
    return fitted(points[points.startIndex...cut], start, middle) + fitted(points[cut...], -middle, end)
  }

  private static func on(_ c: [Point], _ t: Double) -> Point {
    let u = 1 - t
    return c[0] * (u * u * u) + c[1] * (3 * u * u * t) + c[2] * (3 * u * t * t) + c[3] * (t * t * t)
  }

  private static func curve(_ points: ArraySlice<Point>, _ along: [Double], _ start: Point, _ end: Point) -> [Point] {
    let first = points.first!, last = points.last!
    var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0
    for (point, t) in zip(points, along) {
      let u = 1 - t, b1 = 3 * t * u * u, b2 = 3 * t * t * u
      let one = start * b1, two = end * b2
      c00 += dot(one, one); c01 += dot(one, two); c11 += dot(two, two)
      let rest = point - (first * (u * u * u + b1) + last * (b2 + t * t * t))
      x0 += dot(one, rest); x1 += dot(two, rest)
    }
    let size = length(last - first), base = c00 * c11 - c01 * c01
    var a = abs(base) > 1e-12 ? (x0 * c11 - x1 * c01) / base : 0, b = abs(base) > 1e-12 ? (c00 * x1 - c01 * x0) / base : 0
    // Nothing sensible comes of it: a third of the way, by hand.
    if a < size * 1e-6 || b < size * 1e-6 || size < 1e-9 {
      let third = max(size, points.dropFirst().reduce((0.0, first)) { ($0.0 + length($1 - $0.1), $1) }.0 * 0.5) / 3
      (a, b) = (third, third)
    }
    return [first, first + start * a, last + end * b, last]
  }

  private static func furthest(_ points: ArraySlice<Point>, _ along: [Double], _ curve: [Point]) -> (far: Double, at: Int) {
    var far = 0.0, at = points.count / 2
    for (index, (point, t)) in zip(points, along).enumerated() {
      let gap = on(curve, t) - point, size = dot(gap, gap)
      if size > far { (far, at) = (size, index) }
    }
    return (far, at)
  }

  /// A step of Newton's towards the nearest point of the curve.
  private static func nearer(_ point: Point, _ t: Double, _ c: [Point]) -> Double {
    let u = 1 - t, gap = on(c, t) - point
    let one = (c[1] - c[0]) * (3 * u * u) + (c[2] - c[1]) * (6 * u * t) + (c[3] - c[2]) * (3 * t * t)
    let two = (c[2] - c[1] * 2 + c[0]) * (6 * u) + (c[3] - c[2] * 2 + c[1]) * (6 * t)
    let base = dot(one, one) + dot(gap, two)
    return abs(base) < 1e-12 ? t : min(1, max(0, t - dot(gap, one) / base))
  }
}
