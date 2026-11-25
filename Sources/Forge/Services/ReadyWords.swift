import Foundation
import UniformTypeIdentifiers

/// Words that are ready made, each a preset like any other: installed it can be
/// changed, renamed or thrown away.
enum ReadyWords {
  static let entries: [PresetGallery.Entry] = all.map { word, name, summary, category, formats, actions in
    var preset = RulePreset(
      name: name, description: summary, category: category,
      actions: formats.compactMap { UTType(filenameExtension: $0) }.map { .convertFormat(to: $0) } + actions
    )
    preset.nameTrigger = word
    return PresetGallery.Entry(author: "Forge", summary: "With _\(word) in a file\u{2019}s name: \(summary)", preset: preset, tags: ["word"])
  }

  private typealias Ready = (word: String, name: String, summary: String, category: PresetCategory, formats: [String], actions: [Operation])

  private static let all: [Ready] = [
    ("igpost", "Instagram post", "JPEG, 1080 × 1350, filled and cropped.", .image, ["jpg"],
     [.resize(width: 1080, height: 1350, fitMode: .cropCenter), .quality(level: 85)]),
    ("story", "Story", "JPEG, 1080 × 1920, filled and cropped.", .image, ["jpg"],
     [.resize(width: 1080, height: 1920, fitMode: .cropCenter), .quality(level: 85)]),
    ("email", "Email picture", "JPEG, 1600 px, under 1 MB, without metadata.", .image, ["jpg"],
     [.resize(width: 1600, height: 1600, fitMode: .proportional), .quality(level: 75), .limitSize(bytes: 1_000_000), .stripMetadata(policy: .stripAll)]),
    ("sticker", "Sticker", "PNG without its background, 512 px.", .image, ["png"],
     [.tool(.removeBackground), .resize(width: 512, height: 512, fitMode: .proportional)]),
    ("icon", "Mac icon", "ICNS, every size in it.", .image, ["icns"], [.tool(.crop(.shape(1, 1)))]),
    ("reel", "Reel", "MP4, 1080 × 1920, filled and cropped.", .video, ["mp4"],
     [.resize(width: 1080, height: 1920, fitMode: .cropCenter), .encode(codec: .h264)]),
    ("whatsapp", "WhatsApp video", "MP4, 720p, under 16 MB.", .video, ["mp4"],
     [.resize(width: 1280, height: 1280, fitMode: .proportional), .encode(codec: .h264), .limitSize(bytes: 16_000_000)]),
    ("discord", "Discord video", "MP4, 720p, under 10 MB.", .video, ["mp4"],
     [.resize(width: 1280, height: 1280, fitMode: .proportional), .encode(codec: .h264), .limitSize(bytes: 10_000_000)]),
    ("tv", "Apple TV", "MP4, 1080p, HEVC, what an Apple TV plays.", .video, ["mp4"],
     [.resize(width: 1920, height: 1080, fitMode: .proportional), .encode(codec: .hevc)]),
    ("gif", "Animated GIF", "GIF, 480 px wide.", .video, ["gif"], [.resize(width: 480, height: nil, fitMode: .proportional)]),
    ("vhs", "Old tape", "MP4, without stripes and with less noise.", .video, ["mp4"], [.film({
      var film = FilmSettings()
      film.interlacing = .deinterlace
      film.noise = .medium
      return film
    }())]),
    ("subs", "Subtitles", "SRT, from its own track or from what is said.", .video, ["srt"], []),
    ("podcast", "Podcast", "M4A, as loud as the next one.", .audio, ["m4a"], [.tool(.normalize), .quality(level: 60)]),
    ("text", "Transcript", "TXT, from a recording.", .audio, ["txt"], []),
  ]
}
