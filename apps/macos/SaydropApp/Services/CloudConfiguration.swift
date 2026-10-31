import Foundation
import SaydropCore

struct CloudConfiguration: Equatable {
    let baseURL: URL
    let permitsLoopbackHTTP: Bool
    var origin: String { baseURL.absoluteString }
    init(baseURL: URL, permitsLoopbackHTTP: Bool = false) throws {
        guard let c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/",
              c.port.map({ (1...65535).contains($0) }) ?? true,
              !host.isEmpty, scheme == "https" || (scheme == "http" && permitsLoopbackHTTP && ["127.0.0.1", "[::1]", "::1", "localhost"].contains(host)) else { throw CloudClientError.configuration }
        var normalized = URLComponents(); normalized.scheme = scheme; normalized.host = host
        let port = c.port; normalized.port = port == (scheme == "https" ? 443 : 80) ? nil : port
        guard let url = normalized.url else { throw CloudClientError.configuration }
        self.baseURL = url; self.permitsLoopbackHTTP = permitsLoopbackHTTP
    }
    static func application(bundle: Bundle = .main) -> CloudConfiguration? {
        #if DEBUG
        let allowHTTP = true
        #else
        let allowHTTP = false
        #endif
        let configured = bundle.object(forInfoDictionaryKey: "SaydropBackendURL") as? String
        let value = configured.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } ?? ""
        guard let url = URL(string: value) else { return nil }
        return try? Self(baseURL: url, permitsLoopbackHTTP: allowHTTP)
    }
}

/// Operator-reviewed disclosure, never inferred from /healthz or a candidate model.
struct CloudDisclosure: Equatable {
    let version: String
    let receiver: String
    let purpose: String
    let retention: String
    var isConfigured: Bool {
        [version, receiver, purpose, retention].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 4000 && !$0.hasPrefix("$(") }
    }
    var identity: String { ((try? JSONEncoder().encode([version, receiver, purpose, retention])) ?? Data()).base64EncodedString() }
    static func application(bundle: Bundle = .main) -> Self? {
        let names = ["SaydropCloudDisclosureVersion", "SaydropCloudReceiver", "SaydropCloudPurpose", "SaydropCloudRetention"]
        let values = names.map { bundle.object(forInfoDictionaryKey: $0) as? String ?? "" }
        let value = Self(version: values[0], receiver: values[1], purpose: values[2], retention: values[3])
        return value.isConfigured ? value : nil
    }
}

struct InstallationCredential: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let installationID: UUID
    let accessToken: String
    var isValid: Bool { accessToken.count == 43 && accessToken.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 } }
    var description: String { "InstallationCredential(<redacted>)" }
    var debugDescription: String { description }
}
struct PendingTranscription: Codable, Equatable {
    let id: UUID
    let mode: OutputMode
    var locallyCancelled: Bool = false
}
@MainActor protocol InstallationCredentialStoring: AnyObject {
    func read(origin: String) throws -> InstallationCredential?
    func save(_ credential: InstallationCredential, origin: String) throws
}
@MainActor protocol PendingTranscriptionStoring: AnyObject {
    func read(origin: String) throws -> PendingTranscription?
    func save(_ pending: PendingTranscription?, origin: String) throws
}

@MainActor protocol CloudBusinessAPI: TranscriptionServicing {
    var configuration: CloudConfiguration { get }
    var credentialAvailable: Bool { get }
    var pending: PendingTranscription? { get }
    var onQuota: ((Quota?) -> Void)? { get set }
    var onPending: ((PendingTranscription?) -> Void)? { get set }
    func checkHealth() async throws
    func prepareCredential() async throws -> Quota
    func fetchQuota() async throws -> Quota
    func inspectPending() async throws -> TranscriptionDTO
    func abandonPendingRequest() throws
    func shutdown()
}

enum CloudClientError: Error, LocalizedError, Equatable {
    case configuration, credentialStorage, invalidResponse, networkUnavailable, unavailable, pendingRequest, resultUnknown, resultExpired, cancelled, timeout
    case api(code: String, status: Int, retryable: Bool)
    var errorDescription: String? {
        switch self {
        case .configuration: return "Invalid backend configuration. HTTP is allowed only for an explicitly configured local development address."
        case .credentialStorage: return "Secure storage for the anonymous credential is unavailable. It will not be saved in preferences or repeatedly registered."
        case .invalidResponse: return "The server response could not be verified. Check the original request; audio will not be uploaded again automatically."
        case .networkUnavailable: return "Cannot connect to the backend. Check your connection, then check the status of any submitted request."
        case .unavailable: return "The cloud connection or anonymous credential is not ready."
        case .pendingRequest: return "An earlier request needs review. Check its status first; the old recording will not be resent."
        case .resultUnknown: return "The earlier request's result cannot be confirmed yet. It may have counted against your quota; audio will not be uploaded again."
        case .resultExpired: return "This result has expired and cannot be recovered from the server."
        case .cancelled: return "This request was cancelled. Dispatched cloud processing may still count against your quota."
        case .timeout: return "Timed out waiting for the result. Check the original request; it will not be resent automatically."
        case .api(let code, _, _):
            switch code {
            case "invalid_token", "installation_revoked": return "The anonymous credential is unavailable. Check secure storage and the service; a new installation will not be registered to bypass quota."
            case "quota_exhausted": return "Today's transcription quota is exhausted. Wait for the server reset."
            case "rate_limited": return "Request rate or concurrency limit reached. Check again later."
            case "budget_unavailable": return "The server budget or provider configuration is unavailable. The request will not be resent automatically."
            case "empty_audio", "invalid_wav", "audio_too_long", "audio_too_large": return "The recording was empty, invalid, or over a limit. No transcript was produced."
            case "request_timeout": return "Server processing timed out. Check the original request; it may have counted against your quota."
            case "not_found": return "The original request was not found yet. It may still be uploading, so this does not prove it was not counted."
            case "idempotency_conflict": return "The request ID does not match the submitted content. It cannot be reused for different audio."
            default: return "Cloud processing is unavailable. Check the original request; it will not be resent automatically."
            }
        }
    }
}
