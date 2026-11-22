#if os(tvOS)
import CoreUI
import FeatureLiveTVCore
import SwiftUI

/// What the matchup card at the top of the right channel panel shows for a two-team event.
struct LiveTVGlassMatchup: Equatable {
    var leftTeam: String
    var rightTeam: String
    /// Crests, left then right, from the teams' Wikidata logos; `nil` (or empty) draws the league layout for that side.
    var crests: [URL?]
    /// The league badge when the resolver found it; otherwise the league's sport glyph is drawn.
    var leagueBadgeURL: URL?
    var glyphSymbol: String
    /// Only for `A @ B`: the left team visits. `A vs. B` names no home side, so the AWAY and HOME labels are not drawn.
    var hasAwayHome: Bool
    var isLive: Bool
    /// "6:30 PM" when the event has not started.
    var startText: String?
}

/// Design 3's matchup card: two halves tinted per team with the crest, name and AWAY/HOME label, and a centre pill with the league
/// badge and LIVE or the start time.
struct LiveTVGlassMatchupCard: View {
    let matchup: LiveTVGlassMatchup

    private static let height: CGFloat = 259
    private static let crestSide: CGFloat = 110

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                half(name: matchup.leftTeam, crest: matchup.crests.first ?? nil, label: matchup.hasAwayHome ? "AWAY" : nil, tint: .left)
                Rectangle().fill(.white.opacity(0.2)).frame(width: 2)
                half(name: matchup.rightTeam, crest: matchup.crests.dropFirst().first ?? nil, label: matchup.hasAwayHome ? "HOME" : nil, tint: .right)
            }
            centre
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(matchup.leftTeam) versus \(matchup.rightTeam)", comment: "Accessibility label of the sports matchup card. The first and second %@ are team names."))
    }

    private enum Side { case left, right }

    /// The two halves must differ: crest colours are not available, so each side gets a fixed contrasting tint, with the divider above.
    private func half(name: String, crest: URL?, label: LocalizedStringKey?, tint: Side) -> some View {
        VStack(spacing: 6) {
            if let crest {
                ChannelLogoArtwork(
                    name: "", logoURL: crest, size: CGSize(width: Self.crestSide, height: Self.crestSide), cornerRadius: 0,
                    artworkInset: 0, style: .bare()
                )
                .frame(width: Self.crestSide, height: Self.crestSide)
            }
            Text(name)
                .font(.system(size: 30, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
            if let label {
                Text(label)
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .background(tint == .left ? Color(red: 0.12, green: 0.22, blue: 0.45) : Color(red: 0.08, green: 0.28, blue: 0.38))
    }

    private var centre: some View {
        VStack(spacing: 6) {
            if let badge = matchup.leagueBadgeURL {
                ChannelLogoArtwork(name: "", logoURL: badge, size: CGSize(width: 56, height: 40), cornerRadius: 0, artworkInset: 0, style: .bare())
                    .frame(width: 56, height: 40)
            } else {
                Image(systemName: matchup.glyphSymbol).font(.system(size: 32, weight: .semibold))
            }
            if matchup.isLive {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 12, height: 12)
                    Text("LIVE", comment: "Badge on the sports matchup card while the event is on.").font(.system(size: 18, weight: .heavy)).tracking(2)
                }
            } else if let start = matchup.startText {
                Text(start).font(.system(size: 20, weight: .semibold))
            }
            Text("VS", comment: "Between the two team names on the sports matchup card.")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
#endif
