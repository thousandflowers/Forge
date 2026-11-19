import SwiftUI
import AppKit

/// "Custom" as a micro menu: a frame over the picture dragged by its corner,
/// ready-made shapes, the two numbers following along, and how it should fit.
/// Opened from the Convert sheet's Custom… and from a Resize block.
struct CustomSizeMenu: View {
  @Binding var width: Int?
  @Binding var height: Int?
  @Binding var fit: ResizeFitMode
  /// The picture being sized, when there is one to show; otherwise a plain
  /// stand-in of the same shape.
  var source: CGSize = CGSize(width: 3000, height: 2000)
  var image: NSImage?

  @State private var shape: Proportion = .free
  private let stageWidth: CGFloat = 240

  /// Ready-made proportions. Free leaves the height to the picture.
  enum Proportion: String, CaseIterable, Identifiable {
    case free = "Free", square = "1:1", portrait = "4:5", wide = "16:9", photo = "3:2"
    var id: String { rawValue }
    var ratio: CGFloat? {
      switch self {
      case .free: return nil
      case .square: return 1
      case .portrait: return 4.0 / 5.0
      case .wide: return 16.0 / 9.0
      case .photo: return 3.0 / 2.0
      }
    }
  }

  private var stage: CGSize {
    CGSize(width: stageWidth, height: stageWidth * source.height / max(source.width, 1))
  }
  private var scale: CGFloat { stage.width / max(source.width, 1) }
  private var shownWidth: CGFloat { CGFloat(width ?? Int(source.width)) }
  private var shownHeight: CGFloat {
    CGFloat(height ?? Int((shownWidth * source.height / max(source.width, 1)).rounded()))
  }
  private var frame: CGSize {
    CGSize(width: min(stage.width, shownWidth * scale), height: min(stage.height, shownHeight * scale))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Custom size").font(.system(size: Metrics.bodyText, weight: .semibold))
      stageView
      shapes
      numbers
      Picker("", selection: $fit) {
        ForEach(ResizeFitMode.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      // A menu, as on the block: four segments did not fit in 240 points
      // and ran into the popover's edges.
      .pickerStyle(.menu).labelsHidden().fixedSize()
      .accessibilityLabel(Text("How it fits"))
      Text("From \(Int(source.width)) × \(Int(source.height))")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(14)
    .onAppear { shape = Self.proportion(width: width, height: height) }
  }

  /// The ready-made shape a size already is, or Free.
  static func proportion(width: Int?, height: Int?) -> Proportion {
    guard let width, let height, height > 0 else { return .free }
    let ratio = CGFloat(width) / CGFloat(height)
    return Proportion.allCases.first { $0.ratio.map { abs($0 - ratio) < 0.01 } ?? false } ?? .free
  }

  private var stageView: some View {
    ZStack(alignment: .topLeading) {
      picture.opacity(0.35)
      picture.mask(alignment: .topLeading) { Rectangle().frame(width: frame.width, height: frame.height) }
      Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: frame.width, height: frame.height)
      Circle().fill(Color.white).frame(width: 14, height: 14)
        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
        .offset(x: frame.width - 7, y: frame.height - 7)
    }
    .frame(width: stage.width, height: stage.height)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    // The whole stage takes the drag, read in the stage's own points: on the
    // 14-point handle the drag's location was the handle's own, so the frame
    // collapsed to its minimum, and the handle was a hard target besides.
    .contentShape(Rectangle())
    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.stageSpace)).onChanged { value in
      resize(to: value.location)
    })
    .coordinateSpace(name: Self.stageSpace)
    .help("Drag to set the size")
  }

  @ViewBuilder private var picture: some View {
    if let image {
      Image(nsImage: image).resizable().frame(width: stage.width, height: stage.height)
    } else {
      Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: stage.width, height: stage.height)
    }
  }

  private var shapes: some View {
    HStack(spacing: 4) {
      ForEach(Proportion.allCases) { option in
        Button { choose(option) } label: {
          Text(option.rawValue)
            .font(.system(size: 11, weight: shape == option ? .semibold : .regular))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(shape == option ? Color.accentColor : Color.secondary.opacity(0.14), in: Capsule())
            .foregroundStyle(shape == option ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var numbers: some View {
    HStack(spacing: 6) {
      NumberToken(value: $width, placeholder: "auto", startingFrom: Int(source.width))
        .accessibilityLabel(Text("Width"))
      Image(systemName: shape == .free ? "lock.open" : "lock").foregroundStyle(.secondary)
      NumberToken(value: $height, placeholder: "auto", startingFrom: Int(source.height))
        .accessibilityLabel(Text("Height"))
      Text("px").foregroundStyle(.secondary)
    }
  }

  private func choose(_ option: Proportion) {
    shape = option
    guard let ratio = option.ratio else { height = nil; return }
    let base = width ?? Int(source.width)
    width = base
    height = Self.height(for: base, ratio: ratio)
  }

  private static let stageSpace = "custom-size-stage"

  /// A drag on the stage, in the stage's own points: the corner goes there.
  private func resize(to point: CGPoint) {
    let newWidth = Int((max(16, min(stage.width, point.x)) / scale).rounded())
    width = newWidth
    if let ratio = shape.ratio {
      height = Self.height(for: newWidth, ratio: ratio)
    } else {
      height = Int((max(12, min(stage.height, point.y)) / scale).rounded())
    }
  }

  /// The height that gives a width this shape.
  static func height(for width: Int, ratio: CGFloat) -> Int {
    Int((CGFloat(width) / ratio).rounded())
  }
}
