import AppKit
import SwiftUI

/// What Forge is for, the first time it is opened: one idea to a page, each
/// shown happening rather than told.
struct WelcomeView: View {
  static let windowID = "forge.welcome"
  static let seenKey = "welcomeSeen"
  static let size = CGSize(width: 820, height: 560)

  enum Page: Int, CaseIterable {
    case hello, drop, name, drag, ready
  }

  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceMotion) private var isStill
  @State private var page = Page.hello
  @State private var watches = false

  var body: some View {
    VStack(spacing: 0) {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(page)
        .transition(isStill ? .opacity : .asymmetric(
          insertion: .offset(y: 18).combined(with: .opacity), removal: .opacity
        ))
      bar
    }
    .padding(.horizontal, 44)
    .padding(.bottom, 30)
    .frame(width: Self.size.width, height: Self.size.height)
    .background { WelcomeSky(page: page, isStill: isStill).ignoresSafeArea() }
    .environment(\.colorScheme, .dark)
    .onAppear { UserDefaults.standard.set(true, forKey: Self.seenKey) }
  }

  // MARK: - Pages

  @ViewBuilder
  private var content: some View {
    switch page {
    case .hello:
      VStack(spacing: 18) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable().frame(width: 132, height: 132)
          .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
          .accessibilityHidden(true)
        words("Welcome to Forge", "Convert almost any file, or change it, right on your Mac.")
      }
    case .drop:
      VStack(spacing: 30) {
        WelcomeDrop(isStill: isStill)
        words("Drop it in", "Choose what your files become and press Convert. The originals stay where they are.")
      }
    case .name:
      VStack(spacing: 24) {
        WelcomeName(isStill: isStill)
        words("Say it in the name", "In a folder Forge watches, add a word to a file’s name and it is done. Try one.")
      }
    case .drag:
      VStack(spacing: 26) {
        WelcomeDrag(isStill: isStill, keys: model.settings.dragMenuKeys.symbols)
        words("Hold \(model.settings.dragMenuKeys.symbols) while you drag", "A menu opens over the file, wherever you are. Let go on what it should become.")
      }
    case .ready:
      VStack(spacing: 26) {
        words("Make it yours", "Turn on what you like. You can always change it later.")
        VStack(spacing: 0) {
          choice("Show a menu over the file I drag", "hand.draw", $model.settings.dragMenu)
          line
          choice("Watch my Desktop and Downloads for names", "character.cursor.ibeam", $watches)
          line
          choice("Convert files I rename to another extension", "pencil", $model.settings.convertsRenames)
        }
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .frame(width: 480)
        Text("macOS may ask to allow the folders you choose.").font(.callout).foregroundStyle(.white.opacity(0.75))
      }
    }
  }

  private func words(_ title: String, _ more: String) -> some View {
    VStack(spacing: 10) {
      Text(title).font(.system(size: 38, weight: .bold)).foregroundStyle(.white)
      Text(more)
        .font(.system(size: 16))
        .foregroundStyle(.white.opacity(0.88))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 440)
    }
    .accessibilityElement(children: .combine)
  }

  private func choice(_ title: String, _ symbol: String, _ isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
      HStack(spacing: 10) {
        Image(systemName: symbol).frame(width: 22)
        Text(title).frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(.white)
    }
    .toggleStyle(.switch)
    .padding(.horizontal, 18)
    .frame(height: 52)
  }

  private var line: some View { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }

  // MARK: - Going on

  private var bar: some View {
    HStack {
      Button("Back") { go(-1) }
        .buttonStyle(WelcomeButton(isMain: false))
        .opacity(page == .hello ? 0 : 1)
        .disabled(page == .hello)
        .frame(width: 180, alignment: .leading)
      Spacer()
      HStack(spacing: 8) {
        ForEach(Page.allCases, id: \.self) { other in
          Capsule().fill(.white.opacity(other == page ? 0.95 : 0.35)).frame(width: other == page ? 22 : 7, height: 7)
        }
      }
      .accessibilityElement()
      .accessibilityLabel(Text("Page \(page.rawValue + 1) of \(Page.allCases.count)"))
      Spacer()
      Button(page == .ready ? "Start Converting" : "Continue") { page == .ready ? finish() : go(1) }
        .buttonStyle(WelcomeButton(isMain: true))
        .keyboardShortcut(.defaultAction)
        .frame(width: 180, alignment: .trailing)
    }
  }

  private func go(_ step: Int) {
    guard let next = Page(rawValue: page.rawValue + step) else { return }
    withAnimation(isStill ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.86)) { page = next }
  }

  private func finish() {
    model.saveSettings()
    if watches { model.watchForNames() }
    model.section = .process
    openWindow(id: MenuBarView.windowID)
    dismiss()
  }
}

