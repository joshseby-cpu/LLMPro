import SwiftUI
import AppKit

/// Editor for Agent Skills — full CRUD, raw Markdown (parity with the team-agents
/// editor). Each skill is a folder under `skills/<id>/` with a `SKILL.md`
/// (frontmatter `name` / `description` / optional `skills:` links + a markdown
/// instructions body). The user creates, edits, duplicates, and deletes skills
/// here. Skills link to OTHER skills via `skills:` in their frontmatter; AGENTS
/// link to skills via the agent's own `skills:` frontmatter (edited in the team-
/// agents manager). Saving reloads `SkillStore`, so the next run uses the edits.
struct SkillsManagerView: View {
    @State private var store = SkillStore.shared
    @State private var agents = AgentStore.shared
    @State private var selectedID: String = ""
    @State private var draft: String = ""
    @State private var dirty = false
    @State private var savedFlash = false

    @State private var confirmDelete = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.skills.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        skillList
                        Divider()
                        listToolbar
                    }
                    .frame(width: 220)
                    Divider()
                    editor
                }
            }
        }
        .frame(width: 820, height: 580)
        .onAppear {
            store.scan()
            if selectedID.isEmpty { selectedID = store.skills.first?.id ?? "" }
            loadDraft(selectedID)
        }
        .alert("Delete “\(selectedID)”?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteSkill() }
        } message: {
            Text("This removes the skill and unlinks it from any other skill. This can't be undone.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Skills").font(.headline)
                Text("Reusable SKILL.md instruction packs. Create, edit, link, and delete them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { if dirty { save() }; dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "wand.and.stars").font(.largeTitle).foregroundStyle(.secondary)
            Text("No skills yet").font(.title3).bold()
            Text("A skill is a reusable SKILL.md instruction pack. Agents see its name + description and load the full instructions on demand.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button { createSkill() } label: { Label("Create a skill", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Skill list

    private var skillList: some View {
        List(selection: Binding<String?>(
            get: { selectedID },
            set: { newID in if let newID, newID != selectedID { selectIfSafe(newID) } }
        )) {
            ForEach(store.skills) { skill in
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars").foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(skill.name).fontWeight(selectedID == skill.id ? .semibold : .regular)
                        Text(skill.id).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if !skill.links.isEmpty {
                        Image(systemName: "link").font(.caption2).foregroundStyle(.tertiary)
                            .help("Links to: \(skill.links.joined(separator: ", "))")
                    }
                }
                .tag(skill.id)
            }
        }
        .listStyle(.sidebar)
    }

    private var listToolbar: some View {
        HStack(spacing: 4) {
            Button { createSkill() } label: { Image(systemName: "plus") }
                .help("New skill")
            Button { confirmDelete = true } label: { Image(systemName: "minus") }
                .help("Delete this skill")
                .disabled(selectedID.isEmpty)
            Button { duplicateSkill() } label: { Image(systemName: "plus.square.on.square") }
                .help("Duplicate this skill")
                .disabled(selectedID.isEmpty)
            Spacer()
            Text("\(store.skills.count) skills").font(.caption2).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(selectedID)/SKILL.md")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                if dirty { Text("• unsaved").font(.caption2).foregroundStyle(.orange) }
                if savedFlash { Label("Saved", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green) }
                Spacer()
                Button { revealInFinder() } label: { Image(systemName: "folder") }
                    .help("Show the skill folder in Finder")
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty)
            }
            .padding(10)
            Divider()
            // Raw-Markdown editor with automatic substitution OFF, so typed `---`
            // frontmatter fences and code in the body aren't mangled into em-dashes
            // / smart quotes.
            MarkdownEditor(text: Binding(
                get: { draft },
                set: { draft = $0; dirty = true; savedFlash = false }
            ))
            .padding(6)
            Divider()
            referenceFooter
        }
    }

    /// Show what can be linked: other skill ids (for this file's `skills:`) and the
    /// agent ids that may reference this skill (edited on the agent side).
    private var referenceFooter: some View {
        let otherSkills = store.skills.map(\.id).filter { $0 != selectedID }
        let agentIDs = agents.definitions.map(\.id)
        return VStack(alignment: .leading, spacing: 3) {
            Text("Link other skills: add `skills: [id, …]` to this file's frontmatter — when this skill loads, the linked ones are offered too.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Other skills: \(otherSkills.isEmpty ? "(none yet)" : otherSkills.joined(separator: ", "))")
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
            Text("Link to an agent: add `skills: [\(selectedID)]` to that agent in “Edit team agents”. Agents: \(agentIDs.joined(separator: ", "))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    // MARK: Actions

    private func selectIfSafe(_ id: String) {
        if dirty { save() }
        selectedID = id
        loadDraft(id)
    }

    private func loadDraft(_ id: String) {
        draft = id.isEmpty ? "" : store.markdown(for: id)
        dirty = false
        savedFlash = false
    }

    private func save() {
        guard !selectedID.isEmpty else { return }
        store.save(id: selectedID, markdown: draft)
        dirty = false
        savedFlash = true
    }

    private func createSkill() {
        if dirty { save() }
        // Create immediately with a placeholder; the user renames it by editing the
        // `name:` line in the raw markdown (the folder id stays stable). No name
        // dialog — skills are just markdown files, and an alert presented from a
        // sheet-inside-a-popover is unreliable on macOS.
        let skill = store.create(name: "new skill",
                                 description: "Describe when an agent should use this skill.",
                                 instructions: Self.template)
        selectedID = skill.id
        loadDraft(skill.id)
    }

    private func duplicateSkill() {
        if dirty { save() }
        guard let dup = store.duplicate(id: selectedID) else { return }
        selectedID = dup.id
        loadDraft(dup.id)
    }

    private func deleteSkill() {
        // Defer the store mutation one runloop tick so the confirmation .alert
        // fully completes its modal teardown FIRST. Mutating the @Observable store
        // synchronously here bumps its revision and recomputes `body` while the
        // alert is still dismissing — the use-after-free seen as
        // AppKitDialogBridge.updateExistingAlert → NSWindowEndWindowModalSession →
        // _doAnimation → nil PC. Letting the alert close before we re-render avoids it.
        let id = selectedID
        DispatchQueue.main.async {
            store.delete(id: id)
            selectedID = store.skills.first?.id ?? ""
            loadDraft(selectedID)
        }
    }

    private func revealInFinder() {
        if dirty { save() }
        let url = store.fileURL(for: selectedID)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? draft.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static let template = """
    ## When to use
    Describe the situations where this skill applies.

    ## Steps
    1. …
    2. …

    ## Notes
    Anything the agent should keep in mind.
    """
}

#if DEBUG
#Preview("Skills") {
    SkillsManagerView().previewEnvironment()
}
#endif
