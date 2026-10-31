import AppKit
import XCTest
import SaydropCore
@testable import SaydropUI

@MainActor
private final class TargetAccessFake: TextTargetAccess {
    var trusted = true
    var element: AnyObject = NSObject()
    var window: AnyObject = NSObject()
    var pid: pid_t = 123
    var value = "Hello 🌍 world"
    var range = NSRange(location: 6, length: 2)
    var secure = false
    var writable = true
    var readable = true
    var writeSucceeds = true
    var ignoresWrite = false
    var writes = 0
    func read() -> TextTargetState? {
        guard readable else { return nil }
        return TextTargetState(element: element, window: window, pid: pid, name: "Test editor", value: value,
                               range: range, secure: secure, writable: writable)
    }
    func replaceSelection(_ text: String, in target: TextTargetState) -> Bool {
        writes += 1
        if !ignoresWrite { value = (value as NSString).replacingCharacters(in: range, with: text) }
        return writeSucceeds
    }
}

@MainActor
final class AutoInsertionTests: XCTestCase {
    func testUnicodeSelectionReplacementAndSingleUse() {
        let access = TargetAccessFake(), insertion: AutoInsertion
        insertion = AutoInsertion(access: access); insertion.capture()
        XCTAssertEqual(insertion.insert("\u{4E16}\u{754C}").outcome, .confirmed)
        XCTAssertEqual(access.value, "Hello \u{4E16}\u{754C} world")
        XCTAssertEqual(insertion.insert("duplicate").outcome, .preview)
        XCTAssertEqual(access.writes, 1)
    }
    func testCaretInsertion() {
        let access = TargetAccessFake(); access.range = NSRange(location: 0, length: 0)
        let insertion = AutoInsertion(access: access); insertion.capture()
        XCTAssertEqual(insertion.insert("\u{4F60}\u{597D} ").outcome, .confirmed)
        XCTAssertEqual(access.value, "\u{4F60}\u{597D} Hello 🌍 world")
    }
    func testChangedAppWindowElementValueOrSelectionNeverWrites() {
        for change in 0..<5 {
            let access = TargetAccessFake(), insertion: AutoInsertion
            insertion = AutoInsertion(access: access); insertion.capture()
            switch change {
            case 0: access.pid = 456
            case 1: access.window = NSObject()
            case 2: access.element = NSObject()
            case 3: access.value = "changed"
            default: access.range = NSRange(location: 0, length: 0)
            }
            XCTAssertEqual(insertion.insert("text").outcome, .preview)
            XCTAssertEqual(access.writes, 0)
        }
    }
    func testSecureReadOnlyInvalidRangeAndMissingPermission() {
        for change in 0..<5 {
            let access = TargetAccessFake()
            switch change {
            case 0: access.secure = true
            case 1: access.writable = false
            case 2: access.range = NSRange(location: NSNotFound, length: 1)
            case 3: access.trusted = false
            default: access.range = NSRange(location: 7, length: 1) // Split UTF-16 surrogate.
            }
            let insertion = AutoInsertion(access: access); insertion.capture()
            XCTAssertEqual(insertion.insert("text").outcome, .preview)
            XCTAssertEqual(access.writes, 0)
        }
    }
    func testPermissionRevokedAndTargetDisappearedAfterCapture() {
        let access = TargetAccessFake(), insertion: AutoInsertion
        insertion = AutoInsertion(access: access); insertion.capture(); access.trusted = false
        XCTAssertEqual(insertion.insert("text").reason, .accessibilityUnavailable)
        access.trusted = true; insertion.capture(); access.readable = false
        XCTAssertEqual(insertion.insert("text").outcome, .preview)
        XCTAssertEqual(access.writes, 0)
    }
    func testAmbiguousWriteNeverRetries() {
        for ignores in [true, false] {
            let access = TargetAccessFake(); access.ignoresWrite = ignores; access.writeSucceeds = ignores
            let insertion = AutoInsertion(access: access); insertion.capture()
            XCTAssertEqual(insertion.insert("text").outcome, .unknown)
            _ = insertion.insert("duplicate")
            XCTAssertEqual(access.writes, 1)
        }
    }
    func testCancellationClearsTarget() {
        let access = TargetAccessFake(), insertion: AutoInsertion
        insertion = AutoInsertion(access: access); insertion.capture(); insertion.clear()
        XCTAssertEqual(insertion.insert("text").outcome, .preview)
        XCTAssertEqual(access.writes, 0)
    }
}

@MainActor
private final class InsertionSessionBackend: SessionBackend {
    var isConfigured = true
    var suspended = false
    var continuation: CheckedContinuation<Void, Never>?
    func start(id: UUID) async throws {}
    func pause(id: UUID) {}
    func resume(id: UUID) async throws {}
    func finish(id: UUID, mode: OutputMode, stage: @escaping (SessionPhase) -> Void) async throws -> SessionResult {
        stage(.uploading); stage(.transcribing)
        if suspended { await withCheckedContinuation { continuation = $0 } }
        return SessionResult(rawText: "\u{4E16}\u{754C}", outputText: "\u{4E16}\u{754C}")
    }
    func cancel(id: UUID) {}
}

