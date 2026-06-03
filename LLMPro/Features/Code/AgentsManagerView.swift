import SwiftUI
import AppKit

/// Editor for the Code-tab team agents — full CRUD. Each agent is a Markdown file
/// (`agents/<id>.md`) with frontmatter (`id/name/emoji/tint/tools/delegates/
/// maxIterations`) + a system-prompt body. The user can create, edit, duplicate,
/// and delete agents here, and agents reference other agents by id in their
/// `delegates:` list (each becomes a `call_<id>` tool). Saving reloads
/// `AgentStore`, so the next run uses the edits. Built-in agents can be reset to
/// their bundled default but not deleted; the entry agent (Orchestrator) is
/// always present.
struct AgentsManagerView: View {
    @State private var store = AgentStore.shared
    @State private var selectedID: String = AgentStore.entryID
    @State private var draft: String = ""
    @State private var dirty = false
    @State private var savedFlash = false

    @State private var confirmDelete = false

    @Environment(\.dismiss) private var dismiss

    private var isBuiltin: Bool { store.isBuiltin(selectedID) }
    private var isEntry: Bool { selectedID == AgentStore.entryID }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    agentList
                    Divider()
                    listToolbar
                }
                .frame(width: 220)
                Divider()
                editor
            }
        }
        .frame(width: 820, height: 580)
        .onAppear { loadDraft(selectedID) }
        .alert("Delete “\(selectedID)”?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteAgent() }
        } message: {
            Text("This removes the agent and takes it out of every other agent's delegates. This can't be undone.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Team agents").font(.headline)
                Text("Create, edit, and delete agents. Agents call each other by id via their delegates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { if dirty { save() }; dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: Agent list

    private var agentList: some View {
        List(selection: Binding<String?>(
            get: { selectedID },
            set: { newID in if let newID, newID != selectedID { selectIfSafe(newID) } }
        )) {
            ForEach(store.definitions) { def in
                let role = TeamRole(def.id)
                HStack(spacing: 8) {
                    Text(role.emoji)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(role.displayName)
                            .fontWeight(selectedID == def.id ? .semibold : .regular)
                        Text(def.id).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if def.id == AgentStore.entryID {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    } else if !store.isBuiltin(def.id) {
                        Text("custom").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .tag(def.id)
            }
        }
        .listStyle(.sidebar)
    }

    private var listToolbar: some View {
        HStack(spacing: 4) {
            Button { createAgent() } label: { Image(systemName: "plus") }
                .help("New agent")
            Button { confirmDelete = true } label: { Image(systemName: "minus") }
                .help(isBuiltin ? "Built-in agents can't be deleted" : "Delete this agent")
                .disabled(isBuiltin)
            Button { duplicateAgent() } label: { Image(systemName: "plus.square.on.square") }
                .help("Duplicate this agent")
            Spacer()
            Text("\(store.definitions.count) agents").font(.caption2).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(selectedID).md")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                if isEntry { Label("entry", systemImage: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                if dirty { Text("• unsaved").font(.caption2).foregroundStyle(.orange) }
                if savedFlash { Label("Saved", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green) }
                Spacer()
                Button { revealInFinder() } label: { Image(systemName: "folder") }
                    .help("Show the file in Finder")
                if isBuiltin {
                    Button("Reset to default") { resetToDefault() }
                        .help("Replace this agent with the version that ships with the app")
                }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty)
            }
            .padding(10)
            Divider()
            // Raw-Markdown editor with automatic substitution OFF, so typed `---`
            // frontmatter fences and code aren't mangled into em-dashes / smart quotes.
            MarkdownEditor(text: Binding(
                get: { draft },
                set: { draft = $0; dirty = true; savedFlash = false }
            ))
            .padding(6)
            Divider()
            referenceFooter
        }
    }

    /// Help the user wire delegation: show the ids they can put in `delegates:`.
    private var referenceFooter: some View {
        let others = store.definitions.map(\.id).filter { $0 != selectedID }
        return VStack(alignment: .leading, spacing: 3) {
            Text("Delegate to other agents by id — put them in this file's frontmatter, e.g. `delegates: [coder, researcher]`. Each becomes a `call_<id>` tool.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Available agents: \(others.isEmpty ? "(none yet)" : others.joined(separator: ", "))")
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    // MARK: Actions

    private func selectIfSafe(_ id: String) {
        if dirty { save() }     // don't silently lose edits when switching agents
        selectedID = id
        loadDraft(id)
    }

    private func loadDraft(_ id: String) {
        draft = store.markdown(for: id)
        dirty = false
        savedFlash = false
    }

    private func save() {
        store.save(id: selectedID, markdown: draft)
        dirty = false
        savedFlash = true
    }

    private func createAgent() {
        if dirty { save() }
        // Create immediately with a placeholder name; the user renames it by editing
        // the `name:` line in the raw markdown (folder id stays stable). No dialog —
        // an alert from a sheet-inside-a-popover is unreliable on macOS.
        let id = store.create(name: "new agent")
        selectedID = id
        loadDraft(id)
    }

    private func duplicateAgent() {
        if dirty { save() }
        let id = store.duplicate(id: selectedID)
        selectedID = id
        loadDraft(id)
    }

    private func deleteAgent() {
        // Defer the store mutation one runloop tick so the confirmation .alert
        // finishes its modal teardown before the @Observable revision bump
        // recomputes `body` — avoids the updateExistingAlert-during-render
        // use-after-free (see the matching note in SkillsManagerView.deleteSkill).
        let id = selectedID
        DispatchQueue.main.async {
            guard store.delete(id: id) else { return }
            selectedID = AgentStore.entryID
            loadDraft(selectedID)
        }
    }

    private func resetToDefault() {
        store.resetToDefault(id: selectedID)
        draft = store.markdown(for: selectedID)
        dirty = false
        savedFlash = true
    }

    private func revealInFinder() {
        if dirty { save() }
        let url = store.fileURL(for: selectedID)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? draft.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
