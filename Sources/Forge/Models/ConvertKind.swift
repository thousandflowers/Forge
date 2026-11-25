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
enum ConvertKind: String, CaseIterable, Codable, Sendable {
  case image
  case video
  case audio
  case document
  case data
  case model
  case subtitle
  case font
  case archive

  init?(fileType: UTType) {
    // Subtitles first, and before the media check on purpose: AVFoundation
    // lists WebVTT among the types it opens, so a .vtt was being filed as a
    // video - shown with video controls, and failing with "contains no audio
    // or video tracks" when anybody used them.
    if fileType.goes(by: Subtitles.readableExtensions) {
      self = .subtitle
    } else if fileType.goes(by: FontProcessor.readable) {
      self = .font
    // Before the rest: a glTF is JSON and a COLLADA is XML, and neither is
    // what anybody means by one.
    } else if FormatCatalog.isReadableModel(fileType) || (fileType.goes(by: BlenderBridge.extensions) && ExternalTool.blender.isInstalled) {
      self = .model
    } else if fileType.goes(by: MidiProcessor.readable) {
      self = .audio
    // What is opened through something else is filed by what comes of it. A
    // sheet is data before it is pages.
    } else if let way = ThroughProcessor.way(for: fileType), way.kind != .data {
      self = way.kind
    } else if FormatCatalog.isReadableImage(fileType) {
      self = .image
    } else if FormatCatalog.isReadableMedia(fileType) {
      // Which of the two a file really is depends on the tracks inside it, and
      // reading those means opening the asset. The extension is what is known
      // while the sheet is being drawn, and it is right for anything with a
      // normal name; a mislabelled file simply gets one control too many.
      self = fileType.conforms(to: .audio) ? .audio : .video
    } else if DataProcessor.handles(fileType) {
      self = .data
    } else if SimpleDocProcessor.readableTypes.contains(where: { fileType.conforms(to: $0) }) || fileType.goes(by: ComicProcessor.readable) {
      self = .document
    } else if ArchiveProcessor.reads(fileType) {
      self = .archive
    } else if ExternalBridge.canHandle(fileType) {
      // Nothing on the machine reads this, but a tool the user installed does.
      // It is filed by what it is, so the sheet offers the right controls.
      self = fileType.conforms(to: .audiovisualContent) && !fileType.conforms(to: .audio)
        ? .video
        : fileType.conforms(to: .audio) ? .audio : .document
    } else if Tidier.language(of: fileType) != nil {
      // A style sheet becomes nothing else, and can be tidied.
      self = .document
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
    case .archive: return "archive"
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
    case .archive: return "archives"
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
    case .archive: return "doc.zipper"
    }
  }

  /// The preset shelf this kind draws from, so the sheet offers the presets
  /// that suit what was dropped.
  var presetCategory: PresetCategory {
    switch self {
    case .image: return .image
    case .video: return .video
    case .audio: return .audio
    case .document: return .document
    case .data: return .data
    case .model: return .model
    case .subtitle: return .subtitle
    case .font: return .font
    case .archive: return .custom
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
    case .audio, .data, .model, .subtitle, .font, .archive: return false
    }
  }

  /// A quality level, honoured wherever something is re-encoded lossily.
  var supportsQuality: Bool {
    switch self {
    case .image, .video, .document: return true
    case .audio, .data, .model, .subtitle, .font, .archive: return false
    }
  }

  /// Core Image filters, applied by the image and document processors.
  var supportsFilter: Bool {
    switch self {
    case .image, .document: return true
    case .video, .audio, .data, .model, .subtitle, .font, .archive: return false
    }
  }

  /// An explicit codec inside the container, which only AVFoundation exports
  /// take.
  var supportsCodec: Bool {
    switch self {
    case .video, .audio: return true
    case .image, .document, .data, .model, .subtitle, .font, .archive: return false
    }
  }

  /// A ceiling on the finished file. Only `ImageProcessor` writes, measures
  /// and rewrites; offering it for a video would be a promise nothing keeps.
  var supportsSizeLimit: Bool {
    switch self {
    case .image: return true
    case .video, .audio, .document, .data, .model, .subtitle, .font, .archive: return false
    }
  }

