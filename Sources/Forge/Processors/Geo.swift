import Foundation

/// Places and tracks: GPX from a watch, KML from a map, GeoJSON from anywhere.
/// GeoJSON is what the others are read into.
enum Geo {
  private typealias Record = [String: Any]

  private static func collection(_ features: [[String: Any]]) -> [String: Any] { ["type": "FeatureCollection", "features": features] }

  private static func feature(_ kind: String, _ coordinates: Any, _ properties: [String: Any]) -> [String: Any] {
    ["type": "Feature", "geometry": ["type": kind, "coordinates": coordinates], "properties": properties]
  }

  private static func document(_ text: String, _ what: String) throws -> XMLElement {
    guard let root = try? XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever]).rootElement() else { throw DataFormats.broken(what) }
    return root
  }

  /// Wherever it is, whatever prefix it wears.
  private static func all(_ name: String, in element: XMLElement) -> [XMLElement] {
    (element.children ?? []).compactMap { $0 as? XMLElement }.flatMap { child in (child.localName == name ? [child] : []) + all(name, in: child) }
  }

  private static func words(_ name: String, in element: XMLElement) -> String? {
    (element.children ?? []).first { $0.localName == name }?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func facts(_ element: XMLElement, _ names: [String: String]) -> [String: Any] {
    names.reduce(into: [:]) { facts, pair in if let found = words(pair.key, in: element), !found.isEmpty { facts[pair.value] = found } }
  }

  // MARK: - GPX

  @Sendable static func gpx(_ text: String) throws -> Any {
    let root = try document(text, "a GPX file")
    func point(_ element: XMLElement) -> [Double]? {
      guard let lat = element.attribute(forName: "lat")?.stringValue.flatMap(Double.init), let lon = element.attribute(forName: "lon")?.stringValue.flatMap(Double.init) else { return nil }
      return [lon, lat] + (words("ele", in: element).flatMap(Double.init).map { [$0] } ?? [])
    }
    let names = ["name": "name", "desc": "description", "time": "time", "type": "type"]
    let places = all("wpt", in: root).compactMap { one in point(one).map { feature("Point", $0, facts(one, names)) } }
    let tracks = all("trk", in: root).map { one -> [String: Any] in
      let pieces = all("trkseg", in: one).map { all("trkpt", in: $0).compactMap(point) }.filter { !$0.isEmpty }
      var known = facts(one, names)
      let times = all("trkpt", in: one).compactMap { words("time", in: $0) }
      if !times.isEmpty { known["times"] = times }
      return pieces.count == 1 ? feature("LineString", pieces[0], known) : feature("MultiLineString", pieces, known)
    }
    let routes = all("rte", in: root).map { feature("LineString", all("rtept", in: $0).compactMap(point), facts($0, names)) }
    let found = places + tracks + routes
    guard !found.isEmpty else { throw DataFormats.broken("a GPX file") }
    return collection(found)
  }

  @Sendable static func gpx(_ value: Any) throws -> String {
    var body = ""
    func point(_ name: String, _ at: [Double], _ inside: String = "") -> String {
      #"<\#(name) lat="\#(Tool.text(at[1], 7))" lon="\#(Tool.text(at[0], 7))">"# + (at.count > 2 ? "<ele>\(Tool.text(at[2], 2))</ele>" : "") + inside + "</\(name)>"
    }
    for shape in try shapes(of: value) {
      let name = shape.name.map { "<name>\(DataFormats.escaped($0))</name>" } ?? ""
      if shape.isPoint {
        body += point("wpt", shape.lines[0][0], name) + "\n"
      } else {
        var times = shape.times.makeIterator()
        let pieces = shape.lines.map { line in
          "<trkseg>" + line.map { at in point("trkpt", at, times.next().map { "<time>\(DataFormats.escaped($0))</time>" } ?? "") }.joined() + "</trkseg>"
        }
        body += "<trk>" + name + pieces.joined() + "</trk>\n"
      }
    }
    return #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n" + #"<gpx version="1.1" creator="Forge" xmlns="http://www.topografix.com/GPX/1/1">"# + "\n" + body + "</gpx>\n"
  }

  // MARK: - KML

  @Sendable static func kml(_ text: String) throws -> Any {
    let root = try document(text, "a KML file")
    func points(_ element: XMLElement) -> [[Double]] {
      all("coordinates", in: element).first?.stringValue?.split(whereSeparator: \.isWhitespace).compactMap { one in
        let numbers = one.split(separator: ",").compactMap { Double($0) }
        return numbers.count >= 2 ? Array(numbers.prefix(3)) : nil
      } ?? []
    }
    let found = all("Placemark", in: root).flatMap { place -> [[String: Any]] in
      let known = facts(place, ["name": "name", "description": "description"])
      return all("Point", in: place).compactMap { points($0).first.map { feature("Point", $0, known) } }
        + all("LineString", in: place).map { feature("LineString", points($0), known) }
        + all("Polygon", in: place).map { shape in
          feature("Polygon", (all("outerBoundaryIs", in: shape) + all("innerBoundaryIs", in: shape)).map(points), known)
        }
    }
    guard !found.isEmpty else { throw DataFormats.broken("a KML file") }
    return collection(found)
  }

  @Sendable static func kmz(_ url: URL) throws -> Any {
    let zip = try Zip.Reader(url)
    guard let inside = zip.names.first(where: { $0.lowercased().hasSuffix(".kml") }) else { throw DataFormats.broken("a KMZ file") }
    return try kml(try zip.text(inside))
  }

  @Sendable static func kmz(_ value: Any) throws -> Data { Zip.data([Zip.Entry(name: "doc.kml", data: Data(try kml(value).utf8))]) }

  @Sendable static func kml(_ value: Any) throws -> String {
    func said(_ line: [[Double]]) -> String { line.map { $0.map { Tool.text($0, 7) }.joined(separator: ",") }.joined(separator: " ") }
    let places = try shapes(of: value).map { shape -> String in
      let name = shape.name.map { "<name>\(DataFormats.escaped($0))</name>" } ?? ""
      let body: String
      if shape.isPoint {
        body = "<Point><coordinates>\(said(shape.lines[0]))</coordinates></Point>"
      } else if shape.isArea {
        body = "<Polygon>" + shape.lines.enumerated().map { index, ring in
          let side = index == 0 ? "outerBoundaryIs" : "innerBoundaryIs"
          return "<\(side)><LinearRing><coordinates>\(said(ring))</coordinates></LinearRing></\(side)>"
        }.joined() + "</Polygon>"
      } else {
        body = "<MultiGeometry>" + shape.lines.map { "<LineString><coordinates>\(said($0))</coordinates></LineString>" }.joined() + "</MultiGeometry>"
      }
      return "<Placemark>\(name)\(body)</Placemark>\n"
    }
    return #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n" + #"<kml xmlns="http://www.opengis.net/kml/2.2"><Document>"# + "\n" + places.joined() + "</Document></kml>\n"
  }

  // MARK: - What is in it

  private struct Shape {
    var name: String?
    var times: [String] = []
    let lines: [[[Double]]]
    var isPoint = false
    var isArea = false
  }

  @Sendable static func geoJSON(_ value: Any) throws -> String {
    var made = value
    if (value as? [String: Any])?["type"] == nil {
      made = collection(try shapes(of: value).map { feature("Point", $0.lines[0][0], $0.name.map { ["name": $0] } ?? [:]) })
    }
    let data = try JSONSerialization.data(withJSONObject: try DataProcessor.jsonSafe(made), options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self) + "\n"
  }

  private static func shapes(of value: Any) throws -> [Shape] {
    if let record = value as? [String: Any], let kind = record["type"] as? String {
      let features = kind == "FeatureCollection" ? record["features"] as? [[String: Any]] ?? [] : kind == "Feature" ? [record] : [["geometry": record]]
      let found = features.flatMap { one -> [Shape] in
        let known = one["properties"] as? [String: Any] ?? [:]
        return shapes(of: one["geometry"] as? [String: Any] ?? [:], (known["name"] ?? known["title"]).map(Separated.describe), known["times"] as? [String] ?? [], depth: 0)
      }
      if !found.isEmpty { return found }
    }
    // A table with the two numbers in it is a list of places.
    if let tables = DataFormats.tables(in: value) {
      let found = tables.flatMap(\.table.rows).compactMap { row -> Shape? in
        let row = Dictionary(row.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        func number(_ names: [String]) -> Double? { names.compactMap { row[$0] }.compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }.first }
        guard let lat = number(["latitude", "lat", "y"]), let lon = number(["longitude", "lon", "lng", "long", "x"]) else { return nil }
        return Shape(name: row["name"] ?? row["title"], lines: [[[lon, lat] + (number(["elevation", "ele", "altitude"]).map { [$0] } ?? [])]], isPoint: true)
      }
      if !found.isEmpty { return found }
    }
    throw ProcessingError.conversionFailed(reason: "There are no places in it: a table needs the columns “latitude” and “longitude”.")
  }

  private static func shapes(of geometry: [String: Any], _ name: String?, _ times: [String], depth: Int) -> [Shape] {
    func point(_ value: Any) -> [Double]? {
      let numbers = (value as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
      return numbers.count >= 2 ? Array(numbers.prefix(3)) : nil
    }
    func line(_ value: Any) -> [[Double]] { (value as? [Any])?.compactMap(point) ?? [] }
    func lines(_ value: Any) -> [[[Double]]] { ((value as? [Any])?.map(line) ?? []).filter { !$0.isEmpty } }
    let inside = geometry["coordinates"] ?? []
    switch geometry["type"] as? String {
    case "Point": return point(inside).map { [Shape(name: name, lines: [[$0]], isPoint: true)] } ?? []
    case "MultiPoint": return line(inside).map { Shape(name: name, lines: [[$0]], isPoint: true) }
    case "LineString": return line(inside).isEmpty ? [] : [Shape(name: name, times: times, lines: [line(inside)])]
    case "MultiLineString": return lines(inside).isEmpty ? [] : [Shape(name: name, times: times, lines: lines(inside))]
    case "Polygon": return lines(inside).isEmpty ? [] : [Shape(name: name, lines: lines(inside), isArea: true)]
    case "MultiPolygon": return ((inside as? [Any]) ?? []).map(lines).filter { !$0.isEmpty }.map { Shape(name: name, lines: $0, isArea: true) }
    case "GeometryCollection" where depth < 8:
      return (geometry["geometries"] as? [[String: Any]] ?? []).flatMap { shapes(of: $0, name, times, depth: depth + 1) }
    default: return []
    }
  }

  /// Every point of it in a row of its own.
  static func table(of collection: [String: Any]) -> Separated.Table {
    var rows: [[String: String]] = []
    for shape in (try? shapes(of: collection)) ?? [] {
      var times = shape.times.makeIterator()
      for at in shape.lines.flatMap({ $0 }) {
        var row = ["latitude": Tool.text(at[1], 7), "longitude": Tool.text(at[0], 7)]
        if at.count > 2 { row["elevation"] = Tool.text(at[2], 2) }
        if let name = shape.name { row["name"] = name }
        if let time = times.next() { row["time"] = time }
        rows.append(row)
      }
    }
    let columns = ["name", "latitude", "longitude", "elevation", "time"].filter { column in rows.contains { $0[column] != nil } }
    return Separated.Table(columns: columns, rows: rows)
  }
}

extension Tool {
  /// To so many places, and no more zeros than it needs.
  static func text(_ value: Double, _ places: Int) -> String {
    var text = String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
  }
}
