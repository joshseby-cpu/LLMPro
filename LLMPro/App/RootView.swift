import SwiftUI
import SwiftData

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, models, datasets, training, monitor, chat, code, selfImprove, fusion, memory, inspect, export, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard:   "Home"
        case .models:      "Models"
        case .datasets:    "Lessons"
        case .training:    "Teach"
        case .monitor:     "Progress"
        case .chat:        "Try it out"
        case .code:        "Code"
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
        case .chat:        "bubble.left.and.bubble.right"
        case .code:        "chevron.left.forwardslash.chevron.right"
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
            }
        }
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
            pendingTrainingHandoff: $pendingTrainingHandoff))
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .dashboard:   DashboardView()
        case .models:      ModelsBrowserView()
        case .datasets:    DatasetsView()
        case .training:    TrainingConfigView(pendingHandoff: $pendingTrainingHandoff)
        case .monitor:     TrainingMonitorView()
        case .chat:        ArenaView()
        case .code:        CodeView()
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
    // Stash the Teach hand-off payload here so it survives `TrainingConfigView` not
    // existing yet on a first-ever visit; the view consumes it once it mounts.
    @Binding var pendingTrainingHandoff: PendingTrainingHandoff?

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
            .onReceive(NotificationCenter.default.publisher(for: .openChatWithModel)) { _ in
                selection = .chat
            }
            .onReceive(NotificationCenter.default.publisher(for: .openCodeWithModel)) { _ in
                selection = .code
            }
    }
}

#if DEBUG
#Preview("App") {
    RootView().previewEnvironment()
}
#endif
