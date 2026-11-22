#if os(tvOS)
import SwiftUI

/// Draws its content, laid out in 1080p points, at `scale` times its size from the top-leading corner, and reports the scaled size to
/// its parent. The right panel, the quick-menu tray and the context menu use it at 4K (`LiveTVGlassLayout.uiScale`): the mockup scales
/// every one of their sizes by the same factor, so one transform is the same layout, and their line wrapping and room checks are done
/// in the unscaled units.
struct LiveTVGlassUnitScale<Content: View>: View {
    let scale: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if scale == 1 {
            content
        } else {
            LiveTVGlassUnitScaleLayout(scale: scale) { content.scaleEffect(scale, anchor: .topLeading) }
        }
    }
}

private struct LiveTVGlassUnitScaleLayout: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(unscaled(proposal))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let size = subview.sizeThatFits(unscaled(proposal))
        subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }

    private func unscaled(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale })
    }
}
#endif
