import AppKit
import SwiftUI
import AVFoundation
import ServiceManagement
import SaydropCore
import CryptoKit

public enum AppRoute: String, CaseIterable, Identifiable {
    case history, settings, about
    public var id: String { rawValue }
    public var title: String { switch self { case .history: return "History"; case .settings: return "Settings"; case .about: return "About" } }
    public var symbol: String { switch self { case .history: return "doc.text"; case .settings: return "gearshape"; case .about: return "info.circle" } }
}
public struct UserSettings: Codable {
    public var recordingMode: RecordingMode = .toggle
    public var saveAudio = true
    public var saveText = true
    public var audioRetention: RetentionPolicy = SaydropDefaults.retention
    public var textRetention: RetentionPolicy = SaydropDefaults.retention
    public var shortcut = SaydropDefaults.shortcut
    public var launchAtLogin = false
    public var onboardingCompleted = false
    public var lastManualOutputMode: OutputMode = .raw
}
public struct LocalConfirmation: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
    fileprivate let action: LocalAction
}
fileprivate enum LocalAction { case delete(UUID), clear, retention(RetentionPolicy, Bool) }
public enum FeedbackUIState: String { case editing, awaitingConsent, uploading, submitted, failed, submissionUnknown }
public struct FeedbackPresentation: Identifiable {
    public let id = UUID()
    public var draft: FeedbackDraft
    public var state: FeedbackUIState = .editing
    public var confirmation: ConfirmedFeedback?
    public var receiptID: UUID?
    public var message: String?
    fileprivate var retryIdentities: [Data: FeedbackRetryIdentity] = [:]
    fileprivate var unknownIDs: Set<UUID> = []
    fileprivate var queriedIDs: Set<UUID> = []
}
fileprivate struct FeedbackRetryIdentity { let id: UUID; let confirmedAt: Date }
/// Implementations must acknowledge actual capture before the UI enters recording.
/// Capture checks are explicit local diagnostics, never a substitute for cloud dictation.
@MainActor
protocol SessionBackend: AnyObject {
    var isConfigured: Bool { get }
    var supportsLocalCaptureCheck: Bool { get }
    var onLevel: ((UUID, Double) -> Void)? { get set }
    var onFailure: ((UUID, String) -> Void)? { get set }
    var onLimit: ((UUID) -> Void)? { get set }
    func start(id: UUID) async throws
    func pause(id: UUID)
    func resume(id: UUID) async throws
    func finish(id: UUID, mode: OutputMode, stage: @escaping (SessionPhase) -> Void) async throws -> SessionResult
    func finishCaptureCheck(id: UUID) async throws -> CapturedAudio
    func takeResultAudio(id: UUID) -> CapturedAudio?
    func cancel(id: UUID)
}
@MainActor
extension SessionBackend {
    var supportsLocalCaptureCheck: Bool { false }
    var onLevel: ((UUID, Double) -> Void)? { get { nil } set {} }
    var onFailure: ((UUID, String) -> Void)? { get { nil } set {} }
    var onLimit: ((UUID) -> Void)? { get { nil } set {} }
    func finishCaptureCheck(id: UUID) async throws -> CapturedAudio { throw FeedbackValidationError.unavailable }
    func takeResultAudio(id: UUID) -> CapturedAudio? { nil }
}
public struct CaptureCheckSummary: Equatable {
    public let duration: TimeInterval
    public let frameCount: Int
    public let bytes: Int
    public let rms: Double
}
@MainActor
final class UnconfiguredSessionBackend: SessionBackend {
    var isConfigured: Bool { false }
    func start(id: UUID) async throws { throw FeedbackValidationError.unavailable }
    func pause(id: UUID) {}
    func resume(id: UUID) async throws { throw FeedbackValidationError.unavailable }
    func finish(id: UUID, mode: OutputMode, stage: @escaping (SessionPhase) -> Void) async throws -> SessionResult { throw FeedbackValidationError.unavailable }
    func cancel(id: UUID) {}
}
@MainActor
private final class UIDemoSessionBackend: SessionBackend {
    var isConfigured: Bool { true }
    func start(id: UUID) async throws {}
    func pause(id: UUID) {}
    func resume(id: UUID) async throws {}
    func finish(id: UUID, mode: OutputMode, stage: @escaping (SessionPhase) -> Void) async throws -> SessionResult {
        try await Task.sleep(for: .milliseconds(400)); stage(.uploading)
        try await Task.sleep(for: .milliseconds(650)); stage(.transcribing)
        try await Task.sleep(for: .milliseconds(800))
        if mode == .lightPolish { stage(.polishing); try await Task.sleep(for: .milliseconds(500)) }
        return SessionResult(rawText: "Meet Alice at three this afternoon", outputText: mode == .raw ? "Meet Alice at three this afternoon" : "Meet Alice at three this afternoon.", targetName: "Sample target · No real input field captured")
    }
    func cancel(id: UUID) {}
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public var route: AppRoute = .history
    @Published public var records: [HistoryRecord] = []
    @Published public var selectedRecordID: UUID?
    @Published public var searchText = ""
    @Published public private(set) var settings: UserSettings
    @Published public private(set) var quota: Quota?
    @Published public private(set) var permissions = PermissionSnapshot()
    @Published public var notice: String?
    @Published public var showOnboarding = false
    @Published public var showPrivacy = false
    @Published public private(set) var playingRecordID: UUID?
    @Published public private(set) var playbackTime: TimeInterval = 0
    @Published public private(set) var confirmation: LocalConfirmation?
    @Published public private(set) var session: SessionState
    @Published public private(set) var now: TimeInterval = ProcessInfo.processInfo.systemUptime
    @Published public private(set) var feedback: FeedbackPresentation?
    @Published public private(set) var localCaptureCheckEnabled = false
    @Published public private(set) var captureCheckSummary: CaptureCheckSummary?
    @Published public private(set) var inputLevel: Double = 0
    @Published public private(set) var isResuming = false
    @Published public private(set) var globalEscapeAvailable = false
    @Published public private(set) var shortcutStatus = "Initializing shortcut"
    public let isDemo: Bool
    let feedbackPolicy: FeedbackPolicy?
    private let defaults: UserDefaults?
    private let permissionService = PermissionCoordinator()
    private let permissionSnapshot: (() -> PermissionSnapshot)?
    private let clock: () -> TimeInterval
    private let historyStore: (any HistoryStoring)?
    private var historyReadable = true
    private let autoInsertion: AutoInsertion?
    private let backend: SessionBackend
    let cloud: CloudCoordinator?
    private let feedbackAPI: FeedbackAPI
    private var sessionTask: Task<Void, Never>?
    private var resumeAttempt: UUID?
    private var finishAfterResume = false
    private var isCaptureCheckSession = false
    private var feedbackTask: Task<Void, Never>?
    private var temporaryAudio: Data?
    private var temporaryLifetime: TemporaryAudioLifetime?
    private var audioByRecord: [UUID: Data] = [:]
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var positiveIDs: [UUID: UUID] = [:]
    private var positiveInFlight: Set<UUID> = []
    private var positiveUnknown: Set<UUID> = []
    private var positiveReceived: Set<UUID> = []
    public var presentFloatingBar: (() -> Void)?
    public var syncFloatingBar: (() -> Void)?
    public var presentFeedbackWindow: (() -> Void)?
    public var closeFeedbackWindow: (() -> Void)?
    public var presentCaptureCheckWindow: (() -> Void)?
    public var resetShortcutHeld: (() -> Void)?

