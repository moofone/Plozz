#if canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import SwiftUI
import UIKit

/// How a channel logo is presented.
public enum ChannelLogoStyle: Equatable, Sendable {
    /// The logo on its themed backing plate: Home, playback and multiview.
    case plate
    /// The provider's logo in its own colours straight on the row, with no plate,
    /// sized to fill the guide cell like the Live TV guide design. A dark logo is
    /// drawn as a white silhouette. `qualityBadge` ("4K" or "8K") sits just outside the logo's top-right
    /// corner, never over it.
    case bare(qualityBadge: String? = nil)
    /// The bare logo as the Live TV channel panel draws it: left-aligned at the top of its box, sized to the box at
    /// `ChannelLogoExtraction.panelAreaFill` (not the guide cell's geometry), and exactly as tall as the logo drawn. The badge sits at the
    /// logo's top-right corner, outside it, and takes no room.
    case panelLeading(qualityBadge: String? = nil)
}

/// One cached logo and backing treatment for channel guides and live playback.
public struct ChannelLogoArtwork: View {
    private let name: String
    private let logoURL: URL?
    private let size: CGSize
    private let cornerRadius: CGFloat
    private let artworkInset: CGFloat
    private let plozzChannelID: String?
    private let plozzChannelMood: LibraryChannelArtworkMood?
    private let style: ChannelLogoStyle
    private let logoNeedsDarkBackground: Bool
    /// Set for a provider-supplied logo: the brand key it is screened under, so a flag or a logo shared by
    /// unrelated brands draws the channel name instead. `nil` never screens (user and automatic logos).
    private let placeholderScreeningKey: String?
    /// The place printed under a bare guide logo shared by several regional channels; `nil` for none.
    private let regionLabel: String?
    /// Opt-in: when set, a bare logo is drawn only from this synchronously readable cache (`nil` or blank on a miss); nothing is
    /// loaded, decoded, analysed or written by the row. `nil` keeps the loading behaviour.
    private let preparedArtworkCache: ThemedChannelLogoArtworkCache?
    @State private var loaded: LoadedLogo?
    @State private var screenedOut: URL?
    /// Steers the plate: light themes default to light backing, dark to dark.
    @Environment(\.themePalette) private var palette

    public init(
        name: String,
        logoURL: URL?,
        size: CGSize,
        cornerRadius: CGFloat,
        artworkInset: CGFloat? = nil,
        plozzChannelID: String? = nil,
        plozzChannelMood: LibraryChannelArtworkMood? = nil,
        style: ChannelLogoStyle = .plate,
        logoNeedsDarkBackground: Bool = false,
        placeholderScreeningKey: String? = nil,
        regionLabel: String? = nil,
        preparedArtworkCache: ThemedChannelLogoArtworkCache? = nil
    ) {
        self.preparedArtworkCache = preparedArtworkCache
        self.placeholderScreeningKey = placeholderScreeningKey
        self.regionLabel = regionLabel
        self.name = name
        self.logoURL = logoURL
        self.size = size
        self.cornerRadius = cornerRadius
        self.artworkInset = artworkInset ?? size.height * 20 / 128
        self.plozzChannelID = plozzChannelID
        self.plozzChannelMood = plozzChannelMood
        self.style = style
        self.logoNeedsDarkBackground = logoNeedsDarkBackground
    }

    private var isScreenedOut: Bool {
        guard placeholderScreeningKey != nil, let logoURL else { return false }
        return screenedOut == logoURL || ChannelLogoPlaceholderGate.isKnownPlaceholder(logoURL)
    }

    private var current: LoadedLogo? {
        if isScreenedOut { return nil }
        if let loaded, loaded.url == logoURL { return loaded }
        guard let logoURL,
              let cached = HeroLogoMemo.value(for: HeroLogoMemo.key(for: [.remote(logoURL)])) else {
            return nil
        }
        return LoadedLogo(url: logoURL, processed: cached)
    }

    private var bareStyle: (badge: String?, leading: Bool)? {
        switch style {
        case let .bare(badge): (badge, false)
        case let .panelLeading(badge): (badge, true)
        case .plate: nil
        }
    }

