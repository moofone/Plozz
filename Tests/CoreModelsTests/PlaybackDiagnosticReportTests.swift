import CoreModels
import Foundation
import XCTest

final class PlaybackDiagnosticReportTests: XCTestCase {
    func testNonVideoResponsesExplainOnlyObservedContentWithoutGuessingAuthorization() throws {
        for (format, expected) in [
            (PlaybackFailureDiagnostic.Format.html, "web page"),
            (.json, "data document"), (.xml, "data document"), (.empty, "empty video")
        ] {
            let attempt = try XCTUnwrap(PlaybackFailureDiagnostics().begin(
                layer: .iptvProxy, content: .live, captureForPresentation: true
            ))
            let diagnostic = attempt.fail(stage: .body, reason: .invalidResponse, httpStatus: 200, format: format)
            let report = LiveChannelFailureReport(failure: .engine(.invalidResponse), diagnostic: diagnostic)
            let message = String(localized: report.message)
            XCTAssertTrue(message.contains(expected))
            XCTAssertFalse(message.contains("sign in"))
            XCTAssertFalse(message.contains("expired"))
            XCTAssertTrue(PlaybackDiagnosticReport.playback(report).supportText.contains("stream_format=\(format.rawValue)"))
            let unauthorized = LiveChannelFailureReport(failure: .engine(.unauthorized), diagnostic: diagnostic)
            XCTAssertEqual(unauthorized.message, LiveChannelPlaybackFailure.engineMessage(.unauthorized))
            let decoded = try JSONDecoder().decode(
                PlaybackFailureDiagnostic.self, from: JSONEncoder().encode(XCTUnwrap(diagnostic))
            )
            XCTAssertEqual(decoded.format, format)
        }
    }

    func testRecognizedConnectionLimitIsNotReplacedByGenericServerErrorCopy() throws {
        let attempt = try XCTUnwrap(PlaybackFailureDiagnostics().begin(
            layer: .iptvProxy, content: .live, captureForPresentation: true
        ))
        let diagnostic = attempt.fail(stage: .response, httpStatus: 503)
        let report = LiveChannelFailureReport(failure: .engine(.conflict), diagnostic: diagnostic)
        XCTAssertEqual(report.message, LiveChannelPlaybackFailure.engineMessage(.conflict))
        XCTAssertTrue(PlaybackDiagnosticReport.playback(report).supportText.contains("failure=tunerUnavailable"))
        XCTAssertTrue(PlaybackDiagnosticReport.playback(report).supportText.contains("http_status=503"))
        let ordinary = LiveChannelFailureReport(failure: .engine(.invalidResponse), diagnostic: diagnostic)
        XCTAssertNotEqual(ordinary.message, report.message)
    }

    func testVideoNotDecodedReportCarriesCodecAndNoURL() {
        let report = LiveChannelFailureReport(failure: .videoNotDecoded(codec: "avc1"))
        let text = PlaybackDiagnosticReport.playback(report).supportText
        XCTAssertTrue(text.contains("failure=videoNotDecoded"))
        XCTAssertTrue(text.contains("video=none-decoded"))
        XCTAssertTrue(text.contains("codec=avc1"))
        XCTAssertFalse(text.contains("://"))
        XCTAssertNotEqual(report.message, LiveChannelPlaybackFailure.startupTimedOut.message)
    }

    func testVideoNotDecodedCodecIsAClosedFourCharacterVocabulary() {
        for (raw, expected) in [
            ("AVC1", "avc1"), ("hvc1", "hvc1"), (nil, "unknown"), ("", "unknown"),
            ("https://host/x", "unknown"), ("avc1 title=Secret", "unknown"), ("averyveryverylongcodec", "unknown")
        ] as [(String?, String)] {
            let text = PlaybackDiagnosticReport.playback(.init(failure: .videoNotDecoded(codec: raw))).supportText
            XCTAssertTrue(text.contains("codec=\(expected)"), "\(String(describing: raw)) → \(text)")
            XCTAssertFalse(text.contains("Secret"))
        }
        XCTAssertFalse(
            PlaybackDiagnosticReport.playback(.init(failure: .startupTimedOut)).supportText.contains("video=")
        )
    }

    func testOnDemandReportPreservesFactsWithoutInventingSessionExpiry() {
        let report = PlaybackDiagnosticReport.onDemand(
            error: .playback(.init(kind: .unavailable, httpStatus: 410, engineFailure: .sourceRefused)),
            provider: .silo, engine: .plozzigen, stage: .opening
        )
        XCTAssertEqual(report.supportText, """
        format=plozz-playback-1
        operation=playback
        content=onDemand
        provider=silo
        engine=plozzigen
        stage=opening
        failure=HTTP 410
        reason=unavailable
        engine_failure=sourceRefused
        http_status=410
        """)
        XCTAssertFalse(report.supportText.contains("expired"))
        XCTAssertFalse(String(localized: report.message!).contains("expired"))
    }

