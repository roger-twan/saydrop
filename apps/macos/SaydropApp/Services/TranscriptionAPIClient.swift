import Foundation
import SaydropCore

@MainActor
final class TranscriptionAPIClient: CloudBusinessAPI {
    private static let clientVersion = "0.1.0"
    private static let platform = "macos-arm64"
    private static let pollInterval: TimeInterval = 2
    private static let taskDeadline: TimeInterval = 60
    private static let shortRequestTimeout: TimeInterval = 10
    private static let uploadRequestTimeout: TimeInterval = 30
    private static let maximumResultCharacters = 32_000

    let configuration: CloudConfiguration
    private let credentialStore: any InstallationCredentialStoring
    private let pendingStore: any PendingTranscriptionStoring
    private let transport: CloudHTTPTransport
    private let clock: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void

    private var credential: InstallationCredential?
    /// A just-issued credential is deliberately unusable until it has reached the secure store.
    private var credentialPersisted = false
    private var credentialReadPerformed = false
    /// A registration whose response could not be verified must not be retried in this process.
    private var registrationBlocked = false
    private var preparingCredential = false
    private var quota: Quota?
    private var requestTimes: [TimeInterval] = []
    private var activeRequestID: UUID?
    private var activeGeneration: UUID?
    private var currentOperation: Task<SessionResult, Error>?
    private var cancellationGenerations: [UUID: UUID] = [:]
    private var cancellationTasks: [UUID: Task<Void, Never>] = [:]
    private var isShutdown = false
    private var inspectedUnrecoverableID: UUID?

    private(set) var pending: PendingTranscription?
    var credentialAvailable: Bool { credentialPersisted && credential?.isValid == true && !isShutdown }
    var isConfigured: Bool { !isShutdown }
    var onQuota: ((Quota?) -> Void)? { didSet { onQuota?(quota) } }
    var onPending: ((PendingTranscription?) -> Void)? { didSet { onPending?(pending) } }

    init(configuration: CloudConfiguration,
         credentialStore: any InstallationCredentialStoring,
         pendingStore: any PendingTranscriptionStoring,
         deferCredentialRead: Bool = false,
         protocolClasses: [AnyClass]? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) throws {
        self.configuration = configuration
        self.credentialStore = credentialStore
        self.pendingStore = pendingStore
        self.transport = CloudHTTPTransport(protocolClasses: protocolClasses)
        self.clock = clock
        self.sleep = sleep
        do {
            if !deferCredentialRead {
                let storedCredential = try credentialStore.read(origin: configuration.origin)
                guard storedCredential?.isValid ?? true else { throw CloudClientError.credentialStorage }
                credential = storedCredential
                credentialPersisted = storedCredential != nil
                credentialReadPerformed = true
            }
            pending = try pendingStore.read(origin: configuration.origin)
        } catch let error as CloudClientError {
            transport.invalidate()
            throw error
        } catch {
            transport.invalidate()
            throw CloudClientError.credentialStorage
        }
    }

    func checkHealth() async throws {
        try requireRunning()
        let response = try await request(path: "healthz", method: "GET", token: nil, body: nil,
                                         timeout: Self.shortRequestTimeout)
        guard response.statusCode == 200 else { try throwFailure(response, expectedID: nil) }
        let health: HealthResponse = try decode(HealthResponse.self, from: response.data)
        guard health.status == "ok" else { throw CloudClientError.invalidResponse }
    }

