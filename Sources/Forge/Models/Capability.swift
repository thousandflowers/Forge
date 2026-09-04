import Foundation
import UniformTypeIdentifiers

/// Something Forge can do, and whether this Mac can do it.
///
/// The point of listing capabilities rather than formats is that "can Forge
/// convert my 3D models" is the question people actually have, and the answer
/// depends on the machine. Availability is asked of the system, never assumed,
/// for the same reason the format lists are: the app should never offer what
/// it cannot deliver.
struct Capability: Identifiable, Hashable {
  let id: String
  let title: String
  let summary: String
  let symbol: String
  let status: Status
  /// File extensions that mean somebody would want this. Used to put what
  /// would help *this* Mac first, rather than listing everything in the same
  /// flat order for everybody.
  var evidence: [String] = []

  enum Status: Hashable {
    /// Works now, with nothing to install.
    case available(detail: String)
    /// Could work, but is not built yet.
    case planned
    /// macOS can add this itself, on demand. Forge points at the place that
    /// does it rather than shipping a copy of what the system already has.
    case installable(Install)
    /// Would need something Forge does not ship, described plainly.
    case needsPack(Pack)
    /// Cannot be done the way Forge is built, and why.
    case unavailable(reason: String)

    var isAvailable: Bool {
      if case .available = self { return true }
      return false
    }
  }

  /// Something the system downloads for you, and where to ask for it.
  struct Install: Hashable {
    /// What gets added, in the user's words.
    let adds: String
    /// The button.
    let action: String
    /// Where macOS does it.
    let settings: URL
  }

  /// A capability that would arrive as a downloadable addition.
  ///
  /// Nothing installs one yet, and the reason is written down rather than
  /// glossed: a pack means running code Forge did not build, so it needs a
  /// pinned source, a checksum and a signature before it can be offered. The
  /// shape is here so the list can be honest about the difference between "not
  /// built yet" and "needs something we do not ship".
  struct Pack: Hashable {
    let name: String
    /// What the pack would have to contain, in plain words.
    let requires: String
    /// Roughly how large it would be.
    let approximateSize: String
    /// The tool that does this job, if one exists to be installed. Forge does
    /// not ship or download it: the Mac either has it or is told the one
    /// command that gets it.
    var tool: ExternalTool? = nil
    /// Whether Forge actually calls that tool yet. Having the tool installed
    /// and having Forge use it are different facts, and a screen about what
    /// this Mac can do has no business blurring them.
    var isWired: Bool = false
  }
}

/// The inventory, computed from what the system reports.
enum Capabilities {

  static var all: [Capability] { native + notYetBuilt + wouldNeedAPack + outOfReach }

  /// Capabilities macOS will extend on demand.
  static var installable: [Capability] {
    all.filter { if case .installable = $0.status { return true } else { return false } }
  }

  static var available: [Capability] { all.filter(\.status.isAvailable) }

  // MARK: - Working now

  private static var native: [Capability] {
    [
      Capability(
        id: "images",
        title: "Images",
        summary: "Convert, resize, filter and re-encode.",
        symbol: "photo",
        status: .available(
          detail: "\(FormatCatalog.readableImageTypes.count) formats read, "
            + "\(FormatCatalog.writableImageTypes.count) written"
        )
      ),
      Capability(
        id: "raw",
        title: "Camera RAW",
        summary: "Decode raw files from every camera ImageIO knows.",
        symbol: "camera.aperture",
        status: .available(detail: rawFormats.isEmpty ? "supported" : rawFormats.joined(separator: " "))
      ),
      Capability(
        id: "animation",
        title: "Animation",
        summary: "Animated GIF and HEICS, both ways with video, frame timings kept.",
        symbol: "square.stack.3d.forward.dottedline",
        status: .available(detail: "GIF, HEICS, multi-page TIFF and PDF")
      ),
      Capability(
        id: "video",
        title: "Video",
        summary: "Re-encode, resize and change container, audio track intact.",
        symbol: "film",
        status: .available(detail: writable(FormatCatalog.writableVideoTypes))
      ),
      Capability(
        id: "audio",
        title: "Audio",
        summary: "Convert between containers at the source's own rate.",
        symbol: "waveform",
        status: .available(detail: writable(Set(FormatCatalog.writableAudioTypes.keys)))
      ),
      Capability(
        id: "documents",
        title: "Documents",
        summary: "HTML, RTF, DOCX, ODT, Markdown and text, to each other and to PDF.",
        symbol: "doc.richtext",
        status: .available(detail: "PDF, DOCX, RTF, HTML, TXT")
      ),
      Capability(
        id: "data",
        title: "Data files",
        summary: "CSV, TSV, JSON and Property List, between each other.",
        symbol: "tablecells",
        status: .available(detail: "CSV, TSV, JSON, PLIST")
      ),
      Capability(
        id: "ocr",
        title: "Text recognition",
        summary: "Read text out of images and scanned PDFs, on device.",
        symbol: "text.viewfinder",
        status: .available(detail: "\(TextRecognizer.supportedLanguages.count) languages")
      ),
      Capability(
        id: "speech",
        title: "Text to speech",
        summary: "Turn a document into spoken audio. More voices and languages install from macOS itself.",
        symbol: "speaker.wave.2",
        status: .installable(.init(
          adds: "\(SpeechSynthesis.voices.count) voices in \(SpeechSynthesis.languages.count) languages installed",
          action: "Add Voices",
          settings: URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Speech")!
        ))
      ),
      Capability(
        id: "transcription",
        title: "Transcription",
        summary: "Turn a recording, or a video's soundtrack, into text on device.",
        symbol: "text.bubble",
        status: .installable(.init(
          adds: "\(Transcription.supportedLocales.count) locales; macOS downloads the on-device models",
          action: "Add Languages",
          settings: URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
        ))
      ),
      Capability(
        id: "models",
        title: "3D models",
        summary: "Convert between the mesh formats ModelIO handles.",
        symbol: "cube",
        status: .available(detail: writable(FormatCatalog.writableModelTypes))
      ),
    ]
  }

