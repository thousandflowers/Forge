import Foundation

/// The box old Office kept things in: a small disk inside a file, with a table
/// of which piece follows which.
struct Ole {
  private let bytes: Data
  private let next: [Int]
  private let smallNext: [Int]
  private let small: Data
  private let sector: Int
  private struct Place { let start, size: Int; let isRoot: Bool }
  private let places: [String: Place]

  static let broken = ProcessingError.conversionFailed(reason: "It looks damaged: what is inside it cannot be read.")
  private static let most = 1 << 20

  init(_ url: URL) throws {
    let data = try Data(contentsOf: url)
    guard data.prefix(8) == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) else { throw Self.broken }
    bytes = data
    let shift = data.number(2, at: 30)
    guard shift == 9 || shift == 12 else { throw Self.broken }
    let sector = 1 << shift
    self.sector = sector
    func at(_ index: Int) -> Int { (index + 1) * sector }
    // Where the table itself is: some of it listed at the front, the rest in a chain.
    var tables = (0..<109).map { data.number(4, at: 76 + 4 * $0) }.filter { $0 < 0xFFFF_FFFA }
    var more = data.number(4, at: 68), steps = 0
    while more < 0xFFFF_FFFA, steps < Self.most, at(more) + sector <= data.count {
      let count = sector / 4 - 1
      tables += (0..<count).map { data.number(4, at: at(more) + 4 * $0) }.filter { $0 < 0xFFFF_FFFA }
      more = data.number(4, at: at(more) + 4 * count)
      steps += 1
    }
    let next = tables.filter { at($0) + sector <= data.count }.flatMap { table in (0..<(sector / 4)).map { data.number(4, at: at(table) + 4 * $0) } }
    self.next = next
    func chain(_ start: Int, _ next: [Int]) -> [Int] {
      var all: [Int] = [], here = start
      while here < next.count, all.count < Self.most { all.append(here); here = next[here] }
      return all
    }
    func read(_ start: Int) -> Data { chain(start, next).reduce(into: Data()) { $0.append(data.subdata(in: min(at($1), data.count)..<min(at($1) + sector, data.count))) } }
    let folder = read(data.number(4, at: 48))
    smallNext = { let table = read(data.number(4, at: 60)); return (0..<(table.count / 4)).map { table.number(4, at: 4 * $0) } }()

    var names: [(name: String, kind: Int, left: Int, right: Int, child: Int, start: Int, size: Int)] = []
    for index in 0..<min(folder.count / 128, Self.most) {
      let entry = index * 128, length = max(0, min(64, folder.number(2, at: entry + 64)) - 2)
      let name = String(decoding: (0..<(length / 2)).map { UInt16(folder.number(2, at: entry + 2 * $0)) }, as: UTF16.self)
      names.append((name, folder.number(1, at: entry + 66), folder.number(4, at: entry + 68), folder.number(4, at: entry + 72), folder.number(4, at: entry + 76), folder.number(4, at: entry + 116), folder.number(4, at: entry + 120)))
    }
    guard let root = names.first else { throw Self.broken }
    small = read(root.start)
    var places: [String: Place] = [:], seen: Set<Int> = []
    func walk(_ index: Int, _ path: String) {
      guard names.indices.contains(index), seen.insert(index).inserted, seen.count < Self.most else { return }
      let one = names[index]
      walk(one.left, path)
      walk(one.right, path)
      if one.kind == 1 { walk(one.child, path + one.name + "/") } else if one.kind == 2 { places[path + one.name] = Place(start: one.start, size: one.size, isRoot: false) }
    }
    walk(root.child, "")
    self.places = places
  }

  var names: [String] { places.keys.sorted() }

  func data(_ name: String) -> Data? {
    guard let place = places[name], place.size <= bytes.count else { return nil }
    let isSmall = place.size < 4096, size = isSmall ? 64 : sector, table = isSmall ? smallNext : next
    var out = Data(), here = place.start
    while here < table.count, out.count < place.size {
      let start = isSmall ? here * 64 : (here + 1) * sector, from = isSmall ? small : bytes
      guard start + 1 <= from.count else { break }
      out.append(from.subdata(in: start..<min(start + size, from.count)))
      here = table[here]
    }
    return out.prefix(place.size).count == place.size ? Data(out.prefix(place.size)) : nil
  }
}

