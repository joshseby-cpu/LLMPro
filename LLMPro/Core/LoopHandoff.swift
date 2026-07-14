import Foundation

// The feedback loop's hand-off payload: a base model plus, after fine-tuning, its
// LoRA adapter. Stages pass it forward to pre-fill the next tab (Progress→Try-it-out,
// Progress→Code, Practice→Try-it-out) instead of making the user copy disk paths by
// hand. Carried as the `object` of the cross-tab navigation notifications below.
//
// Receivers accept EITHER a `ModelHandoff` (model + adapter) or a bare `String`
// (model only) so older posters that send just a repo ID keep working.
struct ModelHandoff: Sendable {
    let model: String          // base model repo ID or local name
    let adapterPath: String?   // absolute path to the LoRA adapter directory, if any
    /// When true, the receiving tab should kick off a scored evaluation of this
    /// model+adapter automatically (e.g. Progress→Test "and score it"). Additive
    /// with a default of false so every existing poster is unaffected; the SwiftUI
    /// layer sets/consumes it.
    let autoScore: Bool

    init(model: String, adapterPath: String? = nil, autoScore: Bool = false) {
        self.model = model
        self.adapterPath = adapterPath
        self.autoScore = autoScore
    }
}

// The preference-loop hand-off payload: like `ModelHandoff`, but also carries the
// `DatasetRecord.id` of the preference set the user just built in the Arena. Posted
// by "Try it out" when the user has rated enough answers and taps "Teach by
// preference"; consumed by Teach to pre-fill the model + the preferences lesson and
// flip into DPO mode. Carried as the `object` of `.openTrainingWithPreferences`.
struct PreferenceHandoff: Sendable {
    let model: String          // base model repo ID or local name the answers came from
    let adapterPath: String?   // absolute path to the LoRA adapter directory, if any
    let datasetID: UUID        // the `.preference` DatasetRecord to train on
}

// A pending Teach pre-fill that RootView holds on behalf of `TrainingConfigView`.
//
// Why this exists: the cross-tab hand-off notifications carry their payload as the
// notification `object`, and `TrainingConfigView` used to read it via `.onReceive`.
// But the detail pane lazily instantiates `TrainingConfigView` only when the Teach
// tab is selected — so on a first-ever visit (e.g. coming straight from "Try it
// out"), the view doesn't exist yet when the notification fires and `.onReceive`
// never sees it (NotificationCenter has no replay). RootView is always alive, so it
// catches the notification, stashes the request here, and hands it down as a
// `Binding`; the view consumes it on appear (first-mount case) or on change
// (already-mounted case), then nils it out so it can't re-apply.
//
// `token` makes every request distinct even when two identical hand-offs are posted
// back-to-back, so the consumer's `.onChange` still fires the second time. Equatable
// is derived from `token` alone (the payload enum's associated values aren't
// Equatable, and don't need to be — identity is what drives delivery).
struct PendingTrainingHandoff: Equatable, Identifiable {
    enum Payload {
        /// Pre-select a model only (from `.openTrainingWithModel`). String is the repo ID.
        case model(String)
        /// Pre-select model + preference lesson and flip to DPO (from `.openTrainingWithPreferences`).
        case preference(PreferenceHandoff)
    }

    let id = UUID()
    let payload: Payload

    var token: UUID { id }

    static func == (lhs: PendingTrainingHandoff, rhs: PendingTrainingHandoff) -> Bool {
        lhs.id == rhs.id
    }
}

// A pending Try-it-out / Code pre-fill that RootView holds on behalf of
// `ArenaView` / `CodeView` — the same first-mount race `PendingTrainingHandoff`
// fixes for Teach: the detail pane lazily instantiates the destination view, so
// a `.openChatWithModel` / `.openCodeWithModel` posted from another tab was
// delivered before the receiving view existed and its payload (model + adapter +
// autoScore) was silently dropped — "Grade it" / "Try it out" / "Use in Code"
// only switched tabs. RootView stashes the payload here and hands it down as a
// Binding; the view consumes on appear or on change, then nils it. Equality is
// token-identity so back-to-back identical hand-offs still fire `.onChange`.
struct PendingModelHandoff: Equatable, Identifiable {
    let id = UUID()
    let payload: ModelHandoff

    static func == (lhs: PendingModelHandoff, rhs: PendingModelHandoff) -> Bool {
        lhs.id == rhs.id
    }
}

extension Notification.Name {
    /// Open the Code tab and load this model (+ adapter) into the Orchestrator team.
    /// Object: a `ModelHandoff` (or `String` model id).
    static let openCodeWithModel = Notification.Name("LLMPro.openCodeWithModel")

    /// Open the Teach tab pre-filled for a preference (DPO) run. Object: a
    /// `PreferenceHandoff` (model + optional adapter + the preference dataset's id).
    /// RootView selects the tab; TrainingConfigView reads the payload to pre-fill.
    static let openTrainingWithPreferences = Notification.Name("LLMPro.openTrainingWithPreferences")
}
