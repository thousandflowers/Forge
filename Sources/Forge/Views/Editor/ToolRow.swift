import SwiftUI

/// What a tool needs said, in as few controls as it takes.
struct ToolRow: View {
  @Binding var tool: Tool

  private static let shapes: [(Int, Int)] = [(1, 1), (4, 5), (3, 4), (2, 3), (9, 16), (16, 9), (3, 2), (4, 3), (21, 9)]
  private static let speeds: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 4, 8]

  var body: some View {
    switch tool {
    case .trim(let span, let fast):
      HStack(spacing: 6) {
        moment("From", span.from, none: "the start") { tool = .trim(Span(from: $0, to: span.to), fast: fast) }
        Text("to").foregroundStyle(.secondary)
        moment("To", span.to, none: "the end") { tool = .trim(Span(from: span.from, to: $0), fast: fast) }
        Toggle("Fast", isOn: Binding(get: { fast }, set: { tool = .trim(span, fast: $0) }))
          .toggleStyle(.checkbox)
          .help("Without encoding it again. The moment before the cut stays in the file, hidden.")
      }
    case .divide(let division): divide(division)
    case .speed(let speed):
      Picker("", selection: Binding(get: { speed }, set: { tool = .speed($0) })) {
        ForEach(Array(Set(Self.speeds + [speed])).sorted(), id: \.self) { Text("\(Tool.text($0))×").tag($0) }
      }
      .labelsHidden().frame(maxWidth: 100, alignment: .leading)
      .accessibilityLabel(Text("Speed"))
    case .loop(let times):
      HStack(spacing: 6) {
        NumberToken(value: Binding(get: { times }, set: { tool = .loop($0 ?? times) }), placeholder: "2", range: 2...100, startingFrom: times)
          .accessibilityLabel(Text("Times"))
        Text("times").foregroundStyle(.secondary)
      }
    case .turn(let turn):
      Picker("", selection: Binding(get: { turn }, set: { tool = .turn($0) })) {
        ForEach(Tool.Turn.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .labelsHidden().frame(maxWidth: 200, alignment: .leading)
      .accessibilityLabel(Text("Turn or mirror"))
    case .crop(let crop): cropping(crop)
    case .pages(let list): pages(list) { tool = .pages($0) }
    case .dropPages(let list): pages(list) { tool = .dropPages($0) }
    case .frames(let seconds):
      HStack(spacing: 6) {
        moment("Seconds apart", seconds, none: "5") { if let value = $0, value > 0 { tool = .frames(every: value) } }
        Text("seconds").foregroundStyle(.secondary)
      }
    case .sync(let thousandths):
      HStack(spacing: 6) {
        NumberToken(value: Binding(get: { thousandths }, set: { if let value = $0, value != 0 { tool = .sync(value) } }), placeholder: "250", range: -10_000...10_000, startingFrom: thousandths)
        Text("thousandths of a second later").foregroundStyle(.secondary)
      }
    case .adjust(let what, let much):
      HStack(spacing: 6) {
        Picker("", selection: Binding(get: { what }, set: { tool = .adjust($0, min(max(much, $0.range.lowerBound), $0.range.upperBound)) })) {
          ForEach(Tool.Adjustment.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        .labelsHidden().frame(maxWidth: 120)
        .accessibilityLabel(Text("Adjust"))
        NumberToken(value: Binding(get: { much }, set: { if let value = $0, value != 0 { tool = .adjust(what, value) } }), placeholder: "10", range: what.range, startingFrom: much)
      }
    case .border(let width, let isBlack):
      HStack(spacing: 6) {
        NumberToken(value: Binding(get: { width }, set: { tool = .border($0 ?? width, isBlack: isBlack) }), placeholder: "40", range: 1...9999, startingFrom: width)
        Text("px").foregroundStyle(.secondary)
        Toggle("Black", isOn: Binding(get: { isBlack }, set: { tool = .border(width, isBlack: $0) })).toggleStyle(.checkbox)
      }
    case .mark(let text):
      TypedField(label: "Words", placeholder: "© Your name", text: text, width: 200) { typed in
        let tidy = typed.trimmingCharacters(in: .whitespaces)
        guard !tidy.isEmpty else { return false }
        tool = .mark(tidy)
        return true
      }
    case .digest(let digest):
      Picker("", selection: Binding(get: { digest }, set: { tool = .digest($0) })) {
        ForEach(Tool.Digest.allCases, id: \.self) { Text(Tool.digest($0).title).tag($0) }
      }
      .labelsHidden().frame(maxWidth: 120, alignment: .leading)
      .accessibilityLabel(Text("Fingerprint"))
    case .mute, .normalize, .reverse, .removeBackground, .lighter:
      Text(tool.kind.summary).font(.callout).foregroundStyle(.secondary)
    }
  }

  private func moment(_ label: String, _ value: Double?, none: String, set: @escaping (Double?) -> Void) -> some View {
    TypedField(label: label, placeholder: none, text: value.map(Tool.clock) ?? "", width: 80) { typed in
      let tidy = typed.trimmingCharacters(in: .whitespaces)
      if tidy.isEmpty { set(nil); return true }
      guard let seconds = Tool.seconds(tidy) else { return false }
      set(seconds)
      return true
    }
  }

  private func pages(_ list: PageList, set: @escaping (PageList) -> Void) -> some View {
    TypedField(label: "Pages", placeholder: "2-5, 8", text: list.text, width: 140) { typed in
      guard let list = PageList(typed.filter { !$0.isWhitespace }) else { return false }
      set(list)
      return true
    }
  }

  @ViewBuilder
  private func divide(_ division: Tool.Division) -> some View {
    HStack(spacing: 6) {
      Picker("", selection: Binding(get: { division.way }, set: { tool = .divide($0.blank) })) {
        ForEach(Tool.Division.Way.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .labelsHidden().frame(maxWidth: 130)
      .accessibilityLabel(Text("Divide"))
      switch division {
      case .every(let seconds): moment("Seconds", seconds, none: "30") { if let value = $0, value > 0 { tool = .divide(.every(value)) } }
      case .parts(let count):
        NumberToken(value: Binding(get: { count }, set: { tool = .divide(.parts($0 ?? count)) }), placeholder: "2", range: 2...500, startingFrom: count)
      case .pages(let count):
        NumberToken(value: Binding(get: { count }, set: { tool = .divide(.pages($0 ?? count)) }), placeholder: "1", range: 1...9999, startingFrom: count)
      case .chapters: EmptyView()
      }
    }
  }

  @ViewBuilder
  private func cropping(_ crop: Tool.Crop) -> some View {
    switch crop {
    case .shape(let across, let down):
      let own = [(across, down)].filter { one in !Self.shapes.contains { $0 == one } }
      Picker("", selection: Binding(get: { "\(across):\(down)" }, set: { text in
        let sides = text.split(separator: ":").compactMap { Int($0) }
        if sides.count == 2 { tool = .crop(.shape(sides[0], sides[1])) }
      })) {
        ForEach((Self.shapes + own).map { "\($0.0):\($0.1)" }, id: \.self) { Text($0).tag($0) }
      }
      .labelsHidden().frame(maxWidth: 100, alignment: .leading)
      .accessibilityLabel(Text("Shape"))
    case .box(let x, let y, let width, let height):
      Text("\(width) × \(height) from \(x), \(y)").font(.callout).foregroundStyle(.secondary)
    }
  }
}

/// A field that takes what it understands and gives back what it does not.
private struct TypedField: View {
  let label: String
  let placeholder: String
  let text: String
  let width: CGFloat
  let take: (String) -> Bool
  @State private var typed = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    TextField(placeholder, text: $typed)
      .focused($isFocused)
      .frame(width: width)
      .onAppear { typed = text }
      .onChange(of: text) { typed = $0 }
      .onSubmit(commit)
      .onChange(of: isFocused) { if !$0 { commit() } }
      .accessibilityLabel(Text(label))
  }

  private func commit() {
    guard typed != text else { return }
    if !take(typed) { NSSound.beep(); typed = text }
  }
}

extension Tool.Division {
  enum Way: CaseIterable {
    case parts, every, chapters, pages

    var title: String {
      switch self {
      case .parts: return "Into parts"
      case .every: return "Every"
      case .chapters: return "By chapter"
      case .pages: return "Every pages"
      }
    }

    var blank: Tool.Division {
      switch self {
      case .parts: return .parts(2)
      case .every: return .every(30)
      case .chapters: return .chapters
      case .pages: return .pages(1)
      }
    }
  }

  var way: Way {
    switch self {
    case .parts: return .parts
    case .every: return .every
    case .chapters: return .chapters
    case .pages: return .pages
    }
  }
}
