import Compression
import Foundation
import simd

/// The shapes other programs save: FBX, 3D Studio, X3D, AMF.
extension Meshes {
  private static let upright = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0)))

  private static func moved(_ points: [SIMD3<Float>], _ place: simd_float4x4) -> [SIMD3<Float>] {
    points.map { let at = place * SIMD4($0.x, $0.y, $0.z, 1); return SIMD3(at.x, at.y, at.z) }
  }

  private static func shifted(_ t: SIMD3<Float>) -> simd_float4x4 {
    var place = matrix_identity_float4x4
    place.columns.3 = SIMD4(t.x, t.y, t.z, 1)
    return place
  }

  // MARK: - FBX

  private final class Branch {
    let name: String
    var numbers: [Int] = [], decimals: [Double] = [], words: [String] = [], list: [Double] = [], whole: [Int] = [], children: [Branch] = []
    init(_ name: String) { self.name = name }
    func child(_ name: String) -> Branch? { children.first { $0.name == name } }
    /// The value of a property, of the many that are all called P.
    func property(_ name: String) -> [Double]? { child("Properties70")?.children.first { $0.words.first == name }?.decimals }
  }

  static func fbx(_ url: URL) throws -> [Mesh] {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.prefix(18) == Data("Kaydara FBX Binary".utf8) else {
      throw ProcessingError.conversionFailed(reason: "\(url.lastPathComponent) is an FBX written as text, which Forge does not read. Save it as binary.")
    }
    let isLong = data.number(4, at: 23) >= 7500, word = isLong ? 8 : 4
    func branch(_ at: inout Int, _ depth: Int) throws -> Branch? {
      guard depth < 64, at + word * 3 + 1 <= data.count else { return nil }
      let end = data.number(word, at: at), count = data.number(word, at: at + word), length = data.number(1, at: at + word * 3)
      at += word * 3 + 1
      guard end > 0 else { return nil }
      guard end <= data.count, at + length <= end, count >= 0, count < 1 << 24 else { throw broken }
      let one = Branch(String(decoding: data[(data.startIndex + at)..<(data.startIndex + at + length)], as: UTF8.self))
      at += length
      for _ in 0..<count {
        guard at < end else { throw broken }
        let kind = Character(UnicodeScalar(data[data.startIndex + at]))
        at += 1
        func signed(_ size: Int) -> Int { let raw = data.number(size, at: at); return size < 8 && raw >> (size * 8 - 1) == 1 ? raw - 1 << (size * 8) : raw }
        switch kind {
        case "Y": one.numbers.append(signed(2)); one.decimals.append(Double(signed(2))); at += 2
        case "C", "B": one.numbers.append(data.number(1, at: at)); at += 1
        case "I": one.numbers.append(signed(4)); one.decimals.append(Double(signed(4))); at += 4
        case "L": one.numbers.append(signed(8)); one.decimals.append(Double(signed(8))); at += 8
        case "F": one.decimals.append(Double(Float(bitPattern: UInt32(data.number(4, at: at))))); at += 4
        case "D": one.decimals.append(Double(bitPattern: UInt64(bitPattern: Int64(data.number(8, at: at))))); at += 8
        case "S", "R":
          let size = data.number(4, at: at)
          guard at + 4 + size <= end else { throw broken }
          if kind == "S" { one.words.append(String(decoding: data[(data.startIndex + at + 4)..<(data.startIndex + at + 4 + size)], as: UTF8.self)) }
          at += 4 + size
        case "f", "d", "l", "i", "b", "c":
          let items = data.number(4, at: at), packed = data.number(4, at: at + 4) == 1, size = data.number(4, at: at + 8), width = ["f": 4, "d": 8, "l": 8, "i": 4][kind] ?? 1
          let bytes = packed ? size : items * width
          guard items * width <= Zip.largest, at + 12 + bytes <= end else { throw broken }
          let raw = data.subdata(in: (data.startIndex + at + 12)..<(data.startIndex + at + 12 + bytes))
          at += 12 + bytes
          // Only what a shape is made of is worth unpacking.
          guard ["Vertices", "PolygonVertexIndex"].contains(one.name) else { continue }
          let plain = packed ? try Data(raw.dropFirst(2)).unpacked(to: items * width, COMPRESSION_ZLIB) : raw
          for index in 0..<items {
            switch kind {
            case "f": one.list.append(Double(Float(bitPattern: UInt32(plain.number(4, at: index * 4)))))
            case "d": one.list.append(Double(bitPattern: UInt64(bitPattern: Int64(plain.number(8, at: index * 8)))))
            case "i": one.whole.append(Int(Int32(truncatingIfNeeded: plain.number(4, at: index * 4))))
            default: one.whole.append(plain.number(width, at: index * width))
            }
          }
        default: throw broken
        }
      }
      while at < end, let child = try branch(&at, depth + 1) { one.children.append(child) }
      at = end
      return one
    }
    var at = 27, roots: [Branch] = []
    while let one = try branch(&at, 0) { roots.append(one) }
    guard let objects = roots.first(where: { $0.name == "Objects" }) else { throw broken }

    var shapes: [Int: Mesh] = [:], nodes: [Int: Branch] = [:]
    for one in objects.children {
      guard let id = one.numbers.first else { continue }
      if one.name == "Model" { nodes[id] = one }
      guard one.name == "Geometry", let flat = one.child("Vertices")?.list, let corners = one.child("PolygonVertexIndex")?.whole else { continue }
      var mesh = Mesh(name: one.words.first?.components(separatedBy: "\u{0}").first.flatMap { $0.isEmpty ? nil : $0 } ?? "mesh")
      mesh.points = stride(from: 0, through: flat.count - 3, by: 3).map { SIMD3(Float(flat[$0]), Float(flat[$0 + 1]), Float(flat[$0 + 2])) }
      // The last corner of each side is written inside out.
      var face: [UInt32] = []
      for corner in corners {
        face.append(UInt32(clamping: corner < 0 ? ~corner : corner))
        guard corner < 0 else { continue }
        if face.count > 2 { for index in 1..<(face.count - 1) { mesh.triangles += [face[0], face[index], face[index + 1]] } }
        face = []
      }
      shapes[id] = mesh
    }
    var parent: [Int: Int] = [:], owners: [Int: [Int]] = [:]
    for link in roots.first(where: { $0.name == "Connections" })?.children ?? [] where link.numbers.count >= 2 && link.words.first == "OO" {
      let (child, above) = (link.numbers[0], link.numbers[1])
      if shapes[child] != nil { owners[child, default: []].append(above) } else if nodes[child] != nil { parent[child] = above }
    }
    func own(_ node: Branch) -> simd_float4x4 {
      func three(_ name: String, _ other: Float) -> SIMD3<Float> {
        let found = (node.property(name) ?? []).suffix(3).map { Float($0) }
        return found.count == 3 ? SIMD3(found[0], found[1], found[2]) : SIMD3(repeating: other)
      }
      func turned(_ degrees: SIMD3<Float>) -> simd_float4x4 {
        func about(_ angle: Float, _ axis: SIMD3<Float>) -> simd_float4x4 { simd_float4x4(simd_quatf(angle: angle * .pi / 180, axis: axis)) }
        return about(degrees.z, SIMD3(0, 0, 1)) * about(degrees.y, SIMD3(0, 1, 0)) * about(degrees.x, SIMD3(1, 0, 0))
      }
      let size = three("Lcl Scaling", 1)
      return shifted(three("Lcl Translation", 0)) * turned(three("PreRotation", 0)) * turned(three("Lcl Rotation", 0)) * simd_float4x4(diagonal: SIMD4(size.x, size.y, size.z, 1))
    }
    func whole(_ id: Int) -> simd_float4x4 {
      var place = matrix_identity_float4x4, here = id, steps = 0
      while let node = nodes[here], steps < 64 { place = own(node) * place; here = parent[here] ?? 0; steps += 1 }
      return place
    }
    let settings = roots.first { $0.name == "GlobalSettings" }
    // Said in centimetres, or so many of them.
    let metres = Float(settings?.property("UnitScaleFactor")?.last ?? 1) / 100
    let up = (settings?.property("UpAxis")?.last == 2 ? upright : matrix_identity_float4x4) * simd_float4x4(diagonal: SIMD4(metres, metres, metres, 1))
    return shapes.sorted { $0.key < $1.key }.flatMap { id, mesh in
      (owners[id].map { $0.map(whole) } ?? [matrix_identity_float4x4]).map { place in
        var one = mesh
        one.points = moved(mesh.points, up * place)
        return one
      }
    }
  }

  // MARK: - 3D Studio

  static func threeDS(_ url: URL) throws -> [Mesh] {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.number(2, at: 0) == 0x4D4D else { throw broken }
    var found: [Mesh] = []
    func walk(_ from: Int, _ end: Int) {
      var at = from
      while at + 6 <= end {
        let kind = data.number(2, at: at), size = data.number(4, at: at + 2), inside = at + 6, last = at + size
        guard size >= 6, last <= end else { return }
        switch kind {
        case 0x4D4D, 0x3D3D, 0x4100: walk(inside, last)
        case 0x4000:
          let name = data.subdata(in: (data.startIndex + inside)..<(data.startIndex + last)).prefix { $0 != 0 }
          found.append(Mesh(name: String(decoding: name, as: UTF8.self)))
          walk(inside + name.count + 1, last)
        case 0x4110 where !found.isEmpty:
          found[found.count - 1].points = (0..<min(data.number(2, at: inside), (size - 8) / 12)).map { index in
            let place = inside + 2 + index * 12
            func float(_ part: Int) -> Float { Float(bitPattern: UInt32(data.number(4, at: place + part * 4))) }
            return SIMD3(float(0), float(1), float(2))
          }
        case 0x4120 where !found.isEmpty:
          found[found.count - 1].triangles = (0..<min(data.number(2, at: inside), (size - 8) / 8)).flatMap { index in
            (0..<3).map { UInt32(data.number(2, at: inside + 2 + index * 8 + $0 * 2)) }
          }
        default: break
        }
        at = last
      }
    }
    walk(0, data.count)
    return found.map { var one = $0; one.points = moved($0.points, upright); return one }
  }

  // MARK: - X3D

  static func x3d(_ url: URL) throws -> [Mesh] {
    guard let root = try? XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever]).rootElement() else { throw broken }
    var found: [Mesh] = []
    func floats(_ element: XMLElement, _ name: String) -> [Float] {
      (element.attribute(forName: name)?.stringValue ?? "").split { $0.isWhitespace || $0 == "," }.compactMap { Float($0) }
    }
    func walk(_ element: XMLElement, _ above: simd_float4x4, _ depth: Int) {
      guard depth < 64 else { return }
      var place = above
      if element.localName == "Transform" {
        let t = floats(element, "translation"), r = floats(element, "rotation"), s = floats(element, "scale")
        if t.count == 3 { place = place * shifted(SIMD3(t[0], t[1], t[2])) }
        if r.count == 4, r[3] != 0 { place = place * simd_float4x4(simd_quatf(angle: r[3], axis: simd_normalize(SIMD3(r[0], r[1], r[2])))) }
        if s.count == 3 { place = place * simd_float4x4(diagonal: SIMD4(s[0], s[1], s[2], 1)) }
      }
      let kind = element.localName ?? ""
      if ["IndexedFaceSet", "IndexedTriangleSet", "TriangleSet"].contains(kind), let points = (element.children ?? []).compactMap({ $0 as? XMLElement }).first(where: { $0.localName == "Coordinate" }) {
        let flat = floats(points, "point")
        var mesh = Mesh()
        mesh.points = moved(stride(from: 0, through: flat.count - 3, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }, place)
        if kind == "IndexedFaceSet" {
          for face in floats(element, "coordIndex").split(separator: -1) where face.count > 2 {
            let face = face.map { UInt32(exactly: $0.rounded()) ?? .max }
            for index in 1..<(face.count - 1) { mesh.triangles += [face[0], face[index], face[index + 1]] }
          }
        } else if kind == "IndexedTriangleSet" {
          mesh.triangles = floats(element, "index").map { UInt32(exactly: $0.rounded()) ?? .max }
        } else {
          mesh.triangles = (0..<UInt32(mesh.points.count)).map { $0 }
        }
        mesh.triangles.removeLast(mesh.triangles.count % 3)
        found.append(mesh)
      }
      for child in element.children ?? [] { if let child = child as? XMLElement { walk(child, place, depth + 1) } }
    }
    walk(root, matrix_identity_float4x4, 0)
    return found
  }

  // MARK: - AMF

  static func amf(_ url: URL) throws -> [Mesh] {
    var data = try Data(contentsOf: url)
    if let zip = try? Zip.Reader(data), let name = zip.names.first(where: { $0.lowercased().hasSuffix(".amf") }) { data = try zip.data(name) }
    final class Reader: NSObject, XMLParserDelegate {
      var meshes: [Mesh] = [], words = "", point = SIMD3<Float>()
      func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "object" { meshes.append(Mesh()) }
        words = ""
      }
      func parser(_ parser: XMLParser, foundCharacters text: String) { words += text }
      func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard !meshes.isEmpty else { return }
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "x": point.x = Float(said) ?? 0
        case "y": point.y = Float(said) ?? 0
        case "z": point.z = Float(said) ?? 0
        case "vertex": meshes[meshes.count - 1].points.append(point)
        case "v1", "v2", "v3": meshes[meshes.count - 1].triangles.append(UInt32(said) ?? 0)
        default: break
        }
        words = ""
      }
    }
    let reader = Reader(), parser = XMLParser(data: data)
    parser.delegate = reader
    guard parser.parse() else { throw broken }
    return reader.meshes
  }
}
