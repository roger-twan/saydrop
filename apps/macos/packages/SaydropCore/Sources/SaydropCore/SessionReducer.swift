import Foundation

public enum SessionPhase: String, CaseIterable {
    case idle, checking, recording, paused, finalizing, uploading, transcribing, polishing, previewing, completed, captured, failed, cancelled
    public var title: String {
        switch self {
        case .idle: return "Ready"
        case .checking: return "Checking"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .finalizing: return "Preparing audio"
        case .uploading: return "Uploading"
        case .transcribing: return "Transcribing"
        case .polishing: return "Polishing"
        case .previewing: return "Preview"
        case .completed: return "Completed"
        case .captured: return "Local recording complete"
        case .failed: return "Session failed"
        case .cancelled: return "Cancelled"
        }
    }
    public var isProcessing: Bool { [.checking, .finalizing, .uploading, .transcribing, .polishing].contains(self) }
    public var isActive: Bool { [.checking, .recording, .paused, .finalizing, .uploading, .transcribing, .polishing, .previewing].contains(self) }
}
public struct SessionState: Equatable {
    public var id: UUID?
    public var phase: SessionPhase = .idle
    public var mode: OutputMode = .raw
    public var elapsed: TimeInterval = 0
    public var result: SessionResult?
    public var previewReason: PreviewReason?
    public var message: String?
    public var insertionOutcome: InsertionOutcome?
    public var isBarVisible = false
    public private(set) var segmentStartedAt: TimeInterval?
    public private(set) var pausedAt: TimeInterval?
    public var canSelectMode: Bool { [.idle, .recording, .paused].contains(phase) }
    /// Only a capture-start acknowledgement may enter recording. UI begin cannot imply a hot microphone.
    public var microphoneActive: Bool { phase == .recording }
    public init(mode: OutputMode = .raw) { self.mode = mode }
    public func pauseRemaining(at now: TimeInterval) -> TimeInterval {
        guard let pausedAt else { return SaydropDefaults.pauseLimit }
        return max(0, SaydropDefaults.pauseLimit - max(0, now - pausedAt))
    }
    fileprivate mutating func startSegment(at now: TimeInterval) { segmentStartedAt = now; pausedAt = nil }
    fileprivate mutating func stopSegment(at now: TimeInterval) {
        if let segmentStartedAt { elapsed = min(SaydropDefaults.captureLimit, elapsed + max(0, now - segmentStartedAt)) }
        segmentStartedAt = nil
    }
    public func displayedElapsed(at now: TimeInterval) -> TimeInterval {
        min(SaydropDefaults.captureLimit, elapsed + (segmentStartedAt.map { max(0, now - $0) } ?? 0))
    }
    fileprivate mutating func pause(at now: TimeInterval) { stopSegment(at: now); pausedAt = now }
    fileprivate mutating func clearTiming() { segmentStartedAt = nil; pausedAt = nil }
}
public enum SessionEvent {
    case begin(UUID, TimeInterval)
    case captureStarted(UUID, TimeInterval)
    case chooseMode(OutputMode)
    case pause(UUID, TimeInterval)
    case resumeStarted(UUID, TimeInterval)
    case finish(UUID, TimeInterval)
    case tick(UUID, TimeInterval)
    case stage(UUID, SessionPhase)
    case result(UUID, SessionResult, PreviewReason?)
    case captureValidated(UUID, TimeInterval)
    case insertion(UUID, InsertionOutcome)
    case fail(UUID, String)
    case cancel(UUID)
    case closeBar
    case showBar
}
public enum SessionEffect: Equatable { case beginCapture(UUID), pauseCapture(UUID), finalize(UUID), cancel(UUID), showResult(UUID) }
public struct SessionTransition { public let state: SessionState; public let effects: [SessionEffect] }
public enum SessionReducer {
    public static func reduce(_ old: SessionState, _ event: SessionEvent) -> SessionTransition {
        var state = old
        var effects: [SessionEffect] = []
        func current(_ id: UUID) -> Bool { state.id == id && state.phase.isActive }
        switch event {
        case .begin(let id, _):
            guard !state.phase.isActive else { break }
            state = SessionState(mode: old.mode); state.id = id; state.phase = .checking; state.isBarVisible = true
            effects = [.beginCapture(id)]
        case .captureStarted(let id, let now):
            guard current(id), state.phase == .checking else { break }
            state.phase = .recording; state.startSegment(at: now)
        case .chooseMode(let mode):
            if state.canSelectMode { state.mode = mode }
        case .pause(let id, let now):
            guard current(id), state.phase == .recording else { break }
            state.pause(at: now); state.phase = .paused; effects = [.pauseCapture(id)]
        case .resumeStarted(let id, let now):
            guard current(id), state.phase == .paused else { break }
            if state.pauseRemaining(at: now) == 0 {
                state.phase = .cancelled; state.clearTiming(); state.message = "Paused for 5 minutes. This session was cancelled."; effects = [.cancel(id)]
            } else { state.phase = .recording; state.startSegment(at: now) }
        case .finish(let id, let now):
            guard current(id), [.recording, .paused].contains(state.phase) else { break }
            state.stopSegment(at: now); state.clearTiming(); state.phase = .finalizing; effects = [.finalize(id)]
        case .tick(let id, let now):
            guard current(id) else { break }
            if state.phase == .recording && state.displayedElapsed(at: now) >= SaydropDefaults.captureLimit {
                state.stopSegment(at: now); state.clearTiming(); state.phase = .finalizing
                state.message = "The 120-second limit was reached. Processing this recording."; effects = [.finalize(id)]
            } else if state.phase == .paused && state.pauseRemaining(at: now) == 0 {
                state.phase = .cancelled; state.clearTiming(); state.message = "Paused for 5 minutes. This session was cancelled."; effects = [.cancel(id)]
            }
        case .stage(let id, let phase):
            guard current(id) else { break }
            let allowed: Bool
            switch (state.phase, phase) {
            case (.finalizing, .uploading), (.uploading, .transcribing): allowed = true
            case (.transcribing, .polishing): allowed = state.mode == .lightPolish
            default: allowed = false
            }
            if allowed { state.phase = phase }
        case .result(let id, let result, let reason):
            guard current(id), [.transcribing, .polishing].contains(state.phase) else { break }
            state.result = result; state.previewReason = reason; state.phase = .previewing
            if result.polishFallback { state.message = "Light polish was unavailable. The raw transcript was kept." }
            effects = [.showResult(id)]
        case .captureValidated(let id, let duration):
            guard current(id), state.phase == .finalizing, duration.isFinite,
                  duration > 0, duration <= SaydropDefaults.captureLimit else { break }
            state.phase = .captured; state.elapsed = duration; state.clearTiming()
            state.result = nil; state.previewReason = nil; state.insertionOutcome = nil
            state.message = "Local audio check complete. Nothing was uploaded, transcribed, inserted, or saved to history."
        case .insertion(let id, let outcome):
            guard current(id), state.phase == .previewing, state.insertionOutcome == nil else { break }
            state.insertionOutcome = outcome
            if outcome == .confirmed { state.phase = .completed }
            if outcome == .unknown { state.previewReason = .insertionUnknown }
        case .fail(let id, let message):
            guard current(id) else { break }
            state.phase = .failed; state.message = message; state.clearTiming(); effects = [.cancel(id)]
        case .cancel(let id):
            guard state.id == id else { break }
            if state.phase == .completed { state.isBarVisible = false; break }
            guard state.phase.isActive else { state.isBarVisible = false; break }
            state.phase = .cancelled; state.result = nil; state.clearTiming(); effects = [.cancel(id)]
            state.message = [.uploading, .transcribing, .polishing].contains(old.phase)
                ? "Session cancelled. A dispatched request may still count against your quota." : "Session cancelled."
        case .closeBar:
            if !state.phase.isActive { state.isBarVisible = false }
        case .showBar: state.isBarVisible = true
        }
        return SessionTransition(state: state, effects: effects)
    }
}
public struct ShortcutEdges {
    private var isDown = false
    public init() {}
    public mutating func keyDown(isRepeat: Bool) -> Bool {
        guard !isRepeat, !isDown else { return false }; isDown = true; return true
    }
    public mutating func keyUp() -> Bool { guard isDown else { return false }; isDown = false; return true }
    public mutating func reset() { isDown = false }
}
