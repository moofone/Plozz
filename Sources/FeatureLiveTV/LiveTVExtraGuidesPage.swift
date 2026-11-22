import CoreUI
import FeatureLiveTVCore
import SwiftUI

/// Settings → Live TV → (source) → Extra Guides: XMLTV addresses that fill channels the provider's guide has no listings for.
struct LiveTVExtraGuidesPage: View {
    let model: LiveTVExtraGuidesModel
    let accountID: String
    let sourceName: String
    @State private var address = ""

    var body: some View {
        LiveTVSettingsPage(title: "Extra Guides", sourceName: sourceName) {
            let entries = model.entries(accountID: accountID) ?? []
            if !entries.isEmpty {
                SettingsSectionGroup("Guides") {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: entry.url.absoluteString)
                                .lineLimit(2)
                                .privacySensitive()
                            status(of: entry)
                                .font(.caption)
                                .settingsRowSecondary()
                            Button(role: .destructive) {
                                model.remove(entry.url, accountID: accountID)
                            } label: {
                                LiveTVSetupActionLabel(title: "Remove guide", symbol: "minus.circle")
                            }
                            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                            .accessibilityIdentifier("live-tv-remove-extra-guide")
                        }
                    }
                }
            }
            SettingsSectionGroup("Add a guide") {
                LiveTVSetupField(
                    title: "XMLTV guide URL", text: $address, isAddress: true,
                    identifier: "live-tv-extra-guide-address", example: "https://example.com/guide.xml.gz"
                )
                Button {
                    if model.add(address: address, accountID: accountID) { address = "" }
                } label: {
                    LiveTVSetupActionLabel(title: "Add guide", symbol: "plus")
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || entries.count >= LiveTVExtraGuidesModel.maximumGuides)
                .accessibilityIdentifier("live-tv-add-extra-guide")
                if let issue = model.issue { Text(issue.message) }
            } footer: {
                Text("Listings from these guides fill channels your provider's guide doesn't cover. XMLTV or .xml.gz.")
            }
        }
        .onAppear {
            model.clearIssue()
            model.refresh()
        }
    }

    @ViewBuilder
    private func status(of entry: LiveTVExtraGuidesModel.Entry) -> some View {
        if entry.couldNotLoad {
            Text("Couldn't load")
        } else if let date = entry.loadedAt {
            if let count = entry.channelCount {
                Text("Loaded \(date, format: .dateTime.month().day().hour().minute()) · \(count) channels")
            } else {
                Text("Loaded \(date, format: .dateTime.month().day().hour().minute())")
            }
        } else {
            Text("Not loaded yet")
        }
    }
}