  /// Words out of the file: OCR for anything with pixels, transcription for
  /// anything with a soundtrack.
  var supportsTextExtraction: Bool {
    switch self {
    case .image, .document, .video, .audio: return true
    case .subtitle: return true
    case .data, .model, .font, .archive: return false
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
    case .image, .document, .data, .model, .subtitle, .font, .archive: return .runIt
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
        // The soundtrack on its own. Sound-only containers, so "M4A" means
        // the sound and not the film in an MPEG-4 box.
        OutputGroup("Sound", OutputFormat.audio.filter { $0.type.map(MediaProcessor.isSoundOnly) ?? false }),
        OutputGroup("Frames", OutputFormat.images),
        // The track inside the film, or what is said in it.
        OutputGroup("Subtitles", OutputFormat.subtitles),
        OutputGroup("Text", OutputFormat.text),
        OutputGroup("With your tools", OutputFormat.withTools(for: .video)),
      ]
    case .subtitle:
      return [
        OutputGroup("Subtitles", OutputFormat.subtitles),
        OutputGroup("Text", OutputFormat.text),
      ]
    case .font:
      return [OutputGroup("Fonts", OutputFormat.fonts)]
    case .archive:
      return [OutputGroup("Archives", ArchiveProcessor.writable.map { OutputFormat(type: $0) })]
    case .audio:
      return [
        OutputGroup("Audio", OutputFormat.audio),
        OutputGroup("Video container", OutputFormat.video),
        OutputGroup("Text", OutputFormat.text),
        OutputGroup("Subtitles", OutputFormat.subtitles),
        OutputGroup("With your tools", OutputFormat.withTools(for: .audio)),
      ]
    case .document:
      // Audio is not a mistake: SimpleDocProcessor speaks a document asked for
      // a sound file, which is how a PDF becomes something to listen to.
      return [
        OutputGroup("Documents", OutputFormat.documents),
        OutputGroup("Images", OutputFormat.images),
        OutputGroup("Read aloud", OutputFormat.audio),
        OutputGroup("With your tools", OutputFormat.withTools(for: .document)),
      ]
    case .data:
      return [
        OutputGroup("Data", OutputFormat.data),
        OutputGroup("Documents", OutputFormat.dataPages),
        OutputGroup("With your tools", OutputFormat.withTools(for: .data)),
      ]
    case .model:
      return [OutputGroup("3D", OutputFormat.models), OutputGroup("Images", OutputFormat.images)]
    }
  }
}

/// One labelled row of output formats in the Convert sheet.
extension ConvertKind {
  /// The outputs for these files in particular. A kind says what files of the
  /// sort can become - "a document can become a picture" is true of a PDF and
  /// of nothing else filed with it - so each format is kept only if every file
  /// here can become it. A batch is offered what all of it can finish.
  func outputGroups(for files: [ProcessableFile]) -> [OutputGroup] {
    // One file of each extension answers for the rest.
    let distinct = Dictionary(grouping: files) { $0.url.pathExtension.lowercased() }.compactMap(\.value.first)
    return outputGroups.map { group in
      OutputGroup(group.title, group.formats.filter { format in
        guard let type = format.type else { return true }
        return distinct.allSatisfy { Conversions.can($0, become: type) }
      })
    }
  }
}

extension RulePreset {
  /// Whether these files in particular can become what the preset writes:
  /// every one of them, since a batch is offered what all of it can finish. A
  /// preset that names no format - it resizes, or filters - asks nothing of
  /// the file and suits anything.
  func suits(_ files: [ProcessableFile]) -> Bool {
    guard let format = targetFormat else { return true }
    let distinct = Dictionary(grouping: files) { $0.url.pathExtension.lowercased() }.compactMap(\.value.first)
    return distinct.allSatisfy { Conversions.can($0, become: format) }
  }

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

extension ConvertKind {
  /// The formats most people want from this kind, in the order shown. A kind
  /// without a list has few enough formats to show them all.
  private var common: [String] {
    switch self {
    case .image: return ["JPEG", "PNG", "HEIC", "WEBP", "TIFF", "PDF", "GIF", "AVIF"]
    case .video: return ["MP4", "MOV", "GIF", "MP3", "M4A", "SRT", "TXT", "JPEG"]
    case .audio: return ["M4A", "MP3", "WAV", "FLAC", "TXT", "SRT"]
    case .document: return ["PDF", "DOCX", "EPUB", "RTF", "HTML", "TXT", "JPEG", "PNG", "M4A"]
    case .data: return ["CSV", "JSON", "XLSX", "YAML", "XML", "HTML"]
    case .model: return ["OBJ", "STL", "GLB", "USDZ", "3MF", "PNG"]
    case .subtitle, .font, .archive: return []
    }
  }

  /// The ones to show first, out of those these files can really become.
  func leading(of offered: [OutputFormat]) -> [OutputFormat] {
    let first = common.compactMap { label in offered.first { $0.label == label } }
    return first.isEmpty ? offered : first
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
