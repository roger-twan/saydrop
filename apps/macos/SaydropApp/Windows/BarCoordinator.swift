import AppKit
import SwiftUI
import Combine

final class SaydropPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor
final class BarCoordinator {
    private let model: AppModel
    private var panel: SaydropPanel?
    init(model: AppModel) { self.model = model }
    func show() { synchronize() }
    func synchronize() {
        guard model.session.isBarVisible else { panel?.orderOut(nil); return }
        let panel = panel ?? makePanel()
        let fitting = panel.contentView?.fittingSize ?? NSSize(width: 650, height: 100)
        let width: CGFloat = model.session.phase == .previewing ? 560 : 650
        let height = max(90, fitting.height)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        // AX location/target-screen resolver is not integrated in this UI slice.
        // Use an honest fixed safe position; never claim a captured caret rectangle.
        let size = NSSize(width: min(width, visible.width - 32), height: min(height, visible.height - 32))
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 32)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
    private func makePanel() -> SaydropPanel {
        let panel = SaydropPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FloatingBarView(model: model))
        self.panel = panel; return panel
    }
    func close() { panel?.orderOut(nil) }
}
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel?
    private var bar: BarCoordinator?
    private var observers: [NSObjectProtocol] = []
    private var cleanupTimer: Timer?
    private var localKeyMonitor: Any?
    private var gallery: NSWindow?
    private var feedbackWindow: NSWindow?
    private var captureWindow: NSWindow?
    private var shortcuts: ShortcutController?
    private var escapeMonitor: GlobalEscapeMonitor?
    private var distributedObservers: [NSObjectProtocol] = []
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func install(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        let coordinator = BarCoordinator(model: model); bar = coordinator
        model.presentFloatingBar = { [weak coordinator] in coordinator?.show() }
        let escape = GlobalEscapeMonitor(model: model); escapeMonitor = escape
        model.syncFloatingBar = { [weak coordinator, weak escape] in coordinator?.synchronize(); escape?.synchronize() }
        if !model.isDemo {
            ShortcutPreferences.install(model: model)
            let shortcuts = ShortcutController(router: model); self.shortcuts = shortcuts
            model.resetShortcutHeld = { [weak shortcuts] in shortcuts?.resetHeld() }
            ShortcutPreferences.synchronize(model: model)
        } else { model.updateShortcutStatus("UI demo does not register a system shortcut") }
        model.presentFeedbackWindow = { [weak self] in self?.showFeedbackWindow() }
        model.closeFeedbackWindow = { [weak self] in self?.feedbackWindow?.orderOut(nil) }
        model.presentCaptureCheckWindow = { [weak self] in self?.showCaptureCheckWindow() }
        model.purgeExpired()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak model] _ in Task { @MainActor in model?.purgeExpired() } }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak model] _ in
            Task { @MainActor in model?.interruptSession(reason: "The system is about to sleep. This session stopped and will not resume after wake.") }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak model] _ in
            Task { @MainActor in model?.purgeExpired(); model?.refreshPermissions() }
        })
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak model] _ in
                Task { @MainActor in model?.interruptSession(reason: "The system session or display became inactive. Capture stopped and will not resume automatically.") }
            })
        }
        // Additional best-effort lock notification; real lock-screen behavior still needs device acceptance.
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak model] _ in
            Task { @MainActor in model?.interruptSession(reason: "The screen was locked. Recording stopped.") }
        })
        // Local dialogs own Esc; the passive global monitor ignores events while this app is active.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard event.keyCode == 53 else { return event }
            guard let model else { return event }
            if model.feedback != nil { model.closeFeedback(); return nil }
            if model.showOnboarding || model.showPrivacy { return event }
            if model.session.isBarVisible { model.closeOrCancelSession(); return nil }
            return event
        }
    }
    private func showCaptureCheckWindow() {
        guard let model else { return }
        if captureWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Saydrop · Local recording check (no upload)"
            window.contentView = NSHostingView(rootView: CaptureCheckView(model: model))
            window.isReleasedWhenClosed = false; window.delegate = self; window.center(); captureWindow = window
        }
        captureWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showFeedbackWindow() {
        guard let model else { return }
        if feedbackWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Saydrop · Transcription feedback"
            window.contentView = NSHostingView(rootView: FeedbackView(model: model).preferredColorScheme(.light))
            window.isReleasedWhenClosed = false; window.delegate = self; window.center(); feedbackWindow = window
        }
        feedbackWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === feedbackWindow { model?.closeFeedback() }
        if let window = notification.object as? NSWindow, window === captureWindow { model?.setLocalCaptureCheckEnabled(false) }
    }
    func showGallery() {
        if gallery == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Saydrop · UI state gallery (no recording)"; window.contentView = NSHostingView(rootView: UIStateGalleryView())
            window.isReleasedWhenClosed = false; window.center(); gallery = window
        }
        gallery?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.interruptSession(reason: "Saydrop is quitting. The session stopped."); model?.closeFeedback(); model?.stopAudio()
        model?.cloud?.shutdown()
        cleanupTimer?.invalidate(); observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        shortcuts?.shutdown(); escapeMonitor?.stop()
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }; bar?.close()
    }
}
