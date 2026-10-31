import Foundation
import XCTest
import SaydropCore
@testable import SaydropUI

private struct MockCloudReply {
    let status: Int
    let data: Data
    let headers: [String: String]
    let finishes: Bool

    init(_ status: Int, _ data: Data, headers: [String: String] = ["Content-Type": "application/json", "Cache-Control": "no-store"], finishes: Bool = true) {
        self.status = status
        self.data = data
        self.headers = headers
        self.finishes = finishes
    }
}

private final class MockCloudURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> MockCloudReply)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw CloudClientError.unavailable }
            var inspected = request
            if inspected.httpBody == nil, let stream = inspected.httpBodyStream {
                stream.open(); defer { stream.close() }
                var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                inspected.httpBody = body
            }
            let reply = try handler(inspected)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.data.isEmpty { client?.urlProtocol(self, didLoad: reply.data) }
            if reply.finishes { client?.urlProtocolDidFinishLoading(self) }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
private final class FakeCredentialStore: InstallationCredentialStoring {
    var value: InstallationCredential?
    var saveFailure = false
    private(set) var saveCount = 0
    private(set) var readCount = 0

    init(_ value: InstallationCredential? = nil) { self.value = value }

    func read(origin: String) throws -> InstallationCredential? { readCount += 1; return value }
    func save(_ credential: InstallationCredential, origin: String) throws {
        saveCount += 1
        if saveFailure { throw CloudClientError.credentialStorage }
        value = credential
    }
}

@MainActor
private final class FakePendingStore: PendingTranscriptionStoring {
    var value: PendingTranscription?
    var saveFailure = false
    private(set) var savedValues: [PendingTranscription?] = []

    init(_ value: PendingTranscription? = nil) { self.value = value }

    func read(origin: String) throws -> PendingTranscription? { value }
    func save(_ pending: PendingTranscription?, origin: String) throws {
        if saveFailure { throw CloudClientError.credentialStorage }
        value = pending
        savedValues.append(pending)
    }
}

@MainActor
final class CloudTransportTests: XCTestCase {
    private let token = String(repeating: "a", count: 43)

    override func setUp() {
        super.setUp()
        MockCloudURLProtocol.handler = nil
    }

    override func tearDown() {
        MockCloudURLProtocol.handler = nil
        super.tearDown()
    }

