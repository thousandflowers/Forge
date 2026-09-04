import CoreGraphics
import Foundation
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
      guard unknown.isEmpty else {
        throw ProcessingError.validationFailed(
          message: "Vision cannot recognise \(unknown.joined(separator: ", ")). "
            + "It knows: \(supportedLanguages.joined(separator: ", "))"
        )
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
