import AVFoundation
import Foundation
import ImageIO

/// What is being cut out of one file: which part of its time, and which part
/// of its picture. It comes to the same tools a name or a preset would say.
@MainActor
final class CutModel: ObservableObject {
  /// A corner or a side of the box: -1, 0 or 1 each way, from the top left.
  struct Handle: Hashable {
    let x: Int, y: Int
    static let all: [Handle] = [-1, 0, 1].flatMap { y in [-1, 0, 1].map { Handle(x: $0, y: y) } }.filter { $0.x != 0 || $0.y != 0 }
    var isCorner: Bool { x != 0 && y != 0 }
  }

  struct Shape: Hashable {
    let across: Int, down: Int
    var title: String { "\(across):\(down)" }
    var ratio: CGFloat { CGFloat(across) / CGFloat(down) }
    static let common = [Shape(across: 1, down: 1), Shape(across: 4, down: 5), Shape(across: 9, down: 16), Shape(across: 16, down: 9), Shape(across: 4, down: 3), Shape(across: 3, down: 2)]
  }

  /// Less than this is nothing to look at.
  static let shortest = 0.1
  static let smallest: CGFloat = 16

  let file: ProcessableFile
  let kind: ConvertKind
  var isTimed: Bool { kind == .video || kind == .audio }
  var hasPicture: Bool { kind == .video || kind == .image }

  @Published private(set) var isReady = false
  @Published private(set) var problem: String?
  @Published private(set) var length = 0.0
  @Published private(set) var from = 0.0
  @Published private(set) var to = 0.0
  /// As it is seen, before anything is turned here.
  @Published private(set) var seen = CGSize.zero
  @Published private(set) var quarters = 0
  @Published private(set) var isMirrored = false
  /// In the pixels of the picture as it is turned.
  @Published private(set) var box = CGRect.zero
  @Published private(set) var shape: Shape?
  @Published var isMuted = false
  @Published var isFast = false
  @Published var speed = 1.0

  init?(file: ProcessableFile) {
    guard let kind = ConvertKind(fileType: file.fileType), [.video, .audio, .image].contains(kind) else { return nil }
    self.file = file
    self.kind = kind
  }

  func load() async {
    if isTimed {
      guard let seconds = try? await Division.length(of: file.url) else {
        problem = "\(file.fileName) cannot be played here."
        return
      }
      let seen = await ProcessableFile.videoDimensions(url: file.url, type: file.fileType)
      begin(length: seconds, seen: seen.map { CGSize(width: $0.width, height: $0.height) } ?? .zero)
      if kind == .video, seen == nil { problem = "\(file.fileName) cannot be shown here. Convert it to MP4 first." }
    } else {
      let source = CGImageSourceCreateWithURL(file.url as CFURL, nil)
      let orientation = source.map(ImageProcessor.orientation(of:)) ?? .up
      let isOnItsSide = orientation.rawValue >= 5
      let size = file.dimensions.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
      begin(length: 0, seen: isOnItsSide ? CGSize(width: size.height, height: size.width) : size)
      if size == .zero { problem = "\(file.fileName) cannot be shown here." }
    }
  }

  func begin(length: Double, seen: CGSize) {
    self.length = length
    self.seen = seen
    from = 0
    to = length
    box = whole
    isReady = true
  }

  // MARK: - Time

  func setFrom(_ seconds: Double) { from = min(max(seconds, 0), max(0, to - Self.shortest)) }
  func setTo(_ seconds: Double) { to = max(min(seconds, length), min(length, from + Self.shortest)) }
  /// The part as it is, somewhere else.
  func slide(to start: Double) {
    let kept = to - from
    from = min(max(start, 0), length - kept)
    to = from + kept
  }

  var kept: Double { (to - from) / speed }
  var isPart: Bool { from > 0.01 || to < length - 0.01 }

  // MARK: - Picture

  /// The picture as it is turned.
  var size: CGSize { quarters % 2 == 0 ? seen : CGSize(width: seen.height, height: seen.width) }
  var whole: CGRect { CGRect(origin: .zero, size: size) }
  var isCropped: Bool { hasPicture && box.integral != whole.integral }

