import SwiftUI

/// An informational banner that surfaces when the volume backing our model cache /
/// adapters / exports is running low on space. Downloads (multi-GB) and training
/// runs can silently exhaust the disk, so this gives the user an honest heads-up
/// *before* they kick one off. Placed at the top of the Models and Teach tabs.
///
/// Two tiers (amber warning, red critical); hidden entirely when there's plenty of
/// room or the OS query fails — see `DiskSpace.tier(freeGB:)`. Informational only,
/// no action button: the fix (free up space, pick a smaller model) is in the user's
/// hands and the consequence is spelled out in the copy.
struct LowDiskWarningBanner: View {
    /// Latest free-space reading, in decimal GB. `nil` until the first probe (and
    /// if the query fails), which renders nothing.
    @State private var freeGB: Double?

    var body: some View {
        // Decide tier from the latest reading; render nothing when we're fine.
        let tier = DiskSpace.tier(freeGB: freeGB)
        Group {
            switch tier {
            case .ok:
                EmptyView()
            case .warning, .critical:
                banner(tier: tier)
            }
        }
        // Initial read, then a light ~30s refresh so the banner appears/clears as
        // the user frees space or a download eats into it. Cancels on disappear.
        .task {
            freeGB = DiskSpace.freeGBForImportantUsage()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                freeGB = DiskSpace.freeGBForImportantUsage()
            }
        }
    }

    /// The visible card. Colour, icon, and headline come from the tier; the body
    /// copy always states the free-GB figure and the plain-language consequence.
    @ViewBuilder
    private func banner(tier: DiskSpace.Tier) -> some View {
        let tint: Color = (tier == .critical) ? .red : .orange
        let icon = (tier == .critical) ? "exclamationmark.triangle.fill" : "exclamationmark.triangle"
        let headline = (tier == .critical) ? "Very low disk space" : "Low disk space"

        VStack(alignment: .leading, spacing: 6) {
            Label(headline, systemImage: icon)
                .font(.headline)
                .foregroundStyle(tint)
            Text("\(freeText) free. Downloading a model or training may fail — free up space or choose a smaller model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        // Same tinted-rounded-rect card idiom as the Progress tab cards.
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        // Read as one item so VoiceOver speaks the headline + consequence together.
        .accessibilityElement(children: .combine)
    }

    /// User-facing free-space phrase, e.g. "Only 3.4 GB". Rounded to one decimal.
    private var freeText: String {
        guard let freeGB else { return "Very little space" }
        return String(format: "Only %.1f GB", freeGB)
    }
}

#Preview("Live disk reading") {
    // Renders whatever tier the host's real free space maps to (often hidden if
    // the machine has plenty of room — that's the correct, no-banner behaviour).
    LowDiskWarningBanner()
        .frame(width: 480)
        .padding()
}
