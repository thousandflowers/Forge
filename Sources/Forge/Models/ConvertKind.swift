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
  case subtitle
  case font

  init?(fileType: UTType) {
    // Subtitles first, and before the media check on purpose: AVFoundation
    // lists WebVTT among the types it opens, so a .vtt was being filed as a
    // video - shown with video controls, and failing with "contains no audio
    // or video tracks" when anybody used them.
    if Subtitles.reads(fileType.preferredFilenameExtension ?? "") {
      self = .subtitle
    } else if ExternalBridge.Fonts.handles(fileType.preferredFilenameExtension ?? "") {
      self = .font
    } else if FormatCatalog.isReadableImage(fileType) {
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
    } else if ExternalBridge.canHandle(fileType) {
      // Nothing on the machine reads this, but a tool the user installed does.
      // It is filed by what it is, so the sheet offers the right controls.
      self = fileType.conforms(to: .audiovisualContent) && !fileType.conforms(to: .audio)
        ? .video
        : fileType.conforms(to: .audio) ? .audio : .document
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
    case .subtitle: return "subtitle"
    case .font: return "font"
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
    case .subtitle: return "subtitles"
    case .font: return "fonts"
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
    case .subtitle: return "captions.bubble"
    case .font: return "textformat"
    }
  }

  /// The preset shelf this kind draws from, so the sheet offers the presets
  /// that suit what was dropped.
  var presetCategory: PresetCategory {
    switch self {
    case .image: return .image
    case .video: return .video
    case .audio: return .audio
    case .document, .data, .model, .subtitle, .font: return .document
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
    case .audio, .data, .model, .subtitle, .font: return false
    }
  }

  /// A quality level, honoured wherever something is re-encoded lossily.
  var supportsQuality: Bool {
    switch self {
    case .image, .video, .document: return true
    case .audio, .data, .model, .subtitle, .font: return false
    }
  }

  /// Core Image filters, applied by the image and document processors.
  var supportsFilter: Bool {
    switch self {
    case .image, .document: return true
    case .video, .audio, .data, .model, .subtitle, .font: return false
    }
  }

  /// An explicit codec inside the container, which only AVFoundation exports
  /// take.
  var supportsCodec: Bool {
    switch self {
    case .video, .audio: return true
    case .image, .document, .data, .model, .subtitle, .font: return false
    }
  }

  /// A ceiling on the finished file. Only `ImageProcessor` writes, measures
  /// and rewrites; offering it for a video would be a promise nothing keeps.
  var supportsSizeLimit: Bool {
    switch self {
    case .image: return true
    case .video, .audio, .document, .data, .model, .subtitle, .font: return false
    }
  }

  /// Words out of the file: OCR for anything with pixels, transcription for
  /// anything with a soundtrack.
  var supportsTextExtraction: Bool {
    switch self {
    case .image, .document, .video, .audio: return true
    case .subtitle: return true
    case .data, .model, .font: return false
    }
  }

  /// What a preview of this kind may cost.
  ///
  /// A picture converts in a moment, so the preview is the real thing. A film
  /// does not: encoding one to show somebody what encoding it would look like
  /// is the conversion they have not agreed to yet, done twice. It gets a frame
  /// and a description instead, and a recording gets the description alone -
  /// there is nothing to look at in a sound file.
  var previewCost: PreviewCost {
    switch self {
    case .image, .document, .data, .model, .subtitle, .font: return .runIt
    case .video: return .oneFrame
    case .audio: return .describeIt
    }
  }

  enum PreviewCost: Sendable {
    /// Convert the one file for real, into scratch.
    case runIt
    /// Show a frame of the source and say what will happen.
    case oneFrame
    /// Say what will happen.
    case describeIt
  }

  /// Whether a file of this kind can be asked for that format, taken from the
  /// same list the sheet offers rather than from a second one kept beside it.
  func offers(_ format: UTType) -> Bool {
    outputGroups.contains { group in
      group.formats.contains { $0.type == format }
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
        OutputGroup("Images", OutputFormat.imagesWithTools),
        OutputGroup("Text", OutputFormat.text),
      ]
    case .video:
      return [
        OutputGroup("Video", OutputFormat.video),
        OutputGroup("Frames", OutputFormat.images),
        // The track already inside the film, which ffmpeg pulls out.
        OutputGroup("Subtitles", ExternalTools.locate("ffmpeg") == nil ? [] : OutputFormat.subtitles),
        OutputGroup("Text", OutputFormat.text),
      ]
    case .subtitle:
      return [
        OutputGroup("Subtitles", OutputFormat.subtitles),
        OutputGroup("Text", OutputFormat.text),
      ]
    case .font:
      return [OutputGroup("Fonts", OutputFormat.fonts)]
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
extension RulePreset {
  /// Whether this preset is worth offering for the kinds of file in hand.
  ///
  /// Judged by what it writes, not by the shelf it was filed on: a preset that
  /// makes JPEGs and happens to be filed under Video was not offered for a
  /// picture, and nothing anywhere said why. The category picks the icon and
  /// stays the user's to choose.
  func suits(_ kinds: Set<ConvertKind>) -> Bool {
    // No format of its own: it resizes, or filters, or reads the text out.
    // That suits anything which honours those.
    guard let format = targetFormat else { return true }
    return kinds.contains { $0.offers(format) }
  }
}

struct OutputGroup: Identifiable {
  let title: String
  let formats: [OutputFormat]

  var id: String { title }

  init(_ title: String, _ formats: [OutputFormat]) {
    self.title = title
    self.formats = formats
  }
}
