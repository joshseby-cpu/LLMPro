import Foundation
import Observation

/// Drives long-form story generation for the Story tab. Holds the working
/// `StoryProject` and streams chapters into it via `InferenceService`. The hard
/// problem it solves is coherence across a long story (15+ chapters) that can't
/// fit in a context window: each chapter is written with the premise + outline +
/// a rolling set of per-chapter **summaries** + the tail of the previous chapter,
/// not the full prior text. Summaries are generated automatically after each
/// chapter. Behavior/latitude comes entirely from the chosen model + the user's
/// style instructions — this class adds no content policy.
///
/// Concurrency: a `generation` counter (bumped on every start and on `stop()`)
/// makes a cancelled/superseded task's tail a no-op, so a fast Stop→Write can't
/// orphan the new generation's subprocess (same fix as `ChatSession`).
@MainActor
@Observable
final class StoryGenerator {
    var project: StoryProject
    var isGenerating = false
    var streamingChapterID: UUID?
    var statusLine: String = ""
    var error: String?

    private var task: Task<Void, Never>?
    private var generation = 0

    init(project: StoryProject) { self.project = project }

    isolated deinit { task?.cancel() }

    /// Persist directly to the store (which owns the same project id). Avoids
    /// storing a View-capturing closure on this long-lived object.
    private func save() { StoryStore.shared.update(project) }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        isGenerating = false
        streamingChapterID = nil
        statusLine = ""
    }

    // MARK: - Public actions

    /// Write ONE new chapter, optionally guided by an instruction ("introduce a
    /// betrayal", "make it darker", "wrap up the arc").
    func writeNextChapter(instruction: String) {
        guard !isGenerating else { return }
        generation &+= 1
        let myGen = generation
        isGenerating = true
        error = nil
        task = Task { [myGen] in
            await self.appendOneChapter(instruction: instruction, myGen: myGen)
            if self.generation == myGen { self.finishRun() }
        }
    }

    /// Keep writing chapters until the project reaches `targetChapters` (or the
    /// user stops). Each chapter uses the outline + rolling summaries.
    func autoWriteToTarget() {
        guard !isGenerating else { return }
        generation &+= 1
        let myGen = generation
        isGenerating = true
        error = nil
        task = Task { [myGen] in
            while self.generation == myGen, self.project.chapters.count < self.project.targetChapters {
                let ok = await self.appendOneChapter(instruction: "", myGen: myGen)
                if !ok { break }   // empty output / error → stop the loop
            }
            if self.generation == myGen { self.finishRun() }
        }
    }

    /// Rewrite an existing chapter per an instruction. Non-destructive: if the
    /// generation is stopped/errors before producing text, the original chapter is
    /// restored.
    func reviseChapter(id: UUID, instruction: String) {
        guard !isGenerating, let idx = project.chapters.firstIndex(where: { $0.id == id }) else { return }
        generation &+= 1
        let myGen = generation
        isGenerating = true
        error = nil
        let original = project.chapters[idx]
        let prompt = buildRevisePrompt(chapter: original, instruction: instruction)
        let params = inferenceParams()
        project.chapters[idx].text = ""
        project.chapters[idx].summary = ""
        streamingChapterID = id
        statusLine = "Revising \(original.title)…"
        task = Task { [myGen] in
            await self.stream(into: id, prompt: prompt, params: params, myGen: myGen)
            if let i = self.project.chapters.firstIndex(where: { $0.id == id }) {
                self.project.chapters[i].text = ReasoningStripper.visible(self.project.chapters[i].text)
            }
            // Restore the original if nothing came back (cancel/error, or the model
            // only reasoned and produced no prose).
            if let i = self.project.chapters.firstIndex(where: { $0.id == id }),
               self.project.chapters[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.project.chapters[i] = original
            } else if self.generation == myGen {
                await self.summarize(chapterID: id)
            }
            if self.generation == myGen { self.finishRun() }
            self.save()
        }
    }

    /// Regenerate a chapter's rolling-context summary — call after a manual edit
    /// changed its text (a blank summary weakens later chapters' coherence).
    func resummarizeChapter(id: UUID) {
        guard !isGenerating, project.chapters.contains(where: { $0.id == id }) else { return }
        generation &+= 1
        let myGen = generation
        isGenerating = true
        statusLine = "Updating summary…"
        task = Task { [myGen] in
            await self.summarize(chapterID: id)
            if self.generation == myGen { self.finishRun() }
            self.save()
        }
    }

    /// Generate a chapter-by-chapter outline from the premise (helps long-story
    /// coherence). Fills `project.outline`.
    func planOutline() {
        guard !isGenerating else { return }
        generation &+= 1
        let myGen = generation
        isGenerating = true
        error = nil
        statusLine = "Planning the story…"
        let prompt = buildOutlinePrompt()
        var params = inferenceParams()
        params.maxTokens = 1600
        let priorOutline = project.outline   // restore if the run is stopped/errors before output
        project.outline = ""
        task = Task { [myGen] in
            let sink = LineAccumulator()
            await self.streamText(prompt: prompt, params: params, myGen: myGen) { chunk in
                sink.append(chunk)
                self.project.outline = ReasoningStripper.visible(sink.text, streaming: true)
            }
            let final = ReasoningStripper.visible(sink.text)
            self.project.outline = final.isEmpty ? priorOutline : final
            if self.generation == myGen { self.finishRun() }
            self.save()
        }
    }

    // MARK: - Core generation

    /// Append one new chapter and (on success) summarize it. Returns false when the
    /// output was empty (so the auto-write loop knows to stop).
    @discardableResult
    private func appendOneChapter(instruction: String, myGen: Int) async -> Bool {
        let n = project.chapters.count + 1
        // Build the prompt BEFORE appending the empty stub — otherwise storySoFar()
        // would treat the just-added empty chapter as "the previous chapter" and
        // feed an empty continuity tail, breaking coherence.
        let prompt = buildChapterPrompt(instruction: instruction, chapterNumber: n)
        let chapter = StoryChapter(title: "Chapter \(n)", text: "")
        let cid = chapter.id
        project.chapters.append(chapter)
        streamingChapterID = cid
        statusLine = project.targetChapters > n && instruction.isEmpty
            ? "Writing chapter \(n) of \(project.targetChapters)…"
            : "Writing chapter \(n)…"

        let ok = await stream(into: cid, prompt: prompt, params: inferenceParams(), myGen: myGen)
        // Drop the model's <think> reasoning from the chapter prose (so it's never
        // summarized, fed back as context, or exported).
        if let i = project.chapters.firstIndex(where: { $0.id == cid }) {
            project.chapters[i].text = ReasoningStripper.visible(project.chapters[i].text)
        }
        save()

        let empty = project.chapters.first(where: { $0.id == cid })?
            .text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        guard ok, generation == myGen, !empty else {
            // Nothing usable (stopped/errored before any prose) — drop the empty stub;
            // keep a partial chapter if the stream errored after some text.
            if empty, let i = project.chapters.firstIndex(where: { $0.id == cid }) {
                project.chapters.remove(at: i)
                save()
            }
            return false
        }
        statusLine = "Summarizing chapter \(n)…"
        await summarize(chapterID: cid)
        save()
        return true
    }

    @discardableResult
    private func stream(into chapterID: UUID, prompt: String, params: InferenceParams, myGen: Int) async -> Bool {
        await streamText(prompt: prompt, params: params, myGen: myGen) { chunk in
            if let i = self.project.chapters.firstIndex(where: { $0.id == chapterID }) {
                self.project.chapters[i].text.append(chunk)
            }
        }
    }

    /// Shared streaming primitive. Returns true only if the stream ran to a clean
    /// end — false if it was cancelled/superseded or errored, so the auto-write
    /// loop stops instead of counting a truncated chapter and pressing on.
    @discardableResult
    private func streamText(prompt: String, params: InferenceParams, myGen: Int,
                            onChunk: @MainActor @escaping (String) -> Void) async -> Bool {
        do {
            let stream = await InferenceService.shared.stream(
                model: project.model, adapterPath: nil, prompt: prompt, params: params)
            for try await chunk in stream {
                guard generation == myGen else { return false }
                onChunk(chunk)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if generation == myGen { self.error = error.localizedDescription }
            return false
        }
    }

    private func summarize(chapterID: UUID) async {
        guard let idx = project.chapters.firstIndex(where: { $0.id == chapterID }) else { return }
        let text = project.chapters[idx].text
        var params = inferenceParams()
        params.maxTokens = 180
        params.temperature = 0.3
        // Summarize the whole chapter when it fits; only for an over-long chapter
        // sample head+tail (so the opening isn't dropped, which biased continuity).
        let clip: String
        if text.count <= 9000 {
            clip = text
        } else {
            clip = String(text.prefix(5000)) + "\n\n[…middle omitted…]\n\n" + String(text.suffix(4000))
        }
        let prompt = "Summarize the following chapter in 2-3 sentences, capturing the key plot points, character developments, and where it ends. Be concise and factual.\n\nChapter:\n\(clip)\n\nSummary:"
        let sink = LineAccumulator()
        let myGen = generation   // don't let a superseded summarize overwrite
        await streamText(prompt: prompt, params: params, myGen: myGen) { chunk in sink.append(chunk) }
        if generation == myGen, let i = project.chapters.firstIndex(where: { $0.id == chapterID }) {
            project.chapters[i].summary = ReasoningStripper.visible(sink.text)
        }
    }

    private func finishRun() {
        isGenerating = false
        streamingChapterID = nil
        statusLine = ""
    }

    // MARK: - Prompt building

    private func inferenceParams() -> InferenceParams {
        var p = InferenceParams()
        p.temperature = project.temperature
        // ~1.4 tokens/word for the prose, PLUS a reserve for a reasoning model's
        // hidden <think> tokens (which are stripped from the output but still count
        // against max-tokens). The model stops at EOS, so a high cap is safe.
        p.maxTokens = min(8192, max(2048, Int(Double(project.chapterWordTarget) * 1.6) + 2048))
        p.systemPrompt = ""
        return p
    }

    private func styleHeader() -> String {
        let style = project.styleInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = style.isEmpty ? "You are a masterful fiction writer." : style
        s += "\n\n"
        if !project.genre.isEmpty { s += "Genre: \(project.genre)\n" }
        s += "Story title: \(project.isUntitled ? "Untitled" : project.title)\n"
        if !project.premise.isEmpty { s += "Premise: \(project.premise)\n" }
        let outline = project.outline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !outline.isEmpty { s += "\nOutline:\n\(outline)\n" }
        return s
    }

    private func storySoFar() -> String {
        guard !project.chapters.isEmpty else { return "\nThis is the opening chapter.\n" }
        var s = "\nStory so far:\n"
        for (i, ch) in project.chapters.enumerated() {
            let synopsis = ch.summary.isEmpty ? String(ch.text.prefix(400)) : ch.summary
            s += "Chapter \(i + 1) (\(ch.title)): \(synopsis)\n"
        }
        if let last = project.chapters.last, !last.text.isEmpty {
            s += "\nThe previous chapter ended with:\n…\(last.text.suffix(1200))\n"
        }
        return s
    }

    private func buildChapterPrompt(instruction: String, chapterNumber n: Int) -> String {
        var s = styleHeader()
        s += storySoFar()
        s += "\nNow write Chapter \(n)"
        let instr = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instr.isEmpty { s += ", following this guidance: \(instr)" }
        s += ". Aim for roughly \(project.chapterWordTarget) words of vivid, engaging prose. Write the full chapter — do not summarize or add commentary. Begin:\n\n"
        return s
    }

    private func buildRevisePrompt(chapter: StoryChapter, instruction: String) -> String {
        var s = styleHeader()
        // Surrounding context (other chapters' summaries) so "keep it consistent"
        // is actionable — otherwise the revision only sees this one chapter.
        let others = project.chapters.enumerated()
            .filter { $0.element.id != chapter.id && !$0.element.summary.isEmpty }
            .map { "Chapter \($0.offset + 1): \($0.element.summary)" }
        if !others.isEmpty {
            s += "\nStory context (other chapters):\n" + others.joined(separator: "\n") + "\n"
        }
        s += "\nHere is the current text of \(chapter.title):\n\n\(chapter.text)\n\n"
        s += "Revise this chapter according to this instruction: \(instruction)\n"
        s += "Keep it consistent with the rest of the story. Output only the revised chapter text, with no preamble or commentary. Begin:\n\n"
        return s
    }

    private func buildOutlinePrompt() -> String {
        var s = styleHeader()
        s += "\nWrite a concise chapter-by-chapter outline for this story across about \(project.targetChapters) chapters. "
        s += "For each chapter give a title and 1-2 sentences on what happens. Number the chapters. Begin:\n\n"
        return s
    }
}

/// Tiny main-actor text accumulator (avoids capturing a mutable local in the
/// escaping @MainActor onChunk closure).
@MainActor
private final class LineAccumulator {
    private(set) var text = ""
    func append(_ s: String) { text.append(s) }
}
