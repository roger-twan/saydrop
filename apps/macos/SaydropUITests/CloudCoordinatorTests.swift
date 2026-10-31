import XCTest
import Foundation
import SaydropCore
@testable import SaydropUI

@MainActor
private final class CoordinatorFakeAPI: CloudBusinessAPI {
    let configuration = try! CloudConfiguration(baseURL: URL(string: "https://backend.example.test")!)
    var isConfigured = true
    var credentialAvailable = false
    var pending: PendingTranscription? { didSet { onPending?(pending) } }
    var onQuota: ((Quota?) -> Void)?
    var onPending: ((PendingTranscription?) -> Void)?
    var healthError: CloudClientError?
    var quotaError: CloudClientError?
    var healthCalls = 0, prepares = 0, quotaCalls = 0, transcriptions = 0
    var value = Quota(limit: 50, used: 0, reserved: 0, remaining: 50, resetAt: "2030-01-01T00:00:00+08:00")
    var response: TranscriptionDTO?
    func checkHealth() async throws { healthCalls += 1; if let healthError { throw healthError } }
    func prepareCredential() async throws -> Quota { prepares += 1; credentialAvailable = true; return try await fetchQuota() }
    func fetchQuota() async throws -> Quota {
        quotaCalls += 1; if let quotaError { onQuota?(nil); throw quotaError }; onQuota?(value); return value
    }
    func inspectPending() async throws -> TranscriptionDTO { guard let response else { throw CloudClientError.unavailable }; return response }
    func abandonPendingRequest() throws { pending = nil }
    func transcribe(_ wav: Data, id: UUID, mode: OutputMode, stage: @escaping (SessionPhase) -> Void) async throws -> SessionResult {
        transcriptions += 1; stage(.uploading); stage(.transcribing)
        return SessionResult(rawText: "[MOCK] raw \u{4E2D}\u{6587} English", outputText: "[MOCK] raw \u{4E2D}\u{6587} English")
    }
    func cancel(id: UUID) { if pending?.id == id { pending?.locallyCancelled = true } }
    func shutdown() {}
}
@MainActor
private final class CoordinatorFakeAudio: AudioCapturing {
    var onLevel: ((UUID, Double) -> Void)?
    var onFailure: ((UUID, String) -> Void)?
    var starts = 0
    func start(id: UUID) async throws { starts += 1 }
    func pause(id: UUID) {}
    func resume(id: UUID) async throws {}
    func finish(id: UUID) async throws -> CapturedAudio { try AudioPipeline.convertPlanarFloat32ForTesting([Array(repeating: Float(0.2), count: 800)], sampleRate: 16_000) }
    func cancel(id: UUID) {}
}
@MainActor
final class CloudCoordinatorTests: XCTestCase {
    private let disclosure = CloudDisclosure(version: "mock-v1", receiver: "FakeProvider（\u{79BB}\u{7EBF}\u{6D4B}\u{8BD5}）", purpose: "\u{4EC5}\u{5355}\u{5143}\u{6D4B}\u{8BD5}", retention: "\u{79BB}\u{7EBF}\u{6D4B}\u{8BD5}，\u{4E0D}\u{53D1}\u{9001}\u{7F51}\u{7EDC}")
    private func settle() async { for _ in 0..<30 { await Task.yield() }; try? await Task.sleep(nanoseconds: 20_000_000) }
    private func make(_ api: CoordinatorFakeAPI, disclosure: CloudDisclosure? = nil) -> CloudCoordinator {
        CloudCoordinator(api: api, configuration: api.configuration, disclosure: disclosure ?? self.disclosure)
    }
    private func model(_ api: CoordinatorFakeAPI, _ cloud: CloudCoordinator, _ audio: CoordinatorFakeAudio) -> AppModel {
        var permissions = PermissionSnapshot(); permissions.microphone = .allowed
        return AppModel(isDemo: false, defaults: nil, backend: RealSessionBackend(audio: audio, transcriber: api), feedbackAPI: UnconfiguredFeedbackAPI(), feedbackPolicy: nil, cloud: cloud, permissionSnapshot: { permissions })
    }
    func testInitializationDoesNotConnectRegisterOrTranscribe() {
        let api = CoordinatorFakeAPI(), cloud = make(api)
        XCTAssertEqual(api.healthCalls, 0); XCTAssertEqual(api.prepares, 0); XCTAssertEqual(api.transcriptions, 0)
        XCTAssertFalse(cloud.accepted); XCTAssertNotNil(cloud.startBlockReason)
    }
    func testMissingDisclosureFailsClosedEvenWithEndpointAndKey() async {
        let api = CoordinatorFakeAPI(); api.credentialAvailable = true
        let cloud = CloudCoordinator(api: api, configuration: api.configuration, disclosure: nil)
        cloud.acceptAndConnect(); await settle()
        XCTAssertFalse(cloud.accepted); XCTAssertEqual(api.prepares, 0); XCTAssertNotNil(cloud.startBlockReason)
    }
    func testHealthOnlyDoesNotRegisterOrAcceptConsent() async {
        let api = CoordinatorFakeAPI(), cloud = make(api)
        cloud.checkHealthOnly(); await settle()
        XCTAssertEqual(api.healthCalls, 1); XCTAssertEqual(api.prepares, 0); XCTAssertFalse(cloud.accepted); XCTAssertFalse(cloud.connected)
    }
    func testAcceptedConnectUpdatesAuthorityAndRevokePreservesCredential() async {
        let api = CoordinatorFakeAPI(), cloud = make(api)
        cloud.acceptAndConnect(); await settle()
        XCTAssertTrue(cloud.accepted); XCTAssertTrue(cloud.connected); XCTAssertNil(cloud.startBlockReason)
        XCTAssertEqual(cloud.quota?.remaining, 50)
        cloud.revokeConsent(); XCTAssertFalse(cloud.accepted); XCTAssertNil(cloud.quota); XCTAssertTrue(api.credentialAvailable)
    }
    func testChangedPolicyOrOriginInvalidatesSavedConsentWithoutRealPreferences() async throws {
        let api = CoordinatorFakeAPI(); var stored: String?
        let first = CloudCoordinator(api: api, configuration: api.configuration, disclosure: disclosure, consentRead: { stored }, consentWrite: { stored = $0 })
        first.acceptAndConnect(); await settle()
        XCTAssertNotNil(stored)
        let same = CloudCoordinator(api: CoordinatorFakeAPI(), configuration: api.configuration, disclosure: disclosure, consentRead: { stored })
        XCTAssertTrue(same.accepted)
        let changed = CloudDisclosure(version: "mock-v1", receiver: "Different receiver", purpose: disclosure.purpose, retention: disclosure.retention)
        let other = CloudCoordinator(api: CoordinatorFakeAPI(), configuration: api.configuration, disclosure: changed, consentRead: { stored })
        XCTAssertFalse(other.accepted)
        let origin = try CloudConfiguration(baseURL: URL(string: "https://other.example.test")!)
        XCTAssertFalse(CloudCoordinator(api: CoordinatorFakeAPI(), configuration: origin, disclosure: disclosure, consentRead: { stored }).accepted)
    }
    func testFailedPreflightDoesNotOpenAudioAndClearsQuota() async {
        let api = CoordinatorFakeAPI(), cloud = make(api), audio = CoordinatorFakeAudio()
        let model = model(api, cloud, audio); model.showOnboarding = false
        cloud.acceptAndConnect(); await settle(); XCTAssertTrue(model.canStart)
        api.quotaError = .networkUnavailable
        model.beginSession(); await settle()
        XCTAssertEqual(audio.starts, 0); XCTAssertNil(model.quota); XCTAssertEqual(model.session.phase, .failed)
    }
    func testEntireFakeCloudSliceProducesPreviewAndHistory() async {
        let api = CoordinatorFakeAPI(), cloud = make(api), audio = CoordinatorFakeAudio()
        let model = model(api, cloud, audio); model.showOnboarding = false
        cloud.acceptAndConnect(); await settle()
        model.beginSession(); await settle(); XCTAssertEqual(audio.starts, 1)
        model.finishSession(); await settle()
        XCTAssertEqual(api.transcriptions, 1)
        XCTAssertEqual(model.session.result?.rawText, "[MOCK] raw \u{4E2D}\u{6587} English"); XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(model.records.first?.requestID, model.session.id)
        XCTAssertTrue(model.records.first?.hasAudio == true)
        XCTAssertTrue(model.hasTemporaryAudio); model.closeOrCancelSession()
    }
    func testLocalCheckNeverCallsCloudDespiteInjectedTranscriber() async {
        let api = CoordinatorFakeAPI(), cloud = make(api), audio = CoordinatorFakeAudio()
        let model = model(api, cloud, audio); model.showOnboarding = false; model.setLocalCaptureCheckEnabled(true)
        model.beginSession(); await settle(); model.finishSession(); await settle()
        XCTAssertEqual(audio.starts, 1); XCTAssertEqual(api.healthCalls, 0); XCTAssertEqual(api.transcriptions, 0)
        XCTAssertEqual(model.session.phase, .captured); model.setLocalCaptureCheckEnabled(false)
    }
    func testOriginalRequestPreviewHasMonotonicNonRenewingTTL() async throws {
        let api = CoordinatorFakeAPI(); let id = UUID(); api.pending = PendingTranscription(id: id, mode: .raw)
        let json: [String: Any] = ["requestId": id.uuidString, "status": "ready", "outputMode": "raw", "polishStatus": "not_requested", "rawText": "[MOCK]", "outputText": "[MOCK]", "resultExpiresAt": "2030-01-01T00:00:00Z", "quota": ["limit": 50, "used": 1, "reserved": 0, "remaining": 49, "resetAt": "2030-01-01T00:00:00+08:00"]]
        api.response = try JSONDecoder().decode(TranscriptionDTO.self, from: JSONSerialization.data(withJSONObject: json))
        var clock: TimeInterval = 10
        let cloud = CloudCoordinator(api: api, configuration: api.configuration, disclosure: disclosure, clock: { clock })
        cloud.inspectOriginalRequest(); await settle(); XCTAssertEqual(cloud.recovered?.deadline, 70)
        clock = 69; cloud.inspectOriginalRequest(); await settle(); XCTAssertEqual(cloud.recovered?.deadline, 70)
        clock = 70; cloud.tick(at: clock); XCTAssertNil(cloud.recovered)
        cloud.inspectOriginalRequest(); await settle(); XCTAssertNil(cloud.recovered)
        api.pending?.locallyCancelled = true; cloud.inspectOriginalRequest(); await settle(); XCTAssertNil(cloud.recovered)
    }
}
