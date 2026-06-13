import SwiftUI

// MARK: - Brand color

extension Color {
    /// The app's brand accent (purple/violet), backed by the `AccentColor` asset
    /// so it adapts to light/dark. Use this anywhere code needs the tint directly
    /// rather than relying on the inherited `.tint(...)`.
    static let brand = Color("AccentColor")
}

// MARK: - Brand gradient

enum Theme {
    /// A subtle hero gradient from the brand violet to a lighter pinkish violet.
    /// For accent flourishes (icons, headers) — not large fills.
    static let brandGradient = LinearGradient(
        colors: [Color.brand, Color(red: 0.74, green: 0.46, blue: 1.0)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Card surface

/// A defined, slightly-elevated card surface. Replaces the flat
/// `.background(.thinMaterial, in: RoundedRectangle(...))` look with a filled
/// surface that adapts to light/dark, a hairline border, and a soft shadow.
private struct CardModifier: ViewModifier {
    let padding: CGFloat
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .padding(padding)
            .background(Color.primary.opacity(0.04), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}

extension View {
    /// Wrap a view in the shared elevated card surface.
    func card(padding: CGFloat = 16, cornerRadius: CGFloat = 14) -> some View {
        modifier(CardModifier(padding: padding, cornerRadius: cornerRadius))
    }
}

// MARK: - Section header

extension View {
    /// A consistent section header — `.headline`, with an optional leading SF
    /// Symbol tinted in the secondary style.
    @ViewBuilder
    func sectionHeader(_ title: String, systemImage: String? = nil) -> some View {
        if let systemImage {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(.secondary)
            }
            .font(.headline)
        } else {
            Text(title).font(.headline)
        }
    }
}
