import XCTest
import Foundation
import SaydropCore
@testable import SaydropUI

@MainActor
private final class CaptureClock { var time: TimeInterval = 0 }

@MainActor
private final class ControlledAudio: AudioCapturing {
    var onLevel: ((UUID, Double) -> Void)?
    var onFailure: ((UUID, String) -> Void)?
    var onLimit: ((UUID) -> Void)?
    var suspendStart = false
    var suspendResume = false
    var starts: [UUID] = []
    var resumes: [UUID] = []
    var cancellations: [UUID] = []
    var finishCalls = 0
    var hardwareID: UUID?
    var startContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    var resumeContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    var hardwareOn: Bool { hardwareID != nil }
    func start(id: UUID) async throws {
        starts.append(id); hardwareID = id
        if suspendStart { await withCheckedContinuation { startContinuations[id] = $0 } }
        // Deliberately allow a late acknowledgement; the production composition must reject it.
    }
    func pause(id: UUID) { if hardwareID == id { hardwareID = nil } }
    func resume(id: UUID) async throws {
        resumes.append(id)
        if suspendResume { await withCheckedContinuation { resumeContinuations[id] = $0 } }
        hardwareID = id
    }
    func finish(id: UUID) async throws -> CapturedAudio {
        finishCalls += 1; if hardwareID == id { hardwareID = nil }
        return Self.fixture()
    }
    func cancel(id: UUID) { cancellations.append(id); if hardwareID == id { hardwareID = nil } }
    func acknowledgeStart(_ id: UUID) { startContinuations.removeValue(forKey: id)?.resume() }
    func acknowledgeResume(_ id: UUID) { resumeContinuations.removeValue(forKey: id)?.resume() }
    static func fixture() -> CapturedAudio {
        let frames = 800
        var wav = Data()
        func text(_ value: String) { wav.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + frames * 2)); text("WAVE"); text("fmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16); text("data"); u32(UInt32(frames * 2))
        for _ in 0..<frames { u16(8192) }
        return CapturedAudio(wav: wav, duration: Double(frames) / 16_000, frameCount: frames, rms: 0.25)
    }
}

@MainActor
private final class CountingTranscriber: TranscriptionServicing {
    var isConfigured = true
    var calls = 0
    func transcribe(_ wav: Data, id: UUID, mode: OutputMode, stage: @escaping (SessionPhase) -> Void) async throws -> SessionResult {
        calls += 1; XCTFail("Local capture checks must not transcribe"); throw CancellationError()
    }
    func cancel(id: UUID) {}
}

