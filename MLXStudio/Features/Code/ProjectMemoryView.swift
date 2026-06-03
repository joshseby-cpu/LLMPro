import SwiftUI
import AppKit

/// Viewer/editor for the evolving agent's per-project memory — the Markdown file
/// of durable lessons the Code-tab team has learned about THIS project. It is the
/// in-context, no-fine-tuning complement to the Practice loop. (Distinct from the
/// "Memory" sidebar tab, which is about GPU/RAM usage.)
///
/// The agent reads these lessons into its prompt before each task and appends new
/// ones after each task (reflection) or via the `remember` tool. Here the user can
/// read them, hand-edit the Markdown, or clear them.
struct ProjectMemoryView: View {
    let workspace: URL
    @State private var mem = AgentMemoryService.shared
    @State private var draft: String = ""
    @State private var dirty = false
    @State private var savedFlash = false
    @Environment(\.dismiss) private var dismiss

    private var lessons: [String] { AgentMemoryService.parse(draft) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState
            } else {
                editor
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 540)
        .onAppear { reload() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Project memory").font(.headline)
                Text(workspace.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(lessons.count) lesson\(lessons.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            Button("Done") { if dirty { save() }; dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "brain").font(.largeTitle).foregroundStyle(.secondary)
            Text("Nothing learned yet").font(.title3).bold()
            Text("As the team finishes tasks in this project, it saves durable lessons here — build/test commands, conventions, gotchas — and reuses them on the next task. You can also add lessons by hand.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Add a lesson by hand") {
                draft = "# Project memory — \(workspace.lastPathComponent)\n\n- "
                dirty = true
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("One lesson per line, starting with “- ”. The agent reads these before each task.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 8)
            TextEditor(text: Binding(
                get: { draft },
                set: { draft = $0; dirty = true; savedFlash = false }
            ))
            .font(.system(.callout, design: .monospaced))
            .padding(6)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if savedFlash { Label("Saved", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green) }
            else if dirty { Text("• unsaved").font(.caption2).foregroundStyle(.orange) }
            Spacer()
            Button { revealInFinder() } label: { Image(systemName: "folder") }
                .help("Show the memory file in Finder")
            Button("Clear all", role: .destructive) { clearAll() }
                .disabled(lessons.isEmpty)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(!dirty)
        }
        .padding(10)
    }

    // MARK: Actions

    private func reload() {
        draft = mem.rawMarkdown(for: workspace)
        dirty = false
        savedFlash = false
    }

    private func save() {
        mem.saveRaw(draft, for: workspace)
        dirty = false
        savedFlash = true
    }

    private func clearAll() {
        mem.clear(for: workspace)
        draft = ""
        dirty = false
        savedFlash = true
    }

    private func revealInFinder() {
        if dirty { save() }
        let url = mem.fileURL(for: workspace)
        if !FileManager.default.fileExists(atPath: url.path) {
            mem.saveRaw(draft, for: workspace)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
