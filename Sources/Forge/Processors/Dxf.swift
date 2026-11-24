import CoreGraphics
import CoreText
import Foundation
import UniformTypeIdentifiers

/// The drawing every CAD program exchanges: pairs of a number, which says what
/// the next line is, and the line.
struct Dxf {
  struct Stroke { let path: CGPath; let colour: CGColor; var isFilled = false }
  struct Words { let text: String; let at: CGPoint; let height: CGFloat; let angle: CGFloat; let colour: CGColor }

  private(set) var strokes: [Stroke] = []
  private(set) var words: [Words] = []

  private static let deepest = 16
  private static let most = 2_000_000

  private typealias Pairs = [(code: Int, text: String)]
  private struct Entity { let kind: String; let pairs: Pairs
    func all(_ code: Int) -> [CGFloat] { pairs.filter { $0.code == code }.compactMap { Double($0.text).map { CGFloat($0) } } }
    func one(_ code: Int, _ other: CGFloat = 0) -> CGFloat { all(code).first ?? other }
    func text(_ code: Int) -> String? { pairs.first { $0.code == code }?.text }
    func points(_ x: Int, _ y: Int) -> [CGPoint] { zip(all(x), all(y)).map { CGPoint(x: $0, y: $1) } }
  }

  static func read(_ url: URL) throws -> Dxf {
    let text = try DocumentText.text(in: url)
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    let unreadable = ProcessingError.conversionFailed(reason: "\(url.lastPathComponent) is not a DXF drawing Forge can read.")
    guard lines.count < most * 4 else { throw unreadable }
    var pairs: Pairs = []
    for index in stride(from: 0, to: lines.count - 1, by: 2) {
      guard let code = Int(lines[index]) else { if pairs.isEmpty { throw unreadable } else { break } }
      pairs.append((code, lines[index + 1]))
    }
    var entities: [Entity] = [], blocks: [String: (base: CGPoint, entities: [Entity])] = [:], layers: [String: Int] = [:]
    var section = "", block: (name: String, base: CGPoint, entities: [Entity])?
    var at = 0
    while at < pairs.count {
      guard pairs[at].code == 0 else { at += 1; continue }
      let kind = pairs[at].text
      var end = at + 1
      while end < pairs.count, pairs[end].code != 0 { end += 1 }
      let one = Entity(kind: kind, pairs: Array(pairs[(at + 1)..<end]))
      at = end
      switch kind {
      case "SECTION": section = one.text(2) ?? ""
      case "ENDSEC": section = ""
      case "LAYER": if let name = one.text(2) { layers[name] = Int(one.one(62, 7)) }
      case "BLOCK": block = (one.text(2) ?? "", CGPoint(x: one.one(10), y: one.one(20)), [])
      case "ENDBLK":
        if let done = block { blocks[done.name] = (done.base, done.entities) }
        block = nil
      default:
        if block != nil { block?.entities.append(one) } else if section == "ENTITIES" { entities.append(one) }
      }
    }
    var drawing = Dxf()
    drawing.add(entities, .identity, blocks, layers, 0)
    guard !drawing.strokes.isEmpty || !drawing.words.isEmpty else { throw unreadable }
    return drawing
  }

  /// AutoCAD's first colours; the rest are near enough black on paper.
  private static func colour(_ index: Int) -> CGColor {
    let known: [Int: (CGFloat, CGFloat, CGFloat)] = [1: (0.85, 0, 0), 2: (0.75, 0.65, 0), 3: (0, 0.6, 0), 4: (0, 0.6, 0.65), 5: (0, 0, 0.85), 6: (0.75, 0, 0.75), 8: (0.4, 0.4, 0.4), 9: (0.6, 0.6, 0.6)]
    let (r, g, b) = known[index] ?? (0, 0, 0)
    return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
  }

