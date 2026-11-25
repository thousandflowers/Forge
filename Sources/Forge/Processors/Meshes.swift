import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO
import simd

/// The 3D formats the system does not read, as points and triangles. What a
/// shape is made of - its colours, its pictures - stays behind.
// ponytail: geometry only; carry glTF materials across when somebody misses them.
enum Meshes {
  struct Mesh {
    var name = "mesh"
    var points: [SIMD3<Float>] = []
    var triangles: [UInt32] = []
  }

  private static let most = 20_000_000
  static let broken = ProcessingError.conversionFailed(reason: "It looks damaged: there is no shape in it that can be read.")

  static let readable: Set<String> = ["gltf", "glb", "3mf", "off", "dae", "fbx", "3ds", "x3d", "amf"]
  static let writable: Set<String> = ["glb", "gltf", "3mf", "off"]

  static func read(_ url: URL) throws -> [Mesh] {
    let found: [Mesh]
    switch url.pathExtension.lowercased() {
    case "gltf", "glb": found = try glTF(url)
    case "3mf": found = try threeMF(url)
    case "off": found = [try off(url)]
    case "dae": found = try collada(url)
    case "fbx": found = try fbx(url)
    case "3ds": found = try threeDS(url)
    case "x3d": found = try x3d(url)
    case "amf": found = try amf(url)
    default: found = []
    }
    let whole = found.filter { mesh in !mesh.points.isEmpty && mesh.triangles.count >= 3 && mesh.triangles.allSatisfy { Int($0) < mesh.points.count } }
    guard !whole.isEmpty else { throw broken }
    return whole
  }

  static func data(_ meshes: [Mesh], as ext: String) throws -> Data {
    switch ext {
    case "glb": return glb(meshes)
    case "gltf": return plainGLTF(meshes)
    case "3mf": return threeMF(meshes)
    default: return off(meshes)
    }
  }

  // MARK: - To and from the system

  static func asset(_ meshes: [Mesh]) -> MDLAsset {
    let asset = MDLAsset(), allocator = MDLMeshBufferDataAllocator()
    for mesh in meshes {
      let packed = mesh.points.flatMap { [$0.x, $0.y, $0.z] }
      let corners = allocator.newBuffer(with: packed.withUnsafeBytes { Data($0) }, type: .vertex)
      let index = allocator.newBuffer(with: mesh.triangles.withUnsafeBytes { Data($0) }, type: .index)
      let layout = MDLVertexDescriptor()
      layout.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
      layout.layouts[0] = MDLVertexBufferLayout(stride: 12)
      let part = MDLSubmesh(indexBuffer: index, indexCount: mesh.triangles.count, indexType: .uInt32, geometryType: .triangles, material: nil)
      let made = MDLMesh(vertexBuffer: corners, vertexCount: mesh.points.count, descriptor: layout, submeshes: [part])
      made.name = mesh.name
      made.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
      asset.add(made)
    }
    return asset
  }

  static func of(_ asset: MDLAsset) throws -> [Mesh] {
    let found = (asset.childObjects(of: MDLMesh.self) as? [MDLMesh] ?? []).compactMap { mesh -> Mesh? in
      guard let points = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { return nil }
      let place = MDLTransform.globalTransform(with: mesh, atTime: 0)
      var made = Mesh(name: mesh.name.isEmpty ? "mesh" : mesh.name)
      made.points = (0..<mesh.vertexCount).map { index in
        let at = points.dataStart.advanced(by: index * points.stride).assumingMemoryBound(to: Float.self)
        let moved = place * SIMD4(at[0], at[1], at[2], 1)
        return SIMD3(moved.x, moved.y, moved.z)
      }
      for case let part as MDLSubmesh in mesh.submeshes ?? [] {
        // Whatever it is in, as triangles.
        guard let flat = part.geometryType == .triangles ? part : MDLSubmesh(mdlSubmesh: part, indexType: .uInt32, geometryType: .triangles) else { continue }
        let map = flat.indexBuffer(asIndexType: .uInt32).map()
        let numbers = map.bytes.assumingMemoryBound(to: UInt32.self)
        made.triangles += (0..<(flat.indexCount / 3 * 3)).map { numbers[$0] }
      }
      return made.triangles.isEmpty ? nil : made
    }
    guard !found.isEmpty else { throw broken }
    return found
  }

