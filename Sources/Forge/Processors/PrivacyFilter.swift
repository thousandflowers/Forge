import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Takes the identifying parts out of a file, and leaves the parts that make it
/// look like itself.
///
/// Everything here is a list rather than a chain of `if`s about formats: what
/// counts as a location, what counts as identifying, and what is never dropped.
/// A tag that is on no list is carried across, which is the safe direction - a
/// conversion that quietly loses something is worse than one that keeps too
/// much, and the level is what the user chose.
enum PrivacyFilter {

  /// What the chain asks for. The most thorough thing said wins: a preset
  /// asking to remove the location and a filename asking to remove everything
  /// means everything.
  static func policy(in operations: [Operation]) -> PrivacyPolicy {
    operations
      .compactMap { if case .stripMetadata(let policy) = $0 { return policy } else { return nil } }
      .max { $0.thoroughness < $1.thoroughness } ?? .keepAll
  }

  // MARK: - Images

  /// Never dropped, at any level.
  ///
  /// Orientation says which way up the photograph is; the profile says what its
  /// colours mean. A file without them is not a more private version of itself,
  /// it is a broken version of itself.
  static let alwaysKept: Set<String> = [
    kCGImagePropertyOrientation as String,
    kCGImagePropertyProfileName as String,
    kCGImagePropertyColorModel as String,
    kCGImagePropertyDepth as String,
    kCGImagePropertyHasAlpha as String,
    kCGImagePropertyDPIWidth as String,
    kCGImagePropertyDPIHeight as String,
    kCGImagePropertyPixelWidth as String,
    kCGImagePropertyPixelHeight as String,
  ]

  /// Where the picture was taken.
  private static let locationBlocks: Set<String> = [
    kCGImagePropertyGPSDictionary as String,
  ]

  /// Whole blocks that exist to say who, what and when.
  private static let identifyingBlocks: Set<String> = [
    kCGImagePropertyIPTCDictionary as String,
    kCGImagePropertyExifAuxDictionary as String,
  ]

  /// Tags inside the EXIF block that identify a device, a person or a moment.
  private static let identifyingExif: Set<String> = [
    kCGImagePropertyExifDateTimeOriginal as String,
    kCGImagePropertyExifDateTimeDigitized as String,
    kCGImagePropertyExifSubsecTime as String,
    kCGImagePropertyExifSubsecTimeOriginal as String,
    kCGImagePropertyExifSubsecTimeDigitized as String,
    kCGImagePropertyExifBodySerialNumber as String,
    kCGImagePropertyExifLensSerialNumber as String,
    kCGImagePropertyExifLensMake as String,
    kCGImagePropertyExifLensModel as String,
    kCGImagePropertyExifCameraOwnerName as String,
    kCGImagePropertyExifUserComment as String,
    kCGImagePropertyExifMakerNote as String,
    kCGImagePropertyExifImageUniqueID as String,
  ]

  /// The same, in the TIFF block, which is where a camera writes its name.
  private static let identifyingTIFF: Set<String> = [
    kCGImagePropertyTIFFMake as String,
    kCGImagePropertyTIFFModel as String,
    kCGImagePropertyTIFFSoftware as String,
    kCGImagePropertyTIFFArtist as String,
    kCGImagePropertyTIFFCopyright as String,
    kCGImagePropertyTIFFDateTime as String,
    kCGImagePropertyTIFFHostComputer as String,
  ]

  /// The properties to write, given the ones that were read.
  static func filter(
    _ properties: [CFString: Any],
    to policy: PrivacyPolicy
  ) -> [CFString: Any] {
    guard policy.removesSomething else { return properties }

    var kept: [CFString: Any] = [:]
    for (key, value) in properties {
      let name = key as String
      if alwaysKept.contains(name) {
        kept[key] = value
        continue
      }
      if locationBlocks.contains(name) { continue }
      if policy == .stripLocation {
        kept[key] = value
        continue
      }
      if identifyingBlocks.contains(name) { continue }
      // A maker note is whatever the camera felt like writing, under a key
      // named after the camera. Listing the cameras would be a list nobody can
      // finish; the shape of the key is the rule.
      if name.hasPrefix("{Maker") { continue }

      if name == kCGImagePropertyExifDictionary as String {
        kept[key] = strip(identifyingExif, from: value)
      } else if name == kCGImagePropertyTIFFDictionary as String {
        kept[key] = strip(identifyingTIFF, from: value)
      } else {
        kept[key] = value
      }
    }
    return kept
  }

  private static func strip(_ tags: Set<String>, from block: Any) -> Any {
    guard var dictionary = block as? [CFString: Any] else { return block }
    for key in dictionary.keys where tags.contains(key as String) {
      dictionary.removeValue(forKey: key)
    }
    return dictionary
  }

  // MARK: - PDF

  /// Clear what a PDF says about who made it.
  ///
  /// Only at the thorough level: a PDF has no location to remove, so taking the
  /// author out when the user asked about their whereabouts would be doing
  /// something they did not ask for.
  ///
  /// This runs on the scratch file, before it is moved into place, so nothing
  /// the user already has is touched.
  static func strip(pdfAt url: URL, to policy: PrivacyPolicy) throws {
    guard policy == .stripAll, let pdf = PDFDocument(url: url) else { return }

    // The title is kept: it is what the document is called, not who wrote it.
    var attributes: [AnyHashable: Any] = [:]
    if let title = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] {
      attributes[PDFDocumentAttribute.titleAttribute] = title
    }
    pdf.documentAttributes = attributes

    guard pdf.write(to: url) else {
      throw ProcessingError.conversionFailed(
        reason: "Cannot rewrite \(url.lastPathComponent) without its author details"
      )
    }
  }

  /// Apply what can only be done once a file exists, to files that are still
  /// scratch. A no-op for everything handled while it was written.
  static func applyAfterWriting(_ policy: PrivacyPolicy, to outputs: [URL]) throws {
    guard policy.removesSomething else { return }
    for output in outputs where output.pathExtension.lowercased() == "pdf" {
      try strip(pdfAt: output, to: policy)
    }
  }

  // MARK: - Audio and video

  /// The metadata an export should carry.
  static func metadata(_ items: [AVMetadataItem], to policy: PrivacyPolicy) -> [AVMetadataItem] {
    switch policy {
    case .keepAll:
      return items
    case .stripLocation:
      return items.filter { !isLocation($0) }
    case .stripAll:
      // Deliberately narrow rather than empty: a title and an artist are what a
      // music file is, and removing those is not privacy, it is loss.
      return items.filter { !isLocation($0) && !isIdentifying($0) }
    }
  }

  /// What an export session should be told, where the session filters for
  /// itself. AVFoundation's own idea of what is safe to share is maintained by
  /// the people who know what each key means.
  static func filter(for policy: PrivacyPolicy) -> AVMetadataItemFilter? {
    policy == .stripAll ? .forSharing() : nil
  }

  private static func isLocation(_ item: AVMetadataItem) -> Bool {
    guard let identifier = item.identifier?.rawValue.lowercased() else { return false }
    return identifier.contains("location")
  }

  private static func isIdentifying(_ item: AVMetadataItem) -> Bool {
    guard let identifier = item.identifier?.rawValue.lowercased() else { return false }
    return ["make", "model", "software", "creationdate", "author", "owner", "device"]
      .contains { identifier.contains($0) }
  }
}

private extension PrivacyPolicy {
  /// How much each level removes, for deciding which of two wins.
  var thoroughness: Int {
    switch self {
    case .keepAll: return 0
    case .stripLocation: return 1
    case .stripAll: return 2
    }
  }
}
