import Foundation
import SwiftUI
import KeyboardShortcuts
import SaydropCore

enum LegacyShortcutDecision: Equatable {
    case preserveTyped, useInitial, rerecord(String)
    static func decide(legacy: String, hasTyped: Bool) -> Self {
        if hasTyped { return .preserveTyped }
        if legacy == SaydropDefaults.shortcut { return .useInitial }
        return .rerecord(legacy)
    }
}

@MainActor
enum ShortcutPreferences {
    /// Call before first access to Name.recordSession so its initial value cannot erase the migration decision.
    static func install(model: AppModel) {
        guard !model.isDemo else { model.updateShortcutStatus("UI demo does not register a system shortcut"); return }
        let existed = KeyboardShortcuts.storedNames.contains { $0.rawValue == "recordSession" }
        let decision = LegacyShortcutDecision.decide(legacy: model.settings.shortcut, hasTyped: existed)
        if case .rerecord(let original) = decision {
            // Preserve the old display for the user; physical-key mapping depends on keyboard layout.
            UserDefaults.standard.set(original, forKey: "Saydrop.shortcut.legacyDisplay")
            KeyboardShortcuts.setShortcut(nil, for: .recordSession)
            model.notice = "Legacy shortcut value detected: \(original). The value was kept, but it cannot be reliably migrated to a physical key. Record a new shortcut in Settings; the default will not be substituted silently."
        }
        synchronize(model: model)
    }
    static func synchronize(model: AppModel) {
        guard !model.isDemo else { return }
        let shortcut = KeyboardShortcuts.getShortcut(for: .recordSession)
        model.setShortcut(shortcut?.description ?? "Not set")
        if shortcut == nil { model.updateShortcutStatus("No shortcut registered. Record one in Settings.") }
        else if KeyboardShortcuts.isEnabled(for: .recordSession) { model.updateShortcutStatus("Global shortcut registered. The recorder checks for system and app menu conflicts.") }
        else { model.updateShortcutStatus("Shortcut is unavailable or being recorded. Check conflicts or record it again.") }
    }
}

struct GlobalShortcutRecorder: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group {
            if model.isDemo {
                Text(model.settings.shortcut).font(.body.monospaced()).foregroundStyle(.secondary)
            } else {
                KeyboardShortcuts.Recorder(for: .recordSession, onChange: { _ in
                    model.resetShortcutHeld?()
                    ShortcutPreferences.synchronize(model: model)
                })
                .disabled(model.session.phase.isActive)
                .accessibilityLabel("Change global recording shortcut")
            }
        }
    }
}
