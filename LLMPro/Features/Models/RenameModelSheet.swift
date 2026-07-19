import SwiftUI

/// Rename a downloaded model. This sets a **display-name alias only** — the model's
/// on-disk folder and repoID are never changed, so loading, training configs, and the
/// HF cache layout all keep working; it just changes the name LLMPro shows. Works for
/// any model (LLM or image) since it's keyed by a stable id in `ModelMetaStore`.
struct RenameModelSheet: View {
    let modelID: String
    let defaultName: String
    @Environment(\.dismiss) private var dismiss

    @State private var store = ModelMetaStore.shared
    @State private var name: String = ""
    @FocusState private var focused: Bool

    private var hasAlias: Bool { !store.meta(for: modelID).displayName.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Rename model", systemImage: "pencil").font(.headline)
            Text("Give this model a friendlier name. This only changes what LLMPro shows — the model’s files and ID stay the same, so everything keeps working.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Display name").font(.caption).foregroundStyle(.secondary)
                TextField(defaultName, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(save)
                Text("Original: \(defaultName)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }

            HStack {
                Button("Reset to original") { name = ""; save() }
                    .disabled(!hasAlias)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent).tint(.brand)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        .onAppear {
            name = store.meta(for: modelID).displayName
            focused = true
        }
    }

    private func save() {
        store.rename(name, for: modelID, default: defaultName)
        dismiss()
    }
}
