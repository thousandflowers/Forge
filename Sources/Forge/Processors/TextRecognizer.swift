import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Reads text out of an image, on device.
///
/// Vision does the work, so nothing is uploaded anywhere and no model has to be
/// downloaded. It recognises a fixed set of languages; `supportedLanguages`
/// reports which, because promising one it does not have would be the same
/// mistake as offering a format the machine cannot write.
enum TextRecognizer {

  /// Languages Vision can recognise on this machine, as BCP-47 tags.
  static let supportedLanguages: [String] = {
    (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
  }()

  static func supports(_ language: String) -> Bool {
    supportedLanguages.contains { $0.caseInsensitiveCompare(language) == .orderedSame }
      || supportedLanguages.contains { $0.hasPrefix(language + "-") }
  }

  /// Recognised text, in reading order, one line per observation.
  ///
  /// - Parameter languages: BCP-47 tags to look for. Empty means let Vision
  ///   work it out, which is right for most documents.
  static func text(in image: CGImage, languages: [String] = []) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    if languages.isEmpty {
      request.automaticallyDetectsLanguage = true
    } else {
      let unknown = languages.filter { !supports($0) }
      if !unknown.isEmpty {
        // Vision recognises thirty languages and Greek is not one of them.
        // tesseract might have it - the user's tesseract, with the language
        // data the user installed - so it is asked before giving up.
        return try Tesseract.text(in: image, languages: languages)
      }
      request.recognitionLanguages = languages
      request.automaticallyDetectsLanguage = false
    }

    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

    let observations = request.results ?? []
    return observations
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }
}


/// The OCR languages Vision does not have, through the user's tesseract.
///
/// Which languages that is comes from tesseract itself - `--list-langs` is the
/// list of data files somebody installed - and the codes are translated by
/// Foundation rather than by a table here: Vision speaks BCP-47 and tesseract
/// speaks ISO 639-2, and `el-GR` is `ell` in both of their books.
enum Tesseract {

  /// What this machine's tesseract has, asked once.
  static let languages: Set<String> = ask()

  /// tesseract's name for a language Vision would call `el-GR`.
  static func code(for language: String) -> String? {
    Locale.Language(identifier: language).languageCode?.identifier(.alpha3)
  }

  static func has(_ language: String) -> Bool {
    guard let code = code(for: language) else { return false }
    return languages.contains(code)
  }

  static func text(in image: CGImage, languages wanted: [String]) throws -> String {
    let codes = wanted.compactMap(code(for:))
    let missing = wanted.filter { !has($0) }

    guard let tesseract = ExternalTools.locate("tesseract"), missing.isEmpty else {
      throw ProcessingError.validationFailed(
        message: "Neither Vision nor tesseract has \(missing.joined(separator: ", ")) on this Mac. "
          + "Vision knows: \(TextRecognizer.supportedLanguages.joined(separator: ", ")). "
          + "`brew install tesseract-lang` adds the rest."
      )
    }

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("forge-ocr-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let picture = folder.appendingPathComponent("page.png")
    guard let sink = CGImageDestinationCreateWithURL(
      picture as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
      throw ProcessingError.conversionFailed(reason: "Cannot hand the page to tesseract")
    }
    CGImageDestinationAddImage(sink, image, nil)
    guard CGImageDestinationFinalize(sink) else {
      throw ProcessingError.conversionFailed(reason: "Cannot hand the page to tesseract")
    }

    // tesseract names its own output, adding .txt to the base it is given.
    let base = folder.appendingPathComponent("read")
    try ExternalTools.run(tesseract, [
      picture.path, base.path, "-l", codes.joined(separator: "+"),
    ])

    let written = base.appendingPathExtension("txt")
    guard let text = try? String(contentsOf: written, encoding: .utf8) else {
      throw ProcessingError.conversionFailed(reason: "tesseract read the page and wrote nothing")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func ask() -> Set<String> {
    guard let tesseract = ExternalTools.locate("tesseract") else { return [] }
    let process = Process()
    process.executableURL = tesseract
    process.arguments = ["--list-langs"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    guard (try? process.run()) != nil else { return [] }
    let said = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let text = String(data: said, encoding: .utf8) else { return [] }

    // The first line says where the data is; the rest are the languages.
    return Set(
      text.split(separator: "\n")
        .dropFirst()
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    )
  }
}
