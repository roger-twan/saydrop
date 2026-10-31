import AppKit
import ApplicationServices
import SaydropCore

/// Session-scoped, passive listener. No event contents are persisted and no keys are injected.
@MainActor
final class GlobalEscapeMonitor {
    private weak var model: AppModel?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var listeningID: UUID?
    private let allowSystemListener: Bool
    init(model: AppModel, allowSystemListener: Bool = true) {
        self.model = model; self.allowSystemListener = allowSystemListener
    }
    static func shouldListen(_ state: SessionState) -> Bool {
        state.id != nil && state.isBarVisible && (state.phase.isActive || [.captured, .completed].contains(state.phase))
    }
    func synchronize() {
        guard allowSystemListener, let model, !model.isDemo, Self.shouldListen(model.session), CGPreflightListenEventAccess() else {
            stop(); model?.updateGlobalEscapeAvailability(false); return
        }
        listeningID = model.session.id
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            model.updateGlobalEscapeAvailability(CGEvent.tapIsEnabled(tap: tap)); return
        }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            // The source is installed on the MAIN run loop, as required for this isolated state.
            MainActor.assumeIsolated {
                let owner = Unmanaged<GlobalEscapeMonitor>.fromOpaque(context).takeUnretainedValue()
                owner.receive(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                options: .listenOnly, eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue,
                callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            listeningID = nil; model.updateGlobalEscapeAvailability(false); return
        }
        tap = newTap; source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        model.updateGlobalEscapeAvailability(CGEvent.tapIsEnabled(tap: newTap))
    }
    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            model?.updateGlobalEscapeAvailability(false)
            // Next synchronization re-checks the live permission before attempting to re-enable.
            return
        }
        guard type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              let model, listeningID == model.session.id, Self.shouldListen(model.session),
              !NSApp.isActive else { return }
        // Never retain the CGEvent or read its unicode payload. Local app dialogs own their Esc.
        model.closeOrCancelSession()
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); CFRunLoopSourceInvalidate(source) }
        tap = nil; source = nil; listeningID = nil
    }
}
