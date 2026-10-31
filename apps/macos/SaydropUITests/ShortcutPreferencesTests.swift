import XCTest
import SaydropCore
@testable import SaydropUI

@MainActor
final class ShortcutPreferencesTests: XCTestCase {
    func testExistingTypedChoiceIncludingDisabledIsPreserved() {
        XCTAssertEqual(LegacyShortcutDecision.decide(legacy: "⌘⌥R", hasTyped: true), .preserveTyped)
    }
    func testDefaultCanUseProductInitialShortcut() {
        XCTAssertEqual(LegacyShortcutDecision.decide(legacy: SaydropDefaults.shortcut, hasTyped: false), .useInitial)
    }
    func testUnknownLegacyStringMustBeReRecordedNotOverwrittenByDefault() {
        XCTAssertEqual(LegacyShortcutDecision.decide(legacy: "⌘⌥R", hasTyped: false), .rerecord("⌘⌥R"))
    }
    func testGlobalEscIsNotAStandbyListener() {
        XCTAssertFalse(GlobalEscapeMonitor.shouldListen(SessionState()))
        let id = UUID()
        var state = SessionReducer.reduce(SessionState(), .begin(id, 0)).state
        XCTAssertTrue(GlobalEscapeMonitor.shouldListen(state))
        state = SessionReducer.reduce(state, .cancel(id)).state
        XCTAssertFalse(GlobalEscapeMonitor.shouldListen(state))
    }
}
