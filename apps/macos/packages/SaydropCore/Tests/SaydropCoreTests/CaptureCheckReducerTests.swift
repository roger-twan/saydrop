import XCTest
@testable import SaydropCore

final class CaptureCheckReducerTests: XCTestCase {
    func testCaptureCheckDoesNotFabricateTranscriptOrInsertion() {
        let id = UUID()
        var state = SessionReducer.reduce(SessionState(), .begin(id, 0)).state
        state = SessionReducer.reduce(state, .captureStarted(id, 0)).state
        state = SessionReducer.reduce(state, .finish(id, 1)).state
        let completed = SessionReducer.reduce(state, .captureValidated(id, 1))
        XCTAssertEqual(completed.state.phase, .captured)
        XCTAssertNil(completed.state.result); XCTAssertNil(completed.state.insertionOutcome)
        XCTAssertFalse(completed.state.microphoneActive); XCTAssertFalse(completed.state.phase.isActive)
        XCTAssertTrue(completed.effects.isEmpty)
    }
    func testCaptureValidationRequiresCurrentFinalizingSession() {
        let id = UUID()
        let checking = SessionReducer.reduce(SessionState(), .begin(id, 0)).state
        XCTAssertEqual(SessionReducer.reduce(checking, .captureValidated(id, 1)).state, checking)
        let cancelled = SessionReducer.reduce(checking, .cancel(id)).state
        XCTAssertEqual(SessionReducer.reduce(cancelled, .captureValidated(id, 1)).state, cancelled)
    }
    func testCaptureValidationRejectsNonFiniteOrOutOfBoundDuration() {
        let id = UUID()
        var state = SessionReducer.reduce(SessionState(), .begin(id, 0)).state
        state = SessionReducer.reduce(state, .captureStarted(id, 0)).state
        state = SessionReducer.reduce(state, .finish(id, 1)).state
        for duration in [0, -1, Double.infinity, Double.nan, 120.01] {
            XCTAssertEqual(SessionReducer.reduce(state, .captureValidated(id, duration)).state, state)
        }
    }
}