/// A sky of its own for every page, one melting into the next.
private struct WelcomeSky: View {
  let page: WelcomeView.Page
  let isStill: Bool

  private var tints: (top: Color, bottom: Color, glow: Color) {
    switch page {
    case .hello: return (Color(hue: 0.06, saturation: 0.82, brightness: 0.86), Color(hue: 0.98, saturation: 0.78, brightness: 0.62), Color(hue: 0.11, saturation: 0.75, brightness: 1))
    case .drop: return (Color(hue: 0.52, saturation: 0.85, brightness: 0.66), Color(hue: 0.62, saturation: 0.82, brightness: 0.58), Color(hue: 0.47, saturation: 0.6, brightness: 0.9))
    case .name: return (Color(hue: 0.92, saturation: 0.68, brightness: 0.74), Color(hue: 0.78, saturation: 0.68, brightness: 0.52), Color(hue: 0.96, saturation: 0.5, brightness: 1))
    case .drag: return (Color(hue: 0.67, saturation: 0.66, brightness: 0.74), Color(hue: 0.72, saturation: 0.74, brightness: 0.44), Color(hue: 0.60, saturation: 0.6, brightness: 1))
    case .ready: return (Color(hue: 0.44, saturation: 0.75, brightness: 0.52), Color(hue: 0.54, saturation: 0.8, brightness: 0.42), Color(hue: 0.38, saturation: 0.5, brightness: 0.85))
    }
  }

  var body: some View {
    ZStack {
      LinearGradient(colors: [tints.top, tints.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
      RadialGradient(colors: [tints.glow.opacity(0.55), .clear], center: UnitPoint(x: 0.5, y: 0.2), startRadius: 10, endRadius: 420)
    }
    .id(page)
    .transition(.opacity)
    .animation(isStill ? nil : .easeInOut(duration: 0.6), value: page)
    .accessibilityHidden(true)
  }
}

private struct WelcomeButton: ButtonStyle {
  let isMain: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(isMain ? Color.black : .white)
      .padding(.horizontal, 22)
      .frame(height: 40)
      .background(.white.opacity(isMain ? 1 : 0.14), in: Capsule())
      .contentShape(Capsule())
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

/// A file, as the welcome draws one.
private struct WelcomeFile: View {
  let name: String
  let kind: PresetCategory
  var isLarge = false

  var body: some View {
    HStack(spacing: isLarge ? 16 : 12) {
      BlockIcon(symbol: kind.icon, tint: kind.tint, size: isLarge ? 60 : 42)
      Text(name).font(.system(size: isLarge ? 22 : 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1).fixedSize()
    }
    .padding(.leading, isLarge ? 16 : 12).padding(.trailing, isLarge ? 26 : 20)
    .frame(height: isLarge ? 92 : 66)
    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: isLarge ? 24 : 18, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: isLarge ? 24 : 18, style: .continuous).strokeBorder(.white.opacity(0.22)))
    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
  }
}

/// A file goes in, and comes out as something else.
private struct WelcomeDrop: View {
  let isStill: Bool
  @State private var step = 0

  private static let pairs: [(from: String, to: String, was: PresetCategory, became: PresetCategory)] = [
    ("beach.heic", "beach.jpg", .image, .image), ("talk.mov", "talk.mp3", .video, .audio), ("report.docx", "report.pdf", .document, .document),
  ]

  var body: some View {
    let pair = Self.pairs[step % Self.pairs.count]
    HStack(spacing: 22) {
      WelcomeFile(name: pair.from, kind: pair.was, isLarge: true)
      Image(systemName: "arrow.right").font(.system(size: 26, weight: .bold)).foregroundStyle(.white.opacity(0.9))
      WelcomeFile(name: pair.to, kind: pair.became, isLarge: true)
    }
    .id(step)
    .transition(.opacity.combined(with: .scale(scale: 0.96)))
    .frame(height: 110)
    .accessibilityElement(children: .combine)
    .task {
      guard !isStill else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.35)) { step += 1 }
      }
    }
  }
}

/// A name with a word put in it, and what is done. The words are the real ones.
struct WelcomeName: View {
  let isStill: Bool
  @State private var word = Self.words[0]
  @State private var isDone = true

  static let words = ["gray", "nobg", "enhance", "border20", "round40"]
  private static let name = "sunset", ending = ".png"

  var body: some View {
    VStack(spacing: 16) {
      WelcomePicture(word: isDone ? word : "")
        .frame(width: 210, height: 140)
      VStack(spacing: 5) {
        (Text(Self.name) + Text("_\(word)").foregroundColor(.yellow) + Text(Self.ending))
          .font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(.white)
        Text(Tool(word: word)?.title ?? "")
          .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85))
      }

