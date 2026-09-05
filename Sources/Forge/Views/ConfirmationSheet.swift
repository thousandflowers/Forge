import AVFoundation
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One conversion worth asking about, and the file that stands for it.
///
/// One per kind, never one per file: a hundred photos going the same way is one
/// question, and asking it a hundred times is the interruption this gate exists
/// to remove.
struct ConfirmationGroup: Identifiable {
  let kind: ConvertKind
  let representative: ProcessableFile
  let count: Int
  let preset: RulePreset
  let plan: ConversionPlan
  let destination: URL?

  var id: String { kind.rawValue }
}

/// The sober popup: what this actually produces, before it produces it.
///
/// Not an editor. Everything that can be changed lives in the Convert sheet;
/// this says what is about to happen and takes yes or no.
struct ConfirmationSheet: View {
  let groups: [ConfirmationGroup]
  let coordinator: ProcessingCoordinator
  let onConvert: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.title3.weight(.semibold))
        if let sentence = groups.first?.plan.reason?.sentence {
          Text(sentence).font(.callout).foregroundStyle(.secondary)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          ForEach(groups) { group in
            ConfirmationRow(group: group, coordinator: coordinator)
          }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 420)

      Divider()

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { onCancel() }
          .keyboardShortcut(.cancelAction)
        Button("Convert") { onConvert() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
      .padding(16)
    }
    .frame(width: 520)
  }

  private var title: String {
    let files = groups.reduce(0) { $0 + $1.count }
    return files == 1 ? "Convert this file?" : "Convert these \(files) files?"
  }
}

/// One kind's row: the numbers, and a look at the result where looking is
/// cheap enough to be worth it.
private struct ConfirmationRow: View {
  let group: ConfirmationGroup
  let coordinator: ProcessingCoordinator

  @StateObject private var run = PreviewRun()

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: group.kind.icon).foregroundStyle(.secondary)
        Text(group.count == 1
          ? group.representative.fileName
          : "\(group.count) \(group.kind.plural), like \(group.representative.fileName)")
          .font(.callout.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
      }

      switch run.state {
      case .working:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Converting one of them to show you…").font(.caption).foregroundStyle(.secondary)
        }

      case .failed(let reason):
        Text(reason)
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)

      case .ready(let outcome):
        VStack(alignment: .leading, spacing: 8) {
          if outcome.before != nil || outcome.after != nil {
            HStack(spacing: 6) { pictures(outcome) }
          }
          Text(outcome.summary).font(.callout).monospacedDigit()
          if let note = outcome.note {
            Text(note)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .task { await run.make(group, with: coordinator) }
  }

  @ViewBuilder
  private func pictures(_ outcome: PreviewRun.Outcome) -> some View {
    if let before = outcome.before { thumbnail(before, label: "Now") }
    if outcome.before != nil, outcome.after != nil {
      Image(systemName: "arrow.right").foregroundStyle(.tertiary)
    }
    if let after = outcome.after { thumbnail(after, label: "After") }
  }

  private func thumbnail(_ image: NSImage, label: String) -> some View {
    VStack(spacing: 4) {
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .frame(width: 120, height: 90)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)))
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
  }
}

/// Runs one representative file through the real chain, into scratch.
///
/// Scratch only, and deleted the moment a picture has been made of it: a
/// preview must never write where the user's files are, and must leave nothing
/// behind when they say no.
@MainActor
final class PreviewRun: ObservableObject {

  struct Outcome {
    var before: NSImage?
    var after: NSImage?
    /// The line with the numbers in it.
    var summary: String
    /// Where the files land, or why there is nothing to look at.
    var note: String?
  }

  enum State {
    case working
    case ready(Outcome)
    case failed(String)
  }

  @Published private(set) var state: State = .working
  private var started = false

  func make(_ group: ConfirmationGroup, with coordinator: ProcessingCoordinator) async {
    // A row redraws whenever anything above it changes; the conversion happens
    // once.
    guard !started else { return }
    started = true

    switch group.kind.previewCost {
    case .runIt:
      await convert(group, with: coordinator)

    case .oneFrame:
      state = .ready(Outcome(
        before: await Self.frame(of: group.representative.url),
        summary: describe(group),
        note: "Encoding it to show you would be the conversion itself, so this is the film as it stands."
      ))

    case .describeIt:
      state = .ready(Outcome(summary: describe(group)))
    }
  }

  private func convert(_ group: ConfirmationGroup, with coordinator: ProcessingCoordinator) async {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("forge-preview-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    do {
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      let result = try await coordinator.preview(group.representative, with: group.preset, into: scratch)

      var summary = group.representative.fileSize.formatted(.byteCount(style: .file))
        + " → " + result.outputSize.formatted(.byteCount(style: .file))
      if let quality = result.appliedQuality { summary += " @ q\(quality)" }
      if let size = result.outputDimensions { summary += ", \(size.width) × \(size.height)" }

      let written = 1 + result.additionalOutputs.count
      var note: String?
      if written > 1 {
        let folder = group.destination?.lastPathComponent ?? "the destination folder"
        note = "\(written) files per \(group.kind.title), into \(folder)."
      }

      state = .ready(Outcome(
        before: Self.thumbnail(of: group.representative.url),
        after: Self.thumbnail(of: result.outputURL),
        summary: summary,
        note: note
      ))
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  /// What will happen, for the kinds too expensive to show.
  private func describe(_ group: ConfirmationGroup) -> String {
    let size = group.representative.fileSize.formatted(.byteCount(style: .file))
    guard let target = group.preset.targetFormat
      .flatMap(FormatCatalog.fileExtension(for:))?
      .uppercased() else {
      return "\(size), \(group.preset.name)"
    }
    return "\(size) → \(target). The finished size is known once it runs."
  }

  /// A small picture of a file, made by ImageIO at the size it is shown.
  /// Decoding a whole image to draw a thumbnail is how a preview of a sixty
  /// megapixel photograph costs a gigabyte.
  static func thumbnail(of url: URL, maximumPixels: Int = 480) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }

  /// The first frame of a film, which is the cheapest true thing to show about
  /// one.
  static func frame(of url: URL) async -> NSImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 480)
    guard let image = try? await generator.image(at: .zero).image else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
}