    func prepareCredential() async throws -> Quota {
        try requireRunning()
        guard !preparingCredential else { throw CloudClientError.unavailable }
        preparingCredential = true
        defer { preparingCredential = false }
        try loadExistingCredential()
        if let credential {
            guard credential.isValid else { throw CloudClientError.credentialStorage }
            if !credentialPersisted {
                do {
                    try credentialStore.save(credential, origin: configuration.origin)
                    credentialPersisted = true
                } catch {
                    throw CloudClientError.credentialStorage
                }
            }
            return try await fetchQuota()
        }
        guard !registrationBlocked else { throw CloudClientError.invalidResponse }

        let registration = RegistrationRequest(clientVersion: Self.clientVersion, platform: Self.platform)
        let body: Data
        do { body = try JSONEncoder().encode(registration) } catch { throw CloudClientError.invalidResponse }
        do {
            let response = try await request(path: "v1/installations", method: "POST", token: nil, body: body,
                                             timeout: Self.uploadRequestTimeout, contentType: "application/json")
            guard response.statusCode == 201 else { try throwFailure(response, expectedID: nil) }
            let issued: InstallationResponse = try decode(InstallationResponse.self, from: response.data)
            let newCredential = InstallationCredential(installationID: issued.installationId, accessToken: issued.accessToken)
            guard newCredential.isValid, isValidQuota(issued.quota) else {
                registrationBlocked = true
                throw CloudClientError.invalidResponse
            }
            credential = newCredential
            do {
                try credentialStore.save(newCredential, origin: configuration.origin)
                credentialPersisted = true
            } catch {
                credentialPersisted = false
                throw CloudClientError.credentialStorage
            }
            updateQuota(issued.quota)
            return issued.quota
        } catch is CancellationError {
            registrationBlocked = true
            throw CancellationError()
        } catch let error as CloudClientError {
            if error == .networkUnavailable || error == .timeout || error == .invalidResponse { registrationBlocked = true }
            throw error
        }
    }

    func fetchQuota() async throws -> Quota {
        do {
            try requireRunning()
            try loadExistingCredential()
            let token = try usableToken()
            let response = try await request(path: "v1/quota", method: "GET", token: token, body: nil,
                                             timeout: Self.shortRequestTimeout)
            try Task.checkCancellation()
            guard response.statusCode == 200 else { try throwFailure(response, expectedID: nil) }
            let value: Quota = try decode(Quota.self, from: response.data)
            guard isValidQuota(value) else { throw CloudClientError.invalidResponse }
            updateQuota(value)
            return value
        } catch {
            updateQuota(nil)
            throw error
        }
    }

    func transcribe(_ wav: Data, id: UUID, mode: OutputMode,
                    stage: @escaping (SessionPhase) -> Void) async throws -> SessionResult {
        try requireRunning()
        guard activeRequestID == nil else { throw CloudClientError.pendingRequest }
        guard pending == nil else { throw CloudClientError.pendingRequest }
        do { _ = try WAVMetadata.parse(wav) } catch { throw CloudClientError.api(code: "invalid_wav", status: 0, retryable: false) }
        _ = try usableToken()

        let generation = UUID()
        activeRequestID = id
        activeGeneration = generation
        let task = Task<SessionResult, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performTranscription(wav: wav, id: id, mode: mode, stage: stage)
        }
        currentOperation = task
        defer {
            if activeGeneration == generation {
                activeGeneration = nil
                activeRequestID = nil
                currentOperation = nil
            }
        }
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    func inspectPending() async throws -> TranscriptionDTO {
        try requireRunning()
        guard let current = pending else { throw CloudClientError.pendingRequest }
        try loadExistingCredential()
        if current.locallyCancelled {
            inspectedUnrecoverableID = current.id
            scheduleCancellation(for: current.id)
            throw CloudClientError.cancelled
        }
        do {
            let dto = try await fetchTask(id: current.id, mode: current.mode)
            if dto.status == .unknown { inspectedUnrecoverableID = current.id }
            _ = try terminalResult(from: dto, id: current.id, mode: current.mode)
            return dto
        } catch let error as CloudClientError where isNotFound(error) {
            inspectedUnrecoverableID = current.id
            throw error
        }
    }

    /// Only an explicit UI confirmation after inspection can drop a recovery marker.
    /// This never resends audio, refunds quota, or proves that a missing task was uncharged.
    func abandonPendingRequest() throws {
        guard activeRequestID == nil, let current = pending, inspectedUnrecoverableID == current.id else { throw CloudClientError.pendingRequest }
        cancellationTasks[current.id]?.cancel(); cancellationTasks[current.id] = nil; cancellationGenerations[current.id] = nil
        try persistPending(nil)
    }

