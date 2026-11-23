import Foundation
import UniformTypeIdentifiers
import CoreGraphics
import AVFoundation

/// Represents dimensions of a media file
struct Dimensions: Hashable, Sendable {
  let width: Int
  let height: Int
}

/// Represents a file ready for processing
struct ProcessableFile: Identifiable, Hashable, Sendable {
  let id = UUID()
  let url: URL
  let fileType: UTType
  let fileName: String
  let fileSize: Int64
  /// Filled in straight away for images, whose size is in the file header.
  /// Video dimensions arrive later: reading them opens the asset, and doing
  /// that for every file as it is added froze the window on a large batch.
  var dimensions: Dimensions?

  init(url: URL) throws {
    // Absolute, always. A command line hands over `photo.png` relative to the
    // working directory, and a relative URL never compares equal to the
    // absolute one worked out for the output - which made converting in place
    // rename the file `photo 2.png`.
    let url = url.absoluteURL.standardizedFileURL
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

    guard let type = Self.type(of: url) else { throw ProcessingError.unknownType }
    self.fileType = type

    self.dimensions = Self.imageDimensions(url: url, type: type)
  }

  init(url: URL, fileType: UTType, fileName: String, fileSize: Int64, dimensions: Dimensions?) {
    self.url = url
    self.fileType = fileType
    self.fileName = fileName
    self.fileSize = fileSize
    self.dimensions = dimensions
  }

  /// What a file is, by its extension.
  ///
  /// `UTType(filenameExtension:)` invents a dynamic type for an extension the
  /// system has never heard of, which is worse than nil: it looks like an
  /// answer. Those are refused - except for the subtitle formats, which macOS
  /// genuinely has no types for and Forge genuinely reads. Those are given a
  /// dynamic type that at least conforms to plain text, which is what they are.
  private static func type(of url: URL) -> UTType? {
    let named = namedType(of: url)
    // A picture is known by its first bytes, which ImageIO reads without
    // decoding anything. That answer wins when the name gives none - a photo
    // saved from the web with no extension - or claims something that is not
    // a picture at all, like a PNG called .mp4. A name that already says
    // "image" is left alone: ImageIO decodes by content anyway, and a camera
    // RAW is TIFF underneath without being one.
    if named.map({ !$0.conforms(to: .image) }) ?? true, let sniffed = pictureType(of: url),
       named.map({ !$0.conforms(to: sniffed) }) ?? true {
      return sniffed
    }
    return named
  }

  private static func pictureType(of url: URL) -> UTType? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let identifier = CGImageSourceGetType(source) as String?,
          let type = UTType(identifier),
          // ImageIO also recognises a PDF, but the document path reads the
          // type from the extension again, so a misnamed PDF would only fail
          // further in. Pictures go all the way through.
          type.conforms(to: .image) else {
      return nil
    }
    return type
  }

  /// Whether the name alone says what the file is. Pictures are also known by
  /// what is inside them, which is right for a file somebody chose and wrong
  /// for one still arriving under a provisional name.
  static func isNamedForWhatItIs(_ url: URL) -> Bool { namedType(of: url) != nil }

  private static func namedType(of url: URL) -> UTType? {
    guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
    guard type.isDynamic else { return type }
    // TOML for the same reason: `public.toml` does not exist on macOS 14, so
    // a .toml file gets an invented type there and a real one here.
    if Toml.handles(url.pathExtension) || Subtitles.reads(url.pathExtension) {
      return UTType(filenameExtension: url.pathExtension, conformingTo: .plainText)
    }
    // WOFF2 has no type either, and is a font rather than text.
    if ExternalBridge.Fonts.handles(url.pathExtension) {
      return UTType(filenameExtension: url.pathExtension, conformingTo: .font)
    }
    // What pandoc reads and macOS has no name for - reStructuredText, Org,
    // LaTeX, notebooks - is text to a tool that is installed.
    if ExternalBridge.pandocIsKnownToRead(url.pathExtension) {
      return UTType(filenameExtension: url.pathExtension, conformingTo: .text)
    }
    return nil
  }

  /// Image size, read from the header without decoding the image.
  private static func imageDimensions(url: URL, type: UTType) -> Dimensions? {
    guard type.conforms(to: .image) else { return nil }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
      return nil
    }
    return Dimensions(width: width, height: height)
  }

  /// Video size, including the rotation the track carries, loaded off the
  /// caller's thread.
  static func videoDimensions(url: URL, type: UTType) async -> Dimensions? {
    guard type.conforms(to: .movie) || type.conforms(to: .video) else { return nil }
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let size = try? await track.load(.naturalSize),
          let transform = try? await track.load(.preferredTransform) else {
      return nil
    }
    // A portrait recording stores landscape pixels plus a rotation.
    let isPortrait = abs(transform.a) == 0 && abs(transform.b) == 1
    return isPortrait
      ? Dimensions(width: Int(size.height), height: Int(size.width))
      : Dimensions(width: Int(size.width), height: Int(size.height))
  }
}
