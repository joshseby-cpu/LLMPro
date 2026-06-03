import SwiftUI
import SwiftData

@main
struct MLXStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var pythonRuntime = PythonRuntime.shared
    @State private var jobRegistry = JobRegistry.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(pythonRuntime)
                .environment(jobRegistry)
                .frame(minWidth: 1100, minHeight: 700)
                .task {
                    AgentStore.shared.installAndLoad()   // seed + parse the markdown team agents
                    SkillStore.shared.installDefaultsAndScan()   // seed + scan Agent Skills (SKILL.md packages)
                    await pythonRuntime.bootstrapIfNeeded()
                    await jobRegistry.recoverOrphans()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .modelContainer(for: [TrainingJob.self, LocalModel.self, DatasetRecord.self, AppSettings.self, SelfImproveRun.self, AgentProfile.self])

        Settings {
            SettingsView()
                .environment(pythonRuntime)
        }
    }
}
