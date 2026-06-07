import Foundation

struct CodingDatasetPreset: Identifiable, Hashable, Sendable {
    let id: String              // matches the preset ID in prepare_coding_dataset.py
    let displayName: String
    let hfRepo: String
    let approxRows: Int
    let description: String
    let recommendedFor: String
    let licenseHint: String
}

enum CodingDatasetCatalog {
    /// Curated short list of well-known open coding-instruction datasets.
    /// The IDs MUST match the PRESETS dict in `prepare_coding_dataset.py`.
    static let all: [CodingDatasetPreset] = [
        .init(
            id: "codealpaca-20k",
            displayName: "CodeAlpaca 20K",
            hfRepo: "sahil2801/CodeAlpaca-20k",
            approxRows: 20_000,
            description: "Classic instruction-coding pairs. Short prompts, varied languages. Great starter dataset for a 600-iter run.",
            recommendedFor: "Llama 3.2 3B · Gemma 2 2B · first try on any general base",
            licenseHint: "Research only (Alpaca lineage)."
        ),
        .init(
            id: "magicoder-evol-110k",
            displayName: "Magicoder Evol-Instruct 110K",
            hfRepo: "ise-uiuc/Magicoder-Evol-Instruct-110K",
            approxRows: 110_000,
            description: "Evol-Instruct expanded coding tasks — longer, harder prompts. Sample 20–30K rows by default to keep training tractable.",
            recommendedFor: "Qwen 2.5 7B · Mistral 7B — the dataset to use if you want stronger code reasoning",
            licenseHint: "MIT (data); Apache-2.0 (models)."
        ),
        .init(
            id: "magicoder-oss-75k",
            displayName: "Magicoder OSS-Instruct 75K",
            hfRepo: "ise-uiuc/Magicoder-OSS-Instruct-75K",
            approxRows: 75_000,
            description: "Instruction pairs synthesized from real open-source code snippets. Good balance of breadth and realism.",
            recommendedFor: "Any 7B base when you want diverse language coverage",
            licenseHint: "MIT-ish — check the HF card."
        ),
        .init(
            id: "evol-codealpaca",
            displayName: "evol-codealpaca v1",
            hfRepo: "theblackcat102/evol-codealpaca-v1",
            approxRows: 110_000,
            description: "Evolved CodeAlpaca — harder instructions, longer expected outputs. Pair with `max_seq_length: 4096`+.",
            recommendedFor: "Models you've already tuned once on a smaller dataset",
            licenseHint: "Apache-2.0."
        ),
        .init(
            id: "open-coderpair-20k",
            displayName: "Glaive Code Assistant (sample)",
            hfRepo: "glaiveai/glaive-code-assistant",
            approxRows: 140_000,
            description: "Q&A-style coding conversations, multi-turn-ish. Sample 20K rows by default. Good fit for chat-style coding tutors.",
            recommendedFor: "Mistral 7B · Llama 3.2 3B → chat-style coding",
            licenseHint: "Apache-2.0."
        ),
        // C# / .NET focused presets — added for the agent-coding workflow.
        // The 120K multi-language preset gives broad reach (C# alongside JS /
        // Python / Java / etc); the C#-only preset gives focused depth.
        // Both repo IDs verified live against the HF datasets-server API.
        .init(
            id: "tiny-codes-csharp-125k",
            displayName: "C# / .NET instructions",
            hfRepo: "layoric/tiny-codes-alpaca-csharp",
            approxRows: 125_000,
            description: "Pure C# instruction data (~125K rows) synthesized with rich scenario tagging — covers a wide range of C# / .NET / Blazor patterns. The best off-the-shelf C#-focused dataset on HuggingFace today. For Blazor depth, follow up with a HuggingFace search for 'blazor' to add more.",
            recommendedFor: "Any base when you want C# / .NET expertise (Llama 3.2 3B / Qwen 7B sweet spot)",
            licenseHint: "Apache-2.0."
        ),
        .init(
            id: "code-instructions-120k",
            displayName: "Code Instructions 120K (multi-language)",
            hfRepo: "iamtarun/code_instructions_120k_alpaca",
            approxRows: 120_000,
            description: "Broad multi-language coding instructions (Python, C#, Java, JS, Go, etc.). Use when you want the model to be competent across many languages, including .NET. Sample 30K rows by default — full 120K is heavy.",
            recommendedFor: "General-purpose coding base; pair with a C#-only follow-up for .NET focus",
            licenseHint: "Apache-2.0."
        ),
        // Swift / SwiftUI presets — for Apple-platform (Mac / iOS) fine-tunes.
        // All three repo IDs + schemas verified live against the HF datasets-server.
        // Honest framing: these teach Swift LANGUAGE fluency + SwiftUI idiom; no
        // public dataset teaches whole multi-file Xcode apps, so for full Mac/iOS
        // apps pair a fine-tune here with the Code tab's "SwiftUI app builder"
        // Skill (which scaffolds the project structure) + the build loop.
        .init(
            id: "swift-rlvr-133k",
            displayName: "Swift (functions & algorithms) 133K",
            hfRepo: "saurabh5/rlvr-code-data-Swift",
            approxRows: 133_000,
            description: "The largest real Swift instruction set on HuggingFace — ~133K problem→solution pairs (with verified unit tests). Teaches solid Swift LANGUAGE fluency: types, optionals, generics, control flow. It's algorithm/function-style, NOT whole-app structure — use it as the foundation, then layer the SwiftUI set on top. Sample 20–30K rows by default.",
            recommendedFor: "Any 7B+ base you want fluent in Swift (the foundation for Apple-platform work)",
            licenseHint: "Check the HF card (translated from open RLVR code data)."
        ),
        .init(
            id: "swiftui-examples",
            displayName: "SwiftUI Code Examples",
            hfRepo: "MCES10-Software/SwiftUI-Code-Examples",
            approxRows: 1_009,
            description: "Small but on-target: ~1K prompt→SwiftUI-view pairs (\"Create a SwiftUI view with a TabView\" → working SwiftUI code). The only SwiftUI-specific instruction set on HF. SMALL — it specializes an already-capable model in SwiftUI idiom; it won't teach coding from scratch. Best as a SECOND pass after a broader coding or Swift dataset.",
            recommendedFor: "Specializing a Swift-fluent model in SwiftUI views (pair after swift-rlvr-133k)",
            licenseHint: "Check the HF card."
        ),
        .init(
            id: "swift-qa-4k",
            displayName: "Swift code Q&A 4K",
            hfRepo: "mcorsa/swifterX-4k",
            approxRows: 4_800,
            description: "~4.8K instruction→Swift-code pairs drawn from real Swift files (broader than just UI — view controllers, data structures, utilities). Small and specialized; a good supplement to the 133K function set for more real-world Swift patterns.",
            recommendedFor: "Adding real-world Swift breadth on top of the function/algorithm set",
            licenseHint: "Check the HF card."
        )
    ]
}