    func cancel(id: UUID) {
        if activeRequestID == id { currentOperation?.cancel() }
        guard var current = pending, current.id == id else { return }
        do { try loadExistingCredential() } catch { updateQuota(nil) }
        guard !current.locallyCancelled else {
            scheduleCancellation(for: id)
            return
        }
        current.locallyCancelled = true
        do {
            try persistPending(current)
        } catch {
            // The cancellation must not issue a remote request without a durable local shield.
            pending = current; onPending?(current)
            return
        }
        scheduleCancellation(for: id)
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        currentOperation?.cancel()
        cancellationTasks.values.forEach { $0.cancel() }
        cancellationTasks.removeAll()
        cancellationGenerations.removeAll()
        transport.invalidate()
    }

    private func performTranscription(wav: Data, id: UUID, mode: OutputMode,
                                      stage: @escaping (SessionPhase) -> Void) async throws -> SessionResult {
        try Task.checkCancellation()
        let deadline = clock() + Self.taskDeadline
        try persistPending(PendingTranscription(id: id, mode: mode))
        stage(.uploading)

        let acknowledgement: TranscriptionDTO
        do {
            acknowledgement = try await submit(wav: wav, id: id, mode: mode, deadline: deadline)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CloudClientError where error == .networkUnavailable || error == .timeout {
            // The body may have reached the product API. Query the known UUID; never send it again.
            let recovered = try await fetchTask(id: id, mode: mode, deadline: deadline)
            return try await awaitTerminal(startingWith: recovered, id: id, mode: mode, stage: stage, deadline: deadline)
        } catch let error as CloudClientError {
            if case .api(let code, let status, _) = error,
               [401, 403, 422, 429].contains(status) || (status == 503 && code == "budget_unavailable") { try persistPending(nil) }
            throw error
        }

        return try await awaitTerminal(startingWith: acknowledgement, id: id, mode: mode, stage: stage,
                                       initialIsStatusResponse: false, deadline: deadline)
    }

    private func awaitTerminal(startingWith initial: TranscriptionDTO, id: UUID, mode: OutputMode,
                               stage: @escaping (SessionPhase) -> Void,
                               initialIsStatusResponse: Bool = true, deadline: TimeInterval) async throws -> SessionResult {
        var dto = initial
        var isStatusResponse = initialIsStatusResponse
        var attempts = 0
        while attempts < 31, clock() <= deadline {
            try Task.checkCancellation()
            guard pending?.id == id, pending?.locallyCancelled != true else { throw CloudClientError.cancelled }
            // A POST acknowledgement is intentionally short. A terminal ACK must be re-read by UUID
            // before consuming a ready body or deciding a typed terminal outcome.
            if !isStatusResponse, dto.status != .processing {
                stage(.transcribing)
                dto = try await fetchTask(id: id, mode: mode, deadline: deadline)
                isStatusResponse = true
                continue
            }
            if let result = try terminalResult(from: dto, id: id, mode: mode, isStatusResponse: isStatusResponse) { return result }
            stage(.transcribing)
            attempts += 1
            try await sleep(min(Self.pollInterval, max(0, deadline - clock())))
            do {
                dto = try await fetchTask(id: id, mode: mode, deadline: deadline)
                isStatusResponse = true
            } catch let error as CloudClientError where isRateLimited(error) {
                // GET is safe to re-check, but never more often than the documented polling cadence.
                try await sleep(min(Self.pollInterval, max(0, deadline - clock())))
                continue
            }
        }
        throw CloudClientError.timeout
    }

    private func submit(wav: Data, id: UUID, mode: OutputMode, deadline: TimeInterval) async throws -> TranscriptionDTO {
        let token = try usableToken()
        guard clock() < deadline else { throw CloudClientError.timeout }
        let response = try await request(path: "v1/transcriptions", method: "POST", token: token, body: wav,
                                         timeout: min(Self.uploadRequestTimeout, deadline - clock()), contentType: "audio/wav", requestID: id, mode: mode)
        try Task.checkCancellation()
        guard response.statusCode == 202 else { try throwFailure(response, expectedID: id) }
        let dto: TranscriptionDTO = try decode(TranscriptionDTO.self, from: response.data)
        try validateTask(dto, expectedID: id, expectedMode: mode, isStatusResponse: false)
        updateQuota(dto.quota)
        return dto
    }

    private func fetchTask(id: UUID, mode: OutputMode, deadline: TimeInterval? = nil) async throws -> TranscriptionDTO {
        let token = try usableToken()
        let remaining = deadline.map { $0 - clock() } ?? Self.shortRequestTimeout
        guard remaining > 0 else { throw CloudClientError.timeout }
        let response = try await request(path: "v1/transcriptions/\(id.uuidString)", method: "GET", token: token, body: nil,
                                         timeout: min(Self.shortRequestTimeout, remaining))
        try Task.checkCancellation()
        guard response.statusCode == 200 else { try throwFailure(response, expectedID: id) }
        let dto: TranscriptionDTO = try decode(TranscriptionDTO.self, from: response.data)
        try validateTask(dto, expectedID: id, expectedMode: mode, isStatusResponse: true)
        updateQuota(dto.quota)
        return dto
    }

    private func terminalResult(from dto: TranscriptionDTO, id: UUID, mode: OutputMode,
                                isStatusResponse: Bool = true) throws -> SessionResult? {
        try validateTask(dto, expectedID: id, expectedMode: mode, isStatusResponse: isStatusResponse)
        guard pending?.id == id, pending?.locallyCancelled != true else { throw CloudClientError.cancelled }
        switch dto.status {
        case .processing:
            return nil
        case .ready:
            guard let raw = dto.rawText, let output = dto.outputText, let polish = dto.polishStatus else {
                throw CloudClientError.invalidResponse
            }
            let fallback = mode == .lightPolish && polish == .failedFallbackRaw
            try persistPending(nil)
            return SessionResult(rawText: raw, outputText: output, targetName: nil, polishFallback: fallback)
        case .failed:
            try persistPending(nil)
            if let error = dto.error {
                throw CloudClientError.api(code: error.code, status: 200, retryable: error.retryable)
            }
            throw CloudClientError.unavailable
        case .cancelled:
            try persistPending(nil)
            throw CloudClientError.cancelled
        case .unknown:
            throw CloudClientError.resultUnknown
        case .resultExpired:
            try persistPending(nil)
            throw CloudClientError.resultExpired
        }
    }

    private func scheduleCancellation(for id: UUID) {
        guard cancellationGenerations[id] == nil, !isShutdown else { return }
        let generation = UUID()
        cancellationGenerations[id] = generation
        let task = Task<Void, Never> { @MainActor [weak self] in
            await self?.cancelRemotely(id: id, generation: generation)
        }
        cancellationTasks[id] = task
    }

    private func cancelRemotely(id: UUID, generation: UUID) async {
        defer {
            if cancellationGenerations[id] == generation {
                cancellationGenerations[id] = nil
                cancellationTasks[id] = nil
            }
        }
        guard credentialAvailable else { return }
        let deadline = clock() + Self.taskDeadline
        for _ in 0..<31 {
            guard !Task.isCancelled, !isShutdown, cancellationGenerations[id] == generation,
                  pending?.id == id, pending?.locallyCancelled == true, clock() < deadline else { return }
            do {
                let token = try usableToken()
                let response = try await request(path: "v1/transcriptions/\(id.uuidString)", method: "DELETE", token: token,
                                                 body: nil, timeout: min(Self.shortRequestTimeout, deadline - clock()))
                guard !Task.isCancelled, cancellationGenerations[id] == generation, pending?.id == id else { return }
                if response.statusCode == 200 {
                    let dto: CancellationResponse = try decode(CancellationResponse.self, from: response.data)
                    guard dto.requestId == id, dto.cancellationRecorded, isValidQuota(dto.quota) else {
                        return
                    }
                    updateQuota(dto.quota)
                    if dto.status == .cancelled { try? persistPending(nil); return }
                } else {
                    try throwFailure(response, expectedID: id)
                }
            } catch let error as CloudClientError where isNotFound(error) {
                do {
                    let dto = try await fetchTask(id: id, mode: pending?.mode ?? .raw, deadline: deadline)
                    switch dto.status {
                    case .processing:
                        break
                    case .unknown:
                        return
                    case .ready, .failed, .cancelled, .resultExpired:
                        // A locally cancelled session never exposes these possibly late body fields.
                        try? persistPending(nil)
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // The original POST may still be reading; retain the cancellation shield and retry boundedly.
                }
            } catch is CancellationError {
                return
            } catch {
                // Preserve locallyCancelled metadata for a later explicit inspection/retry path.
            }
            do { try await sleep(min(Self.pollInterval, max(0, deadline - clock()))) } catch { return }
        }
    }

    private func request(path: String, method: String, token: String?, body: Data?, timeout: TimeInterval,
                         contentType: String? = nil, requestID: UUID? = nil, mode: OutputMode? = nil) async throws -> CloudHTTPResponse {
        try Task.checkCancellation()
        try await reserveRequestSlot()
        let url = try fixedURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let requestID { request.setValue(requestID.uuidString, forHTTPHeaderField: "Idempotency-Key") }
        if let mode { request.setValue(mode.rawValue, forHTTPHeaderField: "X-Output-Mode") }
        request.httpBody = body
        do {
            let response = try await transport.execute(request)
            try Task.checkCancellation()
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CloudClientError {
            updateQuota(nil)
            throw error
        } catch let error as URLError {
            updateQuota(nil)
            throw error.code == .timedOut ? CloudClientError.timeout : CloudClientError.networkUnavailable
        } catch {
            updateQuota(nil)
            throw CloudClientError.networkUnavailable
        }
    }

    private func fixedURL(_ path: String) throws -> URL {
        guard ["healthz", "v1/installations", "v1/quota", "v1/transcriptions"].contains(path) ||
                path.hasPrefix("v1/transcriptions/") else { throw CloudClientError.configuration }
        let url = configuration.baseURL.appendingPathComponent(path)
        guard let base = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false),
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
              base.scheme?.lowercased() == value.scheme?.lowercased(),
              base.host?.lowercased() == value.host?.lowercased(), base.port == value.port,
              value.query == nil, value.fragment == nil else { throw CloudClientError.configuration }
        return url
    }

    private func reserveRequestSlot() async throws {
        let now = clock()
        requestTimes = requestTimes.filter { now < $0 || now - $0 < 60 }
        guard requestTimes.count < 60 else {
            throw CloudClientError.api(code: "rate_limited", status: 429, retryable: true)
        }
        requestTimes.append(now)
    }

    private func loadExistingCredential() throws {
        guard !credentialReadPerformed else { return }
        do {
            let value = try credentialStore.read(origin: configuration.origin)
            guard value?.isValid ?? true else { throw CloudClientError.credentialStorage }
            credential = value; credentialPersisted = value != nil; credentialReadPerformed = true
        } catch { throw CloudClientError.credentialStorage }
    }

    private func usableToken() throws -> String {
        guard credentialAvailable, let credential, credential.isValid else { throw CloudClientError.unavailable }
        return credential.accessToken
    }

    private func persistPending(_ value: PendingTranscription?) throws {
        do {
            try pendingStore.save(value, origin: configuration.origin)
            pending = value
            if value?.id != inspectedUnrecoverableID { inspectedUnrecoverableID = nil }
            onPending?(value)
        } catch {
            throw CloudClientError.credentialStorage
        }
    }

    private func updateQuota(_ value: Quota?) {
        quota = value
        onQuota?(value)
    }

    private func requireRunning() throws {
        guard !isShutdown else { throw CloudClientError.unavailable }
    }

    private func throwFailure(_ response: CloudHTTPResponse, expectedID: UUID?) throws -> Never {
        guard !(300...399).contains(response.statusCode) else { throw CloudClientError.invalidResponse }
        let envelope: ErrorEnvelope
        do { envelope = try decode(ErrorEnvelope.self, from: response.data) } catch { throw CloudClientError.invalidResponse }
        if let requestID = envelope.requestId, let expectedID, requestID != expectedID {
            throw CloudClientError.invalidResponse
        }
        if let quota = envelope.quota {
            guard isValidQuota(quota) else { throw CloudClientError.invalidResponse }
            updateQuota(quota)
        } else {
            updateQuota(nil)
        }
        throw CloudClientError.api(code: envelope.error.code, status: response.statusCode, retryable: envelope.error.retryable)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { updateQuota(nil); throw CloudClientError.invalidResponse }
    }

    private func validateTask(_ dto: TranscriptionDTO, expectedID: UUID, expectedMode: OutputMode,
                              isStatusResponse: Bool) throws {
        guard dto.requestId == expectedID, isValidQuota(dto.quota) else { throw CloudClientError.invalidResponse }
        if isStatusResponse {
            guard dto.outputMode == expectedMode else { throw CloudClientError.invalidResponse }
        } else if let outputMode = dto.outputMode, outputMode != expectedMode {
            throw CloudClientError.invalidResponse
        }

        switch dto.status {
        case .processing:
            guard dto.rawText == nil, dto.outputText == nil, dto.resultExpiresAt == nil else { throw CloudClientError.invalidResponse }
            if isStatusResponse {
                let expectedPolish: PolishStatus = expectedMode == .raw ? .notRequested : .pending
                guard dto.polishStatus == expectedPolish else { throw CloudClientError.invalidResponse }
            }
        case .ready:
            guard let raw = dto.rawText, let output = dto.outputText, let expires = dto.resultExpiresAt,
                  isSafeText(raw), isSafeText(output), isValidISO8601(expires), dto.error == nil,
                  let polish = dto.polishStatus else { throw CloudClientError.invalidResponse }
            switch expectedMode {
            case .raw:
                guard polish == .notRequested, raw == output else { throw CloudClientError.invalidResponse }
            case .lightPolish:
                guard polish == .succeeded || (polish == .failedFallbackRaw && raw == output) else {
                    throw CloudClientError.invalidResponse
                }
            }
        case .failed, .cancelled, .unknown:
            guard dto.rawText == nil, dto.outputText == nil, dto.resultExpiresAt == nil else { throw CloudClientError.invalidResponse }
        case .resultExpired:
            guard dto.rawText == nil, dto.outputText == nil,
                  dto.resultExpiresAt.map(isValidISO8601) == true else { throw CloudClientError.invalidResponse }
        }
    }

    private func isValidQuota(_ quota: Quota) -> Bool {
        quota.limit == SaydropDefaults.quotaLimit && quota.used >= 0 && quota.reserved >= 0 && quota.remaining >= 0 &&
            quota.used <= quota.limit && quota.reserved <= quota.limit &&
            quota.used + quota.reserved <= quota.limit && quota.remaining == max(0, quota.limit - quota.used - quota.reserved) &&
            isValidISO8601(quota.resetAt)
    }

    private func isValidISO8601(_ value: String) -> Bool {
        guard value.count <= 64, value.contains("T") else { return false }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil || ISO8601DateFormatter().date(from: value) != nil
    }

    private func isSafeText(_ value: String) -> Bool {
        !value.isEmpty && value.count <= Self.maximumResultCharacters && value.utf8.count <= CloudHTTPTransport.maximumResponseBytes
    }

    private func isRateLimited(_ error: CloudClientError) -> Bool {
        if case .api(let code, _, _) = error { return code == "rate_limited" }
        return false
    }

    private func isNotFound(_ error: CloudClientError) -> Bool {
        if case .api(let code, _, _) = error { return code == "not_found" }
        return false
    }
}

private struct RegistrationRequest: Encodable {
    let clientVersion: String
    let platform: String
}

private struct InstallationResponse: Decodable {
    let installationId: UUID
    let accessToken: String
    let quota: Quota
}

private struct HealthResponse: Decodable {
    let status: String
}

private struct CancellationResponse: Decodable {
    let requestId: UUID
    let status: TaskStatus
    let cancellationRecorded: Bool
    let quota: Quota
}