  // MARK: - glTF

  private static func glTF(_ url: URL) throws -> [Mesh] {
    let file = try Data(contentsOf: url)
    var text = file, packed: Data?
    if file.prefix(4) == Data("glTF".utf8) {
      var at = 12
      while at + 8 <= file.count {
        let length = file.number(4, at: at), kind = file.number(4, at: at + 4)
        guard at + 8 + length <= file.count else { throw broken }
        let piece = file.subdata(in: (at + 8)..<(at + 8 + length))
        if kind == 0x4E4F_534A { text = piece } else if kind == 0x004E_4942, packed == nil { packed = piece }
        at += 8 + length
      }
    }
    guard let all = try JSONSerialization.jsonObject(with: text) as? [String: Any] else { throw broken }
    if let needs = all["extensionsRequired"] as? [String], let hard = needs.first(where: { $0.contains("draco") || $0.contains("meshopt") }) {
      throw ProcessingError.conversionFailed(reason: "\(url.lastPathComponent) is squeezed with \(hard), which Forge does not read.")
    }
    func list(_ key: String) -> [[String: Any]] { all[key] as? [[String: Any]] ?? [] }
    let buffers = try list("buffers").enumerated().map { index, buffer -> Data in
      guard let uri = buffer["uri"] as? String else { return index == 0 ? packed ?? Data() : Data() }
      if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") { return Data(base64Encoded: String(uri[uri.index(after: comma)...])) ?? Data() }
      // Beside it and nowhere else.
      let name = uri.removingPercentEncoding ?? uri
      guard !name.contains("/"), !name.contains(":") else { throw broken }
      return try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(name))
    }
    let views = list("bufferViews"), accessors = list("accessors")
    func numbers(_ index: Int, per: Int) throws -> [Double] {
      guard accessors.indices.contains(index), let view = accessors[index]["bufferView"] as? Int, views.indices.contains(view),
            let buffer = views[view]["buffer"] as? Int, buffers.indices.contains(buffer), let count = accessors[index]["count"] as? Int,
            (0...most).contains(count), let kind = accessors[index]["componentType"] as? Int, let size = [5121: 1, 5123: 2, 5125: 4, 5126: 4, 5120: 1, 5122: 2][kind] else { throw broken }
      let data = buffers[buffer], stride = views[view]["byteStride"] as? Int ?? size * per
      let offsets = [views[view]["byteOffset"] as? Int ?? 0, accessors[index]["byteOffset"] as? Int ?? 0]
      // Nothing in it can be further apart, or further on, than all of it.
      guard offsets.allSatisfy({ (0...data.count).contains($0) }), (1...max(1, data.count)).contains(stride) else { throw broken }
      let start = offsets[0] + offsets[1]
      guard count == 0 || start + (count - 1) * stride + size * per <= data.count else { throw broken }
      var out: [Double] = []
      out.reserveCapacity(count * per)
      for one in 0..<count {
        for part in 0..<per {
          let raw = data.number(size, at: start + one * stride + part * size)
          out.append(kind == 5126 ? Double(Float(bitPattern: UInt32(raw))) : Double(raw))
        }
      }
      return out
    }

