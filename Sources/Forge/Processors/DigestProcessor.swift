import CryptoKit
import Foundation

/// What a file comes to, as text: its fingerprint, or all of it in letters.
enum DigestProcessor {
  private static let chunk = 1 << 20
  /// A multiple of three, so that each piece ends where the next begins.
  private static let letters = 3 << 18

  static func write(_ digest: Tool.Digest, of input: URL, to output: URL, progress: (Double) -> Void) throws -> ProcessingResult {
    let start = Date()
    switch digest {
    case .sha256: try "\(sha256(of: input, progress: progress))  \(input.lastPathComponent)\n".write(to: output, atomically: true, encoding: .utf8)
    case .base64: try base64(of: input, to: output, progress: progress)
    }
    progress(1)
    let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
    return ProcessingResult(outputURL: output, outputSize: size, outputDimensions: nil, duration: Date().timeIntervalSince(start))
  }

  static func sha256(of url: URL, progress: (Double) -> Void = { _ in }) throws -> String {
    var hash = SHA256()
    try read(url, by: chunk, progress: progress) { hash.update(data: $0) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func base64(of url: URL, to output: URL, progress: (Double) -> Void) throws {
    guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    try read(url, by: letters, progress: progress) { try handle.write(contentsOf: $0.base64EncodedData()) }
  }

  private static func read(_ url: URL, by size: Int, progress: (Double) -> Void, _ take: (Data) throws -> Void) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let whole = Double((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
    var done = 0.0
    while let data = try handle.read(upToCount: size), !data.isEmpty {
      try Task.checkCancellation()
      try take(data)
      done += Double(data.count)
      if whole > 0 { progress(done / whole) }
    }
  }
}