    func testTranscriptionUsesOnlyExpectedRawWAVHeadersAndReturnsRawResult() async throws {
        let credential = InstallationCredential(installationID: UUID(), accessToken: token)
        let credentialStore = FakeCredentialStore(credential)
        let pendingStore = FakePendingStore()
        let requestID = UUID()
        let wav = validWAV()
        var postCount = 0
        var getCount = 0
        MockCloudURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.example.test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.token)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/transcriptions"):
                postCount += 1
                XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), requestID.uuidString)
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Output-Mode"), "raw")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
                XCTAssertEqual(request.httpBody, wav)
                return self.taskReply(id: requestID, status: "processing", mode: nil, polish: nil)
            case ("GET", "/v1/transcriptions/\(requestID.uuidString)"):
                getCount += 1
                return self.taskReply(id: requestID, status: "ready", mode: "raw", polish: "not_requested", raw: "hello", output: "hello", expires: "2026-10-27T00:00:00+08:00")
            default:
                XCTFail("unexpected request \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return MockCloudReply(500, Data())
            }
        }
        let api = try makeClient(credentialStore: credentialStore, pendingStore: pendingStore)

        let result = try await api.transcribe(wav, id: requestID, mode: .raw, stage: { _ in })

        XCTAssertEqual(postCount, 1)
        XCTAssertEqual(getCount, 1)
        XCTAssertEqual(result, SessionResult(rawText: "hello", outputText: "hello", targetName: nil, polishFallback: false))
        XCTAssertNil(api.pending)
        XCTAssertFalse(pendingStore.savedValues.isEmpty)
    }

    func testPrepareRegistersOnceThenUsesSavedCredentialForQuota() async throws {
        let credentialStore = FakeCredentialStore()
        let pendingStore = FakePendingStore()
        let issuedID = UUID()
        var registrationCount = 0
        var quotaCount = 0
        MockCloudURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/installations"):
                registrationCount += 1
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                XCTAssertEqual(try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String], ["clientVersion": "0.1.0", "platform": "macos-arm64"])
                return MockCloudReply(201, self.json([
                    "installationId": issuedID.uuidString, "accessToken": self.token, "quota": self.quotaJSON()
                ]))
            case ("GET", "/v1/quota"):
                quotaCount += 1
                return MockCloudReply(200, self.json(self.quotaJSON()))
            default:
                XCTFail("unexpected path")
                return MockCloudReply(500, Data())
            }
        }
        let api = try makeClient(credentialStore: credentialStore, pendingStore: pendingStore)

        let first = try await api.prepareCredential()
        let second = try await api.prepareCredential()

        XCTAssertEqual(first.remaining, 50)
        XCTAssertEqual(second.remaining, 50)
        XCTAssertEqual(registrationCount, 1)
        XCTAssertEqual(quotaCount, 1)
        XCTAssertEqual(credentialStore.saveCount, 1)
        XCTAssertTrue(api.credentialAvailable)
    }

    func testFailedCredentialSaveDoesNotRegisterAgain() async throws {
        let credentialStore = FakeCredentialStore()
        credentialStore.saveFailure = true
        let pendingStore = FakePendingStore()
        var registrations = 0
        MockCloudURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/installations")
            registrations += 1
            return MockCloudReply(201, self.json([
                "installationId": UUID().uuidString, "accessToken": self.token, "quota": self.quotaJSON()
            ]))
        }
        let api = try makeClient(credentialStore: credentialStore, pendingStore: pendingStore)

        do { _ = try await api.prepareCredential(); XCTFail("Keychain-like save failure must fail closed") }
        catch { XCTAssertEqual(error as? CloudClientError, .credentialStorage) }
        do { _ = try await api.prepareCredential(); XCTFail("an issued but unsaved credential must not re-register") }
        catch { XCTAssertEqual(error as? CloudClientError, .credentialStorage) }

        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(credentialStore.saveCount, 2)
        XCTAssertFalse(api.credentialAvailable)
    }

    func testExistingCredentialFetchesQuotaWithoutRegistrationAndClearsQuotaOnFailure() async throws {
        let credentialStore = FakeCredentialStore(InstallationCredential(installationID: UUID(), accessToken: token))
        let pendingStore = FakePendingStore()
        var quotaEvents: [Quota?] = []
        MockCloudURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/quota")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.token)")
            return MockCloudReply(200, self.json(self.quotaJSON()))
        }
        let api = try makeClient(credentialStore: credentialStore, pendingStore: pendingStore)
        api.onQuota = { quotaEvents.append($0) }
        _ = try await api.prepareCredential()
        MockCloudURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        do { _ = try await api.fetchQuota(); XCTFail("network failure must not preserve an old authoritative quota") }
        catch { XCTAssertEqual(error as? CloudClientError, .networkUnavailable) }

        XCTAssertEqual(quotaEvents.compactMap { $0 }.count, 1)
        XCTAssertNil(quotaEvents.last!)
    }

    func testLostPostResponseRecoversOnlyByGETOfSameRequestID() async throws {
        let requestID = UUID()
        let credentialStore = FakeCredentialStore(InstallationCredential(installationID: UUID(), accessToken: token))
        let pendingStore = FakePendingStore()
        var postCount = 0
        var getCount = 0
        MockCloudURLProtocol.handler = { request in
            switch request.httpMethod {
            case "POST":
                postCount += 1
                throw URLError(.networkConnectionLost)
            case "GET":
                getCount += 1
                XCTAssertEqual(request.url?.path, "/v1/transcriptions/\(requestID.uuidString)")
                return self.taskReply(id: requestID, status: "ready", mode: "raw", polish: "not_requested", raw: "recovered", output: "recovered", expires: "2026-10-27T00:00:00+08:00")
            default:
                XCTFail("no retry POST or other request is permitted")
                return MockCloudReply(500, Data())
            }
        }
        let api = try makeClient(credentialStore: credentialStore, pendingStore: pendingStore)

        let result = try await api.transcribe(validWAV(), id: requestID, mode: .raw, stage: { _ in })

        XCTAssertEqual(result.rawText, "recovered")
        XCTAssertEqual(postCount, 1)
        XCTAssertEqual(getCount, 1)
        XCTAssertNil(api.pending)
    }

    func testLightPolishFallbackIsExplicitButRawCannotPretendToBePolished() async throws {
        let fallbackID = UUID()
        let credentialStore = FakeCredentialStore(InstallationCredential(installationID: UUID(), accessToken: token))
        let pendingStore = FakePendingStore()
        var phase = 0
        MockCloudURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                phase += 1
                return self.taskReply(id: fallbackID, status: "processing", mode: nil, polish: nil)
            }
            return self.taskReply(id: fallbackID, status: "ready", mode: "light_polish", polish: "failed_fallback_raw", raw: "A-204", output: "A-204", expires: "2026-10-27T00:00:00+08:00")
        }
        let api = try makeClient(credentialStore: credentialStore, pendingStore: pendingStore)
        let fallback = try await api.transcribe(validWAV(), id: fallbackID, mode: .lightPolish, stage: { _ in })
        XCTAssertTrue(fallback.polishFallback)
        XCTAssertEqual(fallback.rawText, fallback.outputText)
        XCTAssertEqual(phase, 1)

        let badID = UUID()
        let secondStore = FakePendingStore()
        MockCloudURLProtocol.handler = { request in
            if request.httpMethod == "POST" { return self.taskReply(id: badID, status: "processing", mode: nil, polish: nil) }
            return self.taskReply(id: badID, status: "ready", mode: "raw", polish: "not_requested", raw: "raw", output: "invented polish", expires: "2026-10-27T00:00:00+08:00")
        }
        let second = try makeClient(credentialStore: credentialStore, pendingStore: secondStore)
        do { _ = try await second.transcribe(validWAV(), id: badID, mode: .raw, stage: { _ in }); XCTFail("raw mode must not accept changed output") }
        catch { XCTAssertEqual(error as? CloudClientError, .invalidResponse) }
    }

    func testUnsafeIDsExpiredReadyAndOversizedResponseFailClosed() async throws {
        let credentialStore = FakeCredentialStore(InstallationCredential(installationID: UUID(), accessToken: token))
        let pendingStore = FakePendingStore()
        let requestID = UUID()
        MockCloudURLProtocol.handler = { request in
            if request.httpMethod == "POST" { return self.taskReply(id: requestID, status: "processing", mode: nil, polish: nil) }
            return self.taskReply(id: UUID(), status: "ready", mode: "raw", polish: "not_requested", raw: "x", output: "x", expires: "not-an-iso-date")
        }
        let api = try makeClient(credentialStore: credentialStore, pendingStore: pendingStore)
        do { _ = try await api.transcribe(validWAV(), id: requestID, mode: .raw, stage: { _ in }); XCTFail("mismatched task ID or bad expiry must fail") }
        catch { XCTAssertEqual(error as? CloudClientError, .invalidResponse) }

        MockCloudURLProtocol.handler = { _ in MockCloudReply(200, Data(repeating: 1, count: CloudHTTPTransport.maximumResponseBytes + 1)) }
        let quotaAPI = try makeClient(credentialStore: credentialStore, pendingStore: FakePendingStore())
        do { _ = try await quotaAPI.fetchQuota(); XCTFail("responses over 1 MiB must be rejected while streaming") }
        catch { XCTAssertEqual(error as? CloudClientError, .invalidResponse) }
    }

    func testRedirectIsRejectedWithoutFollowingTarget() async throws {
        let credentialStore = FakeCredentialStore(InstallationCredential(installationID: UUID(), accessToken: token))
        var calls = 0
        MockCloudURLProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.url?.host, "api.example.test")
            return MockCloudReply(302, Data(), headers: ["Location": "https://attacker.example.test/v1/quota"])
        }
        let api = try makeClient(credentialStore: credentialStore, pendingStore: FakePendingStore())

        do { _ = try await api.fetchQuota(); XCTFail("redirects must not be followed") }
        catch { XCTAssertEqual(error as? CloudClientError, .invalidResponse) }
        XCTAssertEqual(calls, 1)
    }

    func testCancelBeforeAcceptanceKeepsLocalShieldAcross404ThenStopsAtCancellation() async throws {
        let requestID = UUID()
        let credentialStore = FakeCredentialStore(InstallationCredential(installationID: UUID(), accessToken: token))
        let pendingStore = FakePendingStore(PendingTranscription(id: requestID, mode: .raw))
        var deleteCount = 0
        var getCount = 0
        MockCloudURLProtocol.handler = { request in
            switch request.httpMethod {
            case "DELETE":
                deleteCount += 1
                if deleteCount == 1 {
                    return MockCloudReply(404, self.json(["error": ["code": "not_found", "message": "ignored", "retryable": true]]))
                }
                return MockCloudReply(200, self.json([
                    "requestId": requestID.uuidString, "status": "cancelled", "cancellationRecorded": true, "quota": self.quotaJSON()
                ]))
            case "GET":
                getCount += 1
                return self.taskReply(id: requestID, status: "processing", mode: "raw", polish: "not_requested")
            default:
                XCTFail("unexpected request")
                return MockCloudReply(500, Data())
            }
        }
        let api = try makeClient(credentialStore: credentialStore, pendingStore: pendingStore)

        api.cancel(id: requestID)
        for _ in 0..<200 {
            if api.pending == nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(deleteCount, 2)
        XCTAssertEqual(getCount, 1)
        XCTAssertNil(api.pending)
        XCTAssertNil(pendingStore.value)
    }

    func testRestartInspectUsesPendingIDAndNeverPostsAgain() async throws {
        let requestID = UUID()
        let credentialStore = FakeCredentialStore(InstallationCredential(installationID: UUID(), accessToken: token))
        let pendingStore = FakePendingStore(PendingTranscription(id: requestID, mode: .raw))
        var postCount = 0
        MockCloudURLProtocol.handler = { request in
            if request.httpMethod == "POST" { postCount += 1; return MockCloudReply(500, Data()) }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/transcriptions/\(requestID.uuidString)")
            return self.taskReply(id: requestID, status: "ready", mode: "raw", polish: "not_requested", raw: "after restart", output: "after restart", expires: "2026-10-27T00:00:00+08:00")
        }
        let api = try makeClient(credentialStore: credentialStore, pendingStore: pendingStore)

        let dto = try await api.inspectPending()

        XCTAssertEqual(dto.requestId, requestID)
        XCTAssertEqual(postCount, 0)
        XCTAssertNil(api.pending)
    }

    func testUploadAndPollingShareOneMonotonicDeadline() async throws {
        let id = UUID(), store = FakeCredentialStore(InstallationCredential(installationID: UUID(), accessToken: token)), pending = FakePendingStore()
        var now: TimeInterval = 1, posts = 0, gets = 0
        MockCloudURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                posts += 1; now = 31
                return self.taskReply(id: id, status: "processing", mode: nil, polish: nil)
            }
            gets += 1
            return self.taskReply(id: id, status: "processing", mode: "raw", polish: "not_requested")
        }
        let configuration = try CloudConfiguration(baseURL: URL(string: "https://api.example.test")!)
        let api = try TranscriptionAPIClient(configuration: configuration, credentialStore: store, pendingStore: pending,
                                             protocolClasses: [MockCloudURLProtocol.self], clock: { now }, sleep: { now += $0 })
        addTeardownBlock { await MainActor.run { api.shutdown() } }
        do { _ = try await api.transcribe(validWAV(), id: id, mode: .raw, stage: { _ in }); XCTFail("must stop at original 60s deadline") }
        catch { XCTAssertEqual(error as? CloudClientError, .timeout) }
        XCTAssertEqual(now, 61); XCTAssertEqual(posts, 1); XCTAssertLessThanOrEqual(gets, 15); XCTAssertEqual(api.pending?.id, id)
    }

    func testFractionalISOQuotaAndMaliciousIntegerAreHandledWithoutOverflow() async throws {
        let store = FakeCredentialStore(InstallationCredential(installationID: UUID(), accessToken: token))
        MockCloudURLProtocol.handler = { _ in
            var value = self.quotaJSON(); value["resetAt"] = "2026-10-27T00:00:00.123456+08:00"
            return MockCloudReply(200, self.json(value))
        }
        let api = try makeClient(credentialStore: store, pendingStore: FakePendingStore())
        let first = try await api.fetchQuota()
        XCTAssertEqual(first.remaining, 50)
        MockCloudURLProtocol.handler = { _ in
            var value = self.quotaJSON(); value["used"] = Int.max; value["reserved"] = Int.max
            return MockCloudReply(200, self.json(value))
        }
        do { _ = try await api.fetchQuota(); XCTFail("overflow-sized quota must fail closed") }
        catch { XCTAssertEqual(error as? CloudClientError, .invalidResponse) }
    }

    func testUnknownCanOnlyBeAbandonedAfterExplicitInspectionWithoutPOST() async throws {
        let id = UUID(), store = FakeCredentialStore(InstallationCredential(installationID: UUID(), accessToken: token))
        let pending = FakePendingStore(PendingTranscription(id: id, mode: .raw)); var calls = 0
        MockCloudURLProtocol.handler = { request in
            calls += 1; XCTAssertEqual(request.httpMethod, "GET")
            return self.taskReply(id: id, status: "unknown", mode: "raw", polish: "not_requested")
        }
        let api = try makeClient(credentialStore: store, pendingStore: pending)
        XCTAssertThrowsError(try api.abandonPendingRequest()); XCTAssertEqual(api.pending?.id, id)
        do { _ = try await api.inspectPending(); XCTFail("unknown is not a ready result") }
        catch { XCTAssertEqual(error as? CloudClientError, .resultUnknown) }
        XCTAssertEqual(api.pending?.id, id)
        try api.abandonPendingRequest(); XCTAssertNil(api.pending); XCTAssertEqual(calls, 1)
    }

    func testExpiredResultIsNotRecoveredAndReleasesMarker() async throws {
        let id = UUID(), store = FakeCredentialStore(InstallationCredential(installationID: UUID(), accessToken: token))
        MockCloudURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return self.taskReply(id: id, status: "result_expired", mode: "raw", polish: "not_requested", expires: "2020-01-01T00:00:00.123Z")
        }
        let api = try makeClient(credentialStore: store, pendingStore: FakePendingStore(PendingTranscription(id: id, mode: .raw)))
        do { _ = try await api.inspectPending(); XCTFail("expired result cannot contain recovered text") }
        catch { XCTAssertEqual(error as? CloudClientError, .resultExpired) }
        XCTAssertNil(api.pending)
    }

    func testOldCancellationIDCannotTouchDifferentPendingRequest() async throws {
        let id = UUID(), store = FakeCredentialStore(InstallationCredential(installationID: UUID(), accessToken: token))
        let api = try makeClient(credentialStore: store, pendingStore: FakePendingStore(PendingTranscription(id: id, mode: .raw)))
        MockCloudURLProtocol.handler = { _ in XCTFail("old cancellation must not create HTTP"); return MockCloudReply(500, Data()) }
        api.cancel(id: UUID()); await Task.yield()
        XCTAssertEqual(api.pending?.id, id); XCTAssertEqual(api.pending?.locallyCancelled, false)
    }

    func testConcurrentPreparationCannotRegisterTwoInstallations() async throws {
        var registrations = 0
        MockCloudURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST"); registrations += 1
            return MockCloudReply(201, self.json(["installationId": UUID().uuidString, "accessToken": self.token, "quota": self.quotaJSON()]))
        }
        let api = try makeClient(credentialStore: FakeCredentialStore(), pendingStore: FakePendingStore())
        let a = Task { try await api.prepareCredential() }, b = Task { try await api.prepareCredential() }
        let results = await (a.result, b.result)
        var successes = 0
        if case .success = results.0 { successes += 1 }; if case .success = results.1 { successes += 1 }
        XCTAssertEqual(successes, 1); XCTAssertEqual(registrations, 1)
    }

    func testForegroundSlowResponseHasAnIndependentDeadline() async throws {
        MockCloudURLProtocol.handler = { _ in MockCloudReply(200, Data(), finishes: false) }
        let transport = CloudHTTPTransport(protocolClasses: [MockCloudURLProtocol.self]); defer { transport.invalidate() }
        var request = URLRequest(url: URL(string: "https://api.example.test/healthz")!); request.timeoutInterval = 0.03
        let start = ProcessInfo.processInfo.systemUptime
        do { _ = try await transport.execute(request); XCTFail("a response that never finishes must time out") }
        catch { XCTAssertTrue(error as? CloudClientError == .timeout || (error as? URLError)?.code == .timedOut) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testAppBootstrapAndHealthDoNotReadKeychainBeforeExplicitPrepare() async throws {
        let store = FakeCredentialStore(), configuration = try CloudConfiguration(baseURL: URL(string: "https://api.example.test")!)
        let api = try TranscriptionAPIClient(configuration: configuration, credentialStore: store, pendingStore: FakePendingStore(), deferCredentialRead: true, protocolClasses: [MockCloudURLProtocol.self])
        addTeardownBlock { await MainActor.run { api.shutdown() } }
        XCTAssertEqual(store.readCount, 0)
        MockCloudURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); return MockCloudReply(200, self.json(["status": "ok"]))
        }
        try await api.checkHealth(); XCTAssertEqual(store.readCount, 0)
        MockCloudURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/installations")
            return MockCloudReply(201, self.json(["installationId": UUID().uuidString, "accessToken": self.token, "quota": self.quotaJSON()]))
        }
        _ = try await api.prepareCredential(); XCTAssertEqual(store.readCount, 1); XCTAssertEqual(store.saveCount, 1)
    }

    private func makeClient(credentialStore: FakeCredentialStore, pendingStore: FakePendingStore) throws -> TranscriptionAPIClient {
        let configuration = try CloudConfiguration(baseURL: URL(string: "https://api.example.test")!)
        let client = try TranscriptionAPIClient(configuration: configuration, credentialStore: credentialStore, pendingStore: pendingStore,
                                          protocolClasses: [MockCloudURLProtocol.self], clock: { 1 }, sleep: { _ in })
        addTeardownBlock { await MainActor.run { client.shutdown() } }
        return client
    }

    private func quotaJSON() -> [String: Any] {
        ["limit": 50, "used": 0, "reserved": 0, "remaining": 50, "resetAt": "2026-10-27T00:00:00+08:00"]
    }

    private func taskReply(id: UUID, status: String, mode: String?, polish: String?, raw: String? = nil,
                           output: String? = nil, expires: String? = nil) -> MockCloudReply {
        var value: [String: Any] = ["requestId": id.uuidString, "status": status, "quota": quotaJSON()]
        if let mode { value["outputMode"] = mode }
        if let polish { value["polishStatus"] = polish }
        if let raw { value["rawText"] = raw }
        if let output { value["outputText"] = output }
        if let expires { value["resultExpiresAt"] = expires }
        return MockCloudReply(mode == nil ? 202 : 200, json(value))
    }

    private func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [])) ?? Data()
    }

    private func validWAV() -> Data {
        let samples: [UInt8] = [0x01, 0x00, 0xff, 0xff]
        var bytes = Array(repeating: UInt8(0), count: 44 + samples.count)
        func putTag(_ offset: Int, _ text: String) {
            for (index, byte) in text.utf8.enumerated() { bytes[offset + index] = byte }
        }
        func put16(_ offset: Int, _ value: Int) {
            bytes[offset] = UInt8(value & 0xff)
            bytes[offset + 1] = UInt8((value >> 8) & 0xff)
        }
        func put32(_ offset: Int, _ value: Int) {
            bytes[offset] = UInt8(value & 0xff)
            bytes[offset + 1] = UInt8((value >> 8) & 0xff)
            bytes[offset + 2] = UInt8((value >> 16) & 0xff)
            bytes[offset + 3] = UInt8((value >> 24) & 0xff)
        }
        putTag(0, "RIFF"); put32(4, bytes.count - 8); putTag(8, "WAVE"); putTag(12, "fmt ")
        put32(16, 16); put16(20, 1); put16(22, 1); put32(24, 16_000); put32(28, 32_000); put16(32, 2); put16(34, 16)
        putTag(36, "data"); put32(40, samples.count)
        bytes.replaceSubrange(44..<bytes.count, with: samples)
        return Data(bytes)
    }
}
