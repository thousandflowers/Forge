import SwiftUI

/// A name template, with what it would produce shown underneath it.
///
/// Nobody should have to memorise `{counter:03}`. The tokens are a menu that
/// inserts them, and the line under the field is the answer to "what will my
/// files actually be called", worked out by the same resolver that names them.
struct TemplateField: View {
  let title: String
  @Binding var template: String
  /// What the sample file is converted to, so the preview says `.jpeg` rather
  /// than guessing.
  var sampleExtension: String = "jpeg"
  /// Shown when the field is empty, for a preset with no template of its own
  /// that follows the general one.
  var placeholder: String = "{name}"

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        TextField(title, text: $template, prompt: Text(placeholder))
        Menu {
          ForEach(NameTemplate.Token.allCases) { token in
            Button {
              template += token.example
            } label: {
              Text("\(token.example) — \(token.summary)")
            }
          }
        } label: {
          Label("Tokens", systemImage: "curlybraces")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }

      Text(preview)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  /// One made-up file, run through the real resolver. A preview produced by a
  /// second implementation would be a preview of something that does not
  /// happen.
  private var preview: String {
    let text = template.isEmpty ? placeholder : template
    let context = NameTemplate.Static(
      name: "holiday",
      parent: "Photos",
      date: Date(),
      counter: 1,
      ext: sampleExtension,
      quality: 80,
      codec: "h264",
      parameters: ["maxsize": "10MB"]
    )
    // The dynamic half is filled in on purpose: a preview whose second half was
    // still `{width}` would say nothing about what the name becomes.
    let dynamic = NameTemplate.Dynamic(width: 1920, height: 1080, bytes: 2_400_000, quality: 72)

    let resolved = NameTemplate.resolve(text, with: context, and: dynamic)
    let name = resolved.isEmpty ? context.name : resolved
    return "holiday.png → \(name).\(sampleExtension)"
  }
}
