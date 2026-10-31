import Foundation

public struct FeedbackPolicy: Equatable {
    public let baseURL: URL
    public let recipient: String
    public let purpose: String
    public let retention: String
    public let deletionContact: String
    public let version: String
    public init(baseURL: URL, recipient: String, purpose: String, retention: String, deletionContact: String, version: String) {
        self.baseURL = baseURL; self.recipient = recipient; self.purpose = purpose
        self.retention = retention; self.deletionContact = deletionContact; self.version = version
    }
    public var isConfigured: Bool {
        baseURL.scheme?.lowercased() == "https" && baseURL.host != nil && baseURL.user == nil && baseURL.password == nil &&
        [recipient, purpose, retention, deletionContact, version].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
public enum FeedbackValidationError: Error, Equatable {
    case policyUnavailable, invalidPayload, audioExpired, consentChanged, unavailable, submissionUnknown
}
public struct FeedbackDraft: Equatable {
    public var requestID: UUID
    public var outputMode: OutputMode
    public var rawText: String?
    public var outputText: String?
    public var reason = ""
    public var correctedText = ""
    public var audio: Data?
    public var duration: TimeInterval
    public var includeAudio: Bool
    public var includeText: Bool
    public var audioDeadline: TimeInterval?
    public init(requestID: UUID, outputMode: OutputMode, rawText: String?, outputText: String?, audio: Data?, duration: TimeInterval, audioDeadline: TimeInterval? = nil) {
        self.requestID = requestID; self.outputMode = outputMode; self.rawText = rawText; self.outputText = outputText
        self.audio = audio; self.duration = duration; self.includeAudio = audio != nil
        self.includeText = rawText != nil || outputText != nil; self.audioDeadline = audioDeadline
    }
    public func confirm(policy: FeedbackPolicy, at date: Date, uptime: TimeInterval, id: UUID = UUID()) throws -> ConfirmedFeedback {
        guard policy.isConfigured else { throw FeedbackValidationError.policyUnavailable }
        if includeAudio {
            guard let audio, !audio.isEmpty, audio.count <= SaydropDefaults.maximumAudioBytes,
                  duration > 0, duration <= SaydropDefaults.captureLimit else { throw FeedbackValidationError.invalidPayload }
            if let audioDeadline, uptime >= audioDeadline { throw FeedbackValidationError.audioExpired }
        }
        if includeText {
            guard [rawText, outputText, correctedText].compactMap({ $0 }).allSatisfy({ $0.count <= 32_000 }),
                  reason.count <= 2_000 else { throw FeedbackValidationError.invalidPayload }
        }
        guard includeAudio || (includeText && ([rawText, outputText, reason, correctedText].compactMap({ $0 }).contains { !$0.isEmpty })) else {
            throw FeedbackValidationError.invalidPayload
        }
        let snapshot = normalized()
        return ConfirmedFeedback(id: id, draft: snapshot, policy: policy, confirmedAt: date)
    }
    public func normalized() -> Self {
        var value = self
        if !includeAudio { value.audio = nil; value.audioDeadline = nil }
        if !includeText { value.rawText = nil; value.outputText = nil; value.reason = ""; value.correctedText = "" }
        return value
    }
}
public struct ConfirmedFeedback: Equatable {
    public let id: UUID
    public private(set) var draft: FeedbackDraft
    public let policy: FeedbackPolicy
    public let confirmedAt: Date
    fileprivate init(id: UUID, draft: FeedbackDraft, policy: FeedbackPolicy, confirmedAt: Date) {
        self.id = id; self.draft = draft; self.policy = policy; self.confirmedAt = confirmedAt
    }
    public func validate(current: FeedbackDraft, policy: FeedbackPolicy, uptime: TimeInterval) throws {
        guard self.policy == policy, draft == current.normalized() else { throw FeedbackValidationError.consentChanged }
        if let audioDeadline = draft.audioDeadline, draft.includeAudio, uptime >= audioDeadline { throw FeedbackValidationError.audioExpired }
    }
    public mutating func releaseAudio() { draft.audio = nil; draft.includeAudio = false; draft.audioDeadline = nil }
    public func encodedPayload() throws -> Data {
        let iso = ISO8601DateFormatter()
        var object: [String: Any] = ["feedbackId": id.uuidString, "transcriptionRequestId": draft.requestID.uuidString,
                                    "rating": "negative", "outputMode": draft.outputMode.rawValue, "clientVersion": SaydropDefaults.version,
                                    "consent": ["policyVersion": policy.version, "confirmedAt": iso.string(from: confirmedAt),
                                                "includeAudio": draft.includeAudio, "includeText": draft.includeText]]
        if draft.includeText {
            if let rawText = draft.rawText { object["rawText"] = rawText }
            if let outputText = draft.outputText { object["outputText"] = outputText }
            if !draft.reason.isEmpty { object["reason"] = draft.reason }
            if !draft.correctedText.isEmpty { object["correctedText"] = draft.correctedText }
        }
        if draft.includeAudio, let audio = draft.audio { object["audio"] = ["format": "wav", "data": audio.base64EncodedString()] }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 12 * 1024 * 1024 else { throw FeedbackValidationError.invalidPayload }
        return data
    }
}
public struct PositiveFeedback {
    public let id: UUID
    public let requestID: UUID
    public let mode: OutputMode
    public init(id: UUID = UUID(), requestID: UUID, mode: OutputMode) { self.id = id; self.requestID = requestID; self.mode = mode }
    public func encodedPayload() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["feedbackId": id.uuidString, "transcriptionRequestId": requestID.uuidString,
                                                    "rating": "positive", "outputMode": mode.rawValue, "clientVersion": SaydropDefaults.version], options: [.sortedKeys])
    }
}
public enum FeedbackReceiptStatus: String, Codable { case received, processing, failed }
public struct FeedbackReceipt: Codable, Equatable {
    public let feedbackId: UUID
    public let status: FeedbackReceiptStatus
    public let receivedAt: String?
    public init(feedbackId: UUID, status: FeedbackReceiptStatus, receivedAt: String? = nil) { self.feedbackId = feedbackId; self.status = status; self.receivedAt = receivedAt }
    public var isReliableSuccess: Bool {
        guard status == .received, let receivedAt else { return false }
        return ISO8601DateFormatter().date(from: receivedAt) != nil || ISO8601DateFormatter.fractional.date(from: receivedAt) != nil
    }
}
private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter { let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds); return formatter }
}
public enum OriginSafety {
    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() &&
        (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }
}