    public var body: some View {
        if let logoURL, plozzChannelID == nil {
            BareChannelLogo(
                name: name, logoURL: logoURL, size: size, cornerRadius: cornerRadius,
                artworkInset: artworkInset, qualityBadge: bareStyle?.badge,
                providerRequestsDarkBackground: logoNeedsDarkBackground,
                placeholderScreeningKey: placeholderScreeningKey,
                isPanelLeading: bareStyle?.leading ?? false,
                regionLabel: regionLabel,
                preparedArtworkCache: preparedArtworkCache
            )
        } else {
            plateBody
        }
    }

    private var plateBody: some View {
        Group {
            if plozzChannelID != nil, logoURL == nil {
                PlozzChannelWordmark(
                    name: name, mood: plozzChannelMood ?? .neutral,
                    size: size, cornerRadius: cornerRadius
                )
            } else {
                ChannelLogoPlateContent(
                    name: name, image: current?.image,
                    plate: ChannelLogoPlate(tone: current?.tone, prefersLight: palette.isLight),
                    size: size, cornerRadius: cornerRadius, artworkInset: artworkInset,
                    rendersInkLight: ChannelLogoPlate.rendersInkLight(current?.tone, prefersLight: palette.isLight),
                    isTile: ChannelLogoPlate.showsAsTile(current?.tone)
                )
            }
        }
        .task(id: logoURL) {
            guard let logoURL else {
                loaded = nil
                return
            }
            if let key = placeholderScreeningKey, await ChannelLogoPlaceholderGate.shared.rejects(url: logoURL, brandKey: key) {
                screenedOut = logoURL
                loaded = nil
                return
            }
            let prepared = await HeroLogoPipeline.shared.preparedLogo(for: .remote(logoURL))
            guard !Task.isCancelled else { return }
            loaded = prepared.map {
                let processed = HeroLogoAnalysis.analyze($0, backgroundSample: nil)
                HeroLogoMemo.store(processed, for: HeroLogoMemo.key(for: [.remote(logoURL)]))
                return LoadedLogo(url: logoURL, processed: processed)
            }
        }
        .accessibilityHidden(true)
    }

    private struct LoadedLogo {
        let url: URL
        let image: UIImage
        let tone: ResolvedLogoTone?

        init(url: URL, processed: ProcessedLogo) {
            self.url = url
            image = processed.image
            tone = processed.tone
        }
    }
}

