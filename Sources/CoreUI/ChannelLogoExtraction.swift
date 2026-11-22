#if canImport(UIKit)
import CoreGraphics
import CoreModels
import CoreText
import Foundation
import ImageIO
import UIKit

/// Decoded RGBA pixels with straight (non-premultiplied) alpha, row-major, four bytes per pixel.
struct ChannelLogoPixels: Equatable {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(width: Int, height: Int, bytes: [UInt8]) {
        guard width > 0, height > 0, bytes.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}

struct ChannelLogoPixelRect: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

/// Colour channel logo treatment for the Live TV guide: trim, dark-logo test and fit.
///
/// Works only on the logo the provider supplied. The functions are pure so the
/// treatment can be checked against reference buffers without a view.
enum ChannelLogoExtraction {
    /// Pixels at or below this alpha (0–255) are treated as empty when trimming.
    static let trimAlphaThreshold = 12
    /// Mean luminance (0–1) below which a logo is drawn as a white silhouette.
    static let darkLuminanceThreshold = 0.28
    /// Share of the logo box area that the fitted logo aims to cover.
    static let areaFill = 0.42
    /// The channel panel's logo: the mockup's `logoSize(logo, box, .5)`, a little larger than the guide's.
    static let panelAreaFill = 0.5

    /// Bounding box of pixels whose alpha exceeds ``trimAlphaThreshold``; `nil` when none do.
    static func trimRect(_ pixels: ChannelLogoPixels) -> ChannelLogoPixelRect? {
        var minX = pixels.width, minY = pixels.height, maxX = -1, maxY = -1
        pixels.bytes.withUnsafeBufferPointer { bytes in
            for y in 0..<pixels.height {
                let row = y * pixels.width
                for x in 0..<pixels.width where Int(bytes[(row + x) * 4 + 3]) > trimAlphaThreshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    maxY = y
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return ChannelLogoPixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The share of a trimmed logo's bounding box that is ink (alpha above ``trimAlphaThreshold``): 1 for a solid block, low for a thin wordmark.
    static func inkFill(_ pixels: ChannelLogoPixels) -> Double {
        guard let trim = trimRect(pixels) else { return 1 }
        var ink = 0
        pixels.bytes.withUnsafeBufferPointer { bytes in
            for y in trim.y..<(trim.y + trim.height) {
                for x in trim.x..<(trim.x + trim.width) where Int(bytes[(y * pixels.width + x) * 4 + 3]) > trimAlphaThreshold { ink += 1 }
            }
        }
        return Double(ink) / Double(trim.width * trim.height)
    }

    /// Owner rule "v2b": the equal-area fit of the logo's bounding box, then a mark whose ink fills less than ``v2bTargetInkFill`` of that
    /// box is scaled UP by sqrt(target / fill) so thin marks do not look small. Never smaller than the plain fit. The result stays within
    /// the box's width and ``v2bMaximumHeightShare`` of its height (a fit already past that cap is kept as it is).
    static let v2bTargetInkFill = 0.60
    static let v2bMaximumHeightShare = 0.85

    static func v2bSize(aspect: Double, inkFill: Double, in box: CGSize) -> CGSize {
        let base = fittedSize(aspect: aspect, in: box)
        guard base.width > 0, inkFill > 0, inkFill < v2bTargetInkFill else { return base }
        var scale = (v2bTargetInkFill / inkFill).squareRoot()
        scale = min(scale, Double(box.width) / Double(base.width), v2bMaximumHeightShare * Double(box.height) / Double(base.height))
        scale = max(1, scale)
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    /// Colour statistics of sampled, mostly opaque pixels of the untrimmed image; `nil` when no sampled pixel qualifies.
    static func colourProfile(_ pixels: ChannelLogoPixels) -> LogoColourProfile? {
        LogoColourProfile(straightRGBA: pixels.bytes)
    }

    /// A pixel whose brightest channel is at or below this (0–255) is dark ink: black, dark grey, navy, deep brown. A brand colour
    /// (a bright brand red or blue) has a bright channel and is never dark ink.
    static let darkInkMaxChannel = 102
    /// Share of the opaque ink (alpha-weighted) that is dark ink from which the whole logo is drawn as a white silhouette.
    static let wholeSilhouetteInkShare = 0.85
    /// Share from which only the dark ink is whitened and the colour marks stay: a dark wordmark beside a coloured symbol.
    /// Below it the logo is left alone: dark lettering on a colour or light plate reads on that plate.
    static let inkOnlyShare = 0.5
    /// The same, for a logo drawn on a see-through background (at least ``seeThroughShare`` of it empty): its dark ink sits straight on
    /// the guide, not on a plate, so even a small black wordmark or thin "NEWS" line beside a colour mark is whitened.
    static let seeThroughInkOnlyShare = 0.3
    static let seeThroughShare = 0.2

    /// The guide's theme, which decides what ink clashes with the background: dark ink on the dark theme, near-white ink on the light one.
    enum Theme: String, Sendable { case dark, light }

    /// Ink that disappears on `theme`'s background: black, dark grey, navy on dark; white and near-white on light (all three channels
    /// at least ``lightInkMinChannel``). Brand colours are neither.
    static func clashes(_ r: UInt8, _ g: UInt8, _ b: UInt8, on theme: Theme) -> Bool {
        switch theme {
        case .dark: Int(max(r, g, b)) <= darkInkMaxChannel
        case .light: Int(min(r, g, b)) >= lightInkMinChannel
        }
    }
    static let lightInkMinChannel = 190
    /// What clashing ink on the light theme is redrawn as.
    static let lightThemeInk: (UInt8, UInt8, UInt8) = (24, 24, 26)

    /// How a logo is drawn on the dark guide, decided once per logo from its pixels.
    enum InkTreatment: Equatable {
        case unchanged
        /// All ink is dark: drawn as a white silhouette.
        case whole
        /// A dark wordmark with colour marks: the dark ink becomes white, the marks keep their colours.
        case inkOnly
    }

    /// The treatment for the logo's opaque pixels (each weighted by its alpha, so faint halos barely count); `unchanged` for an image
    /// with no ink.
    static func inkTreatment(_ pixels: ChannelLogoPixels, theme: Theme = .dark) -> InkTreatment {
        treatment(for: inkShare(pixels, theme: theme))
    }

    static func treatment(for measured: (share: Double, seeThrough: Bool)?) -> InkTreatment {
        guard let measured else { return .unchanged }
        if measured.share >= wholeSilhouetteInkShare { return .whole }
        return measured.share >= (measured.seeThrough ? seeThroughInkOnlyShare : inkOnlyShare) ? .inkOnly : .unchanged
    }

    /// The alpha-weighted share of the opaque ink that clashes with `theme`'s background, and whether the logo is drawn on a see-through
    /// background; nil when there is no ink.
    static func inkShare(_ pixels: ChannelLogoPixels, theme: Theme = .dark) -> (share: Double, seeThrough: Bool)? {
        var dark = 0, total = 0, empty = 0
        pixels.bytes.withUnsafeBufferPointer { bytes in
            var index = 0
            while index < bytes.count {
                let alpha = Int(bytes[index + 3])
                if alpha <= trimAlphaThreshold { empty += 1 }
                if alpha > trimAlphaThreshold {
                    total += alpha
                    if clashes(bytes[index], bytes[index + 1], bytes[index + 2], on: theme) { dark += alpha }
                }
                index += 4
            }
        }
        guard total > 0 else { return nil }
        return (Double(dark) / Double(total), Double(empty) / Double(pixels.width * pixels.height) >= seeThroughShare)
    }

    /// The pixels with every dark-ink pixel turned white (its alpha kept); colour and light pixels are untouched.
    static func whiteningDarkInk(_ pixels: ChannelLogoPixels, theme: Theme = .dark, protecting kept: [Bool]? = nil) -> ChannelLogoPixels {
        var bytes = pixels.bytes
        var index = 0
        let ink: (UInt8, UInt8, UInt8) = theme == .dark ? (255, 255, 255) : lightThemeInk
        while index < bytes.count {
            if clashes(bytes[index], bytes[index + 1], bytes[index + 2], on: theme), !(kept?[index / 4] ?? false) {
                bytes[index] = ink.0
                bytes[index + 1] = ink.1
                bytes[index + 2] = ink.2
            }
            index += 4
        }
        return ChannelLogoPixels(width: pixels.width, height: pixels.height, bytes: bytes) ?? pixels
    }

    /// Whether the whole logo is drawn as a light silhouette: its ink is dark (black, dark grey, navy), which would vanish on the dark
    /// plate. The provider flag forces the treatment.
    static func isDark(_ pixels: ChannelLogoPixels, providerRequestsDarkBackground: Bool, theme: Theme = .dark) -> Bool {
        theme == .dark && (providerRequestsDarkBackground || inkTreatment(pixels) == .whole)
    }

    /// Equal-area fit: wide and square logos cover the same share of `box`,
    /// then the result is clamped inside it.
    static func fittedSize(aspect: Double, in box: CGSize, areaFill: Double = areaFill) -> CGSize {
        guard aspect > 0, aspect.isFinite, box.width > 0, box.height > 0 else { return .zero }
        let height = (areaFill * Double(box.width) * Double(box.height) / aspect).squareRoot()
        let width = height * aspect
        let scale = min(1, Double(box.width) / width, Double(box.height) / height)
        return CGSize(width: width * scale, height: height * scale)
    }

    /// Guide-row geometry in points, derived from the 1080p reference row
    /// (252 × 82 plate, 164 × 52 logo box, 18.5 badge font) scaled to the actual cell.
    struct GuideGeometry: Equatable {
        static let referenceCellSize = CGSize(width: 252, height: 82)
        static let referenceBoxSize = CGSize(width: 164, height: 52)
        static let referenceBadgeFontSize: CGFloat = 18.5
        static let badgeWidthPerFontSize: CGFloat = 2.5

        let box: CGSize
        let badgeFontSize: CGFloat

        init(cellSize: CGSize) {
            let widthScale = cellSize.width / Self.referenceCellSize.width
            let heightScale = cellSize.height / Self.referenceCellSize.height
            box = CGSize(
                width: max(1, Self.referenceBoxSize.width * widthScale),
                height: max(1, Self.referenceBoxSize.height * heightScale)
            )
            badgeFontSize = Self.referenceBadgeFontSize * min(widthScale, heightScale)
        }

        /// The room the mockup reserves beside a logo for the 4K word: 2.5 font sizes.
        var badgeWidth: CGFloat { (badgeFontSize * Self.badgeWidthPerFontSize).rounded() }

        /// A badge's height (see `QualityBadge`).
        var badgeHeight: CGFloat { badgeFontSize * 1.34 }

        /// How far the badge rises above the logo's top edge, as a share of its own height (mockup `.pqc`: -22%).
        static let badgeRise: CGFloat = 0.22

        /// The width a badge draws at: its text, tracking and side padding (see `QualityBadge`).
        func badgeWidth(of text: String) -> CGFloat {
            let font = UIFont.systemFont(ofSize: badgeFontSize, weight: .bold)
            let textWidth = (text as NSString).size(withAttributes: [
                .font: font, .kern: badgeFontSize * 0.03
            ]).width
            return ceil(textWidth + badgeFontSize * 0.4)
        }

        /// Logo size for `aspect`; a badge beside the logo takes its width from the box.
        func logoSize(aspect: Double, hasBadge: Bool, inkFill: Double = 1) -> CGSize {
            logoSize(aspect: aspect, inkFill: inkFill, reservingBadgeWidth: hasBadge ? badgeWidth : 0)
        }

        /// Where the logo and the badge sit in the box (origin at its top-left), as in the mockup: the logo is centred
        /// and scaled uniformly (a wide logo gives up the badge's room); the badge starts at the logo's trailing edge
        /// and rises 22% of its height above the logo's top, so it never covers the logo.
        func layout(aspect: Double, badge: String?, inkFill: Double = 1) -> (logo: CGRect, badge: CGRect?) {
            let size = logoSize(aspect: aspect, inkFill: inkFill, reservingBadgeWidth: badge == nil ? 0 : badgeWidth)
            let logo = CGRect(
                x: (box.width - size.width) / 2, y: (box.height - size.height) / 2,
                width: size.width, height: size.height)
            guard let badge else { return (logo, nil) }
            return (logo, CGRect(
                x: logo.maxX, y: logo.minY - badgeHeight * Self.badgeRise,
                width: badgeWidth(of: badge), height: badgeHeight))
        }

        private func logoSize(aspect: Double, inkFill: Double, reservingBadgeWidth reserved: CGFloat) -> CGSize {
            let size = ChannelLogoExtraction.v2bSize(aspect: aspect, inkFill: inkFill, in: box)
            guard reserved > 0, size.width > 0 else { return size }
            let room = max(1, box.width - reserved)
            let scale = min(1, room / size.width)
            return CGSize(width: size.width * scale, height: size.height * scale)
        }
    }

    /// A logo prepared for the bare guide treatment.
    struct Prepared: @unchecked Sendable {
        /// The trimmed provider image in its own colours.
        let image: UIImage
        let aspect: Double
        let isDark: Bool
        /// The trimmed content is under ``ChannelLogoExtraction/lowQualityLongSide`` pixels on its long side:
        /// too small to draw crisply, so any better logo should win over it.
        let isLowQuality: Bool
        /// The share of the ink readable on the row; see ``readableInkShare(_:row:inkOverride:inkAlpha:)``.
        var readableShare: Double = 1
        /// The logo is not a quality icon, or still misses ``minimumReadableInkShare`` after recolouring: the channel's cleaned name is
        /// drawn as text in the logo slot instead. There is no plate.
        var needsTextFallback = false
        /// Ink share of the trimmed image's bounding box (see ``ChannelLogoExtraction/inkFill(_:)``); drives the v2b size.
        var inkFill: Double = 1
    }

    // MARK: Quality icons

    /// A quality icon has a see-through background (or one that strips cleanly), enough pixels and a sane shape. Anything else is a
    /// square provider tile, a low-resolution thumbnail or a boxed logo and is shown as text.
    static let minimumIconLongSide = 160
    /// The share of the trimmed icon that must be see-through; a strippable box leaves nothing see-through and fails this.
    static let minimumSeeThroughShare = 0.12
    static let acceptableIconAspect: ClosedRange<Double> = 0.25...8

    /// The row colours the contrast rule is judged against (sRGB 0-255).
    static let darkRowRGB: (Double, Double, Double) = (25, 25, 27)
    static let lightRowRGB: (Double, Double, Double) = (240, 240, 240)

    /// A logo passes when at least this share of its core ink (alpha-weighted, pixels at least half opaque, judged by the ink's own
    /// colour) has WCAG contrast of at least ``minimumInkContrast`` against the row. 3:1 is the WCAG minimum for graphical objects;
    /// 75% leaves room for brand colours that are mid-tone on one theme (a yellow or light-green mark on white, a red on black);
    /// below it a quarter of the logo is lost. Anti-aliased edge pixels (under half opaque) are excluded: they blend into any
    /// background and are not what the eye reads as the ink.
    static let minimumReadableInkShare = 0.75
    static let minimumInkContrast = 3.0
    static let coreInkMinAlpha = 128

    /// The original image must itself be at least this see-through: a logo that arrives on an opaque box (a tile) is not an icon even
    /// when the box strips cleanly and leaves transparency behind.
    static let minimumOriginalSeeThroughShare = 0.12

    /// The share of pixels that are not opaque.
    static func seeThroughShare(_ pixels: ChannelLogoPixels) -> Double {
        var clear = 0, index = 3
        while index < pixels.bytes.count {
            if Int(pixels.bytes[index]) < opaqueAlphaThreshold { clear += 1 }
            index += 4
        }
        return Double(clear) / Double(max(pixels.bytes.count / 4, 1))
    }

    /// Whether the stripped logo is a quality icon.
    static func isQualityIcon(_ pixels: ChannelLogoPixels) -> Bool {
        guard let trim = trimRect(pixels), max(trim.width, trim.height) >= minimumIconLongSide else { return false }
        guard acceptableIconAspect.contains(Double(trim.width) / Double(trim.height)) else { return false }
        var seeThrough = 0, total = 0
        for y in trim.y..<(trim.y + trim.height) {
            var index = (y * pixels.width + trim.x) * 4 + 3
            for _ in 0..<trim.width {
                if Int(pixels.bytes[index]) < opaqueAlphaThreshold { seeThrough += 1 }
                total += 1
                index += 4
            }
        }
        return Double(seeThrough) / Double(max(total, 1)) >= minimumSeeThroughShare
    }

    /// sRGB channel (0-255) to linear light, tabulated: scoring a logo reads a million pixels, so no `pow` per pixel.
    private static let linearLight: [Double] = (0...255).map { c in
        let v = Double(c) / 255
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func relativeLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func lin(_ c: Double) -> Double {
            let i = min(255, max(0, Int(c.rounded())))
            return linearLight[i]
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// The share of `pixels`' core ink with contrast >= ``minimumInkContrast`` against `row`; 1 when there is no ink.
    static func readableInkShare(_ pixels: ChannelLogoPixels, row: (Double, Double, Double), inkOverride: (Double, Double, Double)? = nil, inkAlpha: Double = 1) -> Double {
        let rowL = relativeLuminance(row.0, row.1, row.2)
        var good = 0.0, total = 0.0, index = 0
        while index < pixels.bytes.count {
            let alpha = Int(pixels.bytes[index + 3])
            if alpha >= coreInkMinAlpha {
                let ink = inkOverride ?? (Double(pixels.bytes[index]), Double(pixels.bytes[index + 1]), Double(pixels.bytes[index + 2]))
                let a = inkAlpha
                let l = relativeLuminance(ink.0 * a + row.0 * (1 - a), ink.1 * a + row.1 * (1 - a), ink.2 * a + row.2 * (1 - a))
                let ratio = (max(l, rowL) + 0.05) / (min(l, rowL) + 0.05)
                let weight = Double(alpha) / 255
                total += weight
                if ratio >= minimumInkContrast { good += weight }
            }
            index += 4
        }
        return total == 0 ? 1 : good / total
    }

    /// Whether `pixels`, drawn as they are (a white silhouette at 90% when `silhouette`), read on the theme's row.
    static func readableShare(_ pixels: ChannelLogoPixels, silhouette: Bool, theme: Theme) -> Double {
        readableInkShare(
            pixels, row: theme == .dark ? darkRowRGB : lightRowRGB,
            inkOverride: silhouette ? (255, 255, 255) : nil, inkAlpha: silhouette ? 0.9 : 1)
    }

    /// Trimmed provider logos whose longer side is below this many pixels are low quality.
    static let lowQualityLongSide = 48

    /// Alpha (0–255) below which a pixel counts as see-through when deciding whether a logo is opaque.
    static let opaqueAlphaThreshold = 250

    /// True when no pixel is meaningfully transparent: JPEGs and flattened PNGs, whose
    /// background is part of the picture and has to be removed before trimming.
    static func isOpaque(_ pixels: ChannelLogoPixels) -> Bool {
        var index = 3
        while index < pixels.bytes.count {
            if Int(pixels.bytes[index]) < opaqueAlphaThreshold { return false }
            index += 4
        }
        return true
    }

    /// The share of see-through pixels below which an image still counts as a flattened,
    /// boxed logo: rounded corners and anti-aliased box edges are transparent in many PNGs.
    static let boxedTransparentFraction = 0.05

    /// True when almost no pixel is transparent: a logo drawn on a solid box, possibly with a
    /// few see-through corner or edge pixels, whose box must be removed before trimming.
    static func isMostlyOpaque(_ pixels: ChannelLogoPixels) -> Bool {
        let total = pixels.bytes.count / 4
        guard total > 0 else { return false }
        var transparent = 0
        var index = 3
        while index < pixels.bytes.count {
            if Int(pixels.bytes[index]) < opaqueAlphaThreshold { transparent += 1 }
            index += 4
        }
        return Double(transparent) / Double(total) <= boxedTransparentFraction
    }

    /// Decodes at natural size without colour management, removes a solid baked-in
    /// background from opaque images, then trims and classifies. Images larger than
    /// ``maximumPixelSize`` on a side are downsampled first. The aspect always comes
    /// from the image that is returned, so drawing it scaled uniformly cannot distort it.
    /// The decoded logo with a flat background box (white or black matte of a JPEG) removed: the pixels the ink analysis reads.
    static func withoutBackgroundBox(_ data: Data) -> (CGImage, ChannelLogoPixels)? {
        strippingBackground(data).map { ($0.image, $0.pixels) }
    }

    /// As ``withoutBackgroundBox(_:)``, plus the see-through share of the ORIGINAL image: a baked box that stripping removed still shows
    /// there as an (almost) fully opaque picture.
    static func strippingBackground(_ data: Data) -> (image: CGImage, pixels: ChannelLogoPixels, originalSeeThrough: Double)? {
        guard var cgImage = decode(data), var pixels = rgbaPixels(cgImage) else { return nil }
        let originalSeeThrough = seeThroughShare(pixels)
        if isMostlyOpaque(pixels),
           let stripped = UIImage(cgImage: cgImage).preparedAsHeroLogo()?.image.cgImage,
           let strippedPixels = rgbaPixels(stripped) {
            cgImage = stripped
            pixels = strippedPixels
        }
        // Logos that touch or are clipped by the image edge defeat the hero stripper's flat-border test:
        // a flat background that surrounds the logo is still a box and goes too.
        if isMostlyOpaque(pixels),
           let cleared = removingEdgeBackground(pixels), let clearedImage = makeImage(cleared) {
            cgImage = clearedImage
            pixels = cleared
        }
        return (cgImage, pixels, originalSeeThrough)
    }

    /// The theme-independent work on a logo, done once and cached: decode, background-box removal and the ink measurements for both
    /// themes. A theme's result is derived from it with ``prepare(analysis:providerRequestsDarkBackground:whitensMixedInk:theme:)``.
    // MARK: Region label

    /// The place printed under a network logo that several regional channels share (mockup "Layered" column): one medium line at
    /// 0.24 of the row height, 4 pt below the logo's ink, the logo and the label centred together as one block.
    struct RegionLabelStyle: Equatable {
        static let heightShare: CGFloat = 0.24
        /// The distance from the logo's ink bottom to the label's cap top, in points of the 1080 layout.
        static let inkGap: CGFloat = 4
        static let darkOpacity = 0.8
        static let lightOpacity = 0.72
        /// The text colour on a row of `theme`: white on the dark row, the light theme's ink on the light row.
        static func colour(for theme: Theme) -> (rgb: (Double, Double, Double), opacity: Double) {
            switch theme {
            case .dark: ((255, 255, 255), darkOpacity)
            case .light: ((Double(lightThemeInk.0), Double(lightThemeInk.1), Double(lightThemeInk.2)), lightOpacity)
            }
        }
        /// WCAG contrast of the label over the row it is drawn on.
        static func contrast(on theme: Theme) -> Double {
            let style = colour(for: theme)
            let row = theme == .dark ? darkRowRGB : lightRowRGB
            func blend(_ ink: Double, _ back: Double) -> Double { style.opacity * ink + (1 - style.opacity) * back }
            let text = relativeLuminance(blend(style.rgb.0, row.0), blend(style.rgb.1, row.1), blend(style.rgb.2, row.2))
            let back = relativeLuminance(row.0, row.1, row.2)
            return (max(text, back) + 0.05) / (min(text, back) + 0.05)
        }
    }

    /// The label's ink as Core Text measures it for a font: `bounds` relative to the baseline origin (y up), `advance` the typographic width.
    struct LabelInk: Equatable {
        var bounds: CGRect
        var advance: CGFloat
    }

    static func labelInk(_ text: String, font: UIFont) -> LabelInk {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return LabelInk(bounds: CTLineGetImageBounds(line, context), advance: advance)
    }

    /// Where the logo and the label sit in a guide cell (origin at its top-left). The logo is fitted to the cell's logo box (v2b size),
    /// the block is measured on INK (the logo's trimmed edge to the label's real glyph edges, descenders included) and centred in the
    /// visible cell, and the label's ink centre is centred horizontally with the logo's.
    struct LabelledLogoLayout: Equatable {
        var logo: CGRect
        var fontSize: CGFloat
        /// The label's baseline and how far its centred text box must move so the ink, not the advance, is centred.
        var baseline: CGFloat
        var inkShiftX: CGFloat
        var inkTop: CGFloat
        var inkBottom: CGFloat
    }

    /// The label font is `RegionLabelStyle.heightShare` of the cell height. The logo keeps its v2b size unless the block would not fit the
    /// cell's height, in which case the logo (never the gap) shrinks uniformly.
    static func labelledLayout(
        aspect: Double, inkFill: Double = 1, box: CGSize, cell: CGSize, labelInk measure: (UIFont) -> LabelInk
    ) -> LabelledLogoLayout {
        var fontSize = cell.height * RegionLabelStyle.heightShare
        var font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        var ink = measure(font)
        // The width is not exactly linear in the size (the system font switches optical size), so close in on the box.
        for _ in 0..<4 where ink.bounds.width > box.width + 0.25 && ink.bounds.width > 0 {
            fontSize *= box.width / ink.bounds.width * 0.995
            font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
            ink = measure(font)
        }
        var logo = v2bSize(aspect: aspect, inkFill: inkFill, in: box)
        let room = cell.height - RegionLabelStyle.inkGap - ink.bounds.height
        if logo.height > room, room > 0 {
            let scale = room / logo.height
            logo = CGSize(width: logo.width * scale, height: logo.height * scale)
        }
        let block = logo.height + RegionLabelStyle.inkGap + ink.bounds.height
        let top = (cell.height - block) / 2
        let inkTop = top + logo.height + RegionLabelStyle.inkGap
        let baseline = inkTop + ink.bounds.maxY
        return LabelledLogoLayout(
            logo: CGRect(x: (cell.width - logo.width) / 2, y: top, width: logo.width, height: logo.height),
            fontSize: fontSize, baseline: baseline,
            inkShiftX: ink.advance / 2 - (ink.bounds.minX + ink.bounds.width / 2),
            inkTop: inkTop, inkBottom: inkTop + ink.bounds.height)
    }

    // MARK: Name text layout

    /// How the channel's name is laid out when it stands in for a logo: one line if it fits, else two balanced lines broken at a word
    /// boundary (the break that minimises the longer line; a tie puts the leading words on line 1), never mid-word. `width` measures
    /// a string in the logo font at full size; the block then shrinks to `minimumNameScale` before line 2 is cut with an ellipsis.
    struct NameLayout: Equatable {
        var lines: [String]
        var scale: Double
        var truncatesLastLine: Bool
    }
    static let minimumNameScale = 0.8

    static func nameLayout(_ name: String, maxWidth: Double, width measure: (String) -> Double) -> NameLayout {
        let words = name.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return NameLayout(lines: [], scale: 1, truncatesLastLine: false) }
        let whole = words.joined(separator: " ")
        var lines = [whole]
        if measure(whole) > maxWidth, words.count > 1 {
            var best: (longer: Double, split: Int)?
            for split in 1..<words.count {
                let first = words[..<split].joined(separator: " "), second = words[split...].joined(separator: " ")
                let longer = max(measure(first), measure(second))
                if best == nil || longer < best!.longer - 0.0001 { best = (longer, split) }
            }
            if let best {
                lines = [words[..<best.split].joined(separator: " "), words[best.split...].joined(separator: " ")]
            }
        }
        let longest = lines.map(measure).max() ?? 0
        let scale = longest <= maxWidth ? 1 : max(minimumNameScale, maxWidth / longest)
        return NameLayout(lines: lines, scale: scale, truncatesLastLine: longest * scale > maxWidth + 0.0001)
    }

    // MARK: Filled shapes

    /// A clashing component is a compact filled shape (a tile or disc with a lighter letter inside), not a letter stroke, when it fills
    /// at least this share of its bounding box ...
    static let filledShapeMinFill = 0.55
    /// ... and at least this share of that box is opaque pixels that do not clash (the knocked-out letter).
    static let filledShapeMinCounter = 0.03

    /// Pixels (row-major) of clashing components that are filled shapes enclosing lighter counters; recolouring leaves them alone, so a
    /// navy tile with a white letter keeps its letter. `nil` when there are none. Runs once per logo in `analyze`.
    static func filledShapePixels(_ pixels: ChannelLogoPixels, theme: Theme) -> [Bool]? {
        let width = pixels.width, height = pixels.height
        let count = width * height
        var isInk = [Bool](repeating: false, count: count)
        var any = false
        pixels.bytes.withUnsafeBufferPointer { bytes in
            for i in 0..<count where Int(bytes[i * 4 + 3]) >= coreInkMinAlpha && clashes(bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], on: theme) {
                isInk[i] = true
                any = true
            }
        }
        guard any else { return nil }
        var visited = [Bool](repeating: false, count: count)
        var kept = [Bool](repeating: false, count: count)
        var keptAny = false
        var stack: [Int] = []
        for start in 0..<count where isInk[start] && !visited[start] {
            var members: [Int] = []
            var minX = width, maxX = 0, minY = height, maxY = 0
            stack.append(start)
            visited[start] = true
            while let i = stack.popLast() {
                members.append(i)
                let x = i % width, y = i / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if x > 0, isInk[i - 1], !visited[i - 1] { visited[i - 1] = true; stack.append(i - 1) }
                if x < width - 1, isInk[i + 1], !visited[i + 1] { visited[i + 1] = true; stack.append(i + 1) }
                if y > 0, isInk[i - width], !visited[i - width] { visited[i - width] = true; stack.append(i - width) }
                if y < height - 1, isInk[i + width], !visited[i + width] { visited[i + width] = true; stack.append(i + width) }
            }
            let box = (maxX - minX + 1) * (maxY - minY + 1)
            guard members.count >= 64, Double(members.count) / Double(box) >= filledShapeMinFill else { continue }
            var counters = 0
            pixels.bytes.withUnsafeBufferPointer { bytes in
                for y in minY...maxY {
                    for x in minX...maxX {
                        let i = y * width + x
                        if !isInk[i], Int(bytes[i * 4 + 3]) >= coreInkMinAlpha { counters += 1 }
                    }
                }
            }
            guard Double(counters) / Double(box) >= filledShapeMinCounter else { continue }
            for i in members { kept[i] = true }
            keptAny = true
        }
        return keptAny ? kept : nil
    }

    struct Analysis: @unchecked Sendable {
        let cgImage: CGImage
        let pixels: ChannelLogoPixels
        let darkShare: (share: Double, seeThrough: Bool)?
        let lightShare: (share: Double, seeThrough: Bool)?
        /// Measured once: see ``isQualityIcon(_:)``.
        let isQuality: Bool
        /// Filled shapes per theme (see ``filledShapePixels(_:theme:)``).
        let filledDark: [Bool]?
        let filledLight: [Bool]?
        /// Bytes held, for the cache's cost limit.
        var cost: Int { pixels.bytes.count }
    }

    static func analyze(data: Data) -> Analysis? {
        guard let stripped = strippingBackground(data) else { return nil }
        return Analysis(
            cgImage: stripped.image, pixels: stripped.pixels,
            darkShare: inkShare(stripped.pixels, theme: .dark), lightShare: inkShare(stripped.pixels, theme: .light),
            isQuality: stripped.originalSeeThrough >= minimumOriginalSeeThroughShare && isQualityIcon(stripped.pixels),
            filledDark: filledShapePixels(stripped.pixels, theme: .dark),
            filledLight: filledShapePixels(stripped.pixels, theme: .light))
    }

    /// The single rule for a matched network's logo: of the listed variants' results the one with the best readable share
    /// (ties keep the listed order, the default first), never replaced by the channel's name. Shared by the display loader and the
    /// sync-time artwork cache, so both draw the same variant.
    static func chosenNetworkVariant(among candidates: [Prepared]) -> Prepared? {
        var best: Prepared?
        for candidate in candidates where best == nil || candidate.readableShare > best!.readableShare + 0.0001 { best = candidate }
        guard var chosen = best else { return nil }
        chosen.needsTextFallback = false
        return chosen
    }

    static func prepare(
        data: Data, providerRequestsDarkBackground: Bool, whitensMixedInk: Bool = true, theme: Theme = .dark
    ) -> Prepared? {
        guard let analysis = analyze(data: data) else { return nil }
        return prepare(analysis: analysis, providerRequestsDarkBackground: providerRequestsDarkBackground,
                       whitensMixedInk: whitensMixedInk, theme: theme)
    }

    /// The theme's result from a cached analysis. Pixel work happens only for a recolour, the trim and the plate score.
    static func prepare(
        analysis: Analysis, providerRequestsDarkBackground: Bool, whitensMixedInk: Bool = true, theme: Theme = .dark
    ) -> Prepared {
        var cgImage = analysis.cgImage
        var pixels = analysis.pixels
        let filled = theme == .dark ? analysis.filledDark : analysis.filledLight
        var treatment = treatment(for: theme == .dark ? analysis.darkShare : analysis.lightShare)
        // A filled tile with a lighter letter must not become one white silhouette.
        if treatment == .whole, filled != nil { treatment = .inkOnly }
        let dark = theme == .dark && (providerRequestsDarkBackground || treatment == .whole)
        // A dark wordmark beside a colour mark: whiten the wordmark once here, so drawing stays a plain image (no per-frame work).
        if !dark, whitensMixedInk, treatment != .unchanged {
            let whitened = whiteningDarkInk(pixels, theme: theme, protecting: filled)
            if let image = makeImage(whitened) {
                cgImage = image
                pixels = whitened
            }
        }
        var result = cgImage
        if let trim = trimRect(pixels),
           let cropped = cgImage.cropping(to: CGRect(x: trim.x, y: trim.y, width: trim.width, height: trim.height)) {
            result = cropped
        }
        let readable = readableShare(pixels, silhouette: dark, theme: theme)
        return Prepared(
            image: UIImage(cgImage: result),
            aspect: Double(result.width) / Double(result.height),
            isDark: dark,
            isLowQuality: max(result.width, result.height) < lowQualityLongSide,
            readableShare: readable,
            needsTextFallback: !analysis.isQuality || readable < minimumReadableInkShare,
            inkFill: inkFill(pixels)
        )
    }

    static let maximumPixelSize = 1_024

    /// Squared colour distance (0–255 per channel) from the background colour that is cleared outright.
    private static let backgroundClearDistanceSquared = 45 * 45
    /// Beyond this squared distance a pixel is fully logo; between the two the alpha is graded.
    private static let backgroundKeepDistanceSquared = 120 * 120
    /// Share of the image's edge pixels one colour must cover to count as the background.
    private static let backgroundEdgeShare = 0.4

    /// Clears a flat background that touches the image edge, reaching only pixels connected to the edge, so
    /// colour inside the logo (white letters in a blue outline) stays. The background colour is the dominant
    /// (quantised) colour of the edge pixels, which must cover ``backgroundEdgeShare`` of them. Returns `nil`
    /// when there is no such background or it would erase the logo.
    static func removingEdgeBackground(_ pixels: ChannelLogoPixels) -> ChannelLogoPixels? {
        let width = pixels.width, height = pixels.height
        guard width > 2, height > 2 else { return nil }
        let edge: [Int] = (0..<width).flatMap { [$0, (height - 1) * width + $0] }
            + (1..<(height - 1)).flatMap { [$0 * width, $0 * width + width - 1] }
        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for index in edge {
            let o = index * 4
            let key = Int(pixels.bytes[o] >> 4) << 8 | Int(pixels.bytes[o + 1] >> 4) << 4 | Int(pixels.bytes[o + 2] >> 4)
            var bin = bins[key] ?? (0, 0, 0, 0)
            bin.count += 1
            bin.r += Int(pixels.bytes[o]); bin.g += Int(pixels.bytes[o + 1]); bin.b += Int(pixels.bytes[o + 2])
            bins[key] = bin
        }
        guard let best = bins.values.max(by: { $0.count < $1.count }),
              Double(best.count) >= backgroundEdgeShare * Double(edge.count) else { return nil }
        let bg = (r: best.r / best.count, g: best.g / best.count, b: best.b / best.count)
        func distance(_ index: Int) -> Int {
            let o = index * 4
            let dr = Int(pixels.bytes[o]) - bg.r, dg = Int(pixels.bytes[o + 1]) - bg.g, db = Int(pixels.bytes[o + 2]) - bg.b
            return dr * dr + dg * dg + db * db
        }
        var cleared = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for index in edge where distance(index) <= backgroundClearDistanceSquared && !cleared[index] {
            cleared[index] = true
            stack.append(index)
        }
        while let index = stack.popLast() {
            let x = index % width, y = index / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let next = ny * width + nx
                if !cleared[next], distance(next) <= backgroundClearDistanceSquared {
                    cleared[next] = true
                    stack.append(next)
                }
            }
        }
        var bytes = pixels.bytes
        var removed = 0
        for index in 0..<(width * height) {
            let o = index * 4
            if cleared[index] {
                bytes[o] = 0; bytes[o + 1] = 0; bytes[o + 2] = 0; bytes[o + 3] = 0
                removed += 1
                continue
            }
            // Anti-aliased rim: a pixel touching the cleared region fades in with its distance from the background.
            let x = index % width, y = index / width
            let touches = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].contains { nx, ny in
                nx >= 0 && ny >= 0 && nx < width && ny < height && cleared[ny * width + nx]
            }
            let d = distance(index)
            if touches, d < backgroundKeepDistanceSquared {
                let t = Double(d - backgroundClearDistanceSquared)
                    / Double(backgroundKeepDistanceSquared - backgroundClearDistanceSquared)
                bytes[o + 3] = UInt8(max(0, min(255, (t * 255).rounded())))
            }
        }
        // Nothing to do, or the "background" was the logo.
        guard removed > 0, removed * 20 < width * height * 19 else { return nil }
        return ChannelLogoPixels(width: width, height: height, bytes: bytes)
    }

    /// A CGImage from straight-alpha pixels.
    static func makeImage(_ pixels: ChannelLogoPixels) -> CGImage? {
        var premultiplied = pixels.bytes
        var index = 0
        while index < premultiplied.count {
            let alpha = Int(premultiplied[index + 3])
            if alpha < 255 {
                for channel in 0..<3 {
                    premultiplied[index + channel] = UInt8((Int(premultiplied[index + channel]) * alpha + 127) / 255)
                }
            }
            index += 4
        }
        return premultiplied.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(
                data: raw.baseAddress, width: pixels.width, height: pixels.height, bitsPerComponent: 8,
                bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let longestSide = max(
            (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0,
            (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        )
        if longestSide > maximumPixelSize {
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// Raw device-RGB pixels (no colour conversion), un-premultiplied.
    static func rgbaPixels(_ image: CGImage) -> ChannelLogoPixels? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var index = 0
        while index < bytes.count {
            let alpha = Int(bytes[index + 3])
            if alpha > 0, alpha < 255 {
                for channel in 0..<3 {
                    bytes[index + channel] = UInt8(min(255, (Int(bytes[index + channel]) * 255 + alpha / 2) / alpha))
                }
            }
            index += 4
        }
        return ChannelLogoPixels(width: width, height: height, bytes: bytes)
    }
}

/// Loads provider logo bytes through the shared artwork session, analyses each logo once (theme independent, cached), derives the
/// theme's result from that analysis. A result is saved on disk (``PreparedChannelLogoStore``) and never recomputed; the other theme
/// is derived only when the theme is actually asked for. The work is
/// off the main thread, de-duplicated per key and bounded to ``maximumConcurrentPrepares`` at a time.
actor ChannelLogoExtractionLoader {
    static let shared = ChannelLogoExtractionLoader()

    /// At most this many logos are analysed or derived at once (a cold guide page can ask for hundreds).
    static let maximumConcurrentPrepares = 3

    private struct Key: Hashable {
        let url: URL
        let providerRequestsDarkBackground: Bool
        let theme: ChannelLogoExtraction.Theme
    }

    private final class Entry {
        let prepared: ChannelLogoExtraction.Prepared
        init(_ prepared: ChannelLogoExtraction.Prepared) { self.prepared = prepared }
    }

    private final class AnalysisEntry {
        let analysis: ChannelLogoExtraction.Analysis
        init(_ analysis: ChannelLogoExtraction.Analysis) { self.analysis = analysis }
    }

    /// Both themes live here, so the limit is twice the one-theme count.
    private static let memo: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 800
        return cache
    }()

    /// The analysis keeps the decoded pixels (up to megabytes each), so it is bounded by bytes.
    private static let analyses: NSCache<NSString, AnalysisEntry> = {
        let cache = NSCache<NSString, AnalysisEntry>()
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 200
        return cache
    }()

    private var inFlight: [Key: Task<ChannelLogoExtraction.Prepared?, Never>] = [:]
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Counters for the benchmark and the cache guard test.
    nonisolated(unsafe) static var decodeCount = 0
    nonisolated(unsafe) static var peakConcurrency = 0
    /// Pixel preparations run (not counting results read back from disk).
    nonisolated(unsafe) static var preparedCount = 0

    private static func memoKey(_ url: URL, _ dark: Bool, _ theme: ChannelLogoExtraction.Theme) -> NSString {
        "\(dark ? 1 : 0)|\(theme.rawValue)|\(url.absoluteString)" as NSString
    }

    /// Synchronous lookup so a recycled row does not flash empty.
    nonisolated static func cached(
        url: URL, providerRequestsDarkBackground: Bool, theme: ChannelLogoExtraction.Theme = .dark
    ) -> ChannelLogoExtraction.Prepared? {
        memo.object(forKey: memoKey(url, providerRequestsDarkBackground, theme))?.prepared
    }

    /// Puts an already prepared logo in the synchronous cache, so a hosted render of the guide logo needs no download.
    nonisolated static func seed(
        _ prepared: ChannelLogoExtraction.Prepared, url: URL, providerRequestsDarkBackground: Bool, theme: ChannelLogoExtraction.Theme
    ) {
        memo.setObject(Entry(prepared), forKey: memoKey(url, providerRequestsDarkBackground, theme))
    }

    /// The persisted result for `key`, read and decoded under the concurrency gate; `nil` when none was saved.
    private func storedPrepared(_ key: String) async -> ChannelLogoExtraction.Prepared? {
        await acquire()
        let stored = await Task.detached(priority: .userInitiated) { PreparedChannelLogoStore.load(key: key) }.value
        release()
        return stored
    }

    private func acquire() async {
        if running < Self.maximumConcurrentPrepares { running += 1; Self.peakConcurrency = max(Self.peakConcurrency, running); return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }

    /// The analysis of `url`'s logo: from the cache, else decoded once from the stored bytes.
    private func analysis(for url: URL) async -> ChannelLogoExtraction.Analysis? {
        let key = url.absoluteString as NSString
        if let hit = Self.analyses.object(forKey: key) { return hit.analysis }
        // Logos are kept permanently, so each is downloaded once.
        guard let data = await LiveTVLogoImageStore.shared.data(for: url) else { return nil }
        await acquire()
        let analysed = await Task.detached(priority: .userInitiated) { () -> ChannelLogoExtraction.Analysis? in
            Self.decodeCount += 1
            return ChannelLogoExtraction.analyze(data: data)
        }.value
        release()
        if let analysed { Self.analyses.setObject(AnalysisEntry(analysed), forKey: key, cost: analysed.cost) }
        return analysed
    }

    func prepared(
        url: URL, providerRequestsDarkBackground: Bool, theme: ChannelLogoExtraction.Theme = .dark
    ) async -> ChannelLogoExtraction.Prepared? {
        if let variants = LiveTVNetworkLogoRegistry.shared.variants(for: url) {
            return await preparedNetworkLogo(url: url, variants: variants, providerRequestsDarkBackground: providerRequestsDarkBackground, theme: theme)
        }
        return await preparedLogo(url: url, providerRequestsDarkBackground: providerRequestsDarkBackground, theme: theme)
    }

    /// A matched network's logo is always drawn: the listed variant with the best readable share on the theme (ties keep the listed
    /// order, the default first), recoloured only, never the channel's name. Memoised under the default URL like any logo.
    private func preparedNetworkLogo(
        url: URL, variants: [URL], providerRequestsDarkBackground: Bool, theme: ChannelLogoExtraction.Theme
    ) async -> ChannelLogoExtraction.Prepared? {
        if let hit = Self.cached(url: url, providerRequestsDarkBackground: providerRequestsDarkBackground, theme: theme) { return hit }
        let storeKey = PreparedChannelLogoStore.key(
            url: url, variants: variants, providerRequestsDarkBackground: providerRequestsDarkBackground, theme: theme)
        if let stored = await storedPrepared(storeKey) {
            Self.memo.setObject(Entry(stored), forKey: Self.memoKey(url, providerRequestsDarkBackground, theme))
            return stored
        }
        var candidates: [ChannelLogoExtraction.Prepared] = []
        for variant in variants.prefix(5) {
            guard let candidate = await preparedLogo(
                url: variant, providerRequestsDarkBackground: providerRequestsDarkBackground, theme: theme, memoise: false)
            else { continue }
            candidates.append(candidate)
        }
        guard let chosen = ChannelLogoExtraction.chosenNetworkVariant(among: candidates) else { return nil }
        #if DEBUG
        if chosen.readableShare < ChannelLogoExtraction.minimumReadableInkShare {
            print("LIVE_TV event=networkLogoLowContrast share=\(Int(chosen.readableShare * 100)) theme=\(theme.rawValue)")
        }
        #endif
        Self.memo.setObject(Entry(chosen), forKey: Self.memoKey(url, providerRequestsDarkBackground, theme))
        PreparedChannelLogoStore.save(chosen, key: storeKey)
        return chosen
    }

    private func preparedLogo(
        url: URL, providerRequestsDarkBackground: Bool, theme: ChannelLogoExtraction.Theme, memoise: Bool = true
    ) async -> ChannelLogoExtraction.Prepared? {
        if let hit = Self.cached(url: url, providerRequestsDarkBackground: providerRequestsDarkBackground, theme: theme) {
            return hit
        }
        let key = Key(url: url, providerRequestsDarkBackground: providerRequestsDarkBackground, theme: theme)
        let task: Task<ChannelLogoExtraction.Prepared?, Never>
        if let running = inFlight[key] {
            task = running
        } else {
            task = Task { [self] in
                // Prepared output is final for (logo, flag, theme): read it back before any decode or pixel work.
                let storeKey = PreparedChannelLogoStore.key(
                    url: url, variants: nil, providerRequestsDarkBackground: providerRequestsDarkBackground, theme: theme)
                if memoise, let stored = await storedPrepared(storeKey) { return stored }
                guard let analysis = await analysis(for: url) else { return nil }
                await acquire()
                let result = await Task.detached(priority: .userInitiated) {
                    Self.preparedCount += 1
                    return ChannelLogoExtraction.prepare(
                        analysis: analysis, providerRequestsDarkBackground: providerRequestsDarkBackground, theme: theme)
                }.value
                release()
                if memoise { PreparedChannelLogoStore.save(result, key: storeKey) }
                return result
            }
            inFlight[key] = task
        }
        let result = await task.value
        inFlight[key] = nil
        if let result, memoise {
            Self.memo.setObject(Entry(result), forKey: Self.memoKey(url, providerRequestsDarkBackground, theme))
        }
        return result
    }
}
#endif