@MainActor
final class AutoInsertionSessionTests: XCTestCase {
    private func make(_ access: TargetAccessFake, _ backend: InsertionSessionBackend, history: (any HistoryStoring)? = nil) -> AppModel {
        var permissions = PermissionSnapshot(); permissions.microphone = .allowed; permissions.accessibility = .allowed
        let model = AppModel(isDemo: false, defaults: nil, backend: backend, feedbackAPI: UnconfiguredFeedbackAPI(),
                             feedbackPolicy: nil, autoInsertion: AutoInsertion(access: access), historyStore: history, permissionSnapshot: { permissions })
        model.showOnboarding = false
        model.applyQuotaFromService(Quota(limit: 50, used: 0, reserved: 0, remaining: 50, resetAt: "2026-10-27T00:00:00+08:00"))
        return model
    }
    private func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(20)) }
    func testResultWritesCapturedTargetAndCompletes() async {
        let access = TargetAccessFake(), backend = InsertionSessionBackend()
        let model = make(access, backend)
        model.beginSession(); await settle(); model.finishSession(); await settle()
        XCTAssertEqual(model.session.phase, .completed)
        XCTAssertEqual(model.session.insertionOutcome, .confirmed)
        XCTAssertEqual(model.session.result?.targetName, "Test editor")
        XCTAssertEqual(access.value, "Hello \u{4E16}\u{754C} world"); XCTAssertEqual(access.writes, 1)
        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(model.records.first?.requestID, model.session.id)
        XCTAssertEqual(model.records.first?.insertionOutcome, .confirmed)
        XCTAssertEqual(model.records.first?.outputText, "\u{4E16}\u{754C}")
        model.closeOrCancelSession()
    }
    func testCancellationRejectsLateTranscriptionAndNeverWrites() async {
        let access = TargetAccessFake(), backend = InsertionSessionBackend(); backend.suspended = true
        let model = make(access, backend)
        model.beginSession(); await settle(); model.finishSession(); await settle()
        model.closeOrCancelSession(); backend.continuation?.resume(); await settle()
        XCTAssertEqual(model.session.phase, .cancelled); XCTAssertEqual(access.writes, 0)
        XCTAssertTrue(model.records.isEmpty)
    }
    func testSavingDisabledProducesNoHistory() async {
        let access = TargetAccessFake(), backend = InsertionSessionBackend()
        let model = make(access, backend); model.updateSaving(audio: false, text: false)
        model.beginSession(); await settle(); model.finishSession(); await settle()
        XCTAssertEqual(model.session.phase, .completed); XCTAssertTrue(model.records.isEmpty)
        model.closeOrCancelSession()
    }
    func testPreviewAlsoFormsHistory() async {
        let access = TargetAccessFake(), backend = InsertionSessionBackend()
        access.trusted = false
        let model = make(access, backend)
        model.beginSession(); await settle(); model.finishSession(); await settle()
        XCTAssertEqual(model.session.phase, .previewing)
        XCTAssertEqual(model.records.count, 1); XCTAssertEqual(model.records.first?.insertionOutcome, .preview)
        model.closeOrCancelSession()
    }

    func testPersistReloadAndClearHistory() async {
        let history = MemoryHistoryFake(), access = TargetAccessFake(), backend = InsertionSessionBackend()
        let model = make(access, backend, history: history)
        model.beginSession(); await settle(); model.finishSession(); await settle()
        XCTAssertEqual(history.archive.records.count, 1)
        let reopened = make(TargetAccessFake(), InsertionSessionBackend(), history: history)
        XCTAssertEqual(reopened.records, model.records)
        reopened.requestClearHistory(); reopened.confirmLocalChange()
        XCTAssertTrue(history.archive.records.isEmpty)
        XCTAssertTrue(make(TargetAccessFake(), InsertionSessionBackend(), history: history).records.isEmpty)
        model.closeOrCancelSession()
    }
    func testExpiredHistoryIsPurgedOnLoadAndPersisted() {
        let history = MemoryHistoryFake()
        history.archive.records = [SavePolicy(audioEnabled: false, textEnabled: true).record(
            result: SessionResult(rawText: "old", outputText: "old"), at: Date(timeIntervalSinceNow: -86400 * 10),
            duration: 1, mode: .raw, outcome: .confirmed, audioAvailable: false)!]
        let model = make(TargetAccessFake(), InsertionSessionBackend(), history: history)
        XCTAssertTrue(model.records.isEmpty); XCTAssertTrue(history.archive.records.isEmpty)
    }

}


@MainActor
private final class MemoryHistoryFake: HistoryStoring {
    var archive = HistoryArchive()
    func load() throws -> HistoryArchive { archive }
    func save(_ archive: HistoryArchive) throws { self.archive = archive }
}
