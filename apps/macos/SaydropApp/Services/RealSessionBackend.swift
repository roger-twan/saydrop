import Foundation
import SaydropCore

/// A product API adapter must be explicitly injected; this module never reads server secrets.
@MainActor
protocol TranscriptionServicing: AnyObject {
    var isConfigured: Bool { get }
    func transcribe(_ wav: Data, id: UUID, mode: OutputMode, stage: @escaping (SessionPhase) -> Void) async throws -> SessionResult
    func cancel(id: UUID)
}

@MainActor
final class RealSessionBackend: SessionBackend {
    private let audio: any AudioCapturing
    private let transcriber: (any TranscriptionServicing)?
    private var activeID: UUID?
    private var resultAudio: (UUID, CapturedAudio)?
    var isConfigured: Bool { transcriber?.isConfigured == true }
    var supportsLocalCaptureCheck: Bool { true }
    var onLevel: ((UUID, Double) -> Void)? {
        get { audio.onLevel }
        set { audio.onLevel = newValue }
    }
    var onFailure: ((UUID, String) -> Void)? {
        get { audio.onFailure }
        set { audio.onFailure = newValue }
    }
    var onLimit: ((UUID) -> Void)? {
        get { audio.onLimit }
        set { audio.onLimit = newValue }
    }
    init(audio: any AudioCapturing, transcriber: (any TranscriptionServicing)? = nil) {
        self.audio = audio; self.transcriber = transcriber
    }
    func start(id: UUID) async throws {
        try Task.checkCancellation()
        guard activeID == nil else { throw CancellationError() }
        activeID = id; resultAudio = nil
        do {
            try await audio.start(id: id)
            guard activeID == id, !Task.isCancelled else { audio.cancel(id: id); throw CancellationError() }
        } catch {
            audio.cancel(id: id)
            if activeID == id { activeID = nil }
            throw error
        }
    }
    func pause(id: UUID) { guard activeID == id else { return }; audio.pause(id: id) }
    func resume(id: UUID) async throws {
        guard activeID == id else { throw CancellationError() }
        try await audio.resume(id: id)
        guard activeID == id, !Task.isCancelled else { audio.cancel(id: id); throw CancellationError() }
    }
    func finishCaptureCheck(id: UUID) async throws -> CapturedAudio {
        guard activeID == id else { throw CancellationError() }
        let captured = try await audio.finish(id: id)
        guard activeID == id, !Task.isCancelled else { throw CancellationError() }
        activeID = nil
        return captured
    }
    func finish(id: UUID, mode: OutputMode, stage: @escaping (SessionPhase) -> Void) async throws -> SessionResult {
        guard activeID == id, let transcriber, transcriber.isConfigured else { throw FeedbackValidationError.unavailable }
        let captured = try await audio.finish(id: id)
        guard activeID == id, !Task.isCancelled else { throw CancellationError() }
        guard captured.rms.isFinite, captured.rms >= 0.001 else { throw AudioPipelineError.nearSilent(rms: captured.rms) }
        // The pipeline no longer owns PCM; only this finite foreground operation holds the WAV.
        resultAudio = (id, captured)
        do {
            let result = try await transcriber.transcribe(captured.wav, id: id, mode: mode, stage: stage)
            guard activeID == id, !Task.isCancelled else { throw CancellationError() }
            activeID = nil
            return result
        } catch {
            if resultAudio?.0 == id { resultAudio = nil }
            throw error
        }
    }
    func takeResultAudio(id: UUID) -> CapturedAudio? {
        guard resultAudio?.0 == id else { return nil }
        let value = resultAudio?.1; resultAudio = nil
        return value
    }
    func cancel(id: UUID) {
        audio.cancel(id: id); transcriber?.cancel(id: id)
        if activeID == id { activeID = nil }
        if resultAudio?.0 == id { resultAudio = nil }
    }
}
