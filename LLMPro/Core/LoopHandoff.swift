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

    init(model: String, adapterPath: String? = nil) {
        self.model = model
        self.adapterPath = adapterPath
    }
}

extension Notification.Name {
    /// Open the Code tab and load this model (+ adapter) into the Orchestrator team.
    /// Object: a `ModelHandoff` (or `String` model id).
    static let openCodeWithModel = Notification.Name("LLMPro.openCodeWithModel")
}
