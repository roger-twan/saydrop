import XCTest
@testable import SaydropCore

final class CoreTests: XCTestCase {
    let id = UUID()
    func apply(_ state: inout SessionState, _ event: SessionEvent) -> [SessionEffect] {
        let transition = SessionReducer.reduce(state, event); state = transition.state; return transition.effects
    }
    func recording(mode: OutputMode = .raw) -> SessionState {
        var state = SessionState(mode: mode)
        _ = apply(&state, .begin(id, 0)); _ = apply(&state, .captureStarted(id, 0)); return state
    }
    func preview(outcome: InsertionOutcome? = nil) -> SessionState {
        var state = recording()
        _ = apply(&state, .finish(id, 10)); _ = apply(&state, .stage(id, .uploading)); _ = apply(&state, .stage(id, .transcribing))
        _ = apply(&state, .result(id, SessionResult(rawText: "hello", outputText: "hello"), .targetChanged))
        if let outcome { _ = apply(&state, .insertion(id, outcome)) }; return state
    }
    func testBeginDoesNotClaimActiveMicrophone() {
        var state = SessionState(); _ = apply(&state, .begin(id, 0)); XCTAssertFalse(state.microphoneActive); XCTAssertEqual(state.phase, .checking)
    }
    func testConcurrentBeginIgnored() {
        var state = recording(); XCTAssertTrue(apply(&state, .begin(UUID(), 2)).isEmpty); XCTAssertEqual(state.id, id)
    }
    func testWrongSessionCallbackIgnored() {
        var state = recording(); let old = state
        _ = apply(&state, .fail(UUID(), "late")); XCTAssertEqual(state, old)
    }
    func testCancelRejectsLateResult() {
        var state = recording(); _ = apply(&state, .finish(id, 1)); _ = apply(&state, .cancel(id))
        _ = apply(&state, .stage(id, .transcribing)); _ = apply(&state, .result(id, SessionResult(rawText: "late", outputText: "late"), nil))
        XCTAssertNil(state.result); XCTAssertEqual(state.phase, .cancelled)
    }
    func testCaptureLimitFinalizesRatherThanCancels() {
        var state = recording(); XCTAssertEqual(apply(&state, .tick(id, 120)), [.finalize(id)])
        XCTAssertEqual(state.phase, .finalizing); XCTAssertEqual(state.elapsed, 120); XCTAssertFalse(state.microphoneActive)
        XCTAssertTrue(apply(&state, .tick(id, 121)).isEmpty)
    }
    func testPausedTimeExcludedFromCapture() {
        var state = recording(); _ = apply(&state, .pause(id, 10)); _ = apply(&state, .resumeStarted(id, 110))
        _ = apply(&state, .finish(id, 120)); XCTAssertEqual(state.elapsed, 20)
    }
    func testPauseTimeoutCancels() {
        var state = recording(); _ = apply(&state, .pause(id, 10))
        XCTAssertEqual(apply(&state, .tick(id, 310)), [.cancel(id)]); XCTAssertEqual(state.phase, .cancelled); XCTAssertFalse(state.microphoneActive)
    }
    func testResumeAfterDeadlineCannotRestart() {
        var state = recording(); _ = apply(&state, .pause(id, 10)); _ = apply(&state, .resumeStarted(id, 311))
        XCTAssertEqual(state.phase, .cancelled)
    }
    func testModeLockedAtFinish() {
        var state = recording(); _ = apply(&state, .chooseMode(.lightPolish)); _ = apply(&state, .finish(id, 10))
        _ = apply(&state, .chooseMode(.raw)); XCTAssertEqual(state.mode, .lightPolish)
    }
    func testRawCannotEnterPolishStage() {
        var state = recording(); _ = apply(&state, .finish(id, 10)); _ = apply(&state, .stage(id, .uploading))
        _ = apply(&state, .stage(id, .transcribing)); _ = apply(&state, .stage(id, .polishing)); XCTAssertEqual(state.phase, .transcribing)
    }
    func testOutOfOrderStageIgnored() {
        var state = recording(); _ = apply(&state, .stage(id, .transcribing)); XCTAssertEqual(state.phase, .recording)
    }
    func testUnknownInsertionCannotBeUpgradedOrRetried() {
        var state = preview(outcome: .unknown); _ = apply(&state, .insertion(id, .confirmed))
        XCTAssertEqual(state.insertionOutcome, .unknown); XCTAssertEqual(state.previewReason, .insertionUnknown)
    }
    func testCompletedEscOnlyHidesBar() {
        var state = preview(outcome: .confirmed); let result = state.result
        XCTAssertTrue(apply(&state, .cancel(id)).isEmpty); XCTAssertEqual(state.result, result); XCTAssertEqual(state.phase, .completed); XCTAssertFalse(state.isBarVisible)
    }
    func testPreviewCancelClearsUncommittedResult() {
        var state = preview(); _ = apply(&state, .cancel(id)); XCTAssertNil(state.result); XCTAssertEqual(state.phase, .cancelled)
    }
    func testProcessingCancellationNeverPromisesRefund() {
        var state = recording(); _ = apply(&state, .finish(id, 1)); _ = apply(&state, .stage(id, .uploading)); _ = apply(&state, .cancel(id))
        XCTAssertTrue(state.message?.contains("may still count against your quota") == true)
    }
    func testShortcutRepeatAndDuplicateEdgesIgnored() {
        var edges = ShortcutEdges(); XCTAssertTrue(edges.keyDown(isRepeat: false)); XCTAssertFalse(edges.keyDown(isRepeat: false))
        XCTAssertFalse(edges.keyDown(isRepeat: true)); XCTAssertTrue(edges.keyUp()); XCTAssertFalse(edges.keyUp()); XCTAssertTrue(edges.keyDown(isRepeat: false))
    }
    func testRetentionCustomValidation() {
        for input in ["", "0", "-1", "3651", "1.5", "abc", "１２", "+7"] { XCTAssertNil(RetentionPolicy.custom(input), input) }
        XCTAssertEqual(RetentionPolicy.custom(" 3650 "), .days(3650)); XCTAssertEqual(RetentionPolicy.custom("1"), .days(1))
    }
    func testRetentionPresetsAndForever() {
        let start = Date(timeIntervalSince1970: 0)
        for days in [1, 7, 30, 3650] { XCTAssertEqual(RetentionPolicy.days(days).expiration(from: start), start.addingTimeInterval(Double(days) * 86400)) }
        XCTAssertNil(RetentionPolicy.forever.expiration(from: start)); XCTAssertFalse(RetentionPolicy.days(0).isValid)
    }
    func testFourSaveCombinations() {
        let result = SessionResult(rawText: "raw", outputText: "out")
        for audio in [false, true] { for text in [false, true] {
            let record = SavePolicy(audioEnabled: audio, textEnabled: text).record(result: result, at: Date(), duration: 3, mode: .raw, outcome: .preview, audioAvailable: true)
            if !audio && !text { XCTAssertNil(record) } else { XCTAssertEqual(record?.hasAudio, audio); XCTAssertEqual(record?.outputText, text ? "out" : nil) }
        } }
    }
    func testUnavailableAudioDoesNotCreateFakeHistory() {
        XCTAssertNil(SavePolicy(audioEnabled: true, textEnabled: false).record(result: SessionResult(rawText: "a", outputText: "a"), at: Date(), duration: 1, mode: .raw, outcome: .preview, audioAvailable: false))
    }
    func testAudioOnlyHistoryNotSearchableByTranscript() {
        let record = SavePolicy(audioEnabled: true, textEnabled: false).record(result: SessionResult(rawText: "secret", outputText: "secret"), at: Date(), duration: 2, mode: .raw, outcome: .preview, audioAvailable: true)!
        XCTAssertFalse(record.matches("secret")); XCTAssertEqual(record.summary, "Audio recording · No text saved")
    }
    func testRetentionShorteningImpactAndExpiry() {
        let created = Date(timeIntervalSince1970: 0)
        let record = SavePolicy(audioEnabled: true, textEnabled: true).record(result: SessionResult(rawText: "a", outputText: "a"), at: created, duration: 1, mode: .raw, outcome: .preview, audioAvailable: true)!
        let impact = RetentionImpact.calculate(records: [record], policy: .days(1), forAudio: false, at: created.addingTimeInterval(2 * 86400))
        XCTAssertEqual(impact.affectedCount, 1); XCTAssertEqual(impact.expiredCount, 1)
        XCTAssertEqual(RetentionImpact.calculate(records: [record], policy: .days(30), forAudio: true, at: created).affectedCount, 0)
    }
    func testTextAndAudioExpireIndependently() {
        let created = Date(timeIntervalSince1970: 0)
        var record = SavePolicy(audioEnabled: true, textEnabled: true).record(result: SessionResult(rawText: "a", outputText: "a"), at: created, duration: 1, mode: .raw, outcome: .preview, audioAvailable: true, audioRetention: .days(7), textRetention: .days(1))!
        record.purgeExpired(at: created.addingTimeInterval(86400)); XCTAssertNil(record.outputText); XCTAssertTrue(record.hasAudio)
        record.purgeExpired(at: created.addingTimeInterval(7 * 86400)); XCTAssertFalse(record.hasContent)
    }
    func testTemporaryAudioTTLDoesNotRenewOnRead() {
        let lifetime = TemporaryAudioLifetime(resultAvailableAt: 10)
        XCTAssertEqual(lifetime.remaining(at: 30), 40); XCTAssertEqual(lifetime.remaining(at: 69), 1)
        XCTAssertTrue(lifetime.isExpired(at: 70)); XCTAssertEqual(lifetime.deadline, 70)
    }
    func testDTOMatchesCanonicalCamelCaseAndWireEnums() throws {
        let json = """
        {"requestId":"\(id)","status":"ready","outputMode":"light_polish","polishStatus":"failed_fallback_raw","rawText":"hi","outputText":"hi","resultExpiresAt":"2026-10-26T10:43:00+08:00","quota":{"limit":50,"used":3,"reserved":1,"remaining":46,"resetAt":"2026-10-27T00:00:00+08:00"}}
        """
        let dto = try JSONDecoder().decode(TranscriptionDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.requestId, id); XCTAssertEqual(dto.polishStatus, .failedFallbackRaw); XCTAssertEqual(dto.quota.remaining, 46)
    }
}

