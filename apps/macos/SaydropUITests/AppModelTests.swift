import XCTest
import SaydropCore
@testable import SaydropUI

@MainActor
private final class FakeFeedbackAPI: FeedbackAPI {
    var submissions: [ConfirmedFeedback] = []
    var positives: [PositiveFeedback] = []
    var queries: [UUID] = []
    var cancellations = 0
    var responseStatus: FeedbackReceiptStatus = .received
    var throwOnSubmit = false
    var suspend = false
    func receipt(_ id: UUID) -> FeedbackReceipt { FeedbackReceipt(feedbackId: id, status: responseStatus, receivedAt: responseStatus == .received ? "2026-10-26T11:11:00+08:00" : nil) }
    func submit(_ feedback: ConfirmedFeedback) async throws -> FeedbackReceipt {
        submissions.append(feedback)
        if suspend { try await Task.sleep(for: .seconds(100)) }
        if throwOnSubmit { throw FeedbackValidationError.submissionUnknown }
        return receipt(feedback.id)
    }
    func submitPositive(_ feedback: PositiveFeedback) async throws -> FeedbackReceipt { positives.append(feedback); if throwOnSubmit { throw FeedbackValidationError.submissionUnknown }; return receipt(feedback.id) }
    func status(_ id: UUID) async throws -> FeedbackReceipt { queries.append(id); return receipt(id) }
    func cancel() { cancellations += 1 }
}
@MainActor
final class AppModelTests: XCTestCase {
    let policy = FeedbackPolicy(baseURL: URL(string: "https://feedback.example.test")!, recipient: "\u{6D4B}\u{8BD5}\u{63A5}\u{6536}\u{65B9}", purpose: "\u{95EE}\u{9898}\u{6539}\u{8FDB}", retention: "\u{4EC5}\u{6D4B}\u{8BD5}\u{653F}\u{7B56}", deletionContact: "\u{4EC5}\u{6D4B}\u{8BD5}\u{8054}\u{7CFB}\u{8DEF}\u{5F84}", version: "test-v1")
    private func model(api: FakeFeedbackAPI? = nil, withPolicy: Bool = true) -> AppModel {
        AppModel(isDemo: true, defaults: nil, backend: UnconfiguredSessionBackend(), feedbackAPI: api ?? FakeFeedbackAPI(), feedbackPolicy: withPolicy ? policy : nil)
    }
    private func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(25)) }
    func testDefaultHostHasNoSampleRecordsOrQuota() {
        let model = AppModel(isDemo: false, defaults: nil, backend: UnconfiguredSessionBackend(), feedbackAPI: UnconfiguredFeedbackAPI(), feedbackPolicy: nil)
        XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.quota); XCTAssertFalse(model.canStart); XCTAssertFalse(model.session.microphoneActive)
        model.beginSession(); XCTAssertEqual(model.session.phase, .idle); XCTAssertNotNil(model.notice)
    }
    func testSavingSwitchesDoNotDeleteExistingHistory() {
        let model = model(); let records = model.records
        model.updateSaving(audio: false, text: false); XCTAssertEqual(model.records, records); XCTAssertFalse(model.hasHistoryEnabled)
    }
    func testShorteningDoesNotApplyBeforeLocalConfirmation() {
        let model = model(); model.updateRetention(.days(1), forAudio: false)
        XCTAssertNotNil(model.confirmation); XCTAssertEqual(model.settings.textRetention, .days(7))
        model.cancelLocalChange(); XCTAssertEqual(model.settings.textRetention, .days(7))
    }
    func testConfirmedShorteningPurgesExpiredTextOnly() {
        let model = model(); model.updateRetention(.days(1), forAudio: false); model.confirmLocalChange()
        XCTAssertEqual(model.settings.textRetention, .days(1)); XCTAssertEqual(model.records.count, 3)
    }
    func testInvalidRetentionIsNotSaved() {
        let model = model(); model.updateRetention(.days(0), forAudio: true); XCTAssertEqual(model.settings.audioRetention, .days(7)); XCTAssertNotNil(model.notice)
    }
    func testClearAndDeleteRequireConfirmation() {
        let model = model(); let record = model.records[0]
        model.requestDelete(record); XCTAssertEqual(model.records.count, 4); model.cancelLocalChange(); XCTAssertEqual(model.records.count, 4)
        model.requestDelete(record); model.confirmLocalChange(); XCTAssertEqual(model.records.count, 3)
        model.requestClearHistory(); XCTAssertEqual(model.records.count, 3); model.confirmLocalChange(); XCTAssertTrue(model.records.isEmpty)
    }
    func testOpeningAndPreviewingFeedbackMakeNoRequest() async {
        let api = FakeFeedbackAPI(); let model = model(api: api); model.openFeedback(for: model.records[0]); model.prepareFeedbackConsent()
        await settle(); XCTAssertTrue(api.submissions.isEmpty); XCTAssertEqual(model.feedback?.state, .awaitingConsent)
    }
    func testMissingPolicyFailsClosedWithoutRequest() async {
        let api = FakeFeedbackAPI(); let model = model(api: api, withPolicy: false)
        model.openFeedback(for: model.records[0]); model.prepareFeedbackConsent(); model.confirmAndSubmitFeedback(); await settle()
        XCTAssertTrue(api.submissions.isEmpty); XCTAssertNotNil(model.feedback?.message)
    }
    func testReliableReceiptMarksSubmittedOnlyAfterExplicitConfirm() async {
        let api = FakeFeedbackAPI(); let model = model(api: api)
        model.openFeedback(for: model.records[0]); model.prepareFeedbackConsent(); model.confirmAndSubmitFeedback(); await settle()
        XCTAssertEqual(api.submissions.count, 1); XCTAssertEqual(model.feedback?.state, .submitted)
    }
    func testDuplicateConfirmDoesNotCreateSecondUpload() async {
        let api = FakeFeedbackAPI(); let model = model(api: api)
        model.openFeedback(for: model.records[0]); model.prepareFeedbackConsent(); model.confirmAndSubmitFeedback(); model.confirmAndSubmitFeedback(); await settle()
        XCTAssertEqual(api.submissions.count, 1)
    }
    func testMaterialsChangedReturnToEditing() {
        let model = model(); model.openFeedback(for: model.records[0]); model.prepareFeedbackConsent(); model.editFeedback { $0.reason = "new text" }
        XCTAssertEqual(model.feedback?.state, .editing); XCTAssertNil(model.feedback?.confirmation)
    }
    func testAsyncProcessingReceiptIsNotSuccess() async {
        let api = FakeFeedbackAPI(); api.responseStatus = .processing; let model = model(api: api)
        model.openFeedback(for: model.records[0]); model.prepareFeedbackConsent(); model.confirmAndSubmitFeedback(); await settle()
        XCTAssertEqual(model.feedback?.state, .submissionUnknown); XCTAssertNotNil(model.feedback?.receiptID)
    }
    func testReceiptLossQueriesSameIDWithoutResendingAttachments() async {
        let api = FakeFeedbackAPI(); api.throwOnSubmit = true; let model = model(api: api)
        model.openFeedback(for: model.records[0]); model.prepareFeedbackConsent(); model.confirmAndSubmitFeedback(); await settle()
        let id = model.feedback!.receiptID!; XCTAssertEqual(model.feedback?.state, .submissionUnknown)
        api.throwOnSubmit = false; model.queryFeedbackReceipt(); await settle()
        XCTAssertEqual(api.submissions.count, 1); XCTAssertEqual(api.queries, [id]); XCTAssertEqual(model.feedback?.state, .submitted)
    }
    func testFeedbackDoesNotChangeTranscriptionStateOrQuota() async {
        let api = FakeFeedbackAPI(); let model = model(api: api); let session = model.session; let quota = model.quota
        model.openFeedback(for: model.records[0]); model.prepareFeedbackConsent(); model.confirmAndSubmitFeedback(); await settle()
        XCTAssertEqual(model.session, session); XCTAssertEqual(model.quota, quota)
    }
    func testPositiveFeedbackMetadataOnlyAndDeduplicated() async throws {
        let api = FakeFeedbackAPI(); let model = model(api: api); let record = model.records[0]
        model.submitPositiveFeedback(for: record); model.submitPositiveFeedback(for: record); await settle(); model.submitPositiveFeedback(for: record); await settle()
        XCTAssertEqual(api.positives.count, 1)
        let json = try JSONSerialization.jsonObject(with: api.positives[0].encodedPayload()) as! [String: Any]
        XCTAssertNil(json["audio"]); XCTAssertNil(json["rawText"])
    }
    func testPositiveUnknownClickQueriesInsteadOfReposting() async {
        let api = FakeFeedbackAPI(); api.throwOnSubmit = true; let model = model(api: api); let record = model.records[0]
        model.submitPositiveFeedback(for: record); await settle(); api.throwOnSubmit = false; model.submitPositiveFeedback(for: record); await settle()
        XCTAssertEqual(api.positives.count, 1); XCTAssertEqual(api.queries.count, 1)
    }
    func testAudioTTLInvalidatesConsentAndCancelsInflightUpload() async {
        let api = FakeFeedbackAPI(); api.suspend = true; let model = model(api: api)
        let now = ProcessInfo.processInfo.systemUptime
        model.openFeedback(for: model.records[0]); model.editFeedback { $0.audio = Data([1]); $0.includeAudio = true; $0.audioDeadline = now + 60 }
        model.prepareFeedbackConsent(); model.confirmAndSubmitFeedback(); await settle(); model.tick(at: now + 60)
        XCTAssertNil(model.feedback?.draft.audio); XCTAssertNil(model.feedback?.confirmation); XCTAssertEqual(api.cancellations, 1)
        XCTAssertEqual(model.feedback?.state, .submissionUnknown); model.closeFeedback()
    }
    func testNoFakeAudioPlayback() {
        let model = model(); model.playAudio(model.records[0]); XCTAssertNil(model.playingRecordID); XCTAssertNotNil(model.notice)
    }
    func testCrossOriginInstallationCredentialCannotInitializeAdapter() {
        XCTAssertThrowsError(try FeedbackAPIClient(policy: policy, credential: .sameOriginInstallation(token: "test-only", transcriptionBaseURL: URL(string: "https://transcription.example.test")!)))
    }
    func testUnchangedExplicitRetryReusesExactPayloadAndID() async throws {
        let api = FakeFeedbackAPI(); api.responseStatus = .failed; let model = model(api: api)
        model.openFeedback(for: model.records[0]); model.prepareFeedbackConsent(); model.confirmAndSubmitFeedback(); await settle()
        model.returnToFeedbackEditing(); model.prepareFeedbackConsent(); model.confirmAndSubmitFeedback(); await settle()
        XCTAssertEqual(api.submissions.count, 2); XCTAssertEqual(api.submissions[0].id, api.submissions[1].id)
        XCTAssertEqual(try api.submissions[0].encodedPayload(), try api.submissions[1].encodedPayload())
    }
    func testChangedMaterialsUseNewIDAfterFreshConsent() async {
        let api = FakeFeedbackAPI(); api.responseStatus = .failed; let model = model(api: api)
        model.openFeedback(for: model.records[0]); model.prepareFeedbackConsent(); model.confirmAndSubmitFeedback(); await settle()
        model.returnToFeedbackEditing(); model.editFeedback { $0.reason = "\u{4FEE}\u{6539}\u{540E}\u{7684}\u{8BF4}\u{660E}" }; model.prepareFeedbackConsent(); model.confirmAndSubmitFeedback(); await settle()
        XCTAssertEqual(api.submissions.count, 2); XCTAssertNotEqual(api.submissions[0].id, api.submissions[1].id)
    }
    func testUnknownUnchangedRetryRequiresReceiptQueryFirst() async {
        let api = FakeFeedbackAPI(); api.throwOnSubmit = true; let model = model(api: api)
        model.openFeedback(for: model.records[0]); model.prepareFeedbackConsent(); model.confirmAndSubmitFeedback(); await settle()
        model.returnToFeedbackEditing(); model.prepareFeedbackConsent(); model.confirmAndSubmitFeedback(); await settle()
        XCTAssertEqual(api.submissions.count, 1); XCTAssertEqual(model.feedback?.state, .submissionUnknown)
    }
    func testZeroTranscriptionQuotaDoesNotDisableFeedback() async {
        let api = FakeFeedbackAPI(); let model = model(api: api)
        model.applyQuotaFromService(Quota(limit: 50, used: 50, reserved: 0, remaining: 0, resetAt: "2026-10-27T00:00:00+08:00"))
        model.openFeedback(for: model.records[0]); model.prepareFeedbackConsent(); model.confirmAndSubmitFeedback(); await settle()
        XCTAssertEqual(model.quota?.remaining, 0); XCTAssertEqual(api.submissions.count, 1); XCTAssertEqual(model.feedback?.state, .submitted)
    }
    func testQuotaReadFailureClearsOldAuthoritativeDisplay() {
        let model = model(); XCTAssertNotNil(model.quota); model.applyQuotaFromService(nil); XCTAssertNil(model.quota)
    }
}
