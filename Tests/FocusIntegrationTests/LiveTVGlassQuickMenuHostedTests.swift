@testable import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV

/// The quick menu's focus wiring, hosted with the real menu, heading pill and transition function: focus enters the menu and
/// stays in it, and returns to the heading when it closes without ever landing in the sidebar. The guide is a stand-in with the same
/// scope, disabling and presentation layer as `LiveTVPrototypeView`; the sidebar is a focusable stand-in at the left edge, held out of
/// the focus chain (as the shell does with `pageHoldsFocus`) while the menu is open and until focus is back in the page.
@MainActor
final class LiveTVGlassQuickMenuHostedTests: XCTestCase {
    func testTrayTakesFocusKeepsItInsideAndReturnsItToTheHeading() async throws {
        try await runCloseScenario(holdsRail: true)
    }

    /// Without the hold, closing the menu is what decides where focus lands; this records it (and attaches it) so the cause of Back
    /// opening the sidebar is measured, not assumed.
    func testWithoutTheHoldClosingTheMenuMayLandFocusInTheSidebar() async throws {
        let landed = try await runCloseScenario(holdsRail: false, asserts: false)
        let note = XCTAttachment(string: "Focus after closing the menu with the sidebar left focusable: \(landed)")
        note.name = "Where focus lands without the hold"
        note.lifetime = .keepAlways
        add(note)
    }

    @discardableResult
    private func runCloseScenario(holdsRail: Bool, asserts: Bool = true) async throws -> String {
        let (window, previous) = try await makeWindow()
        let model = QuickMenuFixtureModel()
        model.holdsRail = holdsRail
        let host = UIHostingController(rootView: QuickMenuFixture(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        /// The focused item's frame in window coordinates.
        func focusedFrame() -> CGRect? {
            guard let item = system.focusedItem else { return nil }
            let space: UICoordinateSpace = item.focusItemContainer?.coordinateSpace ?? window.coordinateSpace
            return space.convert(item.frame, to: window.coordinateSpace)
        }
        func settle(until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition(), ContinuousClock.now < deadline {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        // The tray sits at x 114..., y 275.5...; the guide stand-in is the 130 pt inset column above it.
        let trayRegion = CGRect(x: 100, y: 275, width: 800, height: 450)
        let headingRegion = CGRect(x: 100, y: 100, width: 600, height: 150)

        for _ in 0..<50 where system.focusedItem == nil {
            window.layoutIfNeeded()
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(focusedFrame().map { !trayRegion.contains($0) } ?? false)

        model.apply(.toggleQuickMenu)
        try await settle { focusedFrame().map(trayRegion.contains) == true }
        if asserts {
            XCTAssertTrue(focusedFrame().map(trayRegion.contains) ?? false,
                          "Opening the tray moves focus into it, got \(String(describing: focusedFrame()))")
        }

        let open = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        open.name = "Quick menu tray open (fixture)"
        open.lifetime = .keepAlways
        add(open)

        // Asking the engine to move focus back to the (disabled) guide must not take it out of the tray.
        system.requestFocusUpdate(to: host.view)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(focusedFrame().map(trayRegion.contains) ?? false, "Focus must not escape to the guide")

        model.apply(.back)
        try await settle { focusedFrame().map(headingRegion.contains) == true }
        XCTAssertEqual(model.presentation, .none)
        let landed = "\(String(describing: focusedFrame()))"
        if asserts {
            XCTAssertTrue(focusedFrame().map(headingRegion.contains) ?? false,
                          "Back closes the tray and refocuses the heading, got \(landed)")
            XCTAssertFalse(model.railTookFocus, "Focus must never fall into the sidebar while the menu closes")
        }
        return landed + " railTookFocus=\(model.railTookFocus)"
    }

    private func makeWindow() async throws -> (UIWindow, UIWindow?) {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return (window, previous)
    }
}

@MainActor @Observable
private final class QuickMenuFixtureModel {
    var presentation = LiveTVPrototypeGlassPresentation.none
    var returnsFocusToHeading = false
    var resetCount = 0
    /// The sidebar stand-in is out of the focus chain while the menu is open and until focus is back (the shell's `pageHoldsFocus`).
    var holdsRail = true
    var settling = false
    var railTookFocus = false

    func apply(_ event: LiveTVPrototypeGlassEvent) {
        let previous = presentation
        guard let next = previous.applying(event, canPresent: true) else { return }
        presentation = next
        if next.trapsFocus { settling = true }
        if next == .none {
            returnsFocusToHeading = previous.focusReturn == .heading
            resetCount += 1
        }
    }
}

private struct QuickMenuFixture: View {
    let model: QuickMenuFixtureModel
    @Namespace private var scope
    @Environment(\.resetFocus) private var resetFocus
    @FocusState private var railFocused: Bool

    private var inputs: PrototypeGlassHeroInputs {
        PrototypeGlassHeroInputs(
            headingTitle: "My Channels", headingCount: "1.5k",
            isHeadingOpen: model.presentation == .quickMenu,
            openHeading: { model.apply(.toggleQuickMenu) },
            focusScope: scope, prefersFocus: model.returnsFocusToHeading,
            isPlaying: false, now: Date(), isFavorite: false, toggleFavorite: {}, multiview: nil, info: {})
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.blue, .orange], startPoint: .leading, endPoint: .trailing)
            Button("Sidebar") { model.railTookFocus = true }
                .accessibilityLabel("Sidebar")
                .frame(width: 90, height: 600)
                .position(x: 45, y: 540)
                .disabled(model.holdsRail && (model.presentation.trapsFocus || model.settling))
                .focused($railFocused)
                .onChange(of: railFocused) { _, focused in
                    if focused, model.resetCount > 0, model.presentation == .none { model.railTookFocus = true }
                }
            VStack(alignment: .leading, spacing: 24) {
                PrototypeGlassHeading(inputs: inputs)
                    .opacity(model.presentation == .quickMenu ? 0 : 1)
                Button("Guide A") {}.accessibilityLabel("Guide A")
                Button("Guide B") {}.accessibilityLabel("Guide B")
            }
            .padding(130)
            .focusSection()
            .focusScope(scope)
            .disabled(model.presentation.trapsFocus)
            LiveTVPrototypeGlassScrim(dimming: model.presentation.dimming, reduceTransparency: false)
            if model.presentation == .quickMenu {
                LiveTVGlassQuickMenu(
                    entries: [
                        .init(id: "all", kind: .myChannels, title: "My Channels", count: "1.5k", isSelected: true),
                        .init(id: "search", kind: .tool, title: "Search", glyph: .search),
                        .init(id: "multiview", kind: .tool, title: "Multiview", glyph: .multiview)
                    ],
                    headingWidth: 200,
                    onSelect: { _ in model.apply(.close) },
                    onClose: { model.apply(.back) })
                .offset(x: 114, y: 275.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.resetCount) { _, _ in
            Task { @MainActor in
                await Task.yield()
                resetFocus(in: scope)
                await Task.yield()
                model.settling = false
            }
        }
    }
}
