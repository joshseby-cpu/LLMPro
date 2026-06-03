import SwiftUI

/// A small ⓘ icon that opens a popover with a plain-language explanation
/// and an optional "Learn more" hyperlink.
///
/// Used throughout the Advanced sections of the app so a non-expert user
/// can mouse over (or tap) any unfamiliar control and get a real-words
/// description plus a link to authoritative reading. Per the project
/// convention "friendly first, technical disclosed", this is the friendly
/// pass on the technical disclosures.
struct HelpHint: View {
    let title: String
    let message: String
    let learnMoreURL: URL?

    @State private var showing = false

    init(_ title: String, _ message: String, learnMore: URL? = nil) {
        self.title = title
        self.message = message
        self.learnMoreURL = learnMore
    }

    /// Convenience init that takes a plain URL string (no error-checking —
    /// pass valid URLs only).
    init(_ title: String, _ message: String, link: String) {
        self.title = title
        self.message = message
        self.learnMoreURL = URL(string: link)
    }

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .imageScale(.medium)
                .contentShape(Rectangle())
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(title)   // mouse-hover tooltip with just the title — popover has the full body
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = learnMoreURL {
                    Divider()
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Text("Learn more")
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .font(.callout)
                }
            }
            .padding(14)
            .frame(maxWidth: 380, alignment: .leading)
        }
    }
}

/// Convenience: a label row that pairs a `Text` (or any view) with a HelpHint
/// to its right. Most commonly used in front of a Picker / Slider.
struct LabeledHint<Content: View>: View {
    let label: String
    let hint: HelpHint
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label).font(.subheadline.weight(.medium))
                hint
                Spacer(minLength: 0)
            }
            content()
        }
    }
}