/// Excel 97 to 2003.
enum Xls {
  @Sendable static func read(_ url: URL) throws -> Any {
    let ole = try Ole(url)
    guard let book = ole.data("Workbook") ?? ole.data("Book") else { throw DataFormats.broken("an Excel workbook") }
    var records: [(kind: Int, at: Int, data: Data)] = [], at = 0
    while at + 4 <= book.count {
      let size = book.number(2, at: at + 2)
      guard at + 4 + size <= book.count else { break }
      records.append((book.number(2, at: at), at, book.subdata(in: (at + 4)..<(at + 4 + size))))
      at += 4 + size
    }
    guard !records.contains(where: { $0.kind == 0x2F }) else { throw ProcessingError.conversionFailed(reason: "\(url.lastPathComponent) is locked with a password.") }
    var sheets: [(name: String, at: Int)] = [], words: [String] = [], formats: [Int: String] = [:], styles: [Int] = [], countsFrom1904 = false
    for (index, record) in records.enumerated() {
      switch record.kind {
      case 0x85 where record.data.count > 8 && record.data.number(1, at: 5) == 0:
        sheets.append((text(record.data, at: 7, length: record.data.number(1, at: 6), flags: record.data.number(1, at: 7)), record.data.number(4, at: 0)))
      case 0xFC:
        var pieces = [record.data], next = index + 1
        while next < records.count, records[next].kind == 0x3C { pieces.append(records[next].data); next += 1 }
        words = shared(pieces)
      case 0x41E where record.data.count > 5:
        formats[record.data.number(2, at: 0)] = text(record.data, at: 4, length: record.data.number(2, at: 2), flags: record.data.number(1, at: 4))
      case 0xE0: styles.append(record.data.number(2, at: 2))
      case 0x22: countsFrom1904 = record.data.number(2, at: 0) == 1
      default: break
      }
    }
    let dates = Set(styles.indices.filter { Xlsx.isDate(styles[$0], formats[styles[$0]]) })
    return try Grid.book(sheets.map { sheet in
      Grid.sheet(sheet.name, rows(records.drop { $0.at < sheet.at }, words, dates, countsFrom1904))
    })
  }

  private static func text(_ data: Data, at start: Int, length: Int, flags: Int) -> String {
    flags & 1 == 1
      ? String(decoding: (0..<length).map { UInt16(data.number(2, at: start + 1 + 2 * $0)) }, as: UTF16.self)
      : String(data: data.subdata(in: min(start + 1, data.count)..<min(start + 1 + length, data.count)), encoding: .windowsCP1252) ?? ""
  }

  /// The words are one list cut into records wherever one was full, and a word
  /// cut in half says over again how wide its letters are.
  private static func shared(_ pieces: [Data]) -> [String] {
    var words: [String] = [], piece = 0, at = 8
    let count = pieces[0].number(4, at: 4)
    func move() -> Bool {
      while piece < pieces.count, at >= pieces[piece].count { piece += 1; at = 0 }
      return piece < pieces.count
    }
    while words.count < count, move() {
      let length = pieces[piece].number(2, at: at)
      var flags = pieces[piece].number(1, at: at + 2)
      at += 3
      var runs = 0, extra = 0
      if flags & 8 != 0 { runs = pieces[piece].number(2, at: at); at += 2 }
      if flags & 4 != 0 { extra = pieces[piece].number(4, at: at); at += 4 }
      var units: [UInt16] = [], left = length
      while left > 0, piece < pieces.count {
        if at >= pieces[piece].count {
          piece += 1
          guard piece < pieces.count else { break }
          flags = (flags & ~1) | (pieces[piece].number(1, at: 0) & 1)
          at = 1
        }
        let width = flags & 1 == 1 ? 2 : 1, fit = min(left, (pieces[piece].count - at) / width)
        if fit == 0 { at = pieces[piece].count; continue }
        for index in 0..<fit { units.append(UInt16(pieces[piece].number(width, at: at + index * width))) }
        at += fit * width
        left -= fit
      }
      words.append(String(decoding: units, as: UTF16.self))
      var skip = runs * 4 + extra
      while skip > 0, move() {
        let some = min(skip, pieces[piece].count - at)
        at += some
        skip -= some
      }
    }
    return words
  }

