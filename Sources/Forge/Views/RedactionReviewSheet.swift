import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The review a redaction cannot happen without.
///
/// What a detector found is shown as boxes over the picture, all of them off.
/// Ticking one is the only thing that puts it in the file. The sentence saying
/// so stays on the screen, because the difference between "Forge found these"
/// and "this file is anonymous" is the whole of the honesty here.
struct RedactionReviewSheet: View {
  let file: ProcessableFile
  let onFinish: (URL) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var session: RedactionSession?
  @State private var failure: String?
  @State private var working = true
  @State private var applying = false

  private let scout = RedactionScout()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
      Divider()
      footer
    }
    .frame(width: 720, height: 620)
    .task { await look() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Review before covering").font(.title3.weight(.semibold))
      Text(
        "Forge found what it could in \(file.fileName). It misses things — a face turned away, "
          + "handwriting, a name in a reflection — so this is a starting point, not a guarantee "
          + "that the file is anonymous. Nothing is covered until you tick it."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var content: some View {
    if working {
      centred { ProgressView("Looking through the picture…") }
    } else if let failure {
      centred {
        Text(failure).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
      }
    } else if let session {
      HStack(spacing: 0) {
        picture(session)
        Divider()
        list(session)
      }
    }
  }

  private func picture(_ session: RedactionSession) -> some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        if let preview = PreviewRun.thumbnail(of: file.url, maximumPixels: 900) {
          Image(nsImage: preview)
            .resizable()
            .scaledToFit()
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        boxes(session, in: drawnFrame(in: geometry.size))
      }
    }
    .frame(minWidth: 380)
    .padding(12)
  }

  /// Where the picture actually ends up inside the space it was given: the
  /// boxes have to sit on the picture, not on the view.
  private func drawnFrame(in space: CGSize) -> CGRect {
    guard let size = file.dimensions, size.width > 0, size.height > 0 else {
      return CGRect(origin: .zero, size: space)
    }
    let ratio = CGFloat(size.width) / CGFloat(size.height)
    var drawn = CGSize(width: space.width, height: space.width / ratio)
    if drawn.height > space.height {
      drawn = CGSize(width: space.height * ratio, height: space.height)
    }
    return CGRect(
      x: (space.width - drawn.width) / 2,
      y: (space.height - drawn.height) / 2,
      width: drawn.width,
      height: drawn.height
    )
  }

  private func boxes(_ session: RedactionSession, in frame: CGRect) -> some View {
    ForEach(session.candidates) { candidate in
      let on = session.isConfirmed(candidate)
      // Vision measures from the bottom left; the screen measures from the top.
      Rectangle()
        .fill(on ? Color.black.opacity(0.82) : Color.accentColor.opacity(0.12))
        .overlay(Rectangle().strokeBorder(on ? Color.black : Color.accentColor, lineWidth: 1.5))
        .frame(
          width: candidate.rect.width * frame.width,
          height: candidate.rect.height * frame.height
        )
        .offset(
          x: frame.minX + candidate.rect.minX * frame.width,
          y: frame.minY + (1 - candidate.rect.maxY) * frame.height
        )
        .onTapGesture { toggle(candidate) }
    }
  }

  private func list(_ session: RedactionSession) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if session.candidates.isEmpty {
        centred {
          Text("Forge found nothing it recognises here. That is not the same as there being nothing.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(12)
        }
      } else {
        List {
          ForEach(session.candidates) { candidate in
            Toggle(isOn: Binding(
              get: { session.isConfirmed(candidate) },
              set: { _ in toggle(candidate) }
            )) {
              HStack(spacing: 8) {
                Image(systemName: candidate.kind.symbol).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                  Text(candidate.kind.title).font(.callout)
                  if let text = candidate.text {
                    Text(text)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                      .truncationMode(.middle)
                  }
                }
              }
            }
          }
        }
        .listStyle(.inset)
      }
    }
    .frame(width: 260)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      if let session {
        Picker("", selection: Binding(
          get: { session.style },
          set: { style in self.session?.style = style }
        )) {
          ForEach(RedactionStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()

        Text(count(session)).font(.callout).foregroundStyle(.secondary)
      }

      Spacer()

      Button("Cancel", role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(applying ? "Writing…" : "Cover and Save a Copy…") { save() }
        .buttonStyle(.borderedProminent)
        .disabled(session?.hasSomethingToDo != true || applying)
    }
    .padding(16)
  }

  private func count(_ session: RedactionSession) -> String {
    let confirmed = session.confirmedRegions.count
    guard confirmed > 0 else { return "Nothing ticked, so nothing will be covered." }
    return confirmed == 1
      ? "1 region will be covered, permanently, in the copy."
      : "\(confirmed) regions will be covered, permanently, in the copy."
  }

  private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content().frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func toggle(_ candidate: RedactionCandidate) {
    session?.toggle(candidate)
  }

  private func look() async {
    do {
      let found = try await scout.candidates(in: file.url)
      session = RedactionSession(source: file.url, candidates: found)
    } catch {
      failure = error.localizedDescription
    }
    working = false
  }

  /// A copy, always, and to a place the user chose. Burning a redaction into
  /// the original would be the one edit in Forge that cannot be undone.
  private func save() {
    guard let session, session.hasSomethingToDo else { return }

    let panel = NSSavePanel()
    panel.nameFieldStringValue = (file.fileName as NSString).deletingPathExtension + "-covered.png"
    panel.allowedContentTypes = [.png, .jpeg]
    panel.message = "Where should the covered copy go?"
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    applying = true
    Task {
      defer { applying = false }
      do {
        try Redactor.apply(
          session.confirmedRegions,
          style: session.style,
          to: session.source,
          writing: destination
        )
        onFinish(destination)
        dismiss()
      } catch {
        failure = error.localizedDescription
      }
    }
  }
}