@MainActor
final class CaptureIntegrationTests: XCTestCase {
    private func allowedPermissions() -> PermissionSnapshot {
        var snapshot = PermissionSnapshot(); snapshot.microphone = .allowed
        snapshot.accessibility = .denied; snapshot.inputMonitoring = .notRequired; return snapshot
    }
    private func make(_ audio: ControlledAudio, clock: CaptureClock, transcriber: CountingTranscriber? = nil) -> AppModel {
        let snapshot = allowedPermissions()
        let model = AppModel(isDemo: false, defaults: nil, backend: RealSessionBackend(audio: audio, transcriber: transcriber),
                             feedbackAPI: UnconfiguredFeedbackAPI(), feedbackPolicy: nil,
                             permissionSnapshot: { snapshot }, clock: { clock.time })
        model.showOnboarding = false; model.setLocalCaptureCheckEnabled(true)
        return model
    }
    private func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(nanoseconds: 15_000_000) }

    func testFastHoldReleaseDoesNotOpenMicrophoneLater() async {
        let audio = ControlledAudio(), clock = CaptureClock(), model = make(audio, clock: clock)
        model.setRecordingMode(.hold)
        let shortcut = ShortcutController(router: model, registerSystemShortcut: false)
        shortcut.keyDown(); shortcut.keyUp(); await settle()
        XCTAssertEqual(model.session.phase, .cancelled)
        XCTAssertTrue(audio.starts.isEmpty); XCTAssertFalse(audio.hardwareOn)
    }
    func testCancelledStartRejectsLateAcknowledgementAndKeepsNewSession() async {
        let audio = ControlledAudio(), clock = CaptureClock(), model = make(audio, clock: clock)
        audio.suspendStart = true
        model.beginSession(); await settle(); let old = model.session.id!
        model.closeOrCancelSession(); model.beginSession(); await settle(); let next = model.session.id!
        audio.acknowledgeStart(old); await settle()
        XCTAssertEqual(model.session.id, next); XCTAssertEqual(model.session.phase, .checking)
        audio.acknowledgeStart(next); await settle()
        XCTAssertEqual(model.session.phase, .recording)
        model.closeOrCancelSession(); XCTAssertFalse(audio.hardwareOn)
    }
    func testExpiredPauseNeverRestartsHardware() async {
        let audio = ControlledAudio(), clock = CaptureClock(), model = make(audio, clock: clock)
        model.beginSession(); await settle(); clock.time = 10; model.pauseSession()
        clock.time = 310; model.resumeSession(); await settle()
        XCTAssertEqual(model.session.phase, .cancelled); XCTAssertTrue(audio.resumes.isEmpty)
        XCTAssertFalse(audio.hardwareOn)
    }
    func testRepeatedResumeAndHoldReleaseFinalizeOnlyOnce() async {
        let audio = ControlledAudio(), clock = CaptureClock(), model = make(audio, clock: clock)
        model.beginSession(); await settle(); clock.time = 1; model.pauseSession()
        audio.suspendResume = true
        model.resumeSession(); model.resumeSession(); await settle()
        XCTAssertEqual(audio.resumes.count, 1); XCTAssertTrue(model.isResuming)
        model.finishSession(); audio.acknowledgeResume(model.session.id!); await settle()
        XCTAssertEqual(audio.finishCalls, 1); XCTAssertEqual(model.session.phase, .captured)
        XCTAssertFalse(model.isResuming); XCTAssertFalse(audio.hardwareOn)
        model.discardCaptureCheckAudio()
    }
    func testResumeAcknowledgementAfterTimeoutCannotKeepMicrophoneOpen() async {
        let audio = ControlledAudio(), clock = CaptureClock(), model = make(audio, clock: clock)
        model.beginSession(); await settle(); clock.time = 1; model.pauseSession()
        audio.suspendResume = true; clock.time = 300; model.resumeSession(); await settle()
        clock.time = 301; audio.acknowledgeResume(model.session.id!); await settle()
        XCTAssertEqual(model.session.phase, .cancelled); XCTAssertFalse(audio.hardwareOn)
    }
    func testCancelDuringResumeRejectsLateHardwareAcknowledgement() async {
        let audio = ControlledAudio(), clock = CaptureClock(), model = make(audio, clock: clock)
        model.beginSession(); await settle(); model.pauseSession(); audio.suspendResume = true
        let id = model.session.id!; model.resumeSession(); await settle()
        model.closeOrCancelSession(); audio.acknowledgeResume(id); await settle()
        XCTAssertEqual(model.session.phase, .cancelled); XCTAssertFalse(audio.hardwareOn)
    }
    func testLocalCheckNeverTranscribesOrCreatesHistoryAndExpiresAudio() async {
        let audio = ControlledAudio(), clock = CaptureClock(), transcriber = CountingTranscriber()
        let model = make(audio, clock: clock, transcriber: transcriber)
        model.beginSession(); await settle(); model.finishSession(); await settle()
        XCTAssertEqual(model.session.phase, .captured); XCTAssertNil(model.session.result)
        XCTAssertNil(model.session.insertionOutcome); XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(transcriber.calls, 0); XCTAssertTrue(model.hasTemporaryAudio)
        clock.time = 60; model.tick(at: 60); XCTAssertFalse(model.hasTemporaryAudio)
    }
    func testPipelineFrameLimitFinalizesInsteadOfCancelling() async {
        let audio = ControlledAudio(), clock = CaptureClock(), model = make(audio, clock: clock)
        model.beginSession(); await settle(); let id = model.session.id!
        audio.onLimit?(id); await settle()
        XCTAssertEqual(model.session.phase, .captured); XCTAssertEqual(audio.finishCalls, 1)
        XCTAssertFalse(audio.hardwareOn); model.discardCaptureCheckAudio()
    }
    func testStaleLevelAndFailureCannotAffectNewSession() async {
        let audio = ControlledAudio(), clock = CaptureClock(), model = make(audio, clock: clock)
        model.beginSession(); await settle(); let old = model.session.id!
        model.closeOrCancelSession(); model.beginSession(); await settle()
        audio.onLevel?(old, 1); audio.onFailure?(old, "late")
        XCTAssertEqual(model.inputLevel, 0); XCTAssertEqual(model.session.phase, .recording)
        model.closeOrCancelSession()
    }
    func testDefaultDictationStillFailsClosedWithoutTranscriptionService() async {
        let audio = ControlledAudio(), clock = CaptureClock()
        let snapshot = allowedPermissions()
        let model = AppModel(isDemo: false, defaults: nil, backend: RealSessionBackend(audio: audio),
                             feedbackAPI: UnconfiguredFeedbackAPI(), feedbackPolicy: nil,
                             permissionSnapshot: { snapshot }, clock: { clock.time })
        model.beginSession(); await settle()
        XCTAssertTrue(audio.starts.isEmpty); XCTAssertFalse(audio.hardwareOn); XCTAssertEqual(model.session.phase, .idle)
    }
}
