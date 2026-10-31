import Foundation
import SwiftUI
import CryptoKit
import SaydropCore

struct RecoveredCloudResult {
    let id: UUID
    let text: String
    let deadline: TimeInterval
}

@MainActor
final class CloudCoordinator: ObservableObject {
    let configuration: CloudConfiguration?
    let disclosure: CloudDisclosure?
    private let api: (any CloudBusinessAPI)?
    private let readConsent: () -> String?
    private let writeConsent: (String?) -> Void
    private let clock: () -> TimeInterval
    @Published private(set) var accepted = false
    @Published private(set) var connected = false
    @Published private(set) var isBusy = false
    @Published private(set) var quota: Quota?
    @Published private(set) var message: String?
    @Published private(set) var recovered: RecoveredCloudResult?
    @Published private(set) var canAbandonPending = false
    private var recoveryIdentity: (UUID, TimeInterval)?
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    var onUpdate: (() -> Void)?
    var transcriber: (any TranscriptionServicing)? { api }
    var pending: PendingTranscription? { api?.pending }
    var endpointTitle: String { configuration?.origin ?? "Backend address not configured" }
    var startBlockReason: String? {
        guard configuration != nil, api != nil else { return "Cloud client configuration or secure storage is unavailable." }
        guard disclosure?.isConfigured == true else { return "The backend address is configured, but recipient and retention disclosures are missing. Uploads remain disabled." }
        guard accepted else { return "Read and explicitly accept the cloud transcription disclosure first." }
        guard !isBusy else { return "Checking the cloud connection. Start after it completes." }
        guard connected, api?.credentialAvailable == true else { return "Connect to the backend and initialize the anonymous credential and quota first." }
        guard pending == nil else { return "An earlier request needs review. Check its status; the old recording will not be uploaded again." }
        return nil
    }
    private var consentKey: String { "Saydrop.cloudConsent.v1" }
    private var consentIdentity: String? {
        guard let configuration, let disclosure, disclosure.isConfigured else { return nil }
        let data = (try? JSONEncoder().encode([configuration.origin, disclosure.identity])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    init(api: (any CloudBusinessAPI)?, configuration: CloudConfiguration?, disclosure: CloudDisclosure?, defaults: UserDefaults? = nil,
         consentRead: (() -> String?)? = nil, consentWrite: ((String?) -> Void)? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.api = api; self.configuration = configuration; self.disclosure = disclosure; self.clock = clock
        readConsent = consentRead ?? { defaults?.string(forKey: "Saydrop.cloudConsent.v1") }
        writeConsent = consentWrite ?? { value in if let value { defaults?.set(value, forKey: "Saydrop.cloudConsent.v1") } else { defaults?.removeObject(forKey: "Saydrop.cloudConsent.v1") } }
        accepted = consentIdentity.map { readConsent() == $0 } ?? false
        api?.onQuota = { [weak self] quota in self?.quota = quota; self?.onUpdate?() }
        api?.onPending = { [weak self] _ in self?.objectWillChange.send(); self?.onUpdate?() }
    }
    static func application(defaults: UserDefaults) -> CloudCoordinator {
        let configuration = CloudConfiguration.application()
        let api = configuration.flatMap { try? TranscriptionAPIClient(configuration: $0, credentialStore: KeychainInstallationCredentialStore(), pendingStore: UserDefaultsPendingTranscriptionStore(defaults: defaults), deferCredentialRead: true) }
        return Self(api: api, configuration: configuration, disclosure: CloudDisclosure.application(), defaults: defaults)
    }
    func acceptAndConnect() {
        guard disclosure?.isConfigured == true, consentIdentity != nil, api != nil, !isBusy else { return }
        accepted = true; writeConsent(consentIdentity); onUpdate?(); connect()
    }
    func revokeConsent() {
        task?.cancel(); task = nil; operationID = nil; isBusy = false
        accepted = false; connected = false; quota = nil; recovered = nil
        writeConsent(nil); message = "New cloud transcription is disabled. The anonymous credential remains in Keychain, and earlier requests can still be checked."; onUpdate?()
    }
    func checkHealthOnly() {
        guard let api else { message = CloudClientError.configuration.localizedDescription; return }
        run { [weak self] in
            try await api.checkHealth(); try Task.checkCancellation()
            self?.message = "The health endpoint is reachable. This does not verify the provider, budget, or transcription."
        }
    }
    func connect() {
        guard let api, accepted, disclosure?.isConfigured == true else { message = "Cloud disclosure is missing or not accepted. Transcription will not be initialized."; return }
        run { [weak self] in
            try await api.checkHealth(); let quota = try await api.prepareCredential(); try Task.checkCancellation()
            self?.quota = quota; self?.connected = true; self?.message = "Anonymous credential and server quota are ready. A real provider call has not been verified in this run."
        }
    }
    /// Always recheck backend/quota BEFORE microphone start, not after the user speaks.
    func prepareForRecording() async throws {
        guard startBlockReason == nil, let api else { throw CloudClientError.unavailable }
        isBusy = true; onUpdate?()
        defer { isBusy = false; onUpdate?() }
        do {
            try await api.checkHealth(); try Task.checkCancellation()
            let value = try await api.fetchQuota(); try Task.checkCancellation()
            quota = value; connected = true
            guard value.remaining > 0 else { throw CloudClientError.api(code: "quota_exhausted", status: 429, retryable: false) }
        } catch {
            if !(error is CancellationError) { connected = false; quota = nil; message = safeMessage(error) }
            throw error
        }
    }
    func inspectOriginalRequest() {
        guard let api, let pending = api.pending else { message = "No earlier request is available to check."; return }
        run { [weak self] in
            let response = try await api.inspectPending(); try Task.checkCancellation()
            guard let self else { return }
            self.message = "Original request status: \(response.status.rawValue). Audio was not uploaded again."
            if pending.locallyCancelled { self.recovered = nil; return }
            guard response.status == .ready, let text = response.outputText else { self.recovered = nil; return }
            if self.recoveryIdentity?.0 != pending.id {
                var remaining = SaydropDefaults.temporaryAudioTTL
                if let date = response.resultExpiresAt.flatMap(Self.parseDate) { remaining = min(remaining, max(0, date.timeIntervalSinceNow)) }
                self.recoveryIdentity = (pending.id, self.clock() + remaining)
            }
            guard let deadline = self.recoveryIdentity?.1, deadline > self.clock() else { self.message = "The local recovery preview expired. Checking again will not extend it."; self.recovered = nil; return }
            self.recovered = RecoveredCloudResult(id: pending.id, text: text, deadline: deadline)
        }
    }
    func cancelOriginalRequest() {
        guard let pending else { return }; api?.cancel(id: pending.id); recovered = nil
        message = "Cancellation of the original task was requested. Dispatched processing may continue and quota may not be restored."; onUpdate?()
    }
    func abandonOriginalRequest() {
        guard canAbandonPending, !isBusy, let api else { return }
        do {
            try api.abandonPendingRequest(); canAbandonPending = false; recovered = nil
            message = "Recovery of the original request was abandoned. Refresh the connection before starting a new recording. A new session may count again; the old audio was not resent."
        } catch { message = safeMessage(error) }
        onUpdate?()
    }
    func clearRecoveredResult() { recovered = nil; onUpdate?() }
    func tick(at now: TimeInterval) { if let recovered, recovered.deadline <= now { self.recovered = nil; onUpdate?() } }
    func shutdown() { task?.cancel(); task = nil; api?.shutdown(); recovered = nil }
    private func run(_ work: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        let id = UUID(); operationID = id; isBusy = true; message = nil; onUpdate?()
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.operationID == id { self.operationID = nil; self.task = nil; self.isBusy = false; self.onUpdate?() } }
            do { try await work() }
            catch {
                if self.operationID == id && !Task.isCancelled {
                    self.connected = false; self.quota = nil; self.message = self.safeMessage(error)
                    if let error = error as? CloudClientError {
                        if error == .resultUnknown || error == .cancelled { self.canAbandonPending = self.pending != nil }
                        if case .api(let code, _, _) = error, code == "not_found" { self.canAbandonPending = self.pending != nil }
                    }
                }
            }
        }
    }
    private func safeMessage(_ error: Error) -> String { (error as? CloudClientError)?.localizedDescription ?? "The operation did not complete. Check the connection; no upload or new installation will start automatically." }
    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
