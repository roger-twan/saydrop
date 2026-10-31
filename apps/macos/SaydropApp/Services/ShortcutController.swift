import Foundation
import KeyboardShortcuts
import SaydropCore

/// The minimal session surface used by the global shortcut adapter.
///
/// The host owns the reducer, capture acknowledgement, and UI. This controller
/// only serializes KeyboardShortcuts press/release edges into those host actions.
@MainActor
protocol ShortcutSessionRouting: AnyObject {
    var shortcutSession: SessionState { get }
    var shortcutRecordingMode: RecordingMode { get }
    var shortcutInteractionAllowed: Bool { get }

    func shortcutBegin()
    func shortcutResume()
    func shortcutFinish()
    func shortcutClose()
    func shortcutChanged(display: String)
}

extension KeyboardShortcuts.Name {
    /// The sole typed KeyboardShortcuts storage key for Saydrop's record command.
    ///
    /// `initial:` gives a first-run installation ⌘⌥T without replacing a shortcut
    /// that the user has already recorded in KeyboardShortcuts' typed store.
    static let recordSession = Self(
        "recordSession",
        initial: .init(.t, modifiers: [.command, .option])
    )
}

/// Converts the one global record shortcut into reducer-owned session actions.
///
/// The controller intentionally has no microphone, input-monitor, AX, or network
/// responsibility. It does not attempt to discover every conflict outside the
/// system and application-menu checks performed by `KeyboardShortcuts.Recorder`.
@MainActor
final class ShortcutController {
    private static weak var activeSystemController: ShortcutController?
    private static var systemCallbacksInstalled = false

    private weak var router: (any ShortcutSessionRouting)?
    private var edges = ShortcutEdges()
    private var heldSessionID: UUID?
    private var modeAtDown: RecordingMode?
    private var isShutdown = false
    private let registersSystemShortcut: Bool

    /// Set `registerSystemShortcut` to `false` for pure unit tests. In that mode
    /// this initializer does not touch `KeyboardShortcuts.Name.recordSession`,
    /// register a Carbon hotkey, or write `UserDefaults.standard` defaults.
    init(router: any ShortcutSessionRouting, registerSystemShortcut: Bool = true) {
        self.router = router
        self.registersSystemShortcut = registerSystemShortcut

        if registerSystemShortcut {
            installSystemCallbacksIfNeeded()
        }
    }

    /// Receives a key-down edge from KeyboardShortcuts. Repeated key-down events
    /// are ignored by `ShortcutEdges` until a matching release/reset arrives.
    func keyDown() {
        guard !isShutdown,
              let router,
              router.shortcutInteractionAllowed,
              edges.keyDown(isRepeat: false)
        else {
            return
        }

        let state = router.shortcutSession
        let recordingMode = router.shortcutRecordingMode
        modeAtDown = recordingMode

        switch recordingMode {
        case .toggle:
            handleToggleDown(state: state, router: router)
        case .hold:
            handleHoldDown(state: state, router: router)
        }
    }

    /// Receives a key-up edge from KeyboardShortcuts. Toggle mode intentionally
    /// ignores it. Hold mode ends only the exact session captured at key-down.
    func keyUp() {
        guard !isShutdown, edges.keyUp() else {
            return
        }

        let heldID = heldSessionID
        let capturedMode = modeAtDown
        heldSessionID = nil
        modeAtDown = nil

        guard capturedMode == .hold,
              let heldID,
              let router,
              router.shortcutSession.id == heldID
        else {
            return
        }

        // This is also deliberate during `.checking` or an asynchronous resume:
        // AppModel owns the fail-closed cancellation/pending-finish behavior.
        router.shortcutFinish()
    }

    /// Drops local pressed-key state after a system interruption or lifecycle
    /// transition. It never finishes whichever session may now be active.
    func resetHeld() {
        edges.reset()
        heldSessionID = nil
        modeAtDown = nil
    }

    /// Removes this name's complete callback pair when the owning controller exits.
    func shutdown() {
        guard !isShutdown else {
            return
        }

        isShutdown = true
        resetHeld()
        if Self.activeSystemController === self {
            Self.activeSystemController = nil
            if registersSystemShortcut {
                KeyboardShortcuts.removeHandler(for: .recordSession)
                Self.systemCallbacksInstalled = false
            }
        }
    }

    private func installSystemCallbacksIfNeeded() {
        isShutdown = false
        Self.activeSystemController = self

        guard !Self.systemCallbacksInstalled else {
            return
        }

        Self.systemCallbacksInstalled = true
        KeyboardShortcuts.onKeyDown(for: .recordSession) {
            Self.activeSystemController?.keyDown()
        }
        KeyboardShortcuts.onKeyUp(for: .recordSession) {
            Self.activeSystemController?.keyUp()
        }
    }

    private func handleToggleDown(
        state: SessionState,
        router: any ShortcutSessionRouting
    ) {
        switch state.phase {
        case .idle, .cancelled, .completed, .captured, .failed:
            router.shortcutBegin()
        case .checking, .recording, .paused:
            router.shortcutFinish()
        case .finalizing, .uploading, .transcribing, .polishing, .previewing:
            break
        }
    }

    private func handleHoldDown(
        state: SessionState,
        router: any ShortcutSessionRouting
    ) {
        switch state.phase {
        case .idle, .cancelled, .completed, .captured, .failed:
            router.shortcutBegin()
            // `shortcutBegin()` synchronously creates the reducer session before
            // its asynchronous capture acknowledgement. Capturing this ID lets an
            // early release cancel that exact checking session only.
            heldSessionID = router.shortcutSession.id
        case .paused:
            heldSessionID = state.id
            router.shortcutResume()
        case .checking, .recording, .finalizing, .uploading, .transcribing, .polishing, .previewing:
            break
        }
    }
}
