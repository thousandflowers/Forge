import Foundation
import UniformTypeIdentifiers

/// What kind of thing a file is, and therefore what can be asked of it.
///
/// `PresetCategory` answers a different question — which shelf a preset sits on
/// — and has no idea that a JSON supports nothing but a change of format while
/// a video supports four separate things. This is the answer the Convert screen
/// needs: it decides which controls are worth putting in front of somebody.
///
/// The order of the checks mirrors `ProcessingCoordinator.processors`, because
/// the coordinator hands the file to the first processor that claims it and the
/// screen must offer what that same processor can do. Getting the order wrong
/// would offer a CSV the document controls it will never honour.
enum ConvertKind: String, CaseIterable, Sendable {
  case image
  case video
  case audio
  case document
  case data
  case model

  init?(fileType: UTType) {
    if FormatCatalog.isReadableImage(fileType) {
      self = .image
    } else if FormatCatalog.isReadableMedia(fileType) {
      // Which of the two a file really is depends on the tracks inside it, and
      // reading those means opening the asset. The extension is what is known
      // while the sheet is being drawn, and it is right for anything with a
      // normal name; a mislabelled file simply gets one control too many.
      self = fileType.conforms(to: .audio) ? .audio : .video
    } else if DataProcessor.readable.contains(where: { fileType.conforms(to: $0) }) {
      self = .data
    } else if SimpleDocProcessor.readableTypes.contains(where: { fileType.conforms(to: $0) }) {
      self = .document
    } else if FormatCatalog.isReadableModel(fileType) {
      self = .model
    } else {
      return nil
    }
  }

  var title: String {
    switch self {
    case .image: return "image"
    case .video: return "video"
    case .audio: return "audio file"
    case .document: return "document"
    case .data: return "data file"
    case .model: return "3D model"
    }
  }

  var plural: String {
    switch self {
    case .image: return "images"
    case .video: return "videos"
    case .audio: return "audio files"
    case .document: return "documents"
    case .data: return "data files"
    case .model: return "3D models"
    }
  }

  var icon: String {
    switch self {
    case .image: return "photo"
    case .video: return "film"
    case .audio: return "waveform"
    case .document: return "doc.text"
    case .data: return "tablecells"
    case .model: return "cube"
    }
  }

  /// The preset shelf this kind draws from, so the sheet offers the presets
  /// that suit what was dropped.
  var presetCategory: PresetCategory {
    switch self {
    case .image: return .image
    case .video: return .video
    case .audio: return .audio
    case .document, .data, .model: return .document
    }
  }

  // MARK: - What each kind actually honours
  //
  // Taken from the processors, not from what sounds plausible. A control that
  // is offered and then ignored is worse than one that is missing: it makes the
  // app look like it did something it did not do.

  /// Resizing: ImageProcessor scales images, MediaProcessor scales video, and
  /// SimpleDocProcessor scales the pages it rasterises. Audio, data and models
  /// have no pixels to scale.
  var supportsResize: Bool {
    switch self {
    case .image, .video, .document: return true
    case .audio, .data, .model: return false
    }
  }

  /// A quality level, honoured wherever something is re-encoded lossily.
  var supportsQuality: Bool {
    switch self {
    case .image, .video, .document: return true
    case .audio, .data, .model: return false
    }
  }

  /// Core Image filters, applied by the image and document processors.
  var supportsFilter: Bool {
    switch self {
    case .image, .document: return true
    case .video, .audio, .data, .model: return false
    }
  }

  /// An explicit codec inside the container, which only AVFoundation exports
  /// take.
  var supportsCodec: Bool {
    switch self {
    case .video, .audio: return true
    case .image, .document, .data, .model: return false
    }
  }

  /// Words out of the file: OCR for anything with pixels, transcription for
  /// anything with a soundtrack.
  var supportsTextExtraction: Bool {
    switch self {
    case .image, .document, .video, .audio: return true
    case .data, .model: return false
    }
  }

  /// The formats worth offering as output, grouped the way they get chosen.
  ///
  /// A video can become another video, a still or an animation (a frame
  /// export), or a transcript; an audio file can become another audio file, a
  /// movie container, or a transcript. A data file can only become another data
  /// file: `DataProcessor` rejects everything else outright.
  var outputGroups: [OutputGroup] {
    switch self {
    case .image:
      return [
        OutputGroup("Images", OutputFormat.images),
        OutputGroup("Text", OutputFormat.text),
      ]
    case .video:
      return [
        OutputGroup("Video", OutputFormat.video),
        OutputGroup("Frames", OutputFormat.images),
        OutputGroup("Text", OutputFormat.text),
      ]
    case .audio:
      return [
        OutputGroup("Audio", OutputFormat.audio),
        OutputGroup("Video container", OutputFormat.video),
        OutputGroup("Text", OutputFormat.text),
      ]
    case .document:
      // Audio is not a mistake: SimpleDocProcessor speaks a document asked for
      // a sound file, which is how a PDF becomes something to listen to.
      return [
        OutputGroup("Documents", OutputFormat.documents),
        OutputGroup("Images", OutputFormat.images),
        OutputGroup("Read aloud", OutputFormat.audio),
      ]
    case .data:
      return [OutputGroup("Data", OutputFormat.data)]
    case .model:
      return [OutputGroup("3D", OutputFormat.models)]
    }
  }
}

/// One labelled row of output formats in the Convert sheet.
struct OutputGroup: Identifiable {
  let title: String
  let formats: [OutputFormat]

  var id: String { title }

  init(_ title: String, _ formats: [OutputFormat]) {
    self.title = title
    self.formats = formats
  }
}
