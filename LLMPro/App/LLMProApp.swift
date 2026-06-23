import SwiftUI
import SwiftData

@main
struct LLMProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var pythonRuntime = PythonRuntime.shared
    @State private var jobRegistry = JobRegistry.shared

    init() {
        // Runs before any view (so before @AppStorage reads `firstRunComplete`):
        // carry the pre-rebrand UserDefaults across the bundle-id change so a
        // renamed install doesn't re-show First Run or re-seed example skills.
        LegacyMigration.migrateUserDefaultsIfNeeded()
    }

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
        .modelContainer(for: [TrainingJob.self, LocalModel.self, DatasetRecord.self, AppSettings.self, SelfImproveRun.self, AgentProfile.self, EvalRun.self])

        Settings {
            SettingsView()
                .environment(pythonRuntime)
        }

        // Live training/practice status in the menu bar — only inserted while a
        // job is running (the `.constant` re-evaluates as `jobRegistry` changes).
        MenuBarExtra(isInserted: .constant(!jobRegistry.runningJobs.isEmpty)) {
            JobStatusMenuBarContent(jobRegistry: jobRegistry)
        } label: {
            Image(systemName: "graduationcap.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
