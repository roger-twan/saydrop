import AppKit
import ApplicationServices
import Carbon
import SaydropCore

struct TextTargetState {
    let element: AnyObject
    let window: AnyObject
    let pid: pid_t
    let name: String
    let value: String
    let range: NSRange
    let secure: Bool
    let writable: Bool
}

@MainActor
protocol TextTargetAccess: AnyObject {
    var trusted: Bool { get }
    func read() -> TextTargetState?
    func replaceSelection(_ text: String, in target: TextTargetState) -> Bool
}

struct AutoInsertionDecision {
    let outcome: InsertionOutcome
    let reason: PreviewReason
    let targetName: String?
}

/// One captured target per session; never synthesizes paste or retries a write.
@MainActor
final class AutoInsertion {
    private let access: any TextTargetAccess
    private var captured: TextTargetState?
    private var reason: PreviewReason = .rangeUnverifiable
    init(access: any TextTargetAccess) { self.access = access }
    convenience init() { self.init(access: AXTextTargetAccess()) }
    func clear() { captured = nil; reason = .rangeUnverifiable }
    func capture() {
        clear()
        guard access.trusted else { reason = .accessibilityUnavailable; return }
        guard let target = access.read() else { return }
        guard !target.secure else { reason = .secureInput; return }
        guard target.writable, validRange(target) else { return }
        captured = target
    }
    private func validRange(_ target: TextTargetState) -> Bool {
        let count = target.value.utf16.count
        guard count <= 131_072, target.range.location >= 0, target.range.length >= 0,
              target.range.location <= count, target.range.length <= count - target.range.location else { return false }
        let value = target.value as NSString
        func boundary(_ offset: Int) -> Bool {
            offset == count || !(0xDC00...0xDFFF).contains(value.character(at: offset))
        }
        return boundary(target.range.location) && boundary(NSMaxRange(target.range))
            && Range(target.range, in: target.value) != nil
    }
    private func sameTarget(_ a: TextTargetState, _ b: TextTargetState) -> Bool {
        a.pid == b.pid && CFEqual(a.element, b.element) && CFEqual(a.window, b.window)
    }
    func insert(_ text: String) -> AutoInsertionDecision {
        let saved = captured
        captured = nil // Consume before any external mutation, even if it fails.
        func decision(_ outcome: InsertionOutcome = .preview, _ why: PreviewReason) -> AutoInsertionDecision {
            AutoInsertionDecision(outcome: outcome, reason: why, targetName: saved?.name)
        }
        guard access.trusted else { return decision(.preview, .accessibilityUnavailable) }
        guard let saved else { return decision(.preview, reason) }
        guard !text.isEmpty, text.utf16.count <= 32_000, let current = access.read() else {
            return decision(.preview, .rangeUnverifiable)
        }
        guard !current.secure else { return decision(.preview, .secureInput) }
        guard sameTarget(saved, current) else { return decision(.preview, .targetChanged) }
        guard current.writable, validRange(current), current.range == saved.range,
              current.value == saved.value else { return decision(.preview, .rangeUnverifiable) }
        let expected = (saved.value as NSString).replacingCharacters(in: saved.range, with: text)
        // Once a write is attempted, failure is ambiguous: never fall back to paste.
        guard access.replaceSelection(text, in: current) else { return decision(.unknown, .insertionUnknown) }
        guard let after = access.read(), sameTarget(saved, after), !after.secure,
              after.value == expected else { return decision(.unknown, .insertionUnknown) }
        return decision(.confirmed, .rangeUnverifiable)
    }
}

@MainActor
final class AXTextTargetAccess: TextTargetAccess {
    var trusted: Bool { AXIsProcessTrusted() }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    func read() -> TextTargetState? {
        guard trusted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        guard let target = element(attribute(application, kAXFocusedUIElementAttribute)),
              let window = element(attribute(target, kAXWindowAttribute)) else { return nil }
        AXUIElementSetMessagingTimeout(target, 0.3)
        var pid: pid_t = 0
        guard AXUIElementGetPid(target, &pid) == .success, pid == app.processIdentifier else { return nil }
        let role = attribute(target, kAXRoleAttribute) as? String
        let secure = IsSecureEventInputEnabled() || (attribute(target, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
        // Do not read value/selection from password or secure-input targets.
        if secure {
            return TextTargetState(element: target, window: window, pid: pid, name: app.localizedName ?? "Original app",
                                   value: "", range: NSRange(location: 0, length: 0), secure: true, writable: false)
        }
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? ""),
              (attribute(target, kAXEnabledAttribute) as? Bool) == true,
              let value = attribute(target, kAXValueAttribute) as? String,
              value.utf16.count <= 131_072,
              let rawRange = attribute(target, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rawRange) == AXValueGetTypeID() else { return nil }
        let axRange = rawRange as! AXValue
        var range = CFRange()
        guard AXValueGetType(axRange) == .cfRange, AXValueGetValue(axRange, .cfRange, &range) else { return nil }
        // Reject multi-selection editors rather than silently replacing one range.
        if let ranges = attribute(target, kAXSelectedTextRangesAttribute) as? [Any], ranges.count != 1 { return nil }
        var settable = DarwinBoolean(false)
        let writable = AXUIElementIsAttributeSettable(target, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
        return TextTargetState(element: target, window: window, pid: pid, name: app.localizedName ?? "Original app", value: value,
                               range: NSRange(location: range.location, length: range.length), secure: false, writable: writable)
    }
    func replaceSelection(_ text: String, in target: TextTargetState) -> Bool {
        guard CFGetTypeID(target.element) == AXUIElementGetTypeID() else { return false }
        let target = target.element as! AXUIElement
        return AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }
}
