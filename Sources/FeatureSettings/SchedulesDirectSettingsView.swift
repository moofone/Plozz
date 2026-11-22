#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SchedulesDirectService
import SwiftUI

/// Live TV › Guide Data › Schedules Direct. Only reachable when
/// `RuntimeFeatureFlag.schedulesDirect` is on.
struct SchedulesDirectSettingsView: View {
    @State private var model: SchedulesDirectSettingsModel
    @State private var username = ""
    @State private var password = ""

    init(service: SchedulesDirectService) {
        _model = State(initialValue: SchedulesDirectSettingsModel(service: service))
    }

    var body: some View {
        LiveTVPreferencesPage(title: "Schedules Direct") {
            if model.state.isSignedIn {
                signedIn
            } else {
                signedOut
            }
        }
        .task { await model.reload() }
    }

    // MARK: Signed out

    @ViewBuilder private var signedOut: some View {
        SettingsSectionGroup("Schedules Direct") {
            Text("Sign in with your existing Schedules Direct account.")
            SettingsInputRow("Username") {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("schedules-direct-username")
            }
            SettingsInputRow("Password") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("schedules-direct-password")
            }
            Button {
                Task { if await model.signIn(username: username, password: password) { password = "" } }
            } label: {
                HStack {
                    if model.isWorking { ProgressView() }
                    Text("Sign In")
                }
            }
            .buttonStyle(SettingsFormButtonStyle())
            .disabled(model.isWorking || username.isEmpty || password.isEmpty)
            .accessibilityIdentifier("schedules-direct-sign-in")
        } footer: {
            Text("Requires your own membership. Plozz isn't affiliated with Schedules Direct.")
        }
        failureView
    }

    // MARK: Signed in

    @ViewBuilder private var signedIn: some View {
        if let attention = model.state.attention {
            SettingsSectionGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Schedules Direct needs attention", systemImage: "exclamationmark.triangle.fill")
                    Text(verbatim: attention.message).settingsRowSecondary()
                    Button("Reconnect") { Task { await model.reconnect() } }
                        .buttonStyle(SettingsFormButtonStyle())
                        .disabled(model.isWorking)
                }
            }
        }
        SettingsSectionGroup("Account") {
            HStack {
                Text("Account")
                Spacer()
                Text(verbatim: model.state.username ?? "").settingsRowSecondary()
            }
            if let expires = model.state.account?.expires {
                HStack {
                    Text("Membership ends")
                    Spacer()
                    Text(expires, format: .dateTime.year().month().day()).settingsRowSecondary()
                }
            }
        }
        SettingsSectionGroup("Lineups") {
            let lineups = model.state.account?.lineups ?? []
            if lineups.isEmpty {
                Text("No lineups yet.").settingsRowSecondary()
            }
            ForEach(lineups) { lineup in
                HStack(spacing: 16) {
                    Text(verbatim: lineup.name ?? lineup.lineup).lineLimit(2)
                    Spacer()
                    Button("Remove") { Task { await model.remove(lineup: lineup.lineup) } }
                        .plozzActionButton(role: .secondary)
                        .disabled(model.isWorking)
                        .accessibilityLabel(Text("Remove \(lineup.name ?? lineup.lineup)"))
                }
            }
            if lineups.count < 4 {
                SettingsPageLink {
                    SchedulesDirectAddLineupView(model: model)
                } label: {
                    SettingsDisclosureLabel { Label("Add Lineup…", systemImage: "plus") }
                }
                .settingsActionRow()
                .accessibilityIdentifier("schedules-direct-add-lineup")
            }
        } footer: {
            if let remaining = model.state.account?.changesRemaining {
                Text("Lineup changes remaining: \(remaining)")
            }
        }
        SettingsSectionGroup("Sync") {
            HStack {
                Text("Last sync")
                Spacer()
                lastSyncValue
            }
            Button {
                Task { await model.syncNow() }
            } label: {
                HStack {
                    if model.isWorking { ProgressView() }
                    Text("Sync Now")
                }
            }
            .buttonStyle(SettingsFormButtonStyle())
            .disabled(model.isWorking || model.state.syncBlock != nil)
            .accessibilityIdentifier("schedules-direct-sync-now")
        } footer: {
            if let block = model.state.syncBlock { syncBlockText(block) }
        }
        failureView
        SettingsSectionGroup {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
                .buttonStyle(SettingsFormButtonStyle())
                .disabled(model.isWorking)
                .accessibilityIdentifier("schedules-direct-sign-out")
        } footer: {
            Text("Signing out removes your login and the downloaded guide from this device.")
        }
    }

    @ViewBuilder private var lastSyncValue: some View {
        if let date = model.state.lastSyncSuccess {
            if model.state.lastSyncFailed {
                Text("\(date.formatted(date: .abbreviated, time: .shortened)) · Failed").settingsRowSecondary()
            } else {
                Text(date, format: .dateTime.month().day().hour().minute()).settingsRowSecondary()
            }
        } else if model.state.lastSyncFailed {
            Text("Failed").settingsRowSecondary()
        } else {
            Text("Never").settingsRowSecondary()
        }
    }

    @ViewBuilder private func syncBlockText(_ block: SchedulesDirectState.SyncBlock) -> some View {
        switch block {
        case let .notBefore(date), let .budgetExceeded(date), let .syncTooSoon(date):
            Text("Sync is paused until \(date.formatted(date: .omitted, time: .shortened)).")
        case .needsAttention:
            Text("Reconnect to resume syncing.")
        case .networkNotAllowed:
            Text("Connect to Wi-Fi or Ethernet to sync.")
        }
    }

    @ViewBuilder private var failureView: some View {
        if let failure = model.failure {
            SettingsSectionGroup {
                Label(SchedulesDirectFailureText.message(failure), systemImage: "exclamationmark.triangle.fill")
            }
        }
    }
}

