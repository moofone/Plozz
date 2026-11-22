import Foundation

/// A row with no stream content of its own, which is never shown anywhere (My Channels, collections, favourite filters, counts,
/// search, the guide, Events): a section header (`## DISNEY+ ORIGINAL ##`, `#### CANADA ####`), an idle event slot
/// (`NO EVENT STREAMING`, a slot that names no event) and an event whose time has passed. The one rule is the existing
/// section-marker and event-slot logic (`LiveTVChannelKind.isSectionMarker`, `LiveTVEventSlotClassifier`); the lineup cut applies
/// it first so a placeholder is never processed further, and the catalog build applies it again for rows that bypass the cut.
enum LiveTVPlaceholder {
    /// `isEventGroup` lets a caller that sees many rows fold each group once.
    static func isPlaceholder(
        name: String, groups: [String], eventGroups: [String], now: Date = Date(),
        isEventGroup: (String) -> Bool = LiveTVEventSlotClassifier.isEventGroup
    ) -> Bool {
        if LiveTVChannelKind.isSectionMarker(name: name, groups: groups) { return true }
        guard LiveTVEventSlotClassifier.isCandidate(name: name, groups: eventGroups, groupIsEvent: isEventGroup),
              let slot = LiveTVEventSlotClassifier.classify(name: name, groups: eventGroups) else { return false }
        return isPlaceholder(slot, now: now)
    }

    /// An idle slot, or an event that started more than a slot's duration ago.
    static func isPlaceholder(_ slot: LiveTVEventSlot, now: Date) -> Bool {
        if slot.isIdle { return true }
        guard let start = slot.start else { return false }
        return start.addingTimeInterval(LiveTVEventSlot.defaultDuration) <= now
    }
}
