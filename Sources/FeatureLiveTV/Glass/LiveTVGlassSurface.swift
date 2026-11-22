#if os(tvOS)
import CoreUI
import SwiftUI

/// The glass look shared by the Live TV panels: Apple's SDK Liquid Glass (`glassEffect(.regular)`) drawn as a background
/// underlay (wrapping `.glassEffect` around focusable content hangs tvOS focus; see `PlozzGlassCardModifier`), a soft shadow,
/// and an opaque dark fill when transparency is reduced. Every caller gets it; the blurred material is only the pre-tvOS 26 fallback.
struct LiveTVGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.plozzReducePanelGlass) private var reducePanelGlass

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background { surface(shape) }
            .shadow(color: .black.opacity(0.7), radius: 45, x: 0, y: 40)
    }

    @ViewBuilder
    private func surface(_ shape: RoundedRectangle) -> some View {
        if reducePanelGlass || reduceTransparency {
            shape.fill(Color(red: 20 / 255, green: 21 / 255, blue: 26 / 255))
                .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        } else if #available(tvOS 26.0, *) {
            // Plozz's dark panel glass, the same as the guide's sheet and the hero (mockup `.screen.pz .panel.lg`): `.regular` tinted
            // black 40% under a 1 pt white 12% rim.
            PlayerNativeGlassSurface(shape, glass: .regular.tint(.black.opacity(PrototypePlayingGlass.panelTintOpacity)))
                .overlay { shape.strokeBorder(.white.opacity(PrototypePlayingGlass.rimOpacity), lineWidth: 1) }
        } else {
            // The mockup's `.screen .panel.lg`: the picture behind blurred and deepened, a top-lit gradient of white over it and a
            // 1 pt rim. System Liquid Glass here lenses the guide into a smear at the panel's edge, so it is a blurred material.
            shape.fill(.ultraThinMaterial)
                .overlay {
                    shape.fill(LinearGradient(
                        stops: [.init(color: .white.opacity(0.2), location: 0), .init(color: .white.opacity(0.1), location: 0.26),
                                .init(color: .white.opacity(0.06), location: 0.62), .init(color: .white.opacity(0.045), location: 1)],
                        startPoint: .top, endPoint: .bottom))
                }
                .overlay { shape.strokeBorder(.white.opacity(0.17), lineWidth: 1) }
        }
    }
}

extension View {
    func liveTVGlassSurface(cornerRadius: CGFloat) -> some View {
        modifier(LiveTVGlassSurface(cornerRadius: cornerRadius))
    }
}

/// Focus feedback is drawn by the label (it reads `isFocused`); the style only removes the system lift.
struct LiveTVGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

enum LiveTVGlassInk {
    /// Focused tray rows and round buttons.
    static let focusedFill = Color(red: 0xf5 / 255, green: 0xf5 / 255, blue: 0xf7 / 255)
    static let focusedInk = Color(red: 0x0b / 255, green: 0x0b / 255, blue: 0x0d / 255)
    static let selectedCheck = Color(red: 0x4a / 255, green: 0xa3 / 255, blue: 0xff / 255)
    static let focusedCheck = Color(red: 0x1a / 255, green: 0x6f / 255, blue: 0xe0 / 255)
    static let secondary = Color.white.opacity(0.55)
    /// The quick menu's focused row: near-white with dark ink, as in the mockup (`.qm .prow.f`).
    static let menuFocusedFill = Color.white.opacity(0.94)
    static let menuFocusedInk = focusedInk
    /// Counts after a row's name (`.cnt`), chevrons and the "Updated" caption (`.t3`).
    static let menuCount = Color.white.opacity(0.5)
    static let menuTertiary = Color.white.opacity(0.6)
    static let menuSecondary = Color.white.opacity(0.6)
}
#endif