enum SchedulesDirectFailureText {
    static func message(_ failure: SchedulesDirectSettingsModel.Failure) -> LocalizedStringResource {
        switch failure {
        case .featureDisabled: "Schedules Direct isn't available."
        case .signInFailed: "Schedules Direct didn't accept that username and password."
        case .accountAttention: "Schedules Direct needs attention. Syncing has stopped."
        case let .notBefore(date), let .budget(date), let .syncTooSoon(date):
            "Schedules Direct is paused until \(date.formatted(date: .omitted, time: .shortened))."
        case .noWiFi: "Connect to Wi-Fi or Ethernet to sync."
        case .lineupLimit: "This account already has the maximum number of lineups."
        case .lineupChanges: "No lineup changes remain today."
        case .network: "Couldn't reach Schedules Direct."
        case .storage: "Couldn't save on this device."
        case .generic: "Schedules Direct couldn't complete that."
        }
    }
}

struct SchedulesDirectAddLineupView: View {
    let model: SchedulesDirectSettingsModel
    @State private var country = "USA"
    @State private var postalCode = ""
    #if os(tvOS)
    @SettingsPageDismiss private var dismiss
    #else
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        LiveTVPreferencesPage(title: "Add Lineup") {
            SettingsSectionGroup {
                SettingsMenuRow(
                    title: "Country",
                    value: Text(verbatim: SchedulesDirectSettingsModel.countries.first { $0.code == country }?.name ?? country)
                ) {
                    Picker("Country", selection: $country) {
                        ForEach(SchedulesDirectSettingsModel.countries) { Text(verbatim: $0.name).tag($0.code) }
                    }
                }
                SettingsInputRow("Postal code") {
                    TextField("Postal code", text: $postalCode)
                        .autocorrectionDisabled()
                        .onSubmit(search)
                        .accessibilityIdentifier("schedules-direct-postal-code")
                }
                Button("Search") { search() }
                    .buttonStyle(SettingsFormButtonStyle())
                    .disabled(model.isWorking || postalCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let failure = model.failure {
                SettingsSectionGroup { Label(SchedulesDirectFailureText.message(failure), systemImage: "exclamationmark.triangle.fill") }
            }
            if model.didSearch && model.headends.isEmpty {
                SettingsSectionGroup { Text("No lineups found for that postal code.") }
            }
            ForEach(model.headends) { headend in
                SettingsSectionGroup {
                    ForEach(headend.lineups, id: \.lineup) { lineup in
                        Button {
                            Task { if await model.add(lineup: lineup.lineup) { dismiss() } }
                        } label: {
                            HStack { Text(verbatim: lineup.name); Spacer(); Image(systemName: "plus") }
                        }
                        .buttonStyle(SettingsFormButtonStyle())
                        .disabled(model.isWorking)
                    }
                } footer: {
                    Text(verbatim: [headend.location, headend.transport].compactMap { $0 }.joined(separator: " · "))
                }
            }
            if let remaining = model.state.account?.changesRemaining {
                SettingsSectionGroup { Text("Lineup changes remaining: \(remaining)").settingsRowSecondary() }
            }
        }
    }

    private func search() {
        Task { await model.searchHeadends(country: country, postalCode: postalCode) }
    }
}
#endif
