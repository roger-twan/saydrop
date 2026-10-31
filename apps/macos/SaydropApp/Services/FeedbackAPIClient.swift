import Foundation
import SaydropCore

@MainActor
protocol FeedbackAPI {
    func submit(_ feedback: ConfirmedFeedback) async throws -> FeedbackReceipt
    func submitPositive(_ feedback: PositiveFeedback) async throws -> FeedbackReceipt
    func status(_ id: UUID) async throws -> FeedbackReceipt
    func cancel()
}
@MainActor
final class UnconfiguredFeedbackAPI: FeedbackAPI {
    func submit(_ feedback: ConfirmedFeedback) async throws -> FeedbackReceipt { throw FeedbackValidationError.unavailable }
    func submitPositive(_ feedback: PositiveFeedback) async throws -> FeedbackReceipt { throw FeedbackValidationError.unavailable }
    func status(_ id: UUID) async throws -> FeedbackReceipt { throw FeedbackValidationError.unavailable }
    func cancel() {}
}
/// Reject every redirect, including same-origin: consent is for one configured receiving endpoint.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
/// Expected v1 mapping only; real service contract must be reviewed before injecting this adapter.
@MainActor
final class FeedbackAPIClient: FeedbackAPI {
    enum Credential {
        case sameOriginInstallation(token: String, transcriptionBaseURL: URL)
        case serviceScoped(token: String)
    }
    private let policy: FeedbackPolicy
    private let token: String
    private let delegate = NoRedirectDelegate()
    private let session: URLSession
    private var currentTask: Task<FeedbackReceipt, Error>?
    init(policy: FeedbackPolicy, credential: Credential, protocolClasses: [AnyClass]? = nil) throws {
        guard policy.isConfigured else { throw FeedbackValidationError.policyUnavailable }
        switch credential {
        case .sameOriginInstallation(let token, let baseURL):
            guard OriginSafety.sameOrigin(baseURL, policy.baseURL), !token.isEmpty else { throw FeedbackValidationError.unavailable }
            self.token = token
        case .serviceScoped(let token):
            guard !token.isEmpty else { throw FeedbackValidationError.unavailable }; self.token = token
        }
        self.policy = policy
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { config.protocolClasses = protocolClasses }
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    func submit(_ feedback: ConfirmedFeedback) async throws -> FeedbackReceipt {
        guard feedback.policy == policy else { throw FeedbackValidationError.consentChanged }
        if let deadline = feedback.draft.audioDeadline, feedback.draft.includeAudio, ProcessInfo.processInfo.systemUptime >= deadline {
            throw FeedbackValidationError.audioExpired
        }
        if feedback.draft.includeAudio, let audio = feedback.draft.audio {
            do { _ = try WAVMetadata.parse(audio) } catch { throw FeedbackValidationError.invalidPayload }
        }
        return try await send(path: "v1/feedback", id: feedback.id, body: feedback.encodedPayload())
    }
    func submitPositive(_ feedback: PositiveFeedback) async throws -> FeedbackReceipt {
        try await send(path: "v1/feedback", id: feedback.id, body: feedback.encodedPayload())
    }
    func status(_ id: UUID) async throws -> FeedbackReceipt { try await send(path: "v1/feedback/\(id.uuidString)", id: id, body: nil) }
    func cancel() { currentTask?.cancel() }
    private func send(path: String, id: UUID, body: Data?) async throws -> FeedbackReceipt {
        guard currentTask == nil else { throw FeedbackValidationError.unavailable }
        var request = URLRequest(url: policy.baseURL.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(id.uuidString, forHTTPHeaderField: "Idempotency-Key")
            request.httpBody = body
        }
        let session = session
        let task = Task { () throws -> FeedbackReceipt in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  [200, 201, 202].contains(response.statusCode) else { throw FeedbackValidationError.submissionUnknown }
            guard data.count <= 64 * 1024 else { throw FeedbackValidationError.submissionUnknown }
            let receipt = try JSONDecoder().decode(FeedbackReceipt.self, from: data)
            guard receipt.feedbackId == id else { throw FeedbackValidationError.submissionUnknown }
            if response.statusCode == 202 { return FeedbackReceipt(feedbackId: id, status: .processing) }
            return receipt
        }
        currentTask = task
        defer { currentTask = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
