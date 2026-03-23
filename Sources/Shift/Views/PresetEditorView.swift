import SwiftUI

struct PresetEditorView: View {
  @State private var name: String = ""
  @State private var description: String = ""
  @State private var category: PresetCategory = .custom
  @State private var targetFormat: UTType? = nil

  var body: some View {
    VStack(spacing: 20) {
      Text("Create New Preset")
        .font(.title)

      Form {
        TextField("Name", text: $name)
        TextField("Description", text: $description)
        Picker("Category", selection: $category) {
          ForEach(PresetCategory.allCases, id: \.self) { cat in
            Text(cat.rawValue.capitalized).tag(cat)
          }
        }
      }

      Spacer()

      HStack {
        Spacer()
        Button("Cancel") {
          // Dismiss
        }
        Button("Save") {
          // Save preset
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding()
    .frame(width: 500, height: 400)
  }
}