      HStack(spacing: 8) {
        ForEach(Self.words, id: \.self) { other in
          Button("_\(other)") { choose(other) }
            .buttonStyle(WelcomeWord(isChosen: other == word))
        }
      }
    }
  }

  private func choose(_ other: String) {
    word = other
    isDone = false
    withAnimation(isStill ? nil : .easeInOut(duration: 0.35).delay(0.2)) { isDone = true }
  }
}

/// A picture, and what the word does to it.
private struct WelcomePicture: View {
  let word: String

  var body: some View {
    scene
      .grayscale(word == "gray" ? 1 : 0)
      .saturation(word == "enhance" ? 1.5 : 1)
      .contrast(word == "enhance" ? 1.12 : 1)
      .clipShape(RoundedRectangle(cornerRadius: word == "round40" ? 34 : 3, style: .continuous))
      .padding(word == "border20" ? 9 : 0)
      .background(Color.white.opacity(word == "border20" ? 1 : 0))
      .shadow(color: .black.opacity(word == "nobg" ? 0 : 0.3), radius: 14, y: 8)
      .accessibilityHidden(true)
  }

  private var isCutOut: Bool { word == "nobg" }

  private var scene: some View {
    GeometryReader { space in
      let size = space.size
      ZStack {
        LinearGradient(
          colors: [Color(hue: 0.6, saturation: 0.45, brightness: 0.75), Color(hue: 0.09, saturation: 0.5, brightness: 0.95)],
          startPoint: .top, endPoint: .bottom
        )
        .opacity(isCutOut ? 0 : 1)
        Circle().fill(Color(hue: 0.12, saturation: 0.55, brightness: 1))
          .frame(width: size.height * 0.4)
          .position(x: size.width * 0.72, y: size.height * 0.5)
          .opacity(isCutOut ? 0 : 1)
        hill(size, 0.62, 0.78, 0.5).fill(Color(hue: 0.55, saturation: 0.5, brightness: 0.5)).opacity(isCutOut ? 0 : 1)
        hill(size, 0.8, 0.7, 0.92).fill(Color(hue: 0.4, saturation: 0.55, brightness: 0.36)).opacity(isCutOut ? 0 : 1)
        // What the picture is of, which stays.
        VStack(spacing: -2) {
          Circle().fill(Color(hue: 0.07, saturation: 0.45, brightness: 0.85)).frame(width: size.height * 0.26)
          UnevenBody().fill(Color(hue: 0.99, saturation: 0.65, brightness: 0.8)).frame(width: size.height * 0.5, height: size.height * 0.4)
        }
        .position(x: size.width * 0.33, y: size.height * 0.7)
      }
    }
  }

  private func hill(_ size: CGSize, _ left: CGFloat, _ peak: CGFloat, _ right: CGFloat) -> Path {
    Path { path in
      path.move(to: CGPoint(x: 0, y: size.height * left))
      path.addQuadCurve(to: CGPoint(x: size.width, y: size.height * right), control: CGPoint(x: size.width * 0.5, y: size.height * (peak - 0.35)))
      path.addLine(to: CGPoint(x: size.width, y: size.height))
      path.addLine(to: CGPoint(x: 0, y: size.height))
    }
  }

  private struct UnevenBody: Shape {
    func path(in rect: CGRect) -> Path {
      Path { path in
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.minY))
      }
    }
  }
}

private struct WelcomeWord: ButtonStyle {
  let isChosen: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .medium, design: .rounded))
      .foregroundStyle(isChosen ? Color.black : .white)
      .padding(.horizontal, 14)
      .frame(height: 32)
      .background(.white.opacity(isChosen ? 0.95 : 0.14), in: Capsule())
      .contentShape(Capsule())
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
  }
}

/// A file carried over a small menu, until one of the choices lights up.
private struct WelcomeDrag: View {
  let isStill: Bool
  let keys: String
  @State private var isOver = false

  private static let choices = ["JPEG", "PNG", "HEIC", "PDF"]
  private static let chosen = 1
  private static let cell: CGFloat = 104

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        ForEach(Array(Self.choices.enumerated()), id: \.offset) { index, choice in
          let isLit = isOver && index == Self.chosen
          Text(choice)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isLit ? Color.black : .white)
            .frame(width: Self.cell, height: 62)
            .background(.white.opacity(isLit ? 0.95 : 0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(isLit && !isStill ? 1.05 : 1)
        }
      }
      .padding(12)
      .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
      HStack(spacing: 10) {
        Text(keys).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        WelcomeFile(name: "photo.webp", kind: .image)
      }
      .offset(x: isOver ? -20 : 60, y: isOver ? -14 : 12)
    }
    .frame(height: 190, alignment: .top)
    .accessibilityHidden(true)
    .task {
      guard !isStill else { return isOver = true }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: isOver ? 1_700_000_000 : 900_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { isOver.toggle() }
      }
    }
  }
}