  private static func rows(_ records: ArraySlice<(kind: Int, at: Int, data: Data)>, _ words: [String], _ dates: Set<Int>, _ countsFrom1904: Bool) -> [[String]] {
    var rows: [[String]] = [], waiting: (Int, Int)?
    func put(_ row: Int, _ column: Int, _ text: String) {
      guard row < 65_536, column < 256 else { return }
      while rows.count <= row { rows.append([]) }
      while rows[row].count <= column { rows[row].append("") }
      rows[row][column] = text
    }
    func said(_ number: Double, _ style: Int) -> String { dates.contains(style) ? Xlsx.day(number, countsFrom1904) : Xlsx.tidy(Tool.text(number, 10)) }
    func float(_ data: Data, _ at: Int) -> Double { Double(bitPattern: UInt64(data.number(4, at: at)) | UInt64(data.number(4, at: at + 4)) << 32) }
    func packed(_ raw: Int) -> Double {
      let whole = raw & 2 != 0 ? Double(Int32(bitPattern: UInt32(raw)) >> 2) : Double(bitPattern: UInt64(raw & 0xFFFF_FFFC) << 32)
      return raw & 1 != 0 ? whole / 100 : whole
    }
    for record in records {
      let d = record.data, row = d.number(2, at: 0), column = d.number(2, at: 2), style = d.number(2, at: 4)
      switch record.kind {
      case 0x0A: return rows
      case 0xFD: let index = d.number(4, at: 6); if words.indices.contains(index) { put(row, column, words[index]) }
      case 0x203: put(row, column, said(float(d, 6), style))
      case 0x27E: put(row, column, said(packed(d.number(4, at: 6)), style))
      case 0xBD:
        for index in 0..<max(0, (d.count - 6) / 6) { put(row, column + index, said(packed(d.number(4, at: 4 + index * 6 + 2)), d.number(2, at: 4 + index * 6))) }
      case 0x204: put(row, column, text(d, at: 8, length: d.number(2, at: 6), flags: d.number(1, at: 8)))
      case 0x205: put(row, column, d.number(1, at: 7) == 0 ? (d.number(1, at: 6) == 1 ? "true" : "false") : "")
      case 0x06:
        // A formula keeps what it came to; words come in a record of their own.
        if d.number(2, at: 12) == 0xFFFF {
          if d.number(1, at: 6) == 0 { waiting = (row, column) } else if d.number(1, at: 6) == 1 { put(row, column, d.number(1, at: 8) == 1 ? "true" : "false") }
        } else { put(row, column, said(float(d, 6), style)) }
      case 0x207: if let (row, column) = waiting { put(row, column, text(d, at: 2, length: d.number(2, at: 0), flags: d.number(1, at: 2))); waiting = nil }
      default: break
      }
    }
    return rows
  }
}

/// A message as Outlook saves one.
enum Msg {
  static func text(of url: URL) throws -> String {
    let ole = try Ole(url)
    func property(_ id: String, in folder: String = "") -> String? {
      if let wide = ole.data("\(folder)__substg1.0_\(id)001F") { return String(decoding: (0..<(wide.count / 2)).map { UInt16(wide.number(2, at: 2 * $0)) }, as: UTF16.self) }
      return ole.data("\(folder)__substg1.0_\(id)001E").flatMap { String(data: $0, encoding: .windowsCP1252) }
    }
    let sender = [property("0C1A"), property("5D01") ?? property("0C1F")].compactMap { $0 }.filter { !$0.isEmpty }
    let headers: [(String, String?)] = [("From", sender.joined(separator: " ")), ("To", property("0E04")), ("Cc", property("0E03")), ("Subject", property("0037"))]
    // Where there is no plain body there is a page: its words.
    let page = ole.data("__substg1.0_10130102").flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .windowsCP1252) }
    let body = property("1000") ?? page.map { $0.replacing(#/(?s)<(style|script).*?<\/\1>/#, with: "").replacing(#/<[^>]+>/#, with: "") } ?? ""
    let attached = Set(ole.names.filter { $0.hasPrefix("__attach") }.compactMap { $0.split(separator: "/").first }).sorted().compactMap { property("3707", in: $0 + "/") ?? property("3704", in: $0 + "/") }
    guard property("0037") != nil || !body.isEmpty else { throw ProcessingError.conversionFailed(reason: "\(url.lastPathComponent) is not a message") }
    var lines = headers.compactMap { name, value -> String? in value.flatMap { $0.isEmpty ? nil : "\(name): \($0)" } }
    if !attached.isEmpty { lines.append("Attachments: " + attached.joined(separator: ", ")) }
    return lines.joined(separator: "\n") + "\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
  }
}
