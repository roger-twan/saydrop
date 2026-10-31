import Foundation
import XCTest
import SaydropCore
@testable import SaydropUI

private final class MockFeedbackProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw FeedbackValidationError.unavailable }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@MainActor
final class FeedbackTransportTests: XCTestCase {
    let policy = FeedbackPolicy(baseURL: URL(string: "https://feedback.example.test")!, recipient: "\u{6D4B}\u{8BD5}", purpose: "\u{6D4B}\u{8BD5}", retention: "\u{6D4B}\u{8BD5}", deletionContact: "\u{6D4B}\u{8BD5}", version: "test-v1")
    private func api() throws -> FeedbackAPIClient {
        try FeedbackAPIClient(policy: policy, credential: .serviceScoped(token: "mock-credential-only"), protocolClasses: [MockFeedbackProtocol.self])
    }
    func testPositivePOSTUsesExpectedHeadersAndReliableReceipt() async throws {
        let feedback = PositiveFeedback(requestID: UUID(), mode: .raw)
        MockFeedbackProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/feedback"); XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), feedback.id.uuidString)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mock-credential-only")
            let receipt = FeedbackReceipt(feedbackId: feedback.id, status: .received, receivedAt: "2026-10-26T11:11:00+08:00")
            return (201, try JSONEncoder().encode(receipt))
        }
        defer { MockFeedbackProtocol.handler = nil }
        let receipt = try await api().submitPositive(feedback); XCTAssertTrue(receipt.isReliableSuccess)
    }
    func testHTTP202NeverMeansSubmittedEvenWithReceivedBody() async throws {
        let feedback = PositiveFeedback(requestID: UUID(), mode: .raw)
        MockFeedbackProtocol.handler = { _ in (202, try JSONEncoder().encode(FeedbackReceipt(feedbackId: feedback.id, status: .received, receivedAt: "2026-10-26T11:11:00+08:00"))) }
        defer { MockFeedbackProtocol.handler = nil }
        let receipt = try await api().submitPositive(feedback); XCTAssertFalse(receipt.isReliableSuccess); XCTAssertEqual(receipt.status, .processing)
    }
    func testGETReceiptDoesNotResendPayload() async throws {
        let id = UUID()
        MockFeedbackProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody); XCTAssertNil(request.httpBodyStream)
            XCTAssertEqual(request.url?.path, "/v1/feedback/\(id.uuidString)")
            return (200, try JSONEncoder().encode(FeedbackReceipt(feedbackId: id, status: .processing)))
        }
        defer { MockFeedbackProtocol.handler = nil }
        let receipt = try await api().status(id)
        XCTAssertEqual(receipt.status, .processing)
    }
    func testMismatchedReceiptIsUnknownNotSuccess() async throws {
        MockFeedbackProtocol.handler = { _ in (201, try JSONEncoder().encode(FeedbackReceipt(feedbackId: UUID(), status: .received, receivedAt: "2026-10-26T11:11:00+08:00"))) }
        defer { MockFeedbackProtocol.handler = nil }
        do { _ = try await api().submitPositive(PositiveFeedback(requestID: UUID(), mode: .raw)); XCTFail("\u{9519}\u{8BEF}\u{56DE}\u{6267}\u{4E0D}\u{5E94}\u{88AB}\u{63A5}\u{53D7}") } catch { XCTAssertEqual(error as? FeedbackValidationError, .submissionUnknown) }
    }
    func testServerErrorDoesNotAutomaticallyRetryPOST() async throws {
        var count = 0
        MockFeedbackProtocol.handler = { _ in count += 1; return (503, Data("{}".utf8)) }
        defer { MockFeedbackProtocol.handler = nil }
        do { _ = try await api().submitPositive(PositiveFeedback(requestID: UUID(), mode: .raw)); XCTFail("503\u{4E0D}\u{5E94}\u{6210}\u{529F}") } catch { XCTAssertEqual(count, 1) }
    }
    func testInvalidAudioRejectedBeforeHTTP() async throws {
        var count = 0
        MockFeedbackProtocol.handler = { _ in count += 1; return (503, Data()) }
        defer { MockFeedbackProtocol.handler = nil }
        let draft = FeedbackDraft(requestID: UUID(), outputMode: .raw, rawText: "\u{6D4B}\u{8BD5}", outputText: "\u{6D4B}\u{8BD5}", audio: Data([1]), duration: 1)
        let confirmed = try draft.confirm(policy: policy, at: Date(), uptime: 0)
        do { _ = try await api().submit(confirmed); XCTFail("\u{65E0}\u{6548}WAV\u{4E0D}\u{80FD}\u{53D1}\u{9001}") } catch { XCTAssertEqual(error as? FeedbackValidationError, .invalidPayload) }
        XCTAssertEqual(count, 0)
    }
}
