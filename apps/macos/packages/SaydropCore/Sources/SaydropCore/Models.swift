import Foundation

public enum SaydropDefaults {
    public static let version = "0.1.0"
    public static let shortcut = "⌘⌥T"
    public static let captureLimit: TimeInterval = 120
    public static let pauseLimit: TimeInterval = 300
    public static let temporaryAudioTTL: TimeInterval = 60
    public static let maximumAudioBytes = 8 * 1024 * 1024
    public static let quotaLimit = 50
    public static let quotaTimeZone = "Asia/Shanghai"
    public static let retention = RetentionPolicy.days(7)
}

public enum OutputMode: String, Codable, CaseIterable, Identifiable {
    case raw
    case lightPolish = "light_polish"
    public var id: String { rawValue }
    public var title: String { self == .raw ? "Raw" : "Light polish" }
}
public enum RecordingMode: String, Codable, CaseIterable, Identifiable {
    case toggle, hold
    public var id: String { rawValue }
    public var title: String { self == .toggle ? "Toggle" : "Hold to talk" }
}
public enum RetentionPolicy: Codable, Equatable {
    case days(Int), forever
    public var days: Int? { if case .days(let value) = self { return value }; return nil }
    public var isValid: Bool { days.map { (1...3650).contains($0) } ?? true }
    public var title: String { days.map { "\($0) days" } ?? "Forever" }
    public func expiration(from date: Date) -> Date? {
        guard let days, isValid else { return nil }
        return date.addingTimeInterval(Double(days) * 86_400)
    }
    public static func custom(_ input: String) -> RetentionPolicy? {
        let string = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty, string.allSatisfy({ $0.isASCII && $0.isNumber }),
              let days = Int(string), (1...3650).contains(days) else { return nil }
        return .days(days)
    }
}
public enum InsertionOutcome: String, Codable {
    case confirmed, preview, unknown
    public var title: String {
        switch self {
        case .confirmed: return "Inserted at the original input"
        case .preview: return "Not inserted automatically · Copy manually"
        case .unknown: return "Insertion status unknown"
        }
    }
}
public enum PreviewReason: String, Codable {
    case targetChanged, accessibilityUnavailable, secureInput, rangeUnverifiable, destinationUnknown, insertionUnknown
    public var title: String {
        switch self {
        case .targetChanged: return "Input target changed"
        case .accessibilityUnavailable: return "Automatic insertion unavailable"
        case .secureInput: return "Original target is a secure field"
        case .rangeUnverifiable: return "Cannot verify the original selection"
        case .destinationUnknown: return "Cannot confirm the paste destination"
        case .insertionUnknown: return "Insertion status unknown"
        }
    }
    public var explanation: String {
        switch self {
        case .targetChanged: return "The input target changed, so nothing was inserted."
        case .accessibilityUnavailable: return "Accessibility is unavailable. You can still transcribe and copy; nothing will be inserted into the current focus."
        case .secureInput: return "Automatic insertion is disabled for secure fields. Paste manually in a safe location."
        case .rangeUnverifiable: return "The original target or selection could not be verified. Preview only."
        case .destinationUnknown: return "The original paste destination could not be verified. No paste was sent."
        case .insertionUnknown: return "Check the original input before pasting again. No further automatic insertion will be attempted."
        }
    }
}
public struct SessionResult: Equatable {
    public var rawText: String
    public var outputText: String
    public var targetName: String?
    public var polishFallback: Bool
    public init(rawText: String, outputText: String, targetName: String? = nil, polishFallback: Bool = false) {
        self.rawText = rawText; self.outputText = outputText; self.targetName = targetName; self.polishFallback = polishFallback
    }
}
public struct HistoryRecord: Identifiable, Equatable, Codable {
    public let id: UUID
    public let requestID: UUID
    public let createdAt: Date
    public let duration: TimeInterval
    public let outputMode: OutputMode
    public var rawText: String?
    public var outputText: String?
    public let targetName: String?
    public let insertionOutcome: InsertionOutcome
    public var textExpiresAt: Date?
    public var audioExpiresAt: Date?
    public var hasAudio: Bool
    public var summary: String { outputText ?? "Audio recording · No text saved" }
    public init(id: UUID = UUID(), requestID: UUID = UUID(), createdAt: Date, duration: TimeInterval,
                outputMode: OutputMode, rawText: String?, outputText: String?, targetName: String?,
                insertionOutcome: InsertionOutcome, textExpiresAt: Date?, audioExpiresAt: Date?, hasAudio: Bool) {
        self.id = id; self.requestID = requestID; self.createdAt = createdAt; self.duration = duration
        self.outputMode = outputMode; self.rawText = rawText; self.outputText = outputText
        self.targetName = targetName; self.insertionOutcome = insertionOutcome
        self.textExpiresAt = textExpiresAt; self.audioExpiresAt = audioExpiresAt; self.hasAudio = hasAudio
    }
    public func matches(_ query: String) -> Bool {
        query.isEmpty || [rawText, outputText].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
    }
    public mutating func purgeExpired(at date: Date) {
        if let textExpiresAt, textExpiresAt <= date { rawText = nil; outputText = nil }
        if let audioExpiresAt, audioExpiresAt <= date { hasAudio = false }
    }
    public var hasContent: Bool { rawText != nil || outputText != nil || hasAudio }
}
public struct RetentionImpact: Equatable {
    public let affectedCount: Int
    public let expiredCount: Int
    public static func calculate(records: [HistoryRecord], policy: RetentionPolicy, forAudio: Bool, at date: Date) -> Self {
        guard policy.isValid else { return Self(affectedCount: 0, expiredCount: 0) }
        var affected = 0, expired = 0
        for record in records {
            guard forAudio ? record.hasAudio : (record.rawText != nil || record.outputText != nil),
                  let candidate = policy.expiration(from: record.createdAt) else { continue }
            let current = forAudio ? record.audioExpiresAt : record.textExpiresAt
            if current == nil || candidate < current! {
                affected += 1
                if candidate <= date { expired += 1 }
            }
        }
        return Self(affectedCount: affected, expiredCount: expired)
    }
}
public struct SavePolicy: Equatable {
    public var audioEnabled: Bool
    public var textEnabled: Bool
    public var formsHistory: Bool { audioEnabled || textEnabled }
    public init(audioEnabled: Bool, textEnabled: Bool) { self.audioEnabled = audioEnabled; self.textEnabled = textEnabled }
    public func record(result: SessionResult, at date: Date, duration: TimeInterval, mode: OutputMode,
                       outcome: InsertionOutcome, audioAvailable: Bool,
                       audioRetention: RetentionPolicy = SaydropDefaults.retention,
                       textRetention: RetentionPolicy = SaydropDefaults.retention,
                       requestID: UUID = UUID()) -> HistoryRecord? {
        guard formsHistory, audioRetention.isValid, textRetention.isValid else { return nil }
        let audio = audioEnabled && audioAvailable
        guard textEnabled || audio else { return nil }
        return HistoryRecord(requestID: requestID, createdAt: date, duration: duration, outputMode: mode,
                             rawText: textEnabled ? result.rawText : nil, outputText: textEnabled ? result.outputText : nil,
                             targetName: result.targetName, insertionOutcome: outcome,
                             textExpiresAt: textEnabled ? textRetention.expiration(from: date) : nil,
                             audioExpiresAt: audio ? audioRetention.expiration(from: date) : nil, hasAudio: audio)
    }
}
public struct TemporaryAudioLifetime: Equatable {
    public let deadline: TimeInterval
    public init(resultAvailableAt now: TimeInterval) { deadline = now + SaydropDefaults.temporaryAudioTTL }
    public func remaining(at now: TimeInterval) -> TimeInterval { max(0, deadline - now) }
    public func isExpired(at now: TimeInterval) -> Bool { now >= deadline }
}
public struct Quota: Codable, Equatable {
    public let limit: Int
    public let used: Int
    public let reserved: Int
    public let remaining: Int
    public let resetAt: String
    public init(limit: Int, used: Int, reserved: Int, remaining: Int, resetAt: String) {
        self.limit = limit; self.used = used; self.reserved = reserved; self.remaining = remaining; self.resetAt = resetAt
    }
}
public enum TaskStatus: String, Codable { case processing, ready, failed, cancelled, unknown; case resultExpired = "result_expired" }
public enum PolishStatus: String, Codable {
    case notRequested = "not_requested", pending, succeeded, failedFallbackRaw = "failed_fallback_raw"
}
public struct APIErrorBody: Codable, Equatable { public let code: String; public let message: String; public let retryable: Bool }
public struct ErrorEnvelope: Codable { public let error: APIErrorBody; public let requestId: UUID?; public let quota: Quota? }
public struct TranscriptionDTO: Codable {
    public let requestId: UUID
    public let status: TaskStatus
    public let quota: Quota
    public let outputMode: OutputMode?
    public let polishStatus: PolishStatus?
    public let rawText: String?
    public let outputText: String?
    public let resultExpiresAt: String?
    public let error: APIErrorBody?
}