/// The provider logo, trimmed and fitted like the guide design, with no plate.
/// Until the logo loads the cell stays empty; if it cannot load, the ordinary
/// name fallback is shown.
struct BareChannelLogo: View {
    let name: String
    let logoURL: URL
    let size: CGSize
    let cornerRadius: CGFloat
    let artworkInset: CGFloat
    let qualityBadge: String?
    let providerRequestsDarkBackground: Bool
    var placeholderScreeningKey: String? = nil
    var isPanelLeading = false
    var regionLabel: String? = nil
    /// Non-nil makes this a cache-only row: no task, no loader, no disk; a miss draws the empty cell.
    var preparedArtworkCache: ThemedChannelLogoArtworkCache? = nil
    @State private var loaded: Loaded?
    @State private var failedURL: URL?
    @Environment(\.themePalette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private struct LoadID: Hashable {
        let url: URL
        let theme: ChannelLogoExtraction.Theme
    }

    private struct Loaded {
        let url: URL
        let theme: ChannelLogoExtraction.Theme
        let prepared: ChannelLogoExtraction.Prepared
    }

    /// The treatment follows the theme's background; part of the cache key with the URL.
    private var theme: ChannelLogoExtraction.Theme { palette.isLight ? .light : .dark }

    private var isScreenedOut: Bool {
        placeholderScreeningKey != nil && (failedURL == logoURL || ChannelLogoPlaceholderGate.isKnownPlaceholder(logoURL))
    }

    private var current: ChannelLogoExtraction.Prepared? {
        if isScreenedOut { return nil }
        if let preparedArtworkCache {
            return preparedArtworkCache.prepared(
                for: ThemedChannelLogoIdentity(url: logoURL, providerRequestsDarkBackground: providerRequestsDarkBackground),
                theme: theme)
        }
        if let loaded, loaded.url == logoURL, loaded.theme == theme { return loaded.prepared }
        return ChannelLogoExtractionLoader.cached(
            url: logoURL, providerRequestsDarkBackground: providerRequestsDarkBackground, theme: theme
        )
    }

    var body: some View {
        if preparedArtworkCache != nil {
            content.accessibilityHidden(true)
        } else {
            content
                .task(id: LoadID(url: logoURL, theme: theme)) { await load() }
                .accessibilityHidden(true)
        }
    }

    private var content: some View {
        Group {
            if let prepared = current, prepared.needsTextFallback, !name.isEmpty {
                if isPanelLeading {
                    nameText(in: size, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    let box = ChannelLogoExtraction.GuideGeometry(cellSize: size).box
                    nameText(in: box, alignment: .leading).frame(width: size.width, height: size.height)
                }
            } else if let prepared = current, isPanelLeading {
                let aspect = Self.drawnAspect(of: prepared.image, fallback: prepared.aspect)
                let fitted = ChannelLogoExtraction.fittedSize(aspect: aspect, in: size, areaFill: ChannelLogoExtraction.panelAreaFill)
                ZStack(alignment: .topLeading) {
                    logo(prepared, size: fitted)
                    if let qualityBadge {
                        let badgeFont: CGFloat = 27
                        QualityBadge(text: qualityBadge, fontSize: badgeFont)
                            .offset(x: fitted.width, y: -badgeFont * 1.34 * ChannelLogoExtraction.GuideGeometry.badgeRise)
                    }
                }
                .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let prepared = current, let regionLabel, qualityBadge == nil {
                labelledLogo(prepared, label: regionLabel)
            } else if let prepared = current {
                let geometry = ChannelLogoExtraction.GuideGeometry(cellSize: size)
                // The drawn image's own pixel aspect, not the reported trim aspect:
                // they differ when the trim crop failed and the original was kept.
                let layout = geometry.layout(
                    aspect: Self.drawnAspect(of: prepared.image, fallback: prepared.aspect), badge: qualityBadge, inkFill: prepared.inkFill)
                ZStack(alignment: .topLeading) {
                    logo(prepared, size: layout.logo.size)
                        .offset(x: layout.logo.minX, y: layout.logo.minY)
                    if let qualityBadge, let badge = layout.badge {
                        QualityBadge(text: qualityBadge, fontSize: geometry.badgeFontSize)
                            .offset(x: badge.minX, y: badge.minY)
                    }
                }
                .frame(width: geometry.box.width, height: geometry.box.height, alignment: .topLeading)
                .frame(width: size.width, height: size.height)
            } else if failedURL == logoURL || isScreenedOut {
                ChannelLogoPlateContent(
                    name: name, image: nil,
                    plate: ChannelLogoPlate(tone: nil, prefersLight: palette.isLight),
                    size: size, cornerRadius: cornerRadius, artworkInset: artworkInset
                )
            } else {
                Color.clear.frame(width: size.width, height: size.height)
            }
        }
    }

    private func load() async {
        if let key = placeholderScreeningKey,
           await ChannelLogoPlaceholderGate.shared.rejects(url: logoURL, brandKey: key) {
            loaded = nil
            failedURL = logoURL
            return
        }
        let prepared = await ChannelLogoExtractionLoader.shared.prepared(
            url: logoURL, providerRequestsDarkBackground: providerRequestsDarkBackground, theme: theme
        )
        guard !Task.isCancelled else { return }
        if let prepared {
            loaded = Loaded(url: logoURL, theme: theme, prepared: prepared)
            failedURL = nil
        } else {
            failedURL = logoURL
        }
    }

    /// The logo with its place beneath it, centred together on ink in the visible cell (see `ChannelLogoExtraction.labelledLayout`).
    private func labelledLogo(_ prepared: ChannelLogoExtraction.Prepared, label: String) -> some View {
        let box = ChannelLogoExtraction.GuideGeometry(cellSize: size).box
        let layout = ChannelLogoExtraction.labelledLayout(
            aspect: Self.drawnAspect(of: prepared.image, fallback: prepared.aspect), inkFill: prepared.inkFill, box: box, cell: size
        ) { ChannelLogoExtraction.labelInk(label, font: $0) }
        let font = UIFont.systemFont(ofSize: layout.fontSize, weight: .medium)
        let colour = ChannelLogoExtraction.RegionLabelStyle.colour(for: theme)
        return ZStack(alignment: .topLeading) {
            logo(prepared, size: layout.logo.size)
                .offset(x: layout.logo.minX, y: layout.logo.minY)
            Text(verbatim: label)
                .font(Font(font))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Color(red: colour.rgb.0 / 255, green: colour.rgb.1 / 255, blue: colour.rgb.2 / 255).opacity(colour.opacity))
                .frame(width: size.width, height: font.lineHeight, alignment: .center)
                .offset(x: layout.inkShiftX, y: layout.baseline - font.ascender)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    static func drawnAspect(of image: UIImage, fallback: Double) -> Double {
        guard image.size.width > 0, image.size.height > 0 else { return fallback }
        return Double(image.size.width / image.size.height)
    }

    @ViewBuilder
    private func logo(_ prepared: ChannelLogoExtraction.Prepared, size: CGSize) -> some View {
        if prepared.isDark {
            Image(uiImage: prepared.image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
                .foregroundStyle(.white.opacity(0.9))
        } else {
            Image(uiImage: prepared.image)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
        }
    }

    /// The channel's cleaned name in the logo slot, for a logo that is not a quality icon or still misses the contrast rule.
    private func nameText(in box: CGSize, alignment: Alignment) -> some View {
        let fontSize = box.height * 0.36
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let layout = ChannelLogoExtraction.nameLayout(name, maxWidth: box.width) {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }
        return VStack(spacing: 0) {
            ForEach(Array(layout.lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.system(size: fontSize * layout.scale, weight: .semibold, design: .default))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsTightening(index == layout.lines.count - 1 ? false : true)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(palette.isLight ? Color(white: 0.1) : Color.white)
        .frame(width: box.width, height: box.height, alignment: .center)
    }
}

/// The 4K word: bold white with a soft dark halo.
public struct QualityBadge: View {
    let text: String
    let fontSize: CGFloat

    public init(text: String, fontSize: CGFloat) {
        self.text = text
        self.fontSize = fontSize
    }

    public var body: some View {
        let height = fontSize * 1.34
        Text(verbatim: text)
            .font(.system(size: fontSize, weight: .bold))
            .tracking(fontSize * 0.03)
            .foregroundStyle(.white)
            .padding(.horizontal, fontSize * 0.2)
            .frame(height: height)
            .fixedSize()
            .shadow(color: .black.opacity(0.95), radius: 1)
            .shadow(color: .black.opacity(0.85), radius: 2)
            .shadow(color: .black.opacity(0.7), radius: 4)
            .shadow(color: .black.opacity(0.45), radius: 9)
            .allowsHitTesting(false)
    }
}

struct ChannelLogoPlate: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    /// - Parameter prefersLight: the theme's side.
    ///   - Dark themes always get dark backing. A logo whose own solid
    ///     background is light is backed dark anyway, and dark-only ink is
    ///     drawn light over it (see `rendersInkLight`) rather than handed a
    ///     white plate that glares out of a dark guide.
    ///   - Light themes get light backing unless the ink is predominantly pale,
    ///     where white would swallow it.
    init(tone: ResolvedLogoTone?, prefersLight: Bool = false) {
        if let original = tone?.backgroundPlate,
           prefersLight || original.luminance < Self.lightPlateLuminance {
            red = original.red
            green = original.green
            blue = original.blue
            return
        }

        // Brand tint stays secondary to contrast.
        let usesLightBacking = Self.usesLightBacking(tone, prefersLight: prefersLight)
        let base = usesLightBacking
            ? (red: 1.0, green: 1.0, blue: 1.0)
            : (red: 0.14, green: 0.15, blue: 0.17)
        let ink = (red: tone?.red ?? 0, green: tone?.green ?? 0, blue: tone?.blue ?? 0)
        let chroma = max(ink.red, ink.green, ink.blue) - min(ink.red, ink.green, ink.blue)
        let tint = chroma > 0.12 ? (usesLightBacking ? 0.08 : 0.12) : 0
        let mean = (ink.red + ink.green + ink.blue) / 3
        let muted = (
            red: mean + (ink.red - mean) * 0.45,
            green: mean + (ink.green - mean) * 0.45,
            blue: mean + (ink.blue - mean) * 0.45
        )
        red = max(usesLightBacking ? 0 : base.red, base.red + (muted.red - base.red) * tint)
        green = max(usesLightBacking ? 0 : base.green, base.green + (muted.green - base.green) * tint)
        blue = max(usesLightBacking ? 0 : base.blue, base.blue + (muted.blue - base.blue) * tint)
    }

    static func usesLightBacking(_ tone: ResolvedLogoTone?, prefersLight: Bool) -> Bool {
        guard prefersLight else { return false }
        guard let tone else { return true }
        let paleInk = tone.luminance > 0.70 || tone.brightInk > 0.25
        return !paleInk
    }

    /// Dark ink on a dark theme's plate is redrawn light so it stays legible.
    /// Only ink that would genuinely vanish: near-black AND colourless, with no
    /// bright detail. Deep brand colours — navy, maroon, purple — are dark too,
    /// but recolouring them loses the brand for no gain in legibility.
    ///
    /// Never a logo that still carries its own box (high coverage): recolouring
    /// that would paint the whole box white. Such a logo keeps its own look,
    /// as a tile on the dark plate.
    static func rendersInkLight(_ tone: ResolvedLogoTone?, prefersLight: Bool) -> Bool {
        guard !prefersLight, let tone else { return false }
        if let original = tone.backgroundPlate, original.luminance < lightPlateLuminance { return false }
        let chroma = max(tone.red, tone.green, tone.blue) - min(tone.red, tone.green, tone.blue)
        return tone.coverage < 0.85 && tone.brightInk < 0.04
            && tone.luminance < 0.18 && chroma < 0.08
    }

    private static let lightPlateLuminance = 0.55

    /// A logo that fills its own box — square channel art, a badge on a solid
    /// card — rather than ink on transparency. The same coverage line the logo
    /// analysis draws between a boxed and a cut-out logo.
    static func showsAsTile(_ tone: ResolvedLogoTone?) -> Bool {
        (tone?.coverage ?? 0) >= 0.85
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
    var isLight: Bool { 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.55 }
}

struct ChannelLogoPlateContent: View {
    let name: String
    let image: UIImage?
    let plate: ChannelLogoPlate
    let size: CGSize
    let cornerRadius: CGFloat
    let artworkInset: CGFloat
    var rendersInkLight = false
    /// Boxed logos fill more of the plate; playback preserves their source corners.
    var isTile = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.channelLogoPreservesSourceCorners) private var preservesSourceCorners

    /// A tile hugs the plate more closely than ink does.
    private var inset: CGFloat {
        isTile ? min(artworkInset, max(4, size.height * 8 / 128)) : artworkInset
    }

    /// Proportional to the tile itself, not concentric with the plate: a square
    /// tile sits well inside a wide plate, so its corners don't nest in the
    /// plate's, and the concentric remainder (a few points) barely read as round.
    private var tileCornerRadius: CGFloat {
        preservesSourceCorners ? 0 : max(4, (size.height - inset * 2) * 0.08)
    }

    var body: some View {
        ZStack {
            if let image {
                if rendersInkLight {
                    Image(uiImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.white.opacity(0.92))
                } else if isTile {
                    Image(uiImage: image)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous))
                } else {
                    Image(uiImage: image)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                }
            } else {
                Text(name)
                    .font(.system(size: size.height * 0.22, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(plate.isLight ? Color.black : Color.white)
            }
        }
        .frame(
            width: max(1, size.width - inset * 2),
            height: max(1, size.height - inset * 2)
        )
        .frame(width: size.width, height: size.height)
        .background(plate.color)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    (plate.isLight ? Color.black : Color.white)
                        .opacity(contrast == .increased ? 0.4 : 0.14),
                    lineWidth: contrast == .increased ? 2 : 1
                )
                .allowsHitTesting(false)
        }
    }
}

private struct ChannelLogoPreservesSourceCornersKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Live playback keeps boxed source logos unrounded without changing guide-page tiles.
    var channelLogoPreservesSourceCorners: Bool {
        get { self[ChannelLogoPreservesSourceCornersKey.self] }
        set { self[ChannelLogoPreservesSourceCornersKey.self] = newValue }
    }
}
#endif