  private mutating func add(_ entities: [Entity], _ place: CGAffineTransform, _ blocks: [String: (base: CGPoint, entities: [Entity])], _ layers: [String: Int], _ depth: Int) {
    var index = 0
    while index < entities.count, strokes.count < Self.most {
      let one = entities[index]
      index += 1
      let own = Int(one.one(62, 256)), tint = Self.colour(own == 256 ? abs(layers[one.text(8) ?? ""] ?? 7) : own)
      func put(_ path: CGPath, filled: Bool = false) {
        var place = place
        if let moved = path.copy(using: &place) { strokes.append(Stroke(path: moved, colour: tint, isFilled: filled)) }
      }
      let path = CGMutablePath(), centre = CGPoint(x: one.one(10), y: one.one(20))
      // Seen from behind, left is right.
      let flip: CGFloat = one.one(230, 1) < 0 ? -1 : 1
      switch one.kind {
      case "LINE":
        path.move(to: centre)
        path.addLine(to: CGPoint(x: one.one(11), y: one.one(21)))
        put(path)
      case "CIRCLE":
        path.addEllipse(in: CGRect(x: centre.x * flip - one.one(40), y: centre.y - one.one(40), width: 2 * one.one(40), height: 2 * one.one(40)))
        put(path)
      case "ARC":
        let from = one.one(50) * .pi / 180, to = one.one(51) * .pi / 180
        path.addArc(center: CGPoint(x: centre.x * flip, y: centre.y), radius: one.one(40), startAngle: flip < 0 ? .pi - from : from, endAngle: flip < 0 ? .pi - to : to, clockwise: flip < 0)
        put(path)
      case "ELLIPSE":
        let axis = CGPoint(x: one.one(11), y: one.one(21)), ratio = one.one(40, 1), from = one.one(41), to = one.one(42, 2 * .pi)
        let span = to > from ? to - from : to - from + 2 * .pi, steps = max(8, Int(span / .pi * 32))
        for step in 0...steps {
          let t = from + span * CGFloat(step) / CGFloat(steps)
          let point = CGPoint(x: centre.x + axis.x * cos(t) - axis.y * ratio * flip * sin(t), y: centre.y + axis.y * cos(t) + axis.x * ratio * flip * sin(t))
          if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        put(path)
      case "LWPOLYLINE":
        // How each side bulges is said after its corner, where it does.
        var corners: [(CGPoint, CGFloat)] = [], x: CGFloat = 0
        for pair in one.pairs {
          guard let value = Double(pair.text).map({ CGFloat($0) }) else { continue }
          if pair.code == 10 { x = value } else if pair.code == 20 { corners.append((CGPoint(x: x * flip, y: value), 0)) } else if pair.code == 42, !corners.isEmpty { corners[corners.count - 1].1 = value * flip }
        }
        Self.line(corners, isClosed: Int(one.one(70)) & 1 == 1, on: path)
        put(path)
      case "POLYLINE":
        var corners: [(CGPoint, CGFloat)] = []
        while index < entities.count, entities[index].kind == "VERTEX" {
          corners.append((CGPoint(x: entities[index].one(10) * flip, y: entities[index].one(20)), entities[index].one(42) * flip))
          index += 1
        }
        if index < entities.count, entities[index].kind == "SEQEND" { index += 1 }
        // A net of faces is not a line.
        if Int(one.one(70)) & 80 == 0 { Self.line(corners, isClosed: Int(one.one(70)) & 1 == 1, on: path); put(path) }
      case "SPLINE":
        Self.spline(one.points(10, 20), knots: one.all(40), degree: Int(one.one(71, 3)), fits: one.points(11, 21), on: path)
        put(path)
      case "SOLID", "TRACE", "3DFACE":
        let c = (10...13).map { CGPoint(x: one.one($0), y: one.one($0 + 10)) }
        // A solid goes round the wrong way for its last two.
        path.addLines(between: one.kind == "3DFACE" ? c : [c[0], c[1], c[3], c[2]])
        path.closeSubpath()
        put(path, filled: one.kind != "3DFACE")
      case "TEXT", "MTEXT", "ATTRIB":
        let raw = one.pairs.filter { $0.code == 3 }.map(\.text).joined() + (one.text(1) ?? "")
        let said = raw.replacing(#/\\P/#, with: "\n").replacing(#/\\[A-Za-z][^;\\]*;/#, with: "").replacingOccurrences(of: "%%d", with: "°").replacingOccurrences(of: "%%c", with: "⌀").replacingOccurrences(of: "%%p", with: "±").filter { !"{}".contains($0) }
        let size = one.one(40, 2.5) * hypot(place.a, place.b)
        for (line, words) in said.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where !words.isEmpty {
          // Several lines hang from the top.
          let drop = one.kind == "MTEXT" ? -one.one(40, 2.5) * (1 + 1.5 * CGFloat(line)) : 0
          self.words.append(Words(text: String(words), at: CGPoint(x: centre.x, y: centre.y + drop).applying(place), height: size, angle: one.one(50) * .pi / 180 + atan2(place.b, place.a), colour: tint))
        }
      case "INSERT", "DIMENSION":
        guard depth < Self.deepest, let name = one.text(2), let block = blocks[name] else { continue }
        var inside = place
        if one.kind == "INSERT" {
          inside = CGAffineTransform(translationX: centre.x * flip, y: centre.y).concatenating(place)
          inside = CGAffineTransform(rotationAngle: one.one(50) * .pi / 180 * flip).concatenating(inside)
          inside = CGAffineTransform(scaleX: one.one(41, 1) * flip, y: one.one(42, 1)).concatenating(inside)
          inside = CGAffineTransform(translationX: -block.base.x, y: -block.base.y).concatenating(inside)
        }
        add(block.entities, inside, blocks, layers, depth + 1)
      default: break
      }
    }
  }

  private static func line(_ corners: [(CGPoint, CGFloat)], isClosed: Bool, on path: CGMutablePath) {
    guard let first = corners.first, corners.count > 1 else { return }
    path.move(to: first.0)
    for index in 0..<(isClosed ? corners.count : corners.count - 1) {
      let (from, bulge) = corners[index], to = corners[(index + 1) % corners.count].0
      let across = hypot(to.x - from.x, to.y - from.y)
      guard abs(bulge) > 1e-9, across > 0 else { path.addLine(to: to); continue }
      // The tangent of a quarter of the angle it goes round.
      let radius = across * (1 + bulge * bulge) / (4 * abs(bulge)), middle = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
      let off = (1 - bulge * bulge) / (4 * bulge)
      let centre = CGPoint(x: middle.x - (to.y - from.y) * off, y: middle.y + (to.x - from.x) * off)
      path.addArc(center: centre, radius: radius, startAngle: atan2(from.y - centre.y, from.x - centre.x), endAngle: atan2(to.y - centre.y, to.x - centre.x), clockwise: bulge < 0)
    }
    if isClosed { path.closeSubpath() }
  }

  private static func spline(_ control: [CGPoint], knots: [CGFloat], degree: Int, fits: [CGPoint], on path: CGMutablePath) {
    guard degree >= 1, degree < 12, control.count > degree, knots.count == control.count + degree + 1 else {
      // Only where it passes is known.
      path.addLines(between: fits.isEmpty ? control : fits)
      return
    }
    let low = knots[degree], high = knots[control.count], steps = min(4000, control.count * 12)
    for step in 0...steps {
      let t = min(low + (high - low) * CGFloat(step) / CGFloat(steps), high - (high - low) * 1e-9)
      let span = (degree..<control.count).last { knots[$0] <= t } ?? degree
      var d = (0...degree).map { control[span - degree + $0] }
      for round in 1...degree {
        for j in stride(from: degree, through: round, by: -1) {
          let left = knots[span - degree + j], width = knots[span + 1 + j - round] - left
          let share = width == 0 ? 0 : (t - left) / width
          d[j] = CGPoint(x: d[j - 1].x * (1 - share) + d[j].x * share, y: d[j - 1].y * (1 - share) + d[j].y * share)
        }
      }
      if step == 0 { path.move(to: d[degree]) } else { path.addLine(to: d[degree]) }
    }
  }

  // MARK: - Drawn

  private var bounds: CGRect {
    let boxes = strokes.map { $0.path.boundingBoxOfPath }.filter { !$0.isNull && !$0.isInfinite } + words.map { CGRect(x: $0.at.x, y: $0.at.y, width: CGFloat($0.text.count) * $0.height * 0.6, height: $0.height) }
    let all = boxes.dropFirst().reduce(boxes.first ?? .zero) { $0.union($1) }
    let margin = max(all.width, all.height, 1) * 0.03
    return all.insetBy(dx: -margin, dy: -margin)
  }

  /// As large as a sheet of A3, whatever it was measured in.
  private static let side: CGFloat = 1190

  func pdf(to output: URL) throws {
    let all = bounds, scale = Self.side / max(all.width, all.height)
    var box = CGRect(x: 0, y: 0, width: all.width * scale, height: all.height * scale)
    guard let context = CGContext(output as CFURL, mediaBox: &box, nil) else { throw ProcessingError.conversionFailed(reason: "Cannot write \(output.lastPathComponent)") }
    context.beginPDFPage(nil)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -all.minX, y: -all.minY)
    context.setLineWidth(0.75 / scale)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for stroke in strokes {
      context.addPath(stroke.path)
      if stroke.isFilled { context.setFillColor(stroke.colour); context.fillPath() } else { context.setStrokeColor(stroke.colour); context.strokePath() }
    }
    for word in words {
      let font = CTFontCreateWithName("Helvetica" as CFString, word.height * 1.35, nil)
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: word.text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): word.colour,
      ]))
      context.saveGState()
      context.translateBy(x: word.at.x, y: word.at.y)
      context.rotate(by: word.angle)
      context.textPosition = .zero
      CTLineDraw(line, context)
      context.restoreGState()
    }
    context.endPDFPage()
    context.closePDF()
  }

  func svg() -> String {
    let all = bounds
    func n(_ value: CGFloat) -> String { Tool.text(Double(value), 4) }
    // Down is down on a screen, and up on a drawing board.
    func p(_ point: CGPoint) -> String { "\(n(point.x - all.minX)) \(n(all.maxY - point.y))" }
    func hex(_ colour: CGColor) -> String { "#" + (colour.components ?? [0, 0, 0]).prefix(3).map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined() }
    let drawn = strokes.map { stroke -> String in
      var d = ""
      stroke.path.applyWithBlock { piece in
        let at = piece.pointee.points
        switch piece.pointee.type {
        case .moveToPoint: d += "M\(p(at[0]))"
        case .addLineToPoint: d += "L\(p(at[0]))"
        case .addQuadCurveToPoint: d += "Q\(p(at[0])) \(p(at[1]))"
        case .addCurveToPoint: d += "C\(p(at[0])) \(p(at[1])) \(p(at[2]))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
      }
      return stroke.isFilled ? "<path d=\"\(d)\" fill=\"\(hex(stroke.colour))\" stroke=\"none\"/>" : "<path d=\"\(d)\" stroke=\"\(hex(stroke.colour))\"/>"
    } + words.map { word in
      "<text transform=\"translate(\(p(word.at))) rotate(\(n(-word.angle * 180 / .pi)))\" font-family=\"Helvetica\" font-size=\"\(n(word.height * 1.35))\" fill=\"\(hex(word.colour))\" stroke=\"none\">\(DataFormats.escaped(word.text))</text>"
    }
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <svg xmlns="http://www.w3.org/2000/svg" width="\(n(all.width))" height="\(n(all.height))" viewBox="0 0 \(n(all.width)) \(n(all.height))">
      <g fill="none" stroke-width="\(n(max(all.width, all.height) / 1200))" stroke-linecap="round" stroke-linejoin="round">
      \(drawn.joined(separator: "\n"))
      </g></svg>

      """
  }

  // MARK: - Written

  /// The outlines, as the oldest DXF there is, which everything opens.
  static func data(_ paths: [CGPath], height: CGFloat) -> Data {
    var out = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n"
    for path in paths {
      for (points, isClosed) in flat(path) where points.count > 1 {
        out += "0\nPOLYLINE\n8\n0\n66\n1\n70\n\(isClosed ? 1 : 0)\n10\n0\n20\n0\n30\n0\n"
        for point in points { out += "0\nVERTEX\n8\n0\n10\n\(Tool.text(Double(point.x), 4))\n20\n\(Tool.text(Double(height - point.y), 4))\n30\n0\n" }
        out += "0\nSEQEND\n8\n0\n"
      }
    }
    return Data((out + "0\nENDSEC\n0\nEOF\n").utf8)
  }

  /// Curves as short lines: there are none in that DXF.
  private static func flat(_ path: CGPath) -> [([CGPoint], Bool)] {
    var all: [([CGPoint], Bool)] = [], now: [CGPoint] = []
    func end(_ closed: Bool) { if now.count > 1 { all.append((now, closed)) }; now = [] }
    path.applyWithBlock { piece in
      let at = piece.pointee.points
      func curve(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) {
        guard let from = now.last else { return }
        let rough = hypot(a.x - from.x, a.y - from.y) + hypot(b.x - a.x, b.y - a.y) + hypot(c.x - b.x, c.y - b.y), steps = min(200, max(4, Int(rough / 2)))
        for step in 1...steps {
          let t = CGFloat(step) / CGFloat(steps), u = 1 - t
          now.append(CGPoint(x: u * u * u * from.x + 3 * u * u * t * a.x + 3 * u * t * t * b.x + t * t * t * c.x, y: u * u * u * from.y + 3 * u * u * t * a.y + 3 * u * t * t * b.y + t * t * t * c.y))
        }
      }
      switch piece.pointee.type {
      case .moveToPoint: end(false); now = [at[0]]
      case .addLineToPoint: now.append(at[0])
      case .addQuadCurveToPoint:
        if let from = now.last {
          let a = CGPoint(x: from.x + (at[0].x - from.x) * 2 / 3, y: from.y + (at[0].y - from.y) * 2 / 3), b = CGPoint(x: at[1].x + (at[0].x - at[1].x) * 2 / 3, y: at[1].y + (at[0].y - at[1].y) * 2 / 3)
          curve(a, b, at[1])
        }
      case .addCurveToPoint: curve(at[0], at[1], at[2])
      case .closeSubpath:
        let first = now.first
        end(true)
        now = first.map { [$0] } ?? []
      @unknown default: break
      }
    }
    end(false)
    return all
  }
}

/// The outlines in an SVG.
enum SvgPaths {
  static func read(_ url: URL) throws -> (paths: [CGPath], size: CGSize) {
    guard let root = try? XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever]).rootElement(), root.localName == "svg" else {
      throw ProcessingError.conversionFailed(reason: "\(url.lastPathComponent) is not an SVG Forge can read.")
    }
    let names = Dictionary(every(root).compactMap { element in element.attribute(forName: "id")?.stringValue.map { ($0, element) } }, uniquingKeysWith: { first, _ in first })
    var paths: [CGPath] = []
    func number(_ element: XMLElement, _ name: String) -> CGFloat { numbers(element.attribute(forName: name)?.stringValue ?? "").first ?? 0 }
    func walk(_ element: XMLElement, _ above: CGAffineTransform, _ depth: Int) {
      guard depth < 64, !["defs", "symbol", "clipPath", "mask", "marker", "pattern"].contains(element.localName ?? "") || depth == 0 else { return }
      var place = transform(element.attribute(forName: "transform")?.stringValue ?? "").concatenating(above)
      let path = CGMutablePath()
      switch element.localName {
      case "path": path.addPath(outline(element.attribute(forName: "d")?.stringValue ?? ""))
      case "rect":
        let box = CGRect(x: number(element, "x"), y: number(element, "y"), width: number(element, "width"), height: number(element, "height"))
        let rx = min(max(number(element, "rx"), number(element, "ry")), min(box.width, box.height) / 2)
        if box.width > 0, box.height > 0 { if rx > 0 { path.addRoundedRect(in: box, cornerWidth: rx, cornerHeight: rx) } else { path.addRect(box) } }
      case "circle", "ellipse":
        let rx = number(element, element.localName == "circle" ? "r" : "rx"), ry = number(element, element.localName == "circle" ? "r" : "ry")
        path.addEllipse(in: CGRect(x: number(element, "cx") - rx, y: number(element, "cy") - ry, width: 2 * rx, height: 2 * ry))
      case "line":
        path.move(to: CGPoint(x: number(element, "x1"), y: number(element, "y1")))
        path.addLine(to: CGPoint(x: number(element, "x2"), y: number(element, "y2")))
      case "polyline", "polygon":
        let flat = numbers(element.attribute(forName: "points")?.stringValue ?? "")
        let points = stride(from: 0, to: flat.count - 1, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
        if points.count > 1 { path.addLines(between: points); if element.localName == "polygon" { path.closeSubpath() } }
      case "use":
        let link = (element.attribute(forName: "href") ?? element.attribute(forName: "xlink:href"))?.stringValue ?? ""
        place = CGAffineTransform(translationX: number(element, "x"), y: number(element, "y")).concatenating(place)
        if let other = names[String(link.drop { $0 == "#" })] { walk(other, place, depth + 1) }
      default: break
      }
      if !path.isEmpty, let moved = path.copy(using: &place) { paths.append(moved) }
      for child in element.children ?? [] { if let child = child as? XMLElement { walk(child, place, depth + 1) } }
    }
    let box = numbers(root.attribute(forName: "viewBox")?.stringValue ?? "")
    let size = box.count == 4 ? CGSize(width: box[2], height: box[3]) : CGSize(width: number(root, "width"), height: number(root, "height"))
    walk(root, box.count == 4 ? CGAffineTransform(translationX: -box[0], y: -box[1]) : .identity, 0)
    guard !paths.isEmpty else { throw ProcessingError.conversionFailed(reason: "There are no outlines in \(url.lastPathComponent).") }
    return (paths, size)
  }

  private static func every(_ element: XMLElement) -> [XMLElement] { [element] + (element.children ?? []).compactMap { $0 as? XMLElement }.flatMap(every) }

  static func numbers(_ text: String) -> [CGFloat] { text.matches(of: #/[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/#).compactMap { Double($0.0).map { CGFloat($0) } } }

  private static func transform(_ text: String) -> CGAffineTransform {
    text.matches(of: #/(\w+)\s*\(([^)]*)\)/#).reduce(.identity) { all, match in
      let n = numbers(String(match.2)), one: CGAffineTransform
      switch match.1 {
      case "translate": one = CGAffineTransform(translationX: n.first ?? 0, y: n.count > 1 ? n[1] : 0)
      case "scale": one = CGAffineTransform(scaleX: n.first ?? 1, y: n.count > 1 ? n[1] : n.first ?? 1)
      case "rotate":
        let turn = CGAffineTransform(rotationAngle: (n.first ?? 0) * .pi / 180)
        one = n.count == 3 ? CGAffineTransform(translationX: -n[1], y: -n[2]).concatenating(turn).concatenating(CGAffineTransform(translationX: n[1], y: n[2])) : turn
      case "skewX": one = CGAffineTransform(a: 1, b: 0, c: tan((n.first ?? 0) * .pi / 180), d: 1, tx: 0, ty: 0)
      case "skewY": one = CGAffineTransform(a: 1, b: tan((n.first ?? 0) * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
      case "matrix" where n.count == 6: one = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
      default: one = .identity
      }
      return one.concatenating(all)
    }
  }

  static func outline(_ d: String) -> CGPath {
    let path = CGMutablePath()
    var at = CGPoint.zero, start = CGPoint.zero, handle: CGPoint?, last: Character = " "
    for match in d.matches(of: #/([MmLlHhVvCcSsQqTtAaZz])([^MmLlHhVvCcSsQqTtAaZz]*)/#) {
      let code = match.1.first ?? "Z", isRelative = code.isLowercase, kind = Character(code.uppercased())
      let n = kind == "A" ? arcNumbers(String(match.2)) : numbers(String(match.2))
      if kind == "Z" { path.closeSubpath(); at = start; last = kind; handle = nil; continue }
      let size = ["M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7][kind] ?? 2
      for (round, from) in stride(from: 0, through: n.count - size, by: size).enumerated() {
        func point(_ index: Int) -> CGPoint { CGPoint(x: n[from + index] + (isRelative ? at.x : 0), y: n[from + index + 1] + (isRelative ? at.y : 0)) }
        func mirrored(_ kinds: String) -> CGPoint { handle.flatMap { kinds.contains(last) ? CGPoint(x: 2 * at.x - $0.x, y: 2 * at.y - $0.y) : nil } ?? at }
        if path.isEmpty, kind != "M" { path.move(to: at) }
        var to = at, next: CGPoint?
        switch kind {
        case "M": to = point(0); if round == 0 { path.move(to: to); start = to } else { path.addLine(to: to) }
        case "L": to = point(0); path.addLine(to: to)
        case "H": to = CGPoint(x: n[from] + (isRelative ? at.x : 0), y: at.y); path.addLine(to: to)
        case "V": to = CGPoint(x: at.x, y: n[from] + (isRelative ? at.y : 0)); path.addLine(to: to)
        case "C": to = point(4); next = point(2); path.addCurve(to: to, control1: point(0), control2: point(2))
        case "S": let first = mirrored("CS"); to = point(2); next = point(0); path.addCurve(to: to, control1: first, control2: point(0))
        case "Q": to = point(2); next = point(0); path.addQuadCurve(to: to, control: point(0))
        case "T": let first = mirrored("QT"); to = point(0); next = first; path.addQuadCurve(to: to, control: first)
        default:
          to = CGPoint(x: n[from + 5] + (isRelative ? at.x : 0), y: n[from + 6] + (isRelative ? at.y : 0))
          arc(path, at, to, abs(n[from]), abs(n[from + 1]), n[from + 2] * .pi / 180, n[from + 3] != 0, n[from + 4] != 0)
        }
        at = to
        handle = next
        last = kind
      }
    }
    return path
  }

  /// The two flags of an arc may be written with nothing between them.
  private static func arcNumbers(_ text: String) -> [CGFloat] {
    var out: [CGFloat] = [], rest = Substring(text)
    while true {
      rest = rest.drop { $0.isWhitespace || $0 == "," }
      if out.count % 7 == 3 || out.count % 7 == 4 {
        guard let flag = rest.first, flag == "0" || flag == "1" else { return out }
        out.append(flag == "1" ? 1 : 0)
        rest = rest.dropFirst()
      } else {
        guard let match = rest.prefixMatch(of: #/[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/#), let value = Double(match.0) else { return out }
        out.append(CGFloat(value))
        rest = rest[match.range.upperBound...]
      }
    }
  }

  private static func arc(_ path: CGMutablePath, _ from: CGPoint, _ to: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ turn: CGFloat, _ isLarge: Bool, _ isSweep: Bool) {
    guard rx > 0, ry > 0, from != to else { path.addLine(to: to); return }
    let dx = (from.x - to.x) / 2, dy = (from.y - to.y) / 2
    let x = cos(turn) * dx + sin(turn) * dy, y = -sin(turn) * dx + cos(turn) * dy
    let grow = max(1, (x * x / (rx * rx) + y * y / (ry * ry)).squareRoot()), a = rx * grow, b = ry * grow
    let under = a * a * y * y + b * b * x * x
    let share = (max(0, (a * a * b * b - under) / under)).squareRoot() * (isLarge == isSweep ? -1 : 1)
    let cx = share * a * y / b, cy = -share * b * x / a
    let first = atan2((y - cy) / b, (x - cx) / a), second = atan2((-y - cy) / b, (-x - cx) / a)
    let centre = CGPoint(x: cos(turn) * cx - sin(turn) * cy + (from.x + to.x) / 2, y: sin(turn) * cx + cos(turn) * cy + (from.y + to.y) / 2)
    let place = CGAffineTransform(scaleX: a, y: b).concatenating(CGAffineTransform(rotationAngle: turn)).concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
    path.addArc(center: .zero, radius: 1, startAngle: first, endAngle: second, clockwise: !isSweep, transform: place)
  }
}

/// An SVG as lines a cutter follows, or as a PDF with its lines still lines.
final class OutlineProcessor: FileProcessor, @unchecked Sendable {
  let name = "Outline Processor"
  func canProcess(_ file: ProcessableFile) -> Bool { file.fileType == .svg }

  func takes(_ file: ProcessableFile, to target: UTType) -> Bool {
    Conversions.fileExtension(of: target) == "dxf" || target == .pdf
  }

  func process(
    _ input: URL, to output: URL, with operations: [Operation], progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ProcessingResult {
    // A processor that reads a file is asked for any format, and hands on what is not its own.
    guard ["dxf", "pdf"].contains(output.pathExtension.lowercased()) else {
      throw ProcessingError.unsupportedConversion(from: UTType(filenameExtension: input.pathExtension) ?? .data, to: UTType(filenameExtension: output.pathExtension) ?? .data)
    }
    let start = Date()
    if output.pathExtension.lowercased() == "dxf" {
      let (paths, size) = try SvgPaths.read(input)
      try Dxf.data(paths, height: size.height).write(to: output, options: .atomic)
    } else {
      // Asked to be another size, or filtered, it is a picture of itself.
      guard !operations.contains(where: { operation in
        switch operation {
        case .resize, .filter, .tool, .limitSize: return true
        default: return false
        }
      }),
            let root = try? XMLDocument(contentsOf: input, options: [.nodeLoadExternalEntitiesNever]).rootElement() else {
        throw ProcessingError.unsupportedConversion(from: .svg, to: .pdf)
      }
      func side(_ name: String) -> CGFloat? {
        guard let text = root.attribute(forName: name)?.stringValue, !text.hasSuffix("%") else { return nil }
        let scale: CGFloat = text.hasSuffix("mm") ? 96 / 25.4 : text.hasSuffix("cm") ? 96 / 2.54 : text.hasSuffix("in") ? 96 : text.hasSuffix("pt") ? 96.0 / 72 : 1
        return SvgPaths.numbers(text).first.map { $0 * scale }
      }
      let box = SvgPaths.numbers(root.attribute(forName: "viewBox")?.stringValue ?? "")
      let size = CGSize(width: side("width") ?? (box.count == 4 ? box[2] : 512), height: side("height") ?? (box.count == 4 ? box[3] : 512))
      guard size.width > 0, size.height > 0, max(size.width, size.height) < 14_400 else { throw ProcessingError.unsupportedConversion(from: .svg, to: .pdf) }
      try await Drawn.vector(input, size: size, to: output)
    }
    progress(1)
    let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
    return ProcessingResult(outputURL: output, outputSize: size, outputDimensions: nil, duration: Date().timeIntervalSince(start))
  }
}
