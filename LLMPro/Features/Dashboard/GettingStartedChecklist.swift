import SwiftUI

/// The Home "getting started" card, generalized from a single next-step to the
/// whole journey: the four loop stages shown at once with live done/todo states,
/// so a new user sees the full map and a returning user sees progress at a
/// glance. Completion is derived from real data (models / lessons / finished
/// jobs) plus one tiny flag the chat tab sets the first time a prompt is sent.
/// When everything is done the card collapses to a slim celebration banner the
/// user can dismiss for good.
struct GettingStartedChecklist: View {
    let hasModel: Bool
    let hasDataset: Bool
    let hasFinishedJob: Bool

    /// Set by ArenaView the first time the user sends a chat prompt.
    @AppStorage("onboarding.triedChat") private var triedChat: Bool = false
    @AppStorage("onboarding.checklistDismissed") private var dismissed: Bool = false

    private struct Step: Identifiable {
        let id: Int
        let title: String
        let detail: String
        let icon: String
        let done: Bool
        let target: SidebarSection
        let actionLabel: String
    }

    private var steps: [Step] {
        [
            Step(id: 1, title: "Get a model",
                 detail: "Download a blank textbook — Llama 3.2 3B is a great first pick.",
                 icon: "cube.box", done: hasModel, target: .models, actionLabel: "Open Models"),
            Step(id: 2, title: "Get a lesson",
                 detail: "Prepare a starter pack of coding examples, or import your own.",
                 icon: "books.vertical", done: hasDataset, target: .datasets, actionLabel: "Open Lessons"),
            Step(id: 3, title: "Teach it",
                 detail: "One tap — LLMPro picks all the settings for you.",
                 icon: "graduationcap", done: hasFinishedJob, target: .training, actionLabel: "Open Teach"),
            Step(id: 4, title: "Try it out",
                 detail: "Chat with what you trained and see the difference.",
                 icon: "bubble.left.and.bubble.right", done: triedChat, target: .chat, actionLabel: "Open Try it out"),
        ]
    }

    private var allDone: Bool { steps.allSatisfy(\.done) }
    private var current: Step? { steps.first(where: { !$0.done }) }

    var body: some View {
        if allDone {
            if !dismissed { celebration }
        } else {
            checklist
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Your first coding helper", systemImage: "map")
            ForEach(steps) { step in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: step.done ? "checkmark.circle.fill" : "\(step.id).circle")
                        .font(.title2)
                        .foregroundStyle(step.done ? Color.brand : Color.secondary)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.headline)
                            .foregroundStyle(step.done ? .secondary : .primary)
                            .strikethrough(step.done, color: .secondary)
                        if !step.done {
                            Text(step.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !step.done && step.id == current?.id {
                        Button(step.actionLabel) {
                            NotificationCenter.default.post(name: .switchSidebar, object: step.target)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.brand)
                    }
                }
            }
        }
        .card(padding: 20, cornerRadius: 16)
    }

    private var celebration: some View {
        HStack(spacing: 12) {
            Text("🎉").font(.title2)
            Text("You've completed the loop — teach, test, and improve as often as you like.")
                .font(.callout)
            Spacer()
            Button {
                dismissed = true
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide this")
        }
        .card(padding: 14, cornerRadius: 12)
    }
}