  // MARK: - Possible, not built

  private static var notYetBuilt: [Capability] {
    [


      Capability(
        id: "subtitles",
        title: "Subtitles",
        summary: "Pull the subtitle tracks out of a video.",
        symbol: "captions.bubble",
        status: .planned
      ),
    ]
  }

  // MARK: - Would need something Forge does not ship

  private static var wouldNeedAPack: [Capability] {
    [
      Capability(
        id: "webp-encode",
        title: "WebP and JPEG XL encoding",
        summary: "Reading both already works; writing them does not.",
        symbol: "arrow.down.doc",
        status: .needsPack(.init(
          name: "Extra image encoders",
          requires: "an encoder macOS does not ship",
          approximateSize: "a few megabytes",
          tool: ExternalTool(binary: "cwebp", formula: "webp", adds: "writing WebP"),
          isWired: true
        )),
        evidence: ["webp", "jxl"]
      ),
      Capability(
        id: "broadcast-video",
        title: "Broadcast and legacy video",
        summary: "WMV, MXF, FLV, and AV1 or VP9 encoding.",
        symbol: "tv",
        status: .needsPack(.init(
          name: "Extra video codecs",
          requires: "a codec library the size of FFmpeg",
          approximateSize: "tens of megabytes",
          tool: ExternalTool(binary: "ffmpeg", formula: "ffmpeg", adds: "WMV, MXF, FLV, AV1 and VP9"),
          isWired: true
        )),
        evidence: ["wmv", "mxf", "flv", "avi", "mkv", "webm"]
      ),
      Capability(
        id: "office",
        title: "Spreadsheets, slides and ebooks",
        summary: "XLSX, PPTX, EPUB and Kindle formats.",
        symbol: "tablecells",
        status: .needsPack(.init(
          name: "Office and ebook formats",
          requires: "a document engine of its own",
          approximateSize: "hundreds of megabytes",
          tool: ExternalTool(binary: "pandoc", formula: "pandoc", adds: "XLSX, PPTX, EPUB and friends"),
          isWired: true
        )),
        evidence: ["xlsx", "pptx", "epub", "mobi", "azw3", "odt", "ods"]
      ),
      Capability(
        id: "fonts",
        title: "Fonts",
        summary: "Convert between TrueType, OpenType and the web formats.",
        symbol: "textformat",
        status: .needsPack(.init(
          name: "Font tools",
          requires: "a font writer - CoreText reads font tables but cannot write one",
          approximateSize: "a few megabytes",
          tool: ExternalTool(binary: "ttx", formula: "fonttools", adds: "writing TrueType, OpenType, WOFF")
        )),
        evidence: ["ttf", "otf", "woff", "woff2"]
      ),
      Capability(
        id: "ocr-more-languages",
        title: "More OCR languages",
        summary: "Greek and the others Vision does not recognise.",
        symbol: "character.book.closed",
        status: .needsPack(.init(
          name: "Extra recognition languages",
          requires: "a second recognition engine and its language data",
          approximateSize: "tens of megabytes per language",
          tool: ExternalTool(binary: "tesseract", formula: "tesseract-lang", adds: "the languages Vision does not read")
        )),
        evidence: []
      ),
    ]
  }

  // MARK: - Not reachable from here

  private static var outOfReach: [Capability] {
    [
      Capability(
        id: "archives",
        title: "Archives",
        summary: "ZIP, TAR and friends.",
        symbol: "archivebox",
        status: .unavailable(reason: "macOS exposes no archive API; only Apple Archive, which nothing else reads.")
      ),
      Capability(
        id: "config",
        title: "YAML and TOML",
        summary: "Configuration formats.",
        symbol: "curlybraces",
        status: .unavailable(reason: "No parser in Foundation or any Apple framework.")
      ),
      Capability(
        id: "vector",
        title: "Vector tracing",
        summary: "Turning an image into SVG.",
        symbol: "scribble.variable",
        status: .unavailable(reason: "macOS has no tracer, and there is nothing to wrap.")
      ),
    ]
  }

  // MARK: - Helpers

  private static var rawFormats: [String] {
    FormatCatalog.readableImageTypes
      .filter { $0.identifier.hasSuffix("-raw-image") || $0.identifier == "com.adobe.raw-image" }
      .compactMap { $0.preferredFilenameExtension?.uppercased() }
      .sorted()
  }

  private static func writable(_ types: Set<UTType>) -> String {
    types
      .compactMap { $0.preferredFilenameExtension?.uppercased() }
      .sorted()
      .joined(separator: ", ")
  }
}