    func testPreparationReportHasNoEngineAndKeepsProviderRejection() {
        let report = PlaybackDiagnosticReport.onDemand(
            error: .serverRefusal("Plozz requires a seekable stream.", reason: .nonSeekable),
            provider: .silo, engine: nil, stage: .preparation
        )
        XCTAssertTrue(report.supportText.contains("failure=nonSeekable"))
        XCTAssertTrue(report.supportText.contains("stage=preparation"))
        XCTAssertFalse(report.supportText.contains("engine="))
    }

    func testCapturedErrorChainExcludesPrivateTextAndKeepsEveryNumericCause() {
        let secret = "https://private.invalid/path?token=secret"
        let inner = NSError(domain: "CoreMediaErrorDomain", code: -12939,
                            userInfo: [NSLocalizedDescriptionKey: secret])
        let outer = NSError(domain: "AVFoundationErrorDomain", code: -11850,
                            userInfo: [NSUnderlyingErrorKey: inner, NSLocalizedDescriptionKey: secret])
        let report = PlaybackDiagnosticReport.onDemand(
            error: .playback(.init(
                kind: .unknown, engineFailure: .nativeItemFailed,
                underlyingErrors: PlaybackFailureEvidence.ErrorCode.chain(outer)
            )),
            provider: .plex, engine: .native, stage: .playback,
            negotiatedCodec: .h264, retryCodec: .hevc
        )
        XCTAssertTrue(report.supportText.contains("underlying_error_0=avfoundation:-11850"))
        XCTAssertTrue(report.supportText.contains("underlying_error_1=coremedia:-12939"))
        XCTAssertTrue(report.supportText.contains("negotiated_codec=h264"))
        XCTAssertTrue(report.supportText.contains("retried_codec=hevc"))
        XCTAssertFalse(report.supportText.contains("private"))
        XCTAssertFalse(report.supportText.contains("secret"))
    }

    func testAdviceDoesNotReplaceKnownCauseOrInventOne() {
        for error in [
            StreamingQualityError.negotiationFailed, .authenticationRequired, .permissionDenied,
            .sourceUnavailable, .startupTimedOut,
            .playback(.init(kind: .readinessTimedOut)),
            .playback(.init(kind: .audioOutputFailed)),
            .playback(.init(kind: .rateLimited)),
            .playback(.init(kind: .accessRestricted)),
            .playback(.init(kind: .hdrConversionUnconfirmed)),
            .playback(.init(kind: .network, domain: .url, code: -1206))
        ] {
            let message = String(localized: error.userMessage)
            for speculation in ["Check ", "Try ", "subscription", "tone mapping", "your device’s date", "other playback sessions"] {
                XCTAssertFalse(message.contains(speculation), message)
            }
        }
        XCTAssertNotEqual(StreamingPlaybackFailure(kind: .unavailable, httpStatus: 404).userMessage,
                          StreamingPlaybackFailure(kind: .unavailable, httpStatus: 410).userMessage)
        XCTAssertEqual(StreamingPlaybackFailure(kind: .unknown, engineFailure: .audioTrackSwitchFailed).userMessage,
                       PlaybackFailureDiagnostic.EngineFailure.audioTrackSwitchFailed.message)
    }

    // MARK: - What the relay saw when no typed error was recorded

    private func request(
        _ sequence: Int, _ resource: PlaybackDeliveryEvidence.Resource = .child,
        outcome: PlaybackDeliveryEvidence.Outcome, status: Int? = nil, bytes: Int = 0, networkCode: Int? = nil,
        playlist: PlaybackDeliveryEvidence.Playlist? = nil
    ) -> PlaybackDeliveryEvidence.Request {
        var value = PlaybackDeliveryEvidence.Request(
            sequence: sequence, resource: resource, method: .get, startedMilliseconds: sequence * 100
        )
        value.outcome = outcome
        value.status = status
        value.receivedBytes = bytes
        value.networkCode = networkCode
        value.playlist = playlist
        return value
    }

    private func message(_ failure: LiveChannelPlaybackFailure, _ delivery: PlaybackDeliveryEvidence?) -> String {
        String(localized: LiveChannelFailureReport(failure: failure, delivery: delivery).message)
    }

    private let mediaPlaylist = PlaybackDeliveryEvidence.Playlist(
        hasHeader: true, isMaster: false, targetDurationMilliseconds: 6_000, maximumSegmentMilliseconds: 6_000,
        mediaSequence: 10, segments: 5, hasEndList: false, hasByteRanges: false, hasMap: false, hasEncryption: false
    )

