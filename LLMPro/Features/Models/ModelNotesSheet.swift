import SwiftUI

/// Edit notes + tags for a local model. Lets the user remember what a model is
/// for ("best C# fine-tune", "uncensored copy") and tag it for filtering. Persists
/// via `ModelMetaStore` (side JSON, no schema change).
struct ModelNotesSheet: View {
    let modelID: String
    let modelName: String
    @Environment(\.dismiss) private var dismiss

    @State private var store = ModelMetaStore.shared
    @State private var notes: String = ""
    @State private var tagsText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Notes & tags — \(modelName)", systemImage: "tag")

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tags (comma-separated)").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. coding, csharp, favorite", text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                if !parsedTags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(parsedTags, id: \.self) { tag in
                            Text(tag).font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.tint.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }

            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.buttonStyle(.borderedProminent).tint(.brand)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 380)
        .onAppear {
            let m = store.meta(for: modelID)
            notes = m.notes
            tagsText = m.tags.joined(separator: ", ")
        }
    }

    private var parsedTags: [String] {
        tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func save() {
        store.set(ModelMeta(notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), tags: parsedTags), for: modelID)
        dismiss()
    }
}