    var found: [Mesh] = []
    let meshes = list("meshes"), nodes = list("nodes")
    func add(_ index: Int, _ place: simd_float4x4) throws {
      guard meshes.indices.contains(index) else { return }
      for part in meshes[index]["primitives"] as? [[String: Any]] ?? [] {
        guard (part["mode"] as? Int ?? 4) == 4, let position = (part["attributes"] as? [String: Any])?["POSITION"] as? Int else { continue }
        let flat = try numbers(position, per: 3)
        var mesh = Mesh(name: meshes[index]["name"] as? String ?? "mesh")
        mesh.points = stride(from: 0, to: flat.count, by: 3).map { at in
          let moved = place * SIMD4(Float(flat[at]), Float(flat[at + 1]), Float(flat[at + 2]), 1)
          return SIMD3(moved.x, moved.y, moved.z)
        }
        mesh.triangles = try (part["indices"] as? Int).map { try numbers($0, per: 1).map { UInt32(exactly: $0) ?? .max } } ?? (0..<UInt32(mesh.points.count)).map { $0 }
        found.append(mesh)
      }
    }
    func walk(_ index: Int, _ above: simd_float4x4, _ depth: Int) throws {
      guard nodes.indices.contains(index), depth < 64 else { return }
      let node = nodes[index], place = above * transform(node)
      if let mesh = node["mesh"] as? Int { try add(mesh, place) }
      for child in node["children"] as? [Int] ?? [] { try walk(child, place, depth + 1) }
    }
    let scenes = list("scenes"), scene = all["scene"] as? Int ?? 0
    let roots = scenes.indices.contains(scene) ? scenes[scene]["nodes"] as? [Int] ?? [] : Array(nodes.indices)
    for root in roots { try walk(root, matrix_identity_float4x4, 0) }
    if found.isEmpty { for index in meshes.indices { try add(index, matrix_identity_float4x4) } }
    return found
  }

  private static func transform(_ node: [String: Any]) -> simd_float4x4 {
    func floats(_ key: String, _ count: Int) -> [Float]? {
      let found = (node[key] as? [NSNumber])?.map(\.floatValue)
      return found?.count == count ? found : nil
    }
    if let m = floats("matrix", 16) {
      return simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]), SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
    }
    var place = matrix_identity_float4x4
    if let q = floats("rotation", 4) { place = simd_float4x4(simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3])) }
    if let s = floats("scale", 3) { place = place * simd_float4x4(diagonal: SIMD4(s[0], s[1], s[2], 1)) }
    if let t = floats("translation", 3) { place.columns.3 = SIMD4(t[0], t[1], t[2], 1) }
    return place
  }

  private static func described(_ meshes: [Mesh]) -> (json: [String: Any], bytes: Data) {
    var bytes = Data(), views: [[String: Any]] = [], accessors: [[String: Any]] = [], made: [[String: Any]] = []
    for mesh in meshes {
      let low = mesh.points.reduce(mesh.points[0], simd_min), high = mesh.points.reduce(mesh.points[0], simd_max)
      let points = mesh.points.flatMap { [$0.x, $0.y, $0.z] }.withUnsafeBytes { Data($0) }
      let corners = mesh.triangles.withUnsafeBytes { Data($0) }
      views.append(["buffer": 0, "byteOffset": bytes.count, "byteLength": points.count, "target": 34962])
      accessors.append(["bufferView": views.count - 1, "componentType": 5126, "count": mesh.points.count, "type": "VEC3",
                        "min": [low.x, low.y, low.z].map(Double.init), "max": [high.x, high.y, high.z].map(Double.init)])
      bytes.append(points)
      views.append(["buffer": 0, "byteOffset": bytes.count, "byteLength": corners.count, "target": 34963])
      accessors.append(["bufferView": views.count - 1, "componentType": 5125, "count": mesh.triangles.count, "type": "SCALAR"])
      bytes.append(corners)
      made.append(["name": mesh.name, "primitives": [["attributes": ["POSITION": accessors.count - 2], "indices": accessors.count - 1]]])
    }
    return ([
      "asset": ["version": "2.0", "generator": "Forge"], "scene": 0, "scenes": [["nodes": Array(made.indices)]],
      "nodes": made.indices.map { ["mesh": $0] }, "meshes": made, "accessors": accessors, "bufferViews": views,
      "buffers": [["byteLength": bytes.count]],
    ], bytes)
  }

  private static func glb(_ meshes: [Mesh]) -> Data {
    let (json, bytes) = described(meshes)
    var text = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
    while text.count % 4 != 0 { text.append(0x20) }
    var out = Data("glTF".utf8)
    out.append(number: 2, 4); out.append(number: 12 + 8 + text.count + 8 + bytes.count, 4)
    out.append(number: text.count, 4); out.append(number: 0x4E4F_534A, 4); out.append(text)
    out.append(number: bytes.count, 4); out.append(number: 0x004E_4942, 4); out.append(bytes)
    return out
  }

  private static func plainGLTF(_ meshes: [Mesh]) -> Data {
    var (json, bytes) = described(meshes)
    json["buffers"] = [["byteLength": bytes.count, "uri": "data:application/octet-stream;base64," + bytes.base64EncodedString()]]
    return (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
  }

  // MARK: - COLLADA

  /// SceneKit writes one, and reads it somewhere else that is not always let in.
  private static func collada(_ url: URL) throws -> [Mesh] {
    guard let root = try? XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever]).rootElement() else { throw broken }
    func children(_ element: XMLElement, _ name: String) -> [XMLElement] { (element.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name } }
    func every(_ element: XMLElement, _ name: String) -> [XMLElement] {
      (element.children ?? []).compactMap { $0 as? XMLElement }.flatMap { ($0.localName == name ? [$0] : []) + every($0, name) }
    }
    func value(_ element: XMLElement, _ name: String) -> String { element.attribute(forName: name)?.stringValue ?? "" }
    func link(_ element: XMLElement, _ name: String) -> String { String(value(element, name).drop { $0 == "#" }) }
    func floats(_ element: XMLElement) -> [Float] { (element.stringValue ?? "").split(whereSeparator: \.isWhitespace).compactMap { Float($0) } }
    func numbers(_ element: XMLElement) -> [Int] { (element.stringValue ?? "").split(whereSeparator: \.isWhitespace).compactMap { Int($0) } }

    var shapes: [String: [Mesh]] = [:]
    for geometry in every(root, "geometry") {
      guard let body = children(geometry, "mesh").first, let corners = children(body, "vertices").first,
            let position = children(corners, "input").first(where: { value($0, "semantic") == "POSITION" }),
            let source = children(body, "source").first(where: { value($0, "id") == link(position, "source") }),
            let array = children(source, "float_array").first else { continue }
      let flat = floats(array), step = every(source, "accessor").first.flatMap { Int(value($0, "stride")) } ?? 3
      guard step >= 3 else { throw broken }
      var mesh = Mesh(name: value(geometry, "name").isEmpty ? "mesh" : value(geometry, "name"))
      mesh.points = stride(from: 0, through: flat.count - 3, by: step).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }
      for part in ["triangles", "polylist", "polygons"].flatMap({ children(body, $0) }) {
        let inputs = children(part, "input")
        let width = (inputs.compactMap { Int(value($0, "offset")) }.max() ?? 0) + 1
        let place = inputs.first { value($0, "semantic") == "VERTEX" }.flatMap { Int(value($0, "offset")) } ?? 0
        guard width < 64 else { throw broken }
        let counts = children(part, "vcount").first.map(numbers)
        for list in children(part, "p") {
          let all = numbers(list), used = stride(from: place, to: all.count, by: width).map { UInt32(clamping: all[$0]) }
          let sides = counts ?? (part.localName == "triangles" ? Array(repeating: 3, count: used.count / 3) : [used.count])
          var at = 0
          for side in sides where side >= 3 && at + side <= used.count {
            for index in 1..<(side - 1) { mesh.triangles += [used[at], used[at + index], used[at + index + 1]] }
            at += side
          }
        }
      }
      shapes[value(geometry, "id"), default: []].append(mesh)
    }

    let nodes = Dictionary(every(root, "node").map { (value($0, "id"), $0) }, uniquingKeysWith: { first, _ in first })
    var found: [Mesh] = []
    func put(_ id: String, _ place: simd_float4x4) {
      for var mesh in shapes[id] ?? [] {
        mesh.points = mesh.points.map { let moved = place * SIMD4($0.x, $0.y, $0.z, 1); return SIMD3(moved.x, moved.y, moved.z) }
        found.append(mesh)
      }
    }
    func walk(_ node: XMLElement, _ above: simd_float4x4, _ depth: Int) {
      guard depth < 64 else { return }
      var place = above
      for case let step as XMLElement in node.children ?? [] {
        let n = floats(step)
        switch step.localName {
        case "matrix" where n.count == 16: place = place * simd_float4x4(rows: [SIMD4(n[0], n[1], n[2], n[3]), SIMD4(n[4], n[5], n[6], n[7]), SIMD4(n[8], n[9], n[10], n[11]), SIMD4(n[12], n[13], n[14], n[15])])
        case "translate" where n.count == 3:
          var moved = matrix_identity_float4x4
          moved.columns.3 = SIMD4(n[0], n[1], n[2], 1)
          place = place * moved
        case "scale" where n.count == 3: place = place * simd_float4x4(diagonal: SIMD4(n[0], n[1], n[2], 1))
        case "rotate" where n.count == 4 && n[3] != 0: place = place * simd_float4x4(simd_quatf(angle: n[3] * .pi / 180, axis: simd_normalize(SIMD3(n[0], n[1], n[2]))))
        case "instance_geometry", "instance_controller": put(link(step, "url"), place)
        case "instance_node": if let other = nodes[link(step, "url")] { walk(other, place, depth + 1) }
        case "node": walk(step, place, depth + 1)
        default: break
        }
      }
    }
    // Up is up.
    let upright = every(root, "up_axis").first?.stringValue == "Z_UP" ? simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))) : matrix_identity_float4x4
    for scene in every(root, "visual_scene") { for node in children(scene, "node") { walk(node, upright, 0) } }
    if found.isEmpty { for id in shapes.keys.sorted() { put(id, upright) } }
    return found
  }

  // MARK: - 3MF

  private static func threeMF(_ url: URL) throws -> [Mesh] {
    let zip = try Zip.Reader(url)
    var found: [Mesh] = []
    // The whole of it where it is in one part; in several, the shapes in each.
    for part in zip.names where part.lowercased().hasSuffix(".model") { found += try model(try zip.data(part)) }
    return found
  }

  private static func model(_ data: Data) throws -> [Mesh] {
    final class Reader: NSObject, XMLParserDelegate {
      var meshes: [String: Mesh] = [:], order: [String] = [], parts: [String: [(String, simd_float4x4)]] = [:], built: [(String, simd_float4x4)] = []
      var id = ""

      func place(_ text: String?) -> simd_float4x4 {
        let n = (text ?? "").split(separator: " ").compactMap { Float($0) }
        guard n.count == 12 else { return matrix_identity_float4x4 }
        return simd_float4x4(SIMD4(n[0], n[1], n[2], 0), SIMD4(n[3], n[4], n[5], 0), SIMD4(n[6], n[7], n[8], 0), SIMD4(n[9], n[10], n[11], 1))
      }

      func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch name.split(separator: ":").last.map(String.init) ?? name {
        case "object":
          id = a["id"] ?? ""
          meshes[id] = Mesh(name: a["name"] ?? "mesh")
          order.append(id)
        case "vertex": meshes[id]?.points.append(SIMD3(Float(a["x"] ?? "") ?? 0, Float(a["y"] ?? "") ?? 0, Float(a["z"] ?? "") ?? 0))
        case "triangle": meshes[id]?.triangles += ["v1", "v2", "v3"].map { UInt32(a[$0] ?? "") ?? 0 }
        case "component": parts[id, default: []].append((a["objectid"] ?? "", place(a["transform"])))
        case "item": built.append((a["objectid"] ?? "", place(a["transform"])))
        default: break
        }
      }
    }
    let reader = Reader(), parser = XMLParser(data: data)
    parser.delegate = reader
    guard parser.parse() else { throw broken }
    var found: [Mesh] = []
    func put(_ id: String, _ place: simd_float4x4, _ depth: Int) {
      guard depth < 32, var mesh = reader.meshes[id] else { return }
      if !mesh.triangles.isEmpty {
        mesh.points = mesh.points.map { let moved = place * SIMD4($0.x, $0.y, $0.z, 1); return SIMD3(moved.x, moved.y, moved.z) }
        found.append(mesh)
      }
      for (part, inside) in reader.parts[id] ?? [] { put(part, place * inside, depth + 1) }
    }
    for (id, place) in reader.built { put(id, place, 0) }
    if found.isEmpty { for id in reader.order { put(id, matrix_identity_float4x4, 0) } }
    return found
  }

  private static func threeMF(_ meshes: [Mesh]) -> Data {
    let objects = meshes.enumerated().map { index, mesh in
      "<object id=\"\(index + 1)\" type=\"model\" name=\"\(DataFormats.escaped(mesh.name))\"><mesh><vertices>"
        + mesh.points.map { "<vertex x=\"\($0.x)\" y=\"\($0.y)\" z=\"\($0.z)\"/>" }.joined() + "</vertices><triangles>"
        + stride(from: 0, to: mesh.triangles.count - 2, by: 3).map { "<triangle v1=\"\(mesh.triangles[$0])\" v2=\"\(mesh.triangles[$0 + 1])\" v3=\"\(mesh.triangles[$0 + 2])\"/>" }.joined()
        + "</triangles></mesh></object>"
    }
    let head = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
    let model = head + #"<model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources>"# + objects.joined()
      + "</resources><build>" + meshes.indices.map { "<item objectid=\"\($0 + 1)\"/>" }.joined() + "</build></model>"
    return Zip.data([
      Zip.Entry(name: "[Content_Types].xml", data: Data((head + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>"#).utf8)),
      Zip.Entry(name: "_rels/.rels", data: Data((head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>"#).utf8)),
      Zip.Entry(name: "3D/3dmodel.model", data: Data(model.utf8)),
    ])
  }

  // MARK: - OFF

  private static func off(_ url: URL) throws -> Mesh {
    let lines = try DocumentText.text(in: url).split(whereSeparator: \.isNewline).map { $0.split(separator: "#", omittingEmptySubsequences: false)[0] }
    var words = lines.joined(separator: " ").split(whereSeparator: \.isWhitespace).makeIterator()
    guard let first = words.next(), first.hasSuffix("OFF") else { throw broken }
    func number() throws -> Int { guard let word = words.next(), let value = Int(word) else { throw broken }; return value }
    func float() throws -> Float { guard let word = words.next(), let value = Float(word) else { throw broken }; return value }
    let points = try number(), faces = try number()
    _ = try number()
    guard (1...most).contains(points), (1...most).contains(faces) else { throw broken }
    var mesh = Mesh()
    mesh.points = try (0..<points).map { _ in SIMD3(try float(), try float(), try float()) }
    for _ in 0..<faces {
      let corners = try number()
      guard (3...10_000).contains(corners) else { throw broken }
      let face = try (0..<corners).map { _ in UInt32(clamping: try number()) }
      for index in 1..<(corners - 1) { mesh.triangles += [face[0], face[index], face[index + 1]] }
    }
    return mesh
  }

  private static func off(_ meshes: [Mesh]) -> Data {
    var points: [String] = [], faces: [String] = []
    for mesh in meshes {
      let base = UInt32(points.count)
      points += mesh.points.map { "\($0.x) \($0.y) \($0.z)" }
      faces += stride(from: 0, to: mesh.triangles.count - 2, by: 3).map { "3 \(base + mesh.triangles[$0]) \(base + mesh.triangles[$0 + 1]) \(base + mesh.triangles[$0 + 2])" }
    }
    return Data((["OFF", "\(points.count) \(faces.count) 0"] + points + faces).joined(separator: "\n").utf8) + Data("\n".utf8)
  }
}

/// A picture of a shape, from a little above and to one side.
enum ModelPicture {
  private static let side: CGFloat = 1600

  static func draw(_ asset: MDLAsset) throws -> CGImage {
    let scene = SCNScene(mdlAsset: asset)
    scene.background.contents = NSColor.white
    let (low, high) = scene.rootNode.boundingBox
    let middle = SCNVector3((low.x + high.x) / 2, (low.y + high.y) / 2, (low.z + high.z) / 2)
    let reach = sqrt(pow(high.x - low.x, 2) + pow(high.y - low.y, 2) + pow(high.z - low.z, 2)) / 2
    guard reach > 0 else { throw Meshes.broken }
    let eye = SCNNode()
    eye.camera = SCNCamera()
    eye.camera?.fieldOfView = 35
    let away = reach / sin(35 / 2 * .pi / 180) * 1.05
    eye.camera?.zNear = Double(max(away - reach * 2, away * 0.01))
    eye.camera?.zFar = Double(away + reach * 2)
    eye.position = SCNVector3(middle.x + away * 0.55, middle.y + away * 0.4, middle.z + away * 0.733)
    eye.look(at: middle)
    scene.rootNode.addChildNode(eye)
    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice())
    renderer.scene = scene
    renderer.pointOfView = eye
    renderer.autoenablesDefaultLighting = true
    let picture = renderer.snapshot(atTime: 0, with: CGSize(width: side, height: side), antialiasingMode: .multisampling4X)
    guard let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Meshes.broken }
    return image
  }
}
