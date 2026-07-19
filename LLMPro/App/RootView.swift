import SwiftUI
import SwiftData

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, models, datasets, training, monitor, chatDirect, story, chat, code, imagine, selfImprove, fusion, memory, inspect, export, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard:   "Home"
        case .models:      "Models"
        case .datasets:    "Lessons"
        case .training:    "Teach"
        case .monitor:     "Progress"
        case .chatDirect:  "Chat"
        case .story:       "Story"
        case .chat:        "Try it out"
        case .code:        "Code"
        case .imagine:     "Imagine"
        case .selfImprove: "Practice"
        case .fusion:      "Fusion"
        case .memory:      "Memory"
        case .inspect:     "Inspect"
        case .export:      "Save & Use"
        case .settings:    "Settings"
        }
    }
    var icon: String {
        switch self {
        case .dashboard:   "house"
        case .models:      "cube.box"
        case .datasets:    "books.vertical"
        case .training:    "graduationcap"
        case .monitor:     "chart.line.uptrend.xyaxis"
        case .chatDirect:  "message"
        case .story:       "book.closed"
        case .chat:        "bubble.left.and.bubble.right"
        case .code:        "chevron.left.forwardslash.chevron.right"
        case .imagine:     "photo.artframe"
        case .selfImprove: "arrow.triangle.2.circlepath"
        case .fusion:      "arrow.triangle.merge"
        case .memory:      "memorychip"
        case .inspect:     "scope"
        case .export:      "square.and.arrow.up"
        case .settings:    "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(PythonRuntime.self) private var runtime
    @State private var selection: SidebarSection = .dashboard
    @AppStorage("firstRunComplete") private var firstRunComplete: Bool = false

    // A Teach pre-fill captured here (RootView is always alive) so it survives the
    // detail pane not having instantiated `TrainingConfigView` yet — the first-ever-
    // visit race that dropped `.openTrainingWithPreferences` / `.openTrainingWithModel`
    // when the user arrived straight from another tab. Set on notification receipt
    // alongside `selection = .training`; consumed and cleared by `TrainingConfigView`.
    @State private var pendingTrainingHandoff: PendingTrainingHandoff?
    // Same first-mount race, for the other two hand-off destinations: the payload
    // of .openChatWithModel / .openCodeWithModel is stashed here (RootView is
    // always alive) and consumed by ArenaView / CodeView once mounted.
    @State private var pendingChatHandoff: PendingModelHandoff?
    @State private var pendingCodeHandoff: PendingModelHandoff?
    @State private var showCommandPalette = false

    var body: some View {
        Group {
            if !firstRunComplete {
                FirstRunView(onComplete: { firstRunComplete = true })
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail
                }
                .navigationSplitViewStyle(.balanced)
                .task { SystemMetrics.shared.start() }   // one long-lived poller for all tabs
                .sheet(isPresented: $showCommandPalette) { CommandPaletteView() }
                .onReceive(NotificationCenter.default.publisher(for: .openCommandPalette)) { _ in
                    showCommandPalette = true
                }
            }
        }
        // Belt-and-suspenders brand tint so custom views/controls pick up the
        // violet even if the AccentColor asset isn't auto-applied.
        .tint(Color.brand)
    }

    @ViewBuilder
    private var sidebar: some View {
        List(SidebarSection.allCases, selection: $selection) { section in
            Label(section.title, systemImage: section.icon).tag(section)
        }
        .listStyle(.sidebar)
        .navigationTitle("LLMPro")
        .frame(minWidth: 180)
        .safeAreaInset(edge: .bottom) {
            runtimeStatusFooter
        }
        .modifier(SidebarNotificationRouter(
            selection: $selection,
            pendingTrainingHandoff: $pendingTrainingHandoff,
            pendingChatHandoff: $pendingChatHandoff,
            pendingCodeHandoff: $pendingCodeHandoff))
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .dashboard:   DashboardView()
        case .models:      ModelsBrowserView()
        case .datasets:    DatasetsView()
        case .training:    TrainingConfigView(pendingHandoff: $pendingTrainingHandoff)
        case .monitor:     TrainingMonitorView()
        case .chatDirect:  ChatConversationView()
        case .story:       StoryView()
        case .chat:        ArenaView(pendingHandoff: $pendingChatHandoff)
        case .code:        CodeView(pendingHandoff: $pendingCodeHandoff)
        case .imagine:     ImagineView()
        case .selfImprove: SelfImproveView()
        case .fusion:      FusionView()
        case .memory:      MemoryView()
        case .inspect:     ModelInspectorView()
        case .export:      ExportWizardView()
        case .settings:    SettingsView()
        }
    }

    @ViewBuilder
    private var runtimeStatusFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(runtime.statusColor)
                .frame(width: 8, height: 8)
            Text(runtime.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Routes the cross-tab `switch*`/`open*With*` notifications to the sidebar's
/// `selection`. Pulled out of `RootView.sidebar` because a stack of six
/// `.onReceive` modifiers (each with a closure) on one expression is a
/// type-check hot spot the preview compiler is especially sensitive to. Behavior
/// is unchanged — the same notifications drive the same selection.
private struct SidebarNotificationRouter: ViewModifier {
    @Binding var selection: SidebarSection
    // Stash the hand-off payloads here so they survive the destination view not
    // existing yet on a first-ever visit; each view consumes its binding once it
    // mounts (or immediately via .onChange when already mounted).
    @Binding var pendingTrainingHandoff: PendingTrainingHandoff?
    @Binding var pendingChatHandoff: PendingModelHandoff?
    @Binding var pendingCodeHandoff: PendingModelHandoff?

    /// Posters send either a full `ModelHandoff` or a bare `String` model id.
    private func decodeHandoff(_ object: Any?) -> ModelHandoff? {
        if let h = object as? ModelHandoff { return h }
        if let repo = object as? String { return ModelHandoff(model: repo) }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .switchSidebar)) { note in
                if let section = note.object as? SidebarSection { selection = section }
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToMonitor)) { _ in
                selection = .monitor
            }
            .onReceive(NotificationCenter.default.publisher(for: .openTrainingWithModel)) { note in
                if let repo = note.object as? String {
                    pendingTrainingHandoff = PendingTrainingHandoff(payload: .model(repo))
                }
                selection = .training
            }
            .onReceive(NotificationCenter.default.publisher(for: .openTrainingWithPreferences)) { note in
                if let handoff = note.object as? PreferenceHandoff {
                    pendingTrainingHandoff = PendingTrainingHandoff(payload: .preference(handoff))
                }
                selection = .training
            }
            .onReceive(NotificationCenter.default.publisher(for: .openChatWithModel)) { note in
                if let h = decodeHandoff(note.object) {
                    pendingChatHandoff = PendingModelHandoff(payload: h)
                }
                selection = .chat
            }
            .onReceive(NotificationCenter.default.publisher(for: .openCodeWithModel)) { note in
                if let h = decodeHandoff(note.object) {
                    pendingCodeHandoff = PendingModelHandoff(payload: h)
                }
                selection = .code
            }
    }
}

#if DEBUG
#Preview("App") {
    RootView().previewEnvironment()
}
#endif
