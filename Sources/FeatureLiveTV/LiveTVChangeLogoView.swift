import CoreModels
import CoreUI
import FeatureLiveTVCore
import MetadataKit
import SwiftUI

/// Lets the viewer pick a different logo for one channel: a TMDB network found by
/// name, an image URL, or a return to the automatic choice. The current logo is drawn
/// above through the same logo view the guide uses, so it is never stretched.
struct LiveTVChangeLogoView: View {
    @Bindable var model: LiveTVPrototypeModel
    let channel: LiveTVPrototypeChannel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [LiveTVLogoNetworkResult] = []
    @State private var isSearching = false
    @State private var urlText = ""
    @State private var issue: Issue?
    @State private var isApplying = false

    private enum Issue {
        case network, url

        var message: Text {
            switch self {
            case .network: Text("That logo couldn't be loaded from TMDB. Try again later.")
            case .url: Text("Enter a web address starting with http:// or https://, without a user name or password.")
            }
        }
    }

    var body: some View {
        LiveTVSettingsPage(title: "Change Logo") {
            previewSection
            if model.isTMDbLogoAccessEnabled {
                searchSection
            }
            urlSection
            if model.hasLogoOverride(channel) { resetSection }
            if let issue {
                InlineErrorMessage(issue.message)
            }
        }
        .accessibilityIdentifier("live-tv-change-logo")
    }

    // MARK: Sections

    private var previewSection: some View {
        SettingsSectionGroup {
            PrototypeStationMark(
                channel: channel, plateSize: CGSize(width: 252, height: 82),
                cornerRadius: PrototypeLayout.rowRadius, usesBareLogo: true
            )
            .environment(model)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Current logo for \(channel.name)"))
        }
    }

    private var searchSection: some View {
        SettingsSectionGroup {
            LiveTVSetupField(title: "Search TMDB networks", text: $query, identifier: "live-tv-logo-search")
            if isSearching {
                ProgressView().frame(maxWidth: .infinity)
            }
            ForEach(results) { result in
                Button { choose(result.entry) } label: {
                    LiveTVLogoNetworkRow(model: model, result: result)
                }
                .buttonStyle(SettingsFormButtonStyle())
                .disabled(isApplying)
            }
        }
        .task(id: query) { await search() }
    }

    private var urlSection: some View {
        SettingsSectionGroup {
            LiveTVSetupField(
                title: "Enter Image URL", text: $urlText, isAddress: true,
                identifier: "live-tv-logo-url", example: "https://example.com/logo.png"
            )
            Button {
                chooseURL()
            } label: {
                LiveTVSetupActionLabel(title: "Use This Image", symbol: "photo")
            }
            .buttonStyle(SettingsFormButtonStyle())
            .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var resetSection: some View {
        SettingsSectionGroup {
            Button {
                model.resetLogo(for: channel)
                dismiss()
            } label: {
                LiveTVSetupActionLabel(title: "Reset to Automatic", symbol: "arrow.counterclockwise")
            }
            .buttonStyle(SettingsFormButtonStyle())
            .accessibilityIdentifier("live-tv-logo-reset")
        }
    }

    // MARK: Actions

    private func search() async {
        issue = nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        // Typing pauses before a search runs, so every keystroke is not one.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let found = await model.searchLogoNetworks(trimmed)
        guard !Task.isCancelled else { return }
        results = found
        isSearching = false
    }

    private func choose(_ entry: TMDbNetworkEntry) {
        isApplying = true
        issue = nil
        Task {
            let applied = await model.chooseLogoNetwork(entry.id, for: channel)
            isApplying = false
            if applied { dismiss() } else { issue = .network }
        }
    }

    private func chooseURL() {
        if model.chooseLogoURL(urlText, for: channel) {
            dismiss()
        } else {
            issue = .url
        }
    }
}

/// One search result: the network's logo, name and country.
private struct LiveTVLogoNetworkRow: View {
    let model: LiveTVPrototypeModel
    let result: LiveTVLogoNetworkResult
    @State private var logo: TMDbNetworkLogo?

    var body: some View {
        HStack(spacing: 20) {
            ChannelLogoArtwork(
                name: result.entry.name, logoURL: logo?.logoURL, size: CGSize(width: 140, height: 56),
                cornerRadius: 8, artworkInset: 0, style: .bare()
            )
            .frame(width: 140, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: result.entry.name).lineLimit(1)
                if let country = logo?.originCountry {
                    Text(verbatim: country).font(.caption).settingsRowSecondary()
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityName))
        .task { logo = await model.logoNetwork(id: result.id) }
    }

    private var accessibilityName: String {
        [result.entry.name, logo?.originCountry].compactMap { $0 }.joined(separator: ", ")
    }
}
