import SwiftUI
import SwiftData

struct DatasetDetailView: View {
    @Bindable var dataset: DatasetRecord
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var split: DatasetSplit = .train
    @State private var rows: [ChatRow] = []
    @State private var loading: Bool = true
    @State private var loadError: String?
    @State private var dirty: Bool = false
    @State private var saving: Bool = false
    @State private var saveError: String?

    @State private var editingRow: ChatRow?
    @State private var isNewRow: Bool = false
    @State private var confirmDeleteDataset: Bool = false
    @State private var confirmRowDeletionIndex: Int?

    var body: some View {
        content
            .frame(minWidth: 760, idealWidth: 880, minHeight: 580, idealHeight: 700)
            .task(id: split) { await loadCurrent() }
        .sheet(item: $editingRow) { row in
            DatasetRowEditorView(initial: row, isNew: isNewRow) { updated in
                applyRowEdit(row, updated: updated)
            }
        }
        .alert("Delete this dataset?", isPresented: $confirmDeleteDataset) {
            Button("Delete", role: .destructive) { deleteDataset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(dataset.name) and all its lesson files from this Mac. You can't undo this.")
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.top, 12)
            header
                .padding(.horizontal, 16)
                .padding(.top, 8)
            splitPicker
                .padding(.horizontal, 16)
                .padding(.top, 6)
            Divider().padding(.vertical, 8)
            rowList
                .frame(maxHeight: .infinity)
            Divider()
            bottomBar
                .padding(12)
        }
    }

    private var topBar: some View {
        HStack {
            Button("Close") { dismiss() }
            Spacer()
            if let err = saveError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.caption).lineLimit(1)
            }
            Button {
                Task { await save() }
            } label: {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Save", systemImage: dirty ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                }
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!dirty || saving)
        }
    }

    private var bottomBar: some View {
        HStack {
            Button(role: .destructive) {
                confirmDeleteDataset = true
            } label: {
                Label("Delete dataset", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            Spacer()
            Button {
                startNewRow()
            } label: {
                Label("Add row", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Dataset name", text: $dataset.name)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .onChange(of: dataset.name) { _, _ in
                        try? modelContext.save()
                    }
                Spacer()
                Text(dataset.schema.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
            HStack(spacing: 16) {
                Label("\(dataset.trainRows) train", systemImage: "books.vertical")
                Label("\(dataset.validRows) val",   systemImage: "checkmark.seal")
                Label("\(dataset.testRows) test",   systemImage: "questionmark.circle")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var splitPicker: some View {
        Picker("Split", selection: $split) {
            ForEach(DatasetSplit.allCases) { s in
                Text("\(s.displayName) (\(rowCount(for: s)))").tag(s)
            }
        }
        .pickerStyle(.segmented)
    }

    private func rowCount(for s: DatasetSplit) -> Int {
        switch s {
        case .train: return s == split ? rows.count : dataset.trainRows
        case .valid: return s == split ? rows.count : dataset.validRows
        case .test:  return s == split ? rows.count : dataset.testRows
        }
    }

    @ViewBuilder
    private var rowList: some View {
        if loading {
            VStack { ProgressView("Reading lessons…") }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding()
        } else if rows.isEmpty {
            ContentUnavailableView {
                Label("This split is empty", systemImage: "tray")
            } description: {
                Text("Add a row to start building this dataset.")
            } actions: {
                Button("Add a row") { startNewRow() }.controlSize(.large)
            }
        } else {
            List {
                ForEach(rows.indices, id: \.self) { idx in
                    rowCell(idx: idx)
                        .swipeActions {
                            Button(role: .destructive) {
                                deleteRow(at: idx)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button("Edit…") { editRow(at: idx) }
                            Button("Duplicate") { duplicateRow(at: idx) }
                            Divider()
                            Button(role: .destructive) {
                                deleteRow(at: idx)
                            } label: { Text("Delete") }
                        }
                }
            }
            .listStyle(.inset)
        }
    }

    private func rowCell(idx: Int) -> some View {
        let row = rows[idx]
        return Button {
            editRow(at: idx)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("\(idx + 1)")
                    .font(.caption.monospacedDigit())
                    .frame(width: 32, alignment: .trailing)
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.summary.isEmpty ? "(empty)" : row.summary)
                        .font(.callout)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        ForEach(row.messages) { m in
                            Text(m.role.displayName)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(roleColor(m.role).opacity(0.18), in: Capsule())
                                .foregroundStyle(roleColor(m.role))
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func roleColor(_ role: ChatMessageRow.Role) -> Color {
        switch role {
        case .system:    .gray
        case .user:      .blue
        case .assistant: .purple
        }
    }

    // MARK: - Actions

    private func loadCurrent() async {
        loading = true
        loadError = nil
        do {
            let loaded = try DatasetEditorService.load(directory: dataset.directoryURL, split: split)
            self.rows = loaded
            self.dirty = false
        } catch {
            self.loadError = error.localizedDescription
        }
        self.loading = false
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try DatasetEditorService.save(rows: rows, to: dataset.directoryURL, split: split)
            updateRowCount(for: split, count: rows.count)
            dirty = false
            try? modelContext.save()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func startNewRow() {
        let blank = ChatRow(messages: [
            ChatMessageRow(role: .user, content: ""),
            ChatMessageRow(role: .assistant, content: ""),
        ])
        isNewRow = true
        editingRow = blank
    }

    private func editRow(at idx: Int) {
        isNewRow = false
        editingRow = rows[idx]
    }

    private func applyRowEdit(_ original: ChatRow, updated: ChatRow?) {
        defer { editingRow = nil }
        guard let updated else { return }
        // Filter out empty messages so the user can save partial work
        let trimmed = ChatRow(
            id: updated.id,
            messages: updated.messages.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
        guard !trimmed.messages.isEmpty else { return }
        if isNewRow {
            rows.append(trimmed)
        } else if let idx = rows.firstIndex(where: { $0.id == original.id }) {
            rows[idx] = trimmed
        }
        dirty = true
        Task { await save() }
    }

    private func deleteRow(at idx: Int) {
        guard rows.indices.contains(idx) else { return }
        rows.remove(at: idx)
        dirty = true
        Task { await save() }
    }

    private func duplicateRow(at idx: Int) {
        guard rows.indices.contains(idx) else { return }
        var copy = rows[idx]
        copy.id = UUID()
        rows.insert(copy, at: idx + 1)
        dirty = true
        Task { await save() }
    }

    private func updateRowCount(for s: DatasetSplit, count: Int) {
        switch s {
        case .train: dataset.trainRows = count
        case .valid: dataset.validRows = count
        case .test:  dataset.testRows  = count
        }
    }

    private func deleteDataset() {
        try? FileManager.default.removeItem(at: dataset.directoryURL)
        modelContext.delete(dataset)
        try? modelContext.save()
        dismiss()
    }
}