final class FeedbackTests: XCTestCase {
    let policy = FeedbackPolicy(baseURL: URL(string: "https://feedback.example.test")!, recipient: "Test recipient", purpose: "Improve the product", retention: "Test policy", deletionContact: "Test contact", version: "test-v1")
    func draft() -> FeedbackDraft { FeedbackDraft(requestID: UUID(), outputMode: .raw, rawText: "hello", outputText: "hello", audio: nil, duration: 1) }
    func testPositivePayloadIsMetadataOnly() throws {
        let data = try PositiveFeedback(requestID: UUID(), mode: .raw).encodedPayload()
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Set(object.keys), Set(["feedbackId", "transcriptionRequestId", "rating", "outputMode", "clientVersion"]))
    }
    func testMissingPolicyCannotConfirm() {
        let invalid = FeedbackPolicy(baseURL: URL(string: "http://example.test")!, recipient: "", purpose: "", retention: "", deletionContact: "", version: "")
        XCTAssertThrowsError(try draft().confirm(policy: invalid, at: Date(), uptime: 0))
    }
    func testChangedMaterialsRequireNewConsent() throws {
        var draft = draft(); let confirmation = try draft.confirm(policy: policy, at: Date(), uptime: 0)
        draft.reason = "changed"; XCTAssertThrowsError(try confirmation.validate(current: draft, policy: policy, uptime: 1))
    }
    func testChangedPolicyRequiresNewConsent() throws {
        let draft = draft(); let confirmation = try draft.confirm(policy: policy, at: Date(), uptime: 0)
        let next = FeedbackPolicy(baseURL: policy.baseURL, recipient: policy.recipient, purpose: policy.purpose, retention: policy.retention, deletionContact: policy.deletionContact, version: "v2")
        XCTAssertThrowsError(try confirmation.validate(current: draft, policy: next, uptime: 1))
    }
    func testTextOptOutOmitsAllTextFields() throws {
        var draft = draft(); draft.audio = Data([1]); draft.includeAudio = true; draft.includeText = false; draft.reason = "private"; draft.correctedText = "secret"
        let data = try draft.confirm(policy: policy, at: Date(), uptime: 0).encodedPayload()
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["rawText", "outputText", "reason", "correctedText"] { XCTAssertNil(object[key]) }
    }
    func testAudioExpiresDuringConsentWindow() throws {
        var draft = draft(); draft.audio = Data([1]); draft.includeAudio = true; draft.audioDeadline = 60
        let confirmed = try draft.confirm(policy: policy, at: Date(), uptime: 59)
        XCTAssertThrowsError(try confirmed.validate(current: draft, policy: policy, uptime: 60))
        XCTAssertThrowsError(try draft.confirm(policy: policy, at: Date(), uptime: 60))
    }
    func testTextOnlyAfterAudioExpiryRequiresFreshSnapshot() throws {
        var draft = draft(); draft.audio = Data([1]); draft.includeAudio = true; draft.audioDeadline = 60
        let old = try draft.confirm(policy: policy, at: Date(), uptime: 0)
        draft.audio = nil; draft.includeAudio = false; draft.audioDeadline = nil
        XCTAssertThrowsError(try old.validate(current: draft, policy: policy, uptime: 61))
        let next = try draft.confirm(policy: policy, at: Date(), uptime: 61); XCTAssertNotEqual(old.id, next.id)
    }
    func testOversizedTextRejectedNotTruncated() {
        var draft = draft(); draft.reason = String(repeating: "x", count: 2001)
        XCTAssertThrowsError(try draft.confirm(policy: policy, at: Date(), uptime: 0))
    }
    func testMissingMaterialsDoNotBecomeEmptyFakePayload() {
        let draft = FeedbackDraft(requestID: UUID(), outputMode: .raw, rawText: nil, outputText: nil, audio: nil, duration: 0)
        XCTAssertThrowsError(try draft.confirm(policy: policy, at: Date(), uptime: 0))
    }
    func testOnlyReliableReceivedReceiptMeansSuccess() {
        let id = UUID()
        XCTAssertFalse(FeedbackReceipt(feedbackId: id, status: .processing).isReliableSuccess)
        XCTAssertFalse(FeedbackReceipt(feedbackId: id, status: .received).isReliableSuccess)
        XCTAssertTrue(FeedbackReceipt(feedbackId: id, status: .received, receivedAt: "2026-10-26T11:11:00+08:00").isReliableSuccess)
    }
    func testSameOriginRequiresSchemeHostAndPort() {
        let url = URL(string: "https://same.test")!
        XCTAssertTrue(OriginSafety.sameOrigin(url, URL(string: "https://SAME.test:443/path")!))
        XCTAssertFalse(OriginSafety.sameOrigin(url, URL(string: "https://other.test")!))
        XCTAssertFalse(OriginSafety.sameOrigin(url, URL(string: "http://same.test")!))
        XCTAssertFalse(OriginSafety.sameOrigin(url, URL(string: "https://same.test:8443")!))
    }
}