    convenience init(isDemo: Bool = false) {
        let cloud = isDemo ? nil : CloudCoordinator.application(defaults: .standard)
        self.init(isDemo: isDemo, defaults: isDemo ? nil : .standard,
                  backend: isDemo ? UIDemoSessionBackend() : RealSessionBackend(audio: AudioPipeline(), transcriber: cloud?.transcriber),
                  feedbackAPI: UnconfiguredFeedbackAPI(), feedbackPolicy: nil, cloud: cloud,
                  autoInsertion: isDemo ? nil : AutoInsertion(),
                  historyStore: isDemo ? nil : EncryptedHistoryStore.application())
    }
    init(isDemo: Bool, defaults: UserDefaults?, backend: SessionBackend, feedbackAPI: FeedbackAPI, feedbackPolicy: FeedbackPolicy?,
         cloud: CloudCoordinator? = nil,
         autoInsertion: AutoInsertion? = nil,
         historyStore: (any HistoryStoring)? = nil,
         permissionSnapshot: (() -> PermissionSnapshot)? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.isDemo = isDemo; self.defaults = defaults; self.backend = backend; self.cloud = cloud
        self.historyStore = historyStore
        self.autoInsertion = autoInsertion
        self.feedbackAPI = feedbackAPI; self.feedbackPolicy = feedbackPolicy
        self.permissionSnapshot = permissionSnapshot; self.clock = clock
        var value = defaults?.data(forKey: "Saydrop.ui.settings").flatMap { try? JSONDecoder().decode(UserSettings.self, from: $0) } ?? UserSettings()
        if !value.audioRetention.isValid { value.audioRetention = SaydropDefaults.retention }
        if !value.textRetention.isValid { value.textRetention = SaydropDefaults.retention }
        value.launchAtLogin = !isDemo && SMAppService.mainApp.status == .enabled
        self.settings = value; self.session = SessionState(mode: value.lastManualOutputMode)
        if isDemo {
            quota = Quota(limit: 50, used: 3, reserved: 1, remaining: 46, resetAt: "2026-10-27T00:00:00+08:00")
            records = Self.sampleRecords(); selectedRecordID = records.first?.id
        }
        if !isDemo, let historyStore {
            do {
                let archive = try historyStore.load()
                records = archive.records; audioByRecord = archive.audio
                purgeExpired()
            } catch {
                historyReadable = false
                notice = "Local history could not be decrypted or read. The original file was not overwritten. Check Keychain access, then restart Saydrop."
            }
        }
        refreshPermissions()
        showOnboarding = !isDemo && !value.onboardingCompleted
        now = clock()
        cloud?.onUpdate = { [weak self] in
            guard let self else { return }
            self.applyQuotaFromService(self.cloud?.quota)
            if self.cloud?.recovered != nil { self.startTicking() }
            self.objectWillChange.send()
        }
        backend.onLevel = { [weak self] id, level in
            guard let self, self.session.id == id, self.session.phase == .recording else { return }
            self.inputLevel = level.isFinite ? min(1, max(0, level)) : 0
        }
        backend.onFailure = { [weak self] id, message in
            guard let self, self.session.id == id, self.session.phase.isActive else { return }
            self.send(.fail(id, message))
        }
        backend.onLimit = { [weak self] id in
            guard let self, self.session.id == id, self.session.phase == .recording else { return }
            self.finishSession()
        }
    }
    public var filteredRecords: [HistoryRecord] { records.filter { $0.matches(searchText) }.sorted { $0.createdAt > $1.createdAt } }
    public var selectedRecord: HistoryRecord? { filteredRecords.first { $0.id == selectedRecordID } }
    public var hasHistoryEnabled: Bool { settings.saveAudio || settings.saveText }
    public var elapsed: TimeInterval { session.displayedElapsed(at: now) }
    public func applyQuotaFromService(_ value: Quota?) {
        guard let value else { quota = nil; return }
        guard value.limit == SaydropDefaults.quotaLimit, value.used >= 0, value.reserved >= 0,
              value.used <= value.limit, value.reserved <= value.limit,
              value.used + value.reserved <= value.limit,
              value.remaining == max(0, value.limit - value.used - value.reserved) else { quota = nil; return }
        quota = value
    }
    public var canStart: Bool { !session.phase.isActive && startBlockReason == nil }
    public var currentSessionIsCaptureCheck: Bool { isCaptureCheckSession }
    public var hasTemporaryAudio: Bool { temporaryAudio != nil }
    public var temporaryAudioRemaining: TimeInterval { temporaryLifetime?.remaining(at: now) ?? 0 }
    public var startBlockReason: String? {
        if isDemo { return nil }
        if localCaptureCheckEnabled {
            if !backend.supportsLocalCaptureCheck { return "This backend does not support a local recording check." }
            if permissions.microphone != .allowed { return "Allow microphone access to start the local check. Nothing will be uploaded or transcribed." }
            return nil
        }
        if let reason = cloud?.startBlockReason { return reason }
        if !backend.isConfigured { return "Recording and global shortcuts are available, but cloud transcription is not configured. You can run a local recording check without uploading or transcribing." }
        if permissions.microphone != .allowed { return "Allow microphone access before recording." }
        if quota == nil { return "Quota is unavailable. Confirm the connection and server quota before starting." }
        if quota?.remaining == 0 { return "Today's quota is exhausted. Wait for the server reset." }
        return nil
    }
    public func setLocalCaptureCheckEnabled(_ enabled: Bool) {
        guard !isDemo else { notice = "UI demo does not use real recording."; return }
        if session.phase.isActive {
            guard !enabled, isCaptureCheckSession else { notice = "Finish the current session before changing recording purpose."; return }
            closeOrCancelSession()
        }
        localCaptureCheckEnabled = enabled; notice = nil
        if !enabled { clearTemporaryAudio(); captureCheckSummary = nil; resetShortcutHeld?() }
        refreshPermissions()
    }
    public func beginSession() {
        guard !session.phase.isActive else { return }
        refreshPermissions()
        if let reason = startBlockReason { notice = reason; showFloatingBar(); return }
        clearTemporaryAudio(); captureCheckSummary = nil; notice = nil; inputLevel = 0
        isCaptureCheckSession = localCaptureCheckEnabled && !isDemo
        if !isDemo && !isCaptureCheckSession { autoInsertion?.capture() } else { autoInsertion?.clear() }
        let id = UUID(); send(.begin(id, monotonicNow))
    }
    public func pauseSession() { guard let id = session.id else { return }; send(.pause(id, monotonicNow)) }
    public func resumeSession() {
        guard let id = session.id, session.phase == .paused, !isResuming else { return }
        // Check deadlines BEFORE opening the device, and again after asynchronous acknowledgement.
        let time = monotonicNow
        if session.pauseRemaining(at: time) == 0 { send(.tick(id, time)); return }
        refreshPermissions()
        guard isDemo || permissions.microphone == .allowed else { send(.fail(id, "Microphone access is unavailable. This session stopped.")); return }
        let attempt = UUID(); resumeAttempt = attempt; isResuming = true; finishAfterResume = false
        sessionTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, resumeAttempt == attempt, session.id == id, session.phase == .paused else { return }
            do {
                if !isDemo && !isCaptureCheckSession { try await cloud?.prepareForRecording() }
                guard !Task.isCancelled, resumeAttempt == attempt, session.id == id, session.phase == .paused else { return }
                try await backend.resume(id: id)
                guard !Task.isCancelled, resumeAttempt == attempt, session.id == id, session.phase == .paused else {
                    backend.cancel(id: id); return
                }
                let shouldFinish = finishAfterResume
                resumeAttempt = nil; isResuming = false; finishAfterResume = false; sessionTask = nil
                send(.resumeStarted(id, monotonicNow))
                if shouldFinish && session.phase == .recording { finishSession() }
            } catch {
                guard resumeAttempt == attempt, session.id == id, session.phase == .paused else { return }
                resumeAttempt = nil; isResuming = false; finishAfterResume = false; sessionTask = nil
                send(.fail(id, "Could not resume capture. This session stopped."))
            }
        }
    }
    public func finishSession() {
        guard let id = session.id else { return }
        if session.phase == .checking { send(.cancel(id)); return } // Fast hold release: don't open the microphone later.
        if isResuming { finishAfterResume = true; return }
        send(.finish(id, monotonicNow))
    }
    public func closeOrCancelSession() {
        if let id = session.id, session.phase.isActive || session.phase == .completed { send(.cancel(id)) }
        else { send(.closeBar) }
        if isCaptureCheckSession { clearTemporaryAudio() }
    }
    public func chooseMode(_ mode: OutputMode) {
        guard session.canSelectMode else { return }
        send(.chooseMode(mode)); settings.lastManualOutputMode = mode; persistPreferences()
    }
    public func showFloatingBar() { send(.showBar); presentFloatingBar?() }
    private var monotonicNow: TimeInterval { clock() }
    private func send(_ event: SessionEvent) {
        now = monotonicNow
        let transition = SessionReducer.reduce(session, event); session = transition.state
        processEffects(transition.effects)
        updateTicking(); syncFloatingBar?()
    }
    private func processEffects(_ effects: [SessionEffect]) {
        for effect in effects {
            switch effect {
            case .beginCapture(let id):
                sessionTask = Task { [weak self] in
                    guard let self else { return }
                    guard !Task.isCancelled, session.id == id, session.phase == .checking else { return }
                    do {
                        if !isDemo && !isCaptureCheckSession { try await cloud?.prepareForRecording() }
                        guard !Task.isCancelled, session.id == id, session.phase == .checking else { return }
                        try await backend.start(id: id)
                        guard !Task.isCancelled, session.id == id, session.phase == .checking else { backend.cancel(id: id); return }
                        sessionTask = nil; send(.captureStarted(id, monotonicNow))
                    } catch {
                        guard session.id == id, session.phase == .checking else { return }
                        sessionTask = nil; send(.fail(id, (error as? CloudClientError)?.localizedDescription ?? "Could not start capture. Check microphone permission and the system input device."))
                    }
                }
            case .pauseCapture(let id): inputLevel = 0; backend.pause(id: id)
            case .finalize(let id): inputLevel = 0; finalizeSession(id: id)
            case .cancel(let id):
                autoInsertion?.clear()
                sessionTask?.cancel(); sessionTask = nil; backend.cancel(id: id)
                resumeAttempt = nil; isResuming = false; finishAfterResume = false
                inputLevel = 0; clearTemporaryAudio(); resetShortcutHeld?()
            case .showResult:
                // Results and target context remain temporary; no persistent plaintext history.
                if let id = session.id, let captured = backend.takeResultAudio(id: id) {
                    temporaryAudio = captured.wav; temporaryLifetime = TemporaryAudioLifetime(resultAvailableAt: now)
                } else if !settings.saveAudio { temporaryLifetime = TemporaryAudioLifetime(resultAvailableAt: now) }
            }
        }
    }
    private func updateTicking() {
        if session.phase.isActive || cloud?.recovered != nil { startTicking() } else if player == nil && feedback?.state != .uploading && temporaryLifetime == nil { stopTicking() }
    }
    private func finalizeSession(id: UUID) {
        let mode = session.mode, captureOnly = isCaptureCheckSession
        sessionTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, session.id == id, session.phase == .finalizing else { return }
            do {
                if captureOnly {
                    let captured = try await backend.finishCaptureCheck(id: id)
                    guard !Task.isCancelled, session.id == id, session.phase == .finalizing else { return }
                    let metadata = try WAVMetadata.parse(captured.wav)
                    guard abs(metadata.duration - captured.duration) < 0.01 else { throw WAVMetadata.ValidationError.invalidWAV }
                    temporaryAudio = captured.wav
                    captureCheckSummary = CaptureCheckSummary(duration: metadata.duration, frameCount: captured.frameCount, bytes: captured.wav.count, rms: captured.rms)
                    temporaryLifetime = TemporaryAudioLifetime(resultAvailableAt: monotonicNow)
                    sessionTask = nil; send(.captureValidated(id, metadata.duration)); startTicking()
                } else {
                    var result = try await backend.finish(id: id, mode: mode) { [weak self] phase in self?.send(.stage(id, phase)) }
                    guard !Task.isCancelled, session.id == id, [.transcribing, .polishing].contains(session.phase) else { return }
                    let insertion = isDemo ? nil : autoInsertion?.insert(result.outputText)
                    result.targetName = insertion?.targetName ?? result.targetName
                    sessionTask = nil; send(.result(id, result, insertion?.reason ?? .rangeUnverifiable))
                    if let insertion { send(.insertion(id, insertion.outcome)) }
                    saveSessionHistory(id: id)
                }
            } catch {
                guard session.id == id, session.phase == .finalizing || session.phase.isActive else { return }
                sessionTask = nil
                send(.fail(id, captureOnly ? "Local capture did not complete or the audio was invalid. Nothing was uploaded or saved to history. Check the device and start again." : (error as? CloudClientError)?.localizedDescription ?? "Processing did not complete. Audio will not be uploaded again automatically; check the original request first."))
            }
        }
    }
    private func saveSessionHistory(id: UUID) {
        guard !isDemo, !isCaptureCheckSession, session.id == id,
              [.completed, .previewing].contains(session.phase), let result = session.result,
              !records.contains(where: { $0.requestID == id }) else { return }
        let policy = SavePolicy(audioEnabled: settings.saveAudio, textEnabled: settings.saveText)
        guard let record = policy.record(result: result, at: Date(), duration: elapsed, mode: session.mode,
                                         outcome: session.insertionOutcome ?? .preview, audioAvailable: temporaryAudio != nil,
                                         audioRetention: settings.audioRetention, textRetention: settings.textRetention,
                                         requestID: id) else { return }
        records.insert(record, at: 0)
        if record.hasAudio { audioByRecord[record.id] = temporaryAudio }
        selectedRecordID = record.id
        persistHistory()
    }
    private func persistHistory() {
        guard !isDemo, let historyStore else { return }
        guard historyReadable else {
            notice = "The history file is unreadable. New records are available only during this run; the original file was not overwritten."; return
        }
        do { try historyStore.save(HistoryArchive(records: records, audio: audioByRecord)) }
        catch { notice = "Could not save local history. This result can still be viewed and copied. Check Keychain access and disk space." }
    }
    private func clearTemporaryAudio() {
        temporaryAudio = nil; temporaryLifetime = nil
        if feedback?.draft.audioDeadline != nil { expireFeedbackAudio() }
        stopAudio()
        if !session.phase.isActive && feedback?.state != .uploading && cloud?.recovered == nil { stopTicking() }
    }
    private func startTicking() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    private func stopTicking() { timer?.invalidate(); timer = nil }
    func tick(at uptime: TimeInterval? = nil) {
        now = uptime ?? monotonicNow
        cloud?.tick(at: now)
        if let id = session.id { let transition = SessionReducer.reduce(session, .tick(id, now)); session = transition.state
            processEffects(transition.effects)
        }
        if let player { playbackTime = player.currentTime; if !player.isPlaying { stopAudio() } }
        if let lifetime = temporaryLifetime, lifetime.isExpired(at: now) {
            temporaryAudio = nil; temporaryLifetime = nil
            if feedback?.draft.audioDeadline != nil { expireFeedbackAudio() }
            stopAudio()
        }
        if let deadline = feedback?.draft.audioDeadline, now >= deadline { expireFeedbackAudio() }
        if !session.phase.isActive && player == nil && temporaryLifetime == nil && feedback?.state != .uploading && cloud?.recovered == nil { stopTicking() }
        syncFloatingBar?()
    }
    public func updateSaving(audio: Bool?, text: Bool?) {
        if let audio { settings.saveAudio = audio }; if let text { settings.saveText = text }; persistPreferences()
    }
    public func setRecordingMode(_ mode: RecordingMode) { guard !session.phase.isActive else { notice = "Change the recording mode after this session ends."; return }; settings.recordingMode = mode; resetShortcutHeld?(); persistPreferences() }
    public func setShortcut(_ display: String) { settings.shortcut = display; persistPreferences() }
    public func updateShortcutStatus(_ text: String) { shortcutStatus = text }
    public func updateGlobalEscapeAvailability(_ available: Bool) { globalEscapeAvailable = available }
    public func setLaunchAtLogin(_ enabled: Bool) {
        if isDemo { notice = "UI demo does not change the system login item."; return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled; persistPreferences()
            if enabled && !settings.launchAtLogin { notice = "The login item is not enabled. Check System Settings." }
        } catch { settings.launchAtLogin = SMAppService.mainApp.status == .enabled; notice = "Could not update the login item. Check the app location and System Settings." }
    }
    public func updateRetention(_ policy: RetentionPolicy, forAudio: Bool) {
        guard policy.isValid else { notice = "Enter a whole number of days from 1 to 3650."; return }
        let impact = RetentionImpact.calculate(records: records, policy: policy, forAudio: forAudio, at: Date())
        if impact.affectedCount > 0 {
            confirmation = LocalConfirmation(title: "Shorten \(forAudio ? "audio" : "text") retention?",
                message: "This changes \(forAudio ? "audio" : "text") retention for \(impact.affectedCount) existing records. \(impact.expiredCount) will expire and be removed immediately. Submitted cloud feedback will not be deleted, and system backups may retain copies.", action: .retention(policy, forAudio))
        } else { applyRetention(policy, forAudio: forAudio) }
    }
    private func applyRetention(_ policy: RetentionPolicy, forAudio: Bool) {
        if forAudio { settings.audioRetention = policy } else { settings.textRetention = policy }
        // Only shorten existing deadlines. Extending the preference must not revive expired content.
        for index in records.indices {
            guard let candidate = policy.expiration(from: records[index].createdAt) else { continue }
            let current = forAudio ? records[index].audioExpiresAt : records[index].textExpiresAt
            if current == nil || candidate < current! {
                if forAudio && records[index].hasAudio { records[index].audioExpiresAt = candidate }
                if !forAudio && (records[index].rawText != nil || records[index].outputText != nil) { records[index].textExpiresAt = candidate }
            }
        }
        purgeExpired(); persistPreferences(); persistHistory()
    }
    public func requestDelete(_ record: HistoryRecord) {
        confirmation = LocalConfirmation(title: "Delete this local record?", message: "This deletes its saved text, audio, and local references. It will not remove text inserted into another app or uploaded feedback. Copies may remain on an SSD, in backups, or in system snapshots.", action: .delete(record.id))
    }
    public func requestClearHistory() {
        confirmation = LocalConfirmation(title: "Clear existing local content?", message: "This deletes audio and text from \(records.count) local records without changing save settings. Cloud feedback is not deleted, and backups or system copies may remain.", action: .clear)
    }
    public func confirmLocalChange() {
        guard let action = confirmation?.action else { return }; confirmation = nil
        switch action {
        case .delete(let id):
            if playingRecordID == id { stopAudio() }; records.removeAll { $0.id == id }; audioByRecord[id] = nil
            if selectedRecordID == id { selectedRecordID = nil }
        case .clear: stopAudio(); records.removeAll(); audioByRecord.removeAll(); selectedRecordID = nil
        case .retention(let policy, let forAudio): applyRetention(policy, forAudio: forAudio)
        }
        persistHistory()
    }
    public func cancelLocalChange() { confirmation = nil }
    public func purgeExpired(at date: Date = Date()) {
        let previous = records
        for index in records.indices { records[index].purgeExpired(at: date) }
        for record in records where !record.hasAudio { audioByRecord[record.id] = nil; if playingRecordID == record.id { stopAudio() } }
        records.removeAll { !$0.hasContent }
        if let selectedRecordID, !records.contains(where: { $0.id == selectedRecordID }) { self.selectedRecordID = nil }
        let validAudioIDs = Set(records.filter(\.hasAudio).map(\.id))
        audioByRecord = audioByRecord.filter { validAudioIDs.contains($0.key) }
        if records != previous { persistHistory() }
    }
    public func refreshPermissions() {
        permissions = permissionSnapshot?() ?? permissionService.snapshot(inputMonitoringRequired: false)
        settings.launchAtLogin = !isDemo && SMAppService.mainApp.status == .enabled
        if !isDemo, permissions.microphone != .allowed, let id = session.id,
           [.recording, .paused].contains(session.phase) { send(.fail(id, "Microphone access is no longer available. This session stopped.")) }
        syncFloatingBar?()
    }
    public func requestMicrophonePermission() {
        guard !isDemo else { notice = "UI demo does not request microphone access."; return }
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty,
              Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            notice = "Configure your development bundle ID in Xcode, then run Saydrop.app before requesting microphone access. This project does not provide a release bundle ID."; return
        }
        Task { await permissionService.requestMicrophone(); refreshPermissions() }
    }
    public func requestGlobalEscapePermission() {
        guard !isDemo else { notice = "UI demo does not request input monitoring."; return }
        permissionService.requestInputMonitoring()
        permissions = permissionService.snapshot(inputMonitoringRequired: true)
        syncFloatingBar?()
    }
    public func openPermissionSettings(_ kind: PermissionKind) { permissionService.openSettings(kind) }
    @discardableResult public func copyText(_ text: String) -> Bool {
        NSPasteboard.general.clearContents(); return NSPasteboard.general.setString(text, forType: .string)
    }
    public func playAudio(_ record: HistoryRecord) {
        purgeExpired()
        guard record.hasAudio, let data = audioByRecord[record.id] else { notice = "No recording is available for playback."; return }
        if playingRecordID == record.id { stopAudio(); return }
        stopAudio()
        do { let audio = try AVAudioPlayer(data: data); if audio.play() { player = audio; playingRecordID = record.id; playbackTime = 0; startTicking() } }
        catch { notice = "Could not play the recording." }
    }
    public func playTemporaryAudio() {
        guard let data = temporaryAudio, let id = session.id,
              !(temporaryLifetime?.isExpired(at: monotonicNow) ?? true), !session.microphoneActive else {
            notice = "The temporary recording is unavailable or has been cleared."; return
        }
        if playingRecordID == id { stopAudio(); return }
        stopAudio()
        do {
            let audio = try AVAudioPlayer(data: data)
            guard audio.play() else { notice = "Could not play the recording."; return }
            player = audio; playingRecordID = id; playbackTime = 0; startTicking()
        } catch { notice = "Could not play the recording." }
    }
    public func discardCaptureCheckAudio() { clearTemporaryAudio(); captureCheckSummary = nil }
    public func stopAudio() { player?.stop(); player = nil; playingRecordID = nil; playbackTime = 0 }
    public func completeOnboarding() { settings.onboardingCompleted = true; persistPreferences(); showOnboarding = false }
    private func persistPreferences() { if let data = try? JSONEncoder().encode(settings) { defaults?.set(data, forKey: "Saydrop.ui.settings") } }

    public func openFeedback(for record: HistoryRecord) {
        guard feedback?.state != .uploading else { notice = "Finish the current feedback first. Another upload will not start."; return }
        feedback = FeedbackPresentation(draft: FeedbackDraft(requestID: record.requestID, outputMode: record.outputMode, rawText: record.rawText,
            outputText: record.outputText, audio: audioByRecord[record.id], duration: record.duration))
        presentFeedbackWindow?()
    }
    public func openCurrentFeedback() {
        guard feedback?.state != .uploading else { return }
        guard let result = session.result, let id = session.id else { return }
        feedback = FeedbackPresentation(draft: FeedbackDraft(requestID: id, outputMode: session.mode, rawText: result.rawText,
            outputText: result.outputText, audio: temporaryAudio, duration: elapsed, audioDeadline: temporaryLifetime?.deadline))
        presentFeedbackWindow?()
    }
    public func editFeedback(_ edit: (inout FeedbackDraft) -> Void) {
        guard var value = feedback, value.state != .uploading, value.state != .submitted else { return }
        edit(&value.draft); value.confirmation = nil; value.receiptID = nil; value.state = .editing; value.message = nil; feedback = value
    }
    public func prepareFeedbackConsent() {
        guard var value = feedback, value.state != .uploading else { return }
        // This only previews. No request or encoded body is created before explicit confirm.
        value.state = .awaitingConsent; value.message = nil; feedback = value
    }
    public func returnToFeedbackEditing() { guard feedback?.state != .uploading else { return }; feedback?.state = .editing; feedback?.confirmation = nil }
    public func confirmAndSubmitFeedback() {
        guard var value = feedback, value.state == .awaitingConsent else { return }
        guard let policy = feedbackPolicy, policy.isConfigured else {
            value.message = "The feedback endpoint, authentication, and retention/deletion policy are not configured. Nothing was sent."; feedback = value; return
        }
        do {
            let tentative = try value.draft.confirm(policy: policy, at: Date(), uptime: monotonicNow)
            let digest = try feedbackDigest(tentative)
            let identity = value.retryIdentities[digest] ?? FeedbackRetryIdentity(id: tentative.id, confirmedAt: tentative.confirmedAt)
            value.retryIdentities[digest] = identity
            if value.unknownIDs.contains(identity.id), !value.queriedIDs.contains(identity.id) {
                value.receiptID = identity.id; value.state = .submissionUnknown
                value.message = "The previous receipt is unknown. Check the original feedback status first. Nothing was resent."; feedback = value; return
            }
            value.confirmation = try value.draft.confirm(policy: policy, at: identity.confirmedAt, uptime: monotonicNow, id: identity.id)
            value.receiptID = value.confirmation?.id; feedback = value; uploadConfirmedFeedback()
        } catch { value.message = "The content is invalid, over a limit, or the recording expired. Review it and confirm again."; feedback = value }
    }
    private func feedbackDigest(_ confirmed: ConfirmedFeedback) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: confirmed.encodedPayload()) as! [String: Any]
        object.removeValue(forKey: "feedbackId")
        var consent = object["consent"] as! [String: Any]; consent.removeValue(forKey: "confirmedAt"); object["consent"] = consent
        object["receivingPolicy"] = [confirmed.policy.baseURL.absoluteString, confirmed.policy.recipient, confirmed.policy.purpose, confirmed.policy.retention, confirmed.policy.deletionContact, confirmed.policy.version]
        return Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])))
    }
    private func uploadConfirmedFeedback() {
        guard var value = feedback, let confirmed = value.confirmation, let policy = feedbackPolicy else { return }
        do { try confirmed.validate(current: value.draft, policy: policy, uptime: monotonicNow) }
        catch { value.confirmation = nil; value.state = .editing; value.message = "The content or policy changed. Confirm again."; feedback = value; return }
        value.state = .uploading; value.message = nil; feedback = value; startTicking()
        let presentationID = value.id
        feedbackTask = Task { [weak self] in
            guard let self else { return }
            do { let receipt = try await feedbackAPI.submit(confirmed); applyReceipt(receipt, presentationID: presentationID) }
            catch { guard feedback?.id == presentationID, feedback?.receiptID == confirmed.id else { return }; feedback?.state = .submissionUnknown
                feedback?.message = "Submission status is unknown. Check the same feedbackId; nothing will be resent automatically. Sent data may not be retractable."
                feedback?.unknownIDs.insert(confirmed.id)
                feedback?.confirmation?.releaseAudio()
            }
        }
    }
    public func queryFeedbackReceipt() {
        guard let id = feedback?.receiptID, let presentationID = feedback?.id, feedback?.state != .uploading else { return }
        feedback?.state = .uploading
        feedback?.queriedIDs.insert(id)
        feedbackTask = Task { [weak self] in
            guard let self else { return }
            do { let receipt = try await feedbackAPI.status(id); applyReceipt(receipt, presentationID: presentationID) }
            catch { if feedback?.id == presentationID, feedback?.receiptID == id { feedback?.state = .submissionUnknown; feedback?.message = "Receipt status is still unknown. Nothing was resent." } }
        }
    }
    private func applyReceipt(_ receipt: FeedbackReceipt, presentationID: UUID) {
        guard feedback?.id == presentationID, receipt.feedbackId == feedback?.receiptID else { return }
        if receipt.isReliableSuccess { feedback?.state = .submitted; feedback?.message = "Feedback submitted. The server receipt is authoritative; deleting local data does not delete cloud feedback." }
        else if receipt.status == .failed { feedback?.state = .failed; feedback?.message = "The server confirmed submission failed. Review the content and confirm again before deciding whether to submit." }
        else { feedback?.state = .submissionUnknown; feedback?.message = "The service is still processing or the receipt is incomplete. Check the same feedback status." }
        if !receipt.isReliableSuccess && receipt.status != .failed { feedback?.unknownIDs.insert(receipt.feedbackId) }
        feedback?.confirmation?.releaseAudio()
    }
    public func closeFeedback() {
        if feedback?.state == .uploading { feedbackTask?.cancel(); feedbackAPI.cancel(); notice = "Feedback upload was stopped where possible. The recipient may already have received it." }
        feedback = nil
        closeFeedbackWindow?()
    }
    private func expireFeedbackAudio() {
        guard feedback?.draft.audio != nil else { return }
        let uploading = feedback?.state == .uploading && feedback?.draft.includeAudio == true
        if uploading { feedbackTask?.cancel(); feedbackAPI.cancel() }
        feedback?.draft.audio = nil; feedback?.draft.includeAudio = false; feedback?.draft.audioDeadline = nil
        feedback?.confirmation?.releaseAudio(); feedback?.confirmation = nil
        feedback?.state = uploading ? .submissionUnknown : .editing
        feedback?.message = "The temporary recording was cleared. \(uploading ? "Audio upload was stopped where possible, but the recipient may have received it. " : "")Confirm again before submitting text only."
    }
    public func submitPositiveFeedback(for record: HistoryRecord) { submitPositive(requestID: record.requestID, mode: record.outputMode) }
    public func submitCurrentPositiveFeedback() { guard let id = session.id, session.result != nil else { return }; submitPositive(requestID: id, mode: session.mode) }
    private func submitPositive(requestID: UUID, mode: OutputMode) {
        guard let feedbackPolicy, feedbackPolicy.isConfigured else { notice = "The feedback service and policy are not configured. Positive feedback was not uploaded."; return }
        guard !positiveInFlight.contains(requestID), !positiveReceived.contains(requestID) else { return }
        if positiveUnknown.contains(requestID) { notice = "The previous positive feedback receipt is unknown. Checking the original feedback without resending." }
        let id = positiveIDs[requestID] ?? UUID(); positiveIDs[requestID] = id; positiveInFlight.insert(requestID)
        Task { [weak self] in
            guard let self else { return }
            defer { positiveInFlight.remove(requestID) }
            do {
                let receipt: FeedbackReceipt
                if positiveUnknown.contains(requestID) { receipt = try await feedbackAPI.status(id) }
                else { receipt = try await feedbackAPI.submitPositive(PositiveFeedback(id: id, requestID: requestID, mode: mode)) }
                if receipt.feedbackId == id, receipt.isReliableSuccess { positiveReceived.insert(requestID); positiveUnknown.remove(requestID); notice = "Positive feedback submitted without audio or transcript text." }
                else { positiveUnknown.insert(requestID); notice = "Positive feedback receipt is unconfirmed. Clicking again will check the same receipt." }
            } catch { positiveUnknown.insert(requestID); notice = "Positive feedback submission status is unknown. Nothing will be resent automatically." }
        }
    }
    public func interruptSession(reason: String) {
        if let id = session.id, session.phase.isActive { send(.cancel(id)); notice = reason }
        clearTemporaryAudio(); resetShortcutHeld?()
    }
    static func sampleRecords() -> [HistoryRecord] {
        let now = Date()
        let examples: [(String, OutputMode, Double, InsertionOutcome)] = [
            ("Meet Alice at three this afternoon", .raw, 8, .confirmed),
            ("Mark this version as a release candidate.", .lightPolish, 12, .preview),
            ("Review the permission flow tomorrow", .raw, 6, .unknown),
            ("I will send Monday's meeting notes later", .raw, 9, .preview)
        ]
        return examples.enumerated().map { index, example in
            let created = now.addingTimeInterval(index == 3 ? -86400 : -Double(index) * 1800)
            return HistoryRecord(createdAt: created, duration: example.2, outputMode: example.1, rawText: example.0, outputText: example.0,
                targetName: "Sample · Notes", insertionOutcome: example.3, textExpiresAt: created.addingTimeInterval(7 * 86400), audioExpiresAt: nil, hasAudio: false)
        }
    }
}
