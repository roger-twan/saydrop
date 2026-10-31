import SaydropCore

extension AppModel: ShortcutSessionRouting {
    var shortcutSession: SessionState { session }
    var shortcutRecordingMode: RecordingMode { settings.recordingMode }
    var shortcutInteractionAllowed: Bool { !isDemo && !showOnboarding && !showPrivacy && feedback == nil }
    func shortcutBegin() { beginSession() }
    func shortcutResume() { resumeSession() }
    func shortcutFinish() { finishSession() }
    func shortcutClose() { closeOrCancelSession() }
    func shortcutChanged(display: String) { setShortcut(display) }
}
