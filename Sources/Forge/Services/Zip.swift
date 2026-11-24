import Compression
import Foundation

/// The container half the world's files are: spreadsheets, books, models. Read
/// and written in memory, and only as much of the format as those use.
enum Zip {
  /// More than this in one piece is not a document.
  static let largest = 512 * 1024 * 1024

  struct Entry {
    let name: String
    let data: Data
    /// Left as it is, where whoever reads it insists.
    var isStored = false
  }

  // MARK: - Reading

  struct Reader {
    private struct Place { let offset, packed, size, method: Int }
    private let bytes: Data
    private let places: [String: Place]
    /// In the order they were put in.
    let names: [String]

    init(_ url: URL) throws { try self.init(Data(contentsOf: url, options: .mappedIfSafe)) }

    init(_ data: Data) throws {
      let data = data.startIndex == 0 ? data : Data(data)
      bytes = data
      // The list is at the end, before a comment of unknown length.
      var end = data.count - 22
      let last = max(0, data.count - 22 - 65_535)
      while end >= last, end >= 0, data.number(4, at: end) != 0x0605_4b50 { end -= 1 }
      guard end >= last, end >= 0 else { throw Self.broken }
      let count = data.number(2, at: end + 10)
      var at = data.number(4, at: end + 16)
      var found: [String: Place] = [:]
      var order: [String] = []
      for _ in 0..<count {
        guard at + 46 <= data.count, data.number(4, at: at) == 0x0201_4b50 else { throw Self.broken }
        let length = data.number(2, at: at + 28)
        guard at + 46 + length <= data.count else { throw Self.broken }
        let name = String(decoding: data[(at + 46)..<(at + 46 + length)], as: UTF8.self)
        found[name] = Place(
          offset: data.number(4, at: at + 42), packed: data.number(4, at: at + 20),
          size: data.number(4, at: at + 24), method: data.number(2, at: at + 10)
        )
        order.append(name)
        at += 46 + length + data.number(2, at: at + 30) + data.number(2, at: at + 32)
      }
      places = found
      names = order
    }

    func has(_ name: String) -> Bool { places[name] != nil }

    func data(_ name: String) throws -> Data {
      guard let place = places[name], place.offset + 30 <= bytes.count, bytes.number(4, at: place.offset) == 0x0403_4b50 else { throw Self.broken }
      let start = place.offset + 30 + bytes.number(2, at: place.offset + 26) + bytes.number(2, at: place.offset + 28)
      guard start + place.packed <= bytes.count, place.size <= Zip.largest else { throw Self.broken }
      let packed = bytes.subdata(in: start..<(start + place.packed))
      switch place.method {
      case 0: return packed
      case 8: return try packed.unpacked(to: place.size, COMPRESSION_ZLIB)
      default: throw Self.broken
      }
    }

    func text(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }

    static let broken = ProcessingError.conversionFailed(reason: "It looks damaged: what is inside it cannot be read.")
  }

  // MARK: - Writing

  /// - Parameter alignment: where each file must begin, for a reader that maps
  ///   them where they are.
  static func data(_ entries: [Entry], alignment: Int = 1) -> Data {
    var out = Data(), list = Data()
    for entry in entries {
      let name = Data(entry.name.utf8), packed = entry.isStored ? nil : entry.data.packed(COMPRESSION_ZLIB)
      let body = packed.map { $0.count < entry.data.count ? $0 : entry.data } ?? entry.data
      let method = body.count < entry.data.count ? 8 : 0
      var filler = (alignment - (out.count + 30 + name.count) % alignment) % alignment
      // A filler is a field of its own, with four bytes to say so.
      if filler > 0, filler < 4 { filler += alignment }
      var facts = Data()
      facts.append(number: 20, 2); facts.append(number: 0x0800, 2); facts.append(number: method, 2)
      facts.append(number: 0, 2); facts.append(number: 0x21, 2)
      facts.append(number: Int(entry.data.crc32), 4); facts.append(number: body.count, 4); facts.append(number: entry.data.count, 4)
      facts.append(number: name.count, 2)
      let offset = out.count
      out.append(number: 0x0403_4b50, 4); out.append(facts); out.append(number: filler, 2); out.append(name)
      if filler > 0 { out.append(number: 0x1986, 2); out.append(number: filler - 4, 2); out.append(Data(count: filler - 4)) }
      out.append(body)
      list.append(number: 0x0201_4b50, 4); list.append(number: 20, 2); list.append(facts)
      list.append(Data(count: 12)); list.append(number: offset, 4); list.append(name)
    }
    let start = out.count
    out.append(list)
    out.append(number: 0x0605_4b50, 4); out.append(number: 0, 4)
    out.append(number: entries.count, 2); out.append(number: entries.count, 2)
    out.append(number: list.count, 4); out.append(number: start, 4); out.append(number: 0, 2)
    return out
  }
}

extension Data {
  /// Least first, as zip has them.
  func number(_ size: Int, at offset: Int) -> Int {
    guard offset >= 0, offset + size <= count else { return 0 }
    return (0..<size).reduce(0) { $0 | Int(self[startIndex + offset + $1]) << (8 * $1) }
  }

  mutating func append(number: Int, _ size: Int) {
    for byte in 0..<size { append(UInt8(truncatingIfNeeded: number >> (8 * byte))) }
  }

  /// Most first, as fonts have them.
  func big(_ size: Int, at offset: Int) -> Int {
    guard offset >= 0, offset + size <= count else { return 0 }
    return (0..<size).reduce(0) { $0 << 8 | Int(self[startIndex + offset + $1]) }
  }

  mutating func append(big number: Int, _ size: Int) {
    for byte in (0..<size).reversed() { append(UInt8(truncatingIfNeeded: number >> (8 * byte))) }
  }

  func packed(_ how: compression_algorithm) -> Data? {
    guard !isEmpty else { return nil }
    var out = Data(count: count + count / 8 + 4096)
    let room = out.count
    let size = out.withUnsafeMutableBytes { to in
      withUnsafeBytes { from in
        compression_encode_buffer(
          to.bindMemory(to: UInt8.self).baseAddress!, room, from.bindMemory(to: UInt8.self).baseAddress!, count, nil, how
        )
      }
    }
    return size > 0 ? out.prefix(size) : nil
  }

  /// - Parameter size: what it says it is. Anything longer is not waited for.
  func unpacked(to size: Int, _ how: compression_algorithm) throws -> Data {
    guard size > 0 else { return Data() }
    guard !isEmpty else { throw Zip.Reader.broken }
    var out = Data(count: size)
    let made = out.withUnsafeMutableBytes { to in
      withUnsafeBytes { from in
        compression_decode_buffer(
          to.bindMemory(to: UInt8.self).baseAddress!, size, from.bindMemory(to: UInt8.self).baseAddress!, count, nil, how
        )
      }
    }
    guard made == size else { throw Zip.Reader.broken }
    return out
  }

  private static let table: [UInt32] = (0..<256).map { start in
    (0..<8).reduce(UInt32(start)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
  }

  var crc32: UInt32 {
    let table = Self.table
    return ~withUnsafeBytes { bytes in bytes.reduce(UInt32.max) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) } }
  }

  var adler32: Int {
    let sums = withUnsafeBytes { bytes in bytes.reduce((1, 0)) { (($0.0 + Int($1)) % 65_521, ($0.1 + $0.0 + Int($1)) % 65_521) } }
    return sums.1 << 16 | sums.0
  }
}
