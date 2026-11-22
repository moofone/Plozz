#if os(tvOS)
import CoreModels
import SwiftUI

/// The provider's name tags (`EN`, `HD`, `4K`, `60fps`…) as small badges in one line,
/// drawn like the guide's 4K badge: bold, tracked, white. Used by the hero and the channel panel.
struct LiveTVGlassTagRow: View {
    let texts: [String]
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: fontSize * 0.5) {
            ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                Text(verbatim: text)
                    .font(.system(size: fontSize, weight: .bold))
                    .tracking(fontSize * 0.03)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, fontSize * 0.4)
                    .padding(.vertical, fontSize * 0.12)
                    .overlay {
                        RoundedRectangle(cornerRadius: fontSize * 0.3, style: .continuous)
                            .strokeBorder(.white.opacity(0.4), lineWidth: 1.5)
                    }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: texts.joined(separator: ", ")))
    }
}
#endif
