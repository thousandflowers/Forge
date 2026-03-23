import Foundation
import UniformTypeIdentifiers
import CoreGraphics
import AVFoundation

/// Represents a file ready for processing
struct ProcessableFile: Identifiable, Hashable, Codable, Sendable {
  let id = UUID()
  let url: URL
  let fileType: UTType
  let fileName: String
  let fileSize: Int64
  let dimensions: (width: Int, height: Int)?

  enum CodingKeys: String, CodingKey {
    case url, fileType, fileName, fileSize, dimensions
  }

  init(url: URL) throws {
    self.url = url

    // Verify file exists and is not a directory
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
      throw ProcessingError.fileNotFound
    }

    self.fileName = url.lastPathComponent

    // Get file size
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    self.fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

    // Get UTType from extension
    guard let type = UTType(filenameExtension: url.pathExtension) else {
      throw ProcessingError.unknownType
    }
    self.fileType = type

    // Extract dimensions (async would be better but synchronous for init)
    // For large files, you might want to make this async
    self.dimensions = try Self.extractDimensions(url: url, type: type)
  }

  private init(url: URL, fileType: UTType, fileName: String, fileSize: Int64, dimensions: (Int, Int)?) {
    self.url = url
    self.fileType = fileType
    self.fileName = fileName
    self.fileSize = fileSize
    self.dimensions = dimensions
  }

  // For deserialization
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.url = try container.decode(URL.self, forKey: .url)
    self.fileType = try container.decode(UTType.self, forKey: .fileType)
    self.fileName = try container.decode(String.self, forKey: .fileName)
    self.fileSize = try container.decode(Int64.self, forKey: .fileSize)
    self.dimensions = try container.decodeIfPresent((width: Int, height: Int).self, forKey: .dimensions)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(url, forKey: .url)
    try container.encode(fileType, forKey: .fileType)
    try container.encode(fileName, forKey: .fileName)
    try container.encode(fileSize, forKey: .fileSize)
    try container.encodeIfPresent(dimensions, forKey: .dimensions)
  }

  private static func extractDimensions(url: URL, type: UTType) throws -> (Int, Int)? {
    // Images: use CGImageSource (no full decode)
    if type.conforms(to: .image) {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = properties[kCGImagePropertyPixelWidth] as? Int,
            let h = properties[kCGImagePropertyPixelHeight] as? Int else {
        return nil
      }
      return (w, h)
    }

    // Videos: use AVAsset (fast, doesn't load frames)
    if type.conforms(to: .movie) || type.conforms(to: .video) {
      let asset = AVURLAsset(url: url)
      guard let track = asset.tracks(withMediaType: .video).first else {
        return nil
      }
      let size = track.naturalSize
      let transform = track.preferredTransform
      // Handle rotation: if portrait, swap width/height
      let isPortrait = abs(transform.a) == 0 && (abs(transform.b) == 1)
      if isPortrait {
        return (Int(size.height), Int(size.width))
      }
      return (Int(size.width), Int(size.height))
    }

    // Audio: could extract duration, but not dimensions
    return nil
  }
}