  /// The box turns with the picture.
  func turn() {
    let old = size, was = box
    quarters = (quarters + 1) % 4
    box = CGRect(x: old.height - was.maxY, y: was.minX, width: was.height, height: was.width)
    if let shape { self.shape = Shape(across: shape.down, down: shape.across) }
  }

  func mirror() {
    isMirrored.toggle()
    box.origin.x = size.width - box.maxX
  }

  func setShape(_ shape: Shape?) {
    self.shape = shape
    guard let shape else { return }
    let made = try? Tool.Crop.shape(shape.across, shape.down).box(in: size, around: CGPoint(x: box.midX, y: box.midY))
    box = made ?? whole
  }

  func showWhole() {
    shape = nil
    box = whole
  }

  func setBox(_ rect: CGRect) {
    let width = min(max(rect.width, Self.smallest), size.width), height = min(max(rect.height, Self.smallest), size.height)
    box = CGRect(
      x: min(max(rect.minX, 0), size.width - width), y: min(max(rect.minY, 0), size.height - height), width: width, height: height
    )
  }

  func move(_ start: CGRect, by offset: CGSize) {
    box = CGRect(
      x: min(max(start.minX + offset.width, 0), size.width - start.width),
      y: min(max(start.minY + offset.height, 0), size.height - start.height),
      width: start.width, height: start.height
    )
  }

  /// - Parameter start: the box as it was when the handle was taken hold of.
  func drag(_ handle: Handle, from start: CGRect, by offset: CGSize) {
    var left = start.minX, right = start.maxX, top = start.minY, bottom = start.maxY
    if handle.x < 0 { left = min(max(left + offset.width, 0), right - Self.smallest) }
    if handle.x > 0 { right = max(min(right + offset.width, size.width), left + Self.smallest) }
    if handle.y < 0 { top = min(max(top + offset.height, 0), bottom - Self.smallest) }
    if handle.y > 0 { bottom = max(min(bottom + offset.height, size.height), top + Self.smallest) }
    guard let shape, handle.isCorner else {
      if shape == nil { box = CGRect(x: left, y: top, width: right - left, height: bottom - top) }
      return
    }
    // The corner across from it stays where it is, and the shape what it is.
    let room = CGSize(
      width: handle.x < 0 ? start.maxX : size.width - start.minX, height: handle.y < 0 ? start.maxY : size.height - start.minY
    )
    let wanted = max(right - left, (bottom - top) * shape.ratio)
    let width = max(min(wanted, room.width, room.height * shape.ratio), Self.smallest)
    let height = width / shape.ratio
    box = CGRect(
      x: handle.x < 0 ? start.maxX - width : start.minX, y: handle.y < 0 ? start.maxY - height : start.minY, width: width, height: height
    )
  }

  // MARK: - What it comes to

  /// Turned, then cropped: the box is drawn on the picture as it is turned.
  var tools: [Tool] {
    var tools: [Tool] = []
    if let turn = [nil, Tool.Turn.right, .half, .left][quarters], hasPicture { tools.append(.turn(turn)) }
    if isMirrored, hasPicture { tools.append(.turn(.mirror)) }
    if isCropped {
      tools.append(.crop(.box(
        x: Int(box.minX.rounded()), y: Int(box.minY.rounded()), width: Int(box.width.rounded()), height: Int(box.height.rounded())
      )))
    }
    if isTimed {
      if isPart {
        let span = Span(from: from > 0.01 ? Self.thousandth(from) : nil, to: to < length - 0.01 ? Self.thousandth(to) : nil)
        tools.append(.trim(span, fast: isFast && canBeFast))
      }
      if speed != 1 { tools.append(.speed(speed)) }
      if isMuted, kind == .video { tools.append(.mute) }
    }
    return tools
  }

  /// A quick cut leaves the film as it was encoded, so it has to be left as it
  /// was otherwise.
  var canBeFast: Bool { kind == .video && isPart && speed == 1 && quarters == 0 && !isMirrored && !isCropped }

  /// The format it has, where that can be written, or one much like it.
  var preset: RulePreset {
    RulePreset(name: "Cut", description: "", category: .custom, actions: tools.map { .tool($0) })
  }

  private static func thousandth(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
