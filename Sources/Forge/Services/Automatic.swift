import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// How macOS marks a recording of the screen, whatever the file is called and
/// whatever language the Mac is in.
///
/// Inside the film: the `kMDItemIsScreenCapture` attribute is put on pictures
/// and never on recordings.
enum ScreenCapture {
  static let author = "ReplayKitRecording"

  static func isRecording(_ url: URL) async -> Bool {
    guard let items = try? await AVURLAsset(url: url).load(.metadata) else { return false }
    for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .quickTimeMetadataAuthor) {
      if let value = try? await item.load(.stringValue), value == author { return true }
    }
    return false
  }

  /// Where captures are saved: the Desktop, unless somebody said otherwise.
  static var folder: URL {
    let chosen = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
      .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    return chosen ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
  }
}

/// What is done to a file nobody handed over, where that has been allowed.
enum Automatic {
  enum Place: CaseIterable {
    case captures, downloads

    var folder: URL {
      switch self {
      case .captures: return ScreenCapture.folder
      case .downloads: return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
      }
    }

    func isWanted(_ settings: AppSettings) -> Bool {
      switch self {
      case .captures: return settings.lighterRecordings
      case .downloads: return settings.friendlyDownloads
      }
    }
  }

  /// Formats other people's computers and upload forms refuse.
  private static let unfriendly: Set<String> = ["heic", "heif", "webp", "avif"]

  static func preset(for file: ProcessableFile, in place: Place, settings: AppSettings) async -> RulePreset? {
    guard place.isWanted(settings) else { return nil }
    switch place {
    case .captures:
      guard ConvertKind(fileType: file.fileType) == .video, await ScreenCapture.isRecording(file.url),
            await isH264(file.url) else { return nil }
      var lighter = Lighter.preset(for: file)
      lighter?.onlyIfLighter = true
      lighter?.name = "Screen recording"
      return lighter
    case .downloads:
      guard unfriendly.contains(file.url.pathExtension.lowercased()), Lighter.preset(for: file) != nil else { return nil }
      return RulePreset(name: "Download", description: "", category: .image, actions: [.convertFormat(to: .jpeg), .quality(level: 90)])
    }
  }

  /// The only codec halving the weight of leaves looking the same.
  private static func isH264(_ url: URL) async -> Bool {
    guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
          let formats = try? await track.load(.formatDescriptions) else { return false }
    return formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }
  }

  /// Replaced only where the original is kept.
  static func mode(for settings: AppSettings) -> DestinationMode {
    settings.createBackupBeforeOverwrite ? .overwrite : .copyTo
  }
}
