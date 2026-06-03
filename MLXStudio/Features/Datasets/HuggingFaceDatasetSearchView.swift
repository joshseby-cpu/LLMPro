import SwiftUI

/// Modal sheet for finding any dataset on HuggingFace, previewing the first rows,
/// optionally remapping column names, and downloading + normalizing into the
/// app's standard chat JSONL format.
struct HuggingFaceDatasetSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prep = DatasetPrepService.shared

    @State private var query: String = "coding instructions"
    @State private var searching: Bool = false
    @State private var searchError: String?
    @State private var results: [HFDataset] = []
    @State private var selected: HFDataset?

    @State private var detail: HFDatasetDetail?
    @State private var rows: HFDatasetRows?
    @State private var loadingDetail: Bool = false
    @State private var detailError: String?

    // Mapping & options
    @State private var schemaChoice: SchemaChoice = .auto
    @State private var maxRows: Int = 20_000
    @State private var split: String = "train"

    // Column overrides (used when schemaChoice != .auto)
    @State private var fieldMessages: String = "messages"
    @State private var fieldInstruction: String = "instruction"
    @State private var fieldInput: String = "input"
    @State private var fieldOutput: String = "output"
    @State private var fieldPrompt: String = "prompt"
    @State private var fieldCompletion: String = "completion"
    @State private var fieldQuestion: String = "question"
    @State private var fieldAnswer: String = "answer"
    @State private var fieldText: String = "text"

    enum SchemaChoice: String, CaseIterable, Identifiable {
        case auto, messages, sharegpt, instruction_output, prompt_completion, question_answer, text
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .auto:               "Auto-detect"
            case .messages:           "Chat messages"
            case .sharegpt:           "ShareGPT conversations"
            case .instruction_output: "Instruction → output"
            case .prompt_completion:  "Prompt → completion"
            case .question_answer:    "Question → answer"
            case .text:               "Raw text"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            HSplitView {
                resultsList
                    .frame(minWidth: 280, idealWidth: 320)
                detailPane
                    .frame(minWidth: 380)
            }
            Divider()
            footer
        }
        .frame(minWidth: 880, minHeight: 600)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search HuggingFace datasets (e.g. \"code instructions\", \"alpaca\", \"math\")",
                      text: $query, onCommit: search)
                .textFieldStyle(.plain)
                .onSubmit { search() }
            Button(action: search) {
                if searching { ProgressView().controlSize(.small) }
                else { Text("Search") }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            Button {
                dismiss()
            } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    @ViewBuilder
    private var resultsList: some View {
        List(selection: $selected) {
            if let err = searchError {
                Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            ForEach(results) { ds in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(ds.shortName).font(.headline).lineLimit(1)
                        Spacer()
                        if let d = ds.downloads {
                            Text(d.formatted(.number.notation(.compactName))).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(ds.repoID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let tags = ds.tags, !tags.isEmpty {
                        Text(tags.prefix(4).joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                .tag(ds)
            }
            if !searching && results.isEmpty && searchError == nil {
                Text("Search to see datasets. Try \"alpaca\", \"code\", \"sharegpt\".")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let ds = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader(ds: ds)
                    if loadingDetail { ProgressView("Loading preview…") }
                    if let err = detailError {
                        Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                    }
                    if let rows { previewRows(rows) }
                    optionsForm
                }
                .padding(16)
            }
            .task(id: ds.id) { await loadDetail(ds: ds) }
        } else {
            ContentUnavailableView(
                "Pick a dataset",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Select a result on the left to preview its rows and pick how to read them.")
            )
        }
    }

    private func detailHeader(ds: HFDataset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ds.repoID).font(.title3.bold()).textSelection(.enabled)
            HStack(spacing: 12) {
                if let d = ds.downloads { Label("\(d.formatted())", systemImage: "arrow.down.circle") }
                if let l = ds.likes { Label("\(l)", systemImage: "heart") }
                if let lic = detail?.cardData?.license { Label(lic, systemImage: "doc.badge.gearshape") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func previewRows(_ rows: HFDatasetRows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("First rows").font(.headline)
            if let features = rows.features, !features.isEmpty {
                Text("Columns: " + features.map(\.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array((rows.rows ?? []).prefix(3).enumerated()), id: \.offset) { i, row in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Row \(i + 1)").font(.caption2).foregroundStyle(.tertiary)
                    let columns = row.row.dict.sorted(by: { $0.key < $1.key })
                    ForEach(columns, id: \.key) { key, value in
                        HStack(alignment: .top, spacing: 6) {
                            Text(key).font(.caption2.monospaced()).foregroundStyle(.secondary).frame(minWidth: 80, alignment: .leading)
                            Text(truncated(value.stringDescription))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func truncated(_ s: String, _ max: Int = 240) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }

    @ViewBuilder
    private var optionsForm: some View {
        Form {
            Section("How to read this dataset") {
                Picker("Shape", selection: $schemaChoice) {
                    ForEach(SchemaChoice.allCases) { Text($0.displayName).tag($0) }
                }
                if schemaChoice != .auto {
                    columnMappingFields(for: schemaChoice)
                }
            }
            Section("Options") {
                Stepper("Max rows: \(maxRows.formatted())", value: $maxRows, in: 100...500_000, step: 1_000)
                TextField("Split (usually \"train\")", text: $split)
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 280)
    }

    @ViewBuilder
    private func columnMappingFields(for choice: SchemaChoice) -> some View {
        switch choice {
        case .messages, .sharegpt:
            TextField("Messages column", text: $fieldMessages)
        case .instruction_output:
            TextField("Instruction column", text: $fieldInstruction)
            TextField("Input column (optional)", text: $fieldInput)
            TextField("Output column", text: $fieldOutput)
        case .prompt_completion:
            TextField("Prompt column", text: $fieldPrompt)
            TextField("Completion column", text: $fieldCompletion)
        case .question_answer:
            TextField("Question column", text: $fieldQuestion)
            TextField("Answer column", text: $fieldAnswer)
        case .text:
            TextField("Text column", text: $fieldText)
        case .auto:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack {
            if let active = prep.active.last {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(active.stage) — \(active.message)")
                        .font(.caption)
                        .lineLimit(1)
                }
            } else {
                Spacer()
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                kickoff()
            } label: {
                Label("Download & Prepare", systemImage: "arrow.down.circle.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selected == nil)
        }
        .padding(14)
    }

    // MARK: - Actions

    private func search() {
        guard !searching else { return }
        searching = true
        searchError = nil
        Task {
            do {
                let hits = try await HuggingFaceClient.shared.searchDatasets(query: query)
                self.results = hits
            } catch {
                self.searchError = error.localizedDescription
            }
            self.searching = false
        }
    }

    private func loadDetail(ds: HFDataset) async {
        loadingDetail = true
        detailError = nil
        detail = nil
        rows = nil
        async let d: HFDatasetDetail? = (try? await HuggingFaceClient.shared.datasetDetail(repoID: ds.repoID))
        async let r: HFDatasetRows? = (try? await HuggingFaceClient.shared.datasetFirstRows(repoID: ds.repoID, split: split))
        let (gotDetail, gotRows) = await (d, r)
        await MainActor.run {
            self.detail = gotDetail
            self.rows = gotRows
            if gotRows == nil {
                self.detailError = "Couldn't fetch rows (dataset may be gated or use a non-default config). You can still try to download — pass an explicit schema below."
            }
            self.loadingDetail = false
        }
    }

    private func kickoff() {
        guard let ds = selected else { return }
        var fields: [String: String] = [:]
        switch schemaChoice {
        case .auto: break
        case .messages, .sharegpt:
            fields["messages"] = fieldMessages
        case .instruction_output:
            fields["instruction"] = fieldInstruction
            if !fieldInput.isEmpty { fields["input"] = fieldInput }
            fields["output"] = fieldOutput
        case .prompt_completion:
            fields["prompt"] = fieldPrompt
            fields["completion"] = fieldCompletion
        case .question_answer:
            fields["question"] = fieldQuestion
            fields["answer"] = fieldAnswer
        case .text:
            fields["text"] = fieldText
        }
        let request = DatasetPrepService.ArbitraryHFRequest(
            repoID: ds.repoID,
            displayName: ds.shortName,
            maxRows: maxRows,
            schema: schemaChoice.rawValue,
            fields: fields,
            config: nil,
            split: split
        )
        DatasetPrepService.shared.prepareArbitrary(request: request) { _ in
            // The Lessons tab listens to prep.history changes and inserts into SwiftData.
            // Dismiss the sheet once prep completes so the user sees the new dataset row.
            Task { @MainActor in dismiss() }
        }
    }
}