    func testStartupTimeoutNamesTheProviderStepThatNeverDelivered() {
        let generic = String(localized: LiveChannelPlaybackFailure.startupTimedOut.message)
        // The channel request was never answered (still waiting, or given up on by the player).
        for outcome in [PlaybackDeliveryEvidence.Outcome.pending, .consumerClosed] {
            let root = request(1, .root, outcome: outcome)
            XCTAssertEqual(message(.startupTimedOut, .init(root: root, recent: [root])),
                           "The provider did not respond to the request for this channel.")
        }
        // Answered 200, no bytes.
        let silent = request(1, .root, outcome: .receiving, status: 200)
        XCTAssertEqual(message(.startupTimedOut, .init(root: silent, recent: [silent])),
                       "The provider accepted the request but sent no data for this channel.")
        // A playlist, then segments that never delivered a byte.
        let playlist = request(1, .root, outcome: .complete, status: 200, bytes: 864, playlist: mediaPlaylist)
        let segments = [request(2, outcome: .pending), request(3, outcome: .consumerClosed, status: 200)]
        XCTAssertEqual(message(.startupTimedOut, .init(root: playlist, recent: [playlist] + segments)),
                       "The provider sent the channel’s playlist but no video.")
        // A refusal or network failure anywhere before video is the cause.
        let refused = request(2, outcome: .upstreamFailure, status: 503)
        XCTAssertEqual(message(.startupTimedOut, .init(root: playlist, firstFailure: refused, recent: [playlist, refused])),
                       "The provider returned a server error (HTTP 503).")
        let teapot = request(2, outcome: .upstreamFailure, status: 418)
        XCTAssertEqual(message(.startupTimedOut, .init(root: playlist, firstFailure: teapot, recent: [playlist, teapot])),
                       "The provider refused the stream (HTTP 418).")
        let timedOut = request(2, outcome: .upstreamFailure, networkCode: URLError.timedOut.rawValue)
        XCTAssertEqual(message(.startupTimedOut, .init(root: playlist, firstFailure: timedOut, recent: [playlist, timedOut])),
                       "The request to the provider did not respond in time.")
        // Nothing conclusive: segments arrived (a decode problem, not the provider), a master playlist, or no relay.
        let delivered = [request(2, outcome: .complete, status: 200, bytes: 400_000)]
        XCTAssertEqual(message(.startupTimedOut, .init(root: playlist, recent: [playlist] + delivered)), generic)
        var master = playlist
        master.playlist?.isMaster = true
        XCTAssertEqual(message(.startupTimedOut, .init(root: master, recent: [master] + segments)), generic)
        XCTAssertEqual(message(.startupTimedOut, nil), generic)
        XCTAssertEqual(message(.startupTimedOut, .init()), generic)
    }

    func testATimeoutWithARecordedRefusalShowsTheRefusal() throws {
        for (status, expected) in [(429, "The provider is limiting requests."), (403, "The provider refused access (HTTP 403).")] {
            let attempt = try XCTUnwrap(PlaybackFailureDiagnostics().begin(
                layer: .iptvProxy, content: .live, captureForPresentation: true
            ))
            let diagnostic = attempt.fail(stage: .response, httpStatus: status)
            for failure in [LiveChannelPlaybackFailure.startupTimedOut, .bufferingTimedOut, .ended] {
                XCTAssertEqual(String(localized: LiveChannelFailureReport(failure: failure, diagnostic: diagnostic).message),
                               expected, "\(failure) \(status)")
            }
        }
    }

    func testAStallOrEndBlamesOnlyRecentProviderFailures() {
        let playlist = request(1, .root, outcome: .complete, status: 200, bytes: 864, playlist: mediaPlaylist)
        let old404 = request(2, outcome: .upstreamFailure, status: 404)
        let later = (3...10).map { request($0, outcome: .complete, status: 200, bytes: 200_000) }
        // A segment error the stream recovered from long ago is not why it ended.
        let recovered = PlaybackDeliveryEvidence(root: playlist, firstFailure: old404, recent: later)
        XCTAssertEqual(message(.ended, recovered), String(localized: LiveChannelPlaybackFailure.ended.message))
        XCTAssertEqual(message(.bufferingTimedOut, recovered),
                       String(localized: LiveChannelPlaybackFailure.bufferingTimedOut.message))
        // The provider cutting the stream off is.
        let cut = request(11, outcome: .upstreamFailure, status: 403)
        let ended = PlaybackDeliveryEvidence(root: playlist, firstFailure: old404, recent: Array(later.dropFirst()) + [cut])
        XCTAssertEqual(message(.ended, ended), "The provider refused access (HTTP 403).")
        let reset = request(11, outcome: .upstreamFailure, networkCode: URLError.timedOut.rawValue)
        XCTAssertEqual(message(.bufferingTimedOut, .init(root: playlist, recent: [reset])),
                       "The request to the provider did not respond in time.")
        // Startup-only causes never explain a stream that already showed video.
        let silent = request(12, .root, outcome: .pending)
        XCTAssertEqual(message(.ended, .init(root: silent, recent: [silent])),
                       String(localized: LiveChannelPlaybackFailure.ended.message))
    }

    func testTimeoutDetailsCarryTheRelayEvidenceWithoutURLs() {
        let root = request(1, .root, outcome: .pending)
        let report = LiveChannelFailureReport(failure: .startupTimedOut, delivery: .init(root: root, recent: [root]))
        let text = PlaybackDiagnosticReport.playback(report).supportText
        XCTAssertTrue(text.contains("failure=startupTimedOut"))
        XCTAssertTrue(text.contains("upstream_root.outcome=pending"))
        XCTAssertTrue(text.contains("upstream_0.resource=root"))
        XCTAssertFalse(text.contains("://"))
    }
}
