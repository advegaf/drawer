import SwiftUI

struct DrawerChrome<S: Shape>: View {
    let shape: S
    var theme: Theme = .default
    var separatesFromBackdrop = true
    var size: CGSize? = nil
    var body: some View {
        Color.clear
            .frame(width: size?.width, height: size?.height)
            .modifier(DrawerSurface(shape: shape, theme: theme, separatesFromBackdrop: separatesFromBackdrop))
    }
}

struct DrawerSurface<S: Shape>: ViewModifier {
    let shape: S
    var theme: Theme = .default
    var separatesFromBackdrop = true
    @Environment(\.colorScheme) private var systemScheme

    private var resolvedTheme: Theme { theme.resolved(system: systemScheme) }

    func body(content: Content) -> some View {
        surface(content)
            .modifier(DrawerBackdropSeparation(shape: shape, theme: resolvedTheme, enabled: separatesFromBackdrop))
            .environment(\.colorScheme, resolvedTheme.colorScheme(fallback: systemScheme))
    }

    private func surface(_ content: Content) -> some View {
        content.background {
            shape.fill(Palette.notch(resolvedTheme))
        }
    }
}

struct DrawerBackdropSeparation<S: Shape>: ViewModifier {
    let shape: S
    let theme: Theme
    var enabled = true

    func body(content: Content) -> some View {
        let opacity = enabled ? 1.0 : 0.0
        content
            .shadow(color: .black.opacity(0.12 * opacity), radius: 16, y: 4)
            .shadow(color: .black.opacity(0.04 * opacity), radius: 3, y: 1)
    }
}
