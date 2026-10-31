import Foundation
import XCTest
import SaydropCore
@testable import SaydropUI

@MainActor
private final class FakeShortcutRouter: ShortcutSessionRouting {
    enum Call: Equatable {
        case begin
        case resume
        case finish
        case close
        case changed(String)
    }

    var shortcutSession = SessionState()
    var shortcutRecordingMode: RecordingMode = .toggle
    var shortcutInteractionAllowed = true
    private(set) var calls: [Call] = []

    func shortcutBegin() {
        calls.append(.begin)
        shortcutSession = state(id: UUID(), phase: .checking)
    }

    func shortcutResume() {
        calls.append(.resume)
    }

    func shortcutFinish() {
        calls.append(.finish)
    }

    func shortcutClose() {
        calls.append(.close)
    }

    func shortcutChanged(display: String) {
        calls.append(.changed(display))
    }

    func replaceSession(id: UUID? = UUID(), phase: SessionPhase) {
        shortcutSession = state(id: id, phase: phase)
    }

    private func state(id: UUID?, phase: SessionPhase) -> SessionState {
        var state = SessionState()
        state.id = id
        state.phase = phase
        return state
    }
}

@MainActor
final class ShortcutControllerTests: XCTestCase {
    private func makeController(
        router: FakeShortcutRouter
    ) -> ShortcutController {
        // Unit tests intentionally avoid KeyboardShortcuts registration and the
        // package's UserDefaults.standard-backed initial shortcut write.
        ShortcutController(router: router, registerSystemShortcut: false)
    }

    func testToggleStartsOnKeyDownAndIgnoresKeyUp() {
        let router = FakeShortcutRouter()
        router.shortcutRecordingMode = .toggle
        let controller = makeController(router: router)

        controller.keyDown()
        controller.keyUp()

        XCTAssertEqual(router.calls, [.begin])
    }

    func testToggleFinishesRecordingOnlyOnceForRepeatedKeyDown() {
        let router = FakeShortcutRouter()
        router.shortcutRecordingMode = .toggle
        router.replaceSession(phase: .recording)
        let controller = makeController(router: router)

        controller.keyDown()
        controller.keyDown()
        controller.keyUp()

        XCTAssertEqual(router.calls, [.finish])
    }

    func testHoldStartsCheckingSessionThenFinishesThatSessionOnRelease() {
        let router = FakeShortcutRouter()
        router.shortcutRecordingMode = .hold
        let controller = makeController(router: router)

        controller.keyDown()
        let startedID = router.shortcutSession.id
        controller.keyUp()

        XCTAssertNotNil(startedID)
        XCTAssertEqual(router.calls, [.begin, .finish])
    }

    func testHoldResumesPausedSessionThenFinishesOnRelease() {
        let router = FakeShortcutRouter()
        router.shortcutRecordingMode = .hold
        let pausedID = UUID()
        router.replaceSession(id: pausedID, phase: .paused)
        let controller = makeController(router: router)

        controller.keyDown()
        controller.keyUp()

        XCTAssertEqual(router.calls, [.resume, .finish])
    }

    func testStaleHoldReleaseCannotFinishANewerSession() {
        let router = FakeShortcutRouter()
        router.shortcutRecordingMode = .hold
        router.replaceSession(id: UUID(), phase: .paused)
        let controller = makeController(router: router)

        controller.keyDown()
        router.replaceSession(id: UUID(), phase: .recording)
        controller.keyUp()

        XCTAssertEqual(router.calls, [.resume])
    }

    func testInteractionDisabledDropsShortcutEdges() {
        let router = FakeShortcutRouter()
        router.shortcutInteractionAllowed = false
        let controller = makeController(router: router)

        controller.keyDown()
        controller.keyUp()

        XCTAssertTrue(router.calls.isEmpty)
    }

    func testResetHeldDropsPendingHoldRelease() {
        let router = FakeShortcutRouter()
        router.shortcutRecordingMode = .hold
        let controller = makeController(router: router)

        controller.keyDown()
        controller.resetHeld()
        controller.keyUp()

        XCTAssertEqual(router.calls, [.begin])
    }

    func testProcessingSessionDoesNotStartOrFinishAnotherSession() {
        let router = FakeShortcutRouter()
        router.shortcutRecordingMode = .toggle
        router.replaceSession(phase: .uploading)
        let controller = makeController(router: router)

        controller.keyDown()
        controller.keyUp()

        XCTAssertTrue(router.calls.isEmpty)
    }
}
