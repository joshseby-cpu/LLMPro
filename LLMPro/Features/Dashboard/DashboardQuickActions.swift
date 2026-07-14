import SwiftUI

/// One-tap launcher tiles for the loop's stages plus a rotating "tip of the day".
/// Tiles are prerequisite-aware: an action whose ingredient is missing (e.g.
/// Teach with no model) renders dimmed with a hint instead of a dead end. Tips
/// are curated product guidance — plain Swift constants, stable per day, with a
/// "next tip" button.
struct DashboardQuickActions: View {
    let hasModel: Bool
    let hasDataset: Bool

    @AppStorage("dashboard.tipOffset") private var tipOffset: Int = 0

    private struct Action: Identifiable {
        let id: String
        let emoji: String
        let title: String
        let target: SidebarSection
        let enabled: Bool
        let hint: String
    }

    private var actions: [Action] {
        [
            Action(id: "teach", emoji: "🎓", title: "Teach", target: .training,
                   enabled: hasModel && hasDataset,
                   hint: hasModel ? "Add a lesson first" : "Download a model first"),
            Action(id: "chat", emoji: "💬", title: "Try it out", target: .chat,
                   enabled: hasModel, hint: "Download a model first"),
            Action(id: "score", emoji: "📊", title: "Score a model", target: .chat,
                   enabled: hasModel, hint: "Download a model first"),
            Action(id: "practice", emoji: "🔄", title: "Practice", target: .selfImprove,
                   enabled: hasModel, hint: "Download a model first"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    ForEach(actions) { action in tile(action) }
                }
            }
            tipCard
        }
    }

    private func tile(_ action: Action) -> some View {
        Button {
            NotificationCenter.default.post(name: .switchSidebar, object: action.target)
        } label: {
            VStack(spacing: 6) {
                Text(action.emoji).font(.title)
                Text(action.title).font(.callout.weight(.medium))
                if !action.enabled {
                    Text(action.hint).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(padding: 4, cornerRadius: 12)
        .opacity(action.enabled ? 1 : 0.55)
        .disabled(!action.enabled)
        .help(action.enabled ? "Open \(action.title)" : action.hint)
    }

    // MARK: - Tip of the day

    private static let tips: [String] = [
        "The star rating in Progress shows how fast your model is learning — 5 stars means the loss dropped a lot.",
        "Quick / Standard / Thorough in Teach control how long training runs. Start Quick; you can always teach again.",
        "\"Score it\" in Try it out gives your model a report card — a comparable number you can track across fine-tunes.",
        "Practice runs the whole teach-test loop automatically, keeping only the answers that pass real unit tests.",
        "Right-click a model in Models for extras: duplicate, send to LM Studio, export to GGUF, or make it text-only.",
        "The 👍 buttons in Try it out collect preference pairs — enough of them unlocks \"Teach by preference\" (DPO).",
        "Pin your favorite models and lessons with the star — they float to the top of their lists.",
        "Long exports and training runs post a notification when they finish — feel free to switch apps.",
        "Check a lesson before teaching: the Check button finds empty rows, duplicates, and missing replies.",
        "Q4_K_M is the sweet-spot GGUF format for Ollama and LM Studio — small, fast, and near-lossless.",
        "Storage (in Settings) shows what's using disk and can safely clear regenerable caches.",
        "Compare past runs in Progress → Past lessons to see which recipe actually learned best.",
        "A fine-tune only changes a small adapter — your base model stays untouched until you fuse or export.",
        "The system-prompt Persona menu in Try it out switches your model's personality in one click.",
        "Training survives closing the window — LLMPro keeps going in the background and shows progress in the menu bar.",
    ]

    private var tipCard: some View {
        let index = (dayOfYear + tipOffset) % Self.tips.count
        return HStack(alignment: .top, spacing: 10) {
            Text("💡").font(.title3)
            Text(Self.tips[index]).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                tipOffset += 1
            } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Next tip")
        }
        .card(padding: 12, cornerRadius: 12)
    }

    private var dayOfYear: Int {
        Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
    }
}
