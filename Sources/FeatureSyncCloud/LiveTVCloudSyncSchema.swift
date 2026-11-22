import Foundation

public extension CloudSyncSchemaDescriptor {
    static let liveTVSourcesV1 = CloudSyncSchemaDescriptor(
        recordType: "PlozzTrackerTokensV1Record", encryptsValue: true,
        zoneName: "PlozzLiveTVSourcesV1Zone", maximumPayloadBytes: 256 * 1_024 * 1_024
    )

    /// Reuses the deployed non-secret media-state record type/fields, in an
    /// isolated zone. Old media-state clients omit unknown prefixes from their
    /// authoritative captures, so sharing their zone would let them delete Live
    /// TV records. This remains a channel on the ONE existing CKSyncEngine.
    static let liveTVStateV1 = CloudSyncSchemaDescriptor(
        recordType: "PlozzMediaStateV1Record",
        zoneName: "PlozzLiveTVStateV1Zone",
        kindDerivation: .prefixBeforeFirstColon
    )

    /// Channel logo choices shared by every profile: data only, no image bytes. Same deployed
    /// non-secret record type, in its own zone, as a channel on the one existing engine.
    static let liveTVLogosV1 = CloudSyncSchemaDescriptor(
        recordType: "PlozzMediaStateV1Record",
        zoneName: "PlozzLiveTVLogosV1Zone",
        kindDerivation: .prefixBeforeFirstColon
    )
}
