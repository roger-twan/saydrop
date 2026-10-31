import AppKit
import SwiftUI
import SaydropCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if proxy.size.width >= 820 {
                        HStack(alignment: .top, spacing: 20) {
                            recordingAndPermissions
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            localStorageAndCloud
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            recordingAndPermissions
                            localStorageAndCloud
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 1180, alignment: .leading)
            }
            .background(SaydropTheme.background.ignoresSafeArea())
        }
        .navigationTitle("Settings")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(SaydropTheme.ink)
            Text("Make voice input work your way")
                .font(.body)
                .foregroundStyle(SaydropTheme.secondary)
        }
    }

    private var recordingAndPermissions: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionCard(title: "Recording and shortcuts") {
                RecordingAndShortcutContent(model: model)
            }

            SectionCard(title: "Permissions") {
                PermissionsContent(model: model)
            }
        }
    }

    private var localStorageAndCloud: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionCard(title: "Local storage") {
                LocalStorageSettingsContent(model: model, showsClearButton: true)
            }

            SectionCard(title: "Cloud transcription") {
                if let cloud = model.cloud {
                    CloudConnectionView(cloud: cloud, model: model)
                } else {
                    CloudDisclosureContent {
                        model.showPrivacy = true
                    }
                }
            }
        }
    }
}

private struct RecordingAndShortcutContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "Global shortcut") {
                GlobalShortcutRecorder(model: model)
            }

            Divider()

            SettingsRow(label: "Recording mode", alignment: .top) {
                VStack(alignment: .trailing, spacing: 7) {
                    HStack(spacing: 8) {
                        recordingModeButton(.toggle, title: "Toggle")
                        recordingModeButton(.hold, title: "Hold to talk")
                    }
                    Text("Toggle: press once to start, then again to finish")
                        .font(.caption)
                        .foregroundStyle(SaydropTheme.secondary)
                }
            }

            Divider()

            SettingsRow(label: "Input device") {
                Text("System default")
                    .foregroundStyle(SaydropTheme.secondary)
            }

            Divider()

            SettingsRow(label: "Launch at login") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(SaydropTheme.accent)
            }

            InfoNote("Choose the output mode for each session in the floating bar. It is locked when recording ends.")
                .padding(.top, 12)

            InfoNote(model.shortcutStatus)
                .padding(.top, 8)
            Button("Local recording check (no upload)…") { model.presentCaptureCheckWindow?() }
                .buttonStyle(.bordered).disabled(model.isDemo).padding(.top, 12)
        }
    }

    private func recordingModeButton(_ mode: RecordingMode, title: String) -> some View {
        let selected: Bool
        switch (model.settings.recordingMode, mode) {
        case (.toggle, .toggle), (.hold, .hold):
            selected = true
        default:
            selected = false
        }

        return Button(title) {
            model.setRecordingMode(mode)
        }
        .buttonStyle(.bordered)
        .tint(selected ? SaydropTheme.accent : SaydropTheme.secondary)
        .controlSize(.regular)
        .accessibilityLabel("Recording mode: \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(model.session.phase.isActive)
    }
}

private struct PermissionsContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionSettingsRow(
                title: "Microphone",
                detail: "Captures audio only during a session you start or resume.",
                status: model.permissions.microphone,
                primaryActionTitle: microphoneActionTitle,
                primaryAction: microphoneAction,
                settingsAction: { model.openPermissionSettings(.microphone) }
            )

            Divider()

            PermissionSettingsRow(
                title: "Accessibility",
                detail: "Verifies the original input target and inserts when safe. You can still transcribe and copy without it.",
                status: model.permissions.accessibility,
                primaryActionTitle: nil,
                primaryAction: nil,
                settingsAction: { model.openPermissionSettings(.accessibility) }
            )

            Divider()

            PermissionSettingsRow(
                title: "Input Monitoring",
                detail: "Global Esc uses a read-only listener during the current session. You can cancel from the bar without it. Permission is not requested at first launch.",
                status: model.permissions.inputMonitoring,
                primaryActionTitle: model.isDemo ? nil : "Configure global Esc",
                primaryAction: model.isDemo ? nil : { model.requestGlobalEscapePermission() },
                settingsAction: { model.openPermissionSettings(.inputMonitoring) }
            )

            HStack {
                Spacer()
                Button("Check again") {
                    model.refreshPermissions()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var microphoneActionTitle: String? {
        switch model.permissions.microphone {
        case .notDetermined:
            return "Request access"
        case .allowed, .denied, .restricted, .notRequired:
            return nil
        }
    }

    private var microphoneAction: (() -> Void)? {
        switch model.permissions.microphone {
        case .notDetermined:
            return { model.requestMicrophonePermission() }
        case .allowed, .denied, .restricted, .notRequired:
            return nil
        }
    }
}

struct LocalStorageSettingsContent: View {
    @ObservedObject var model: AppModel
    let showsClearButton: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Save audio", isOn: Binding(
                get: { model.settings.saveAudio },
                set: { model.updateSaving(audio: $0, text: nil) }
            ))
            .tint(SaydropTheme.accent)
            .toggleStyle(.switch)

            RetentionSelector(
                title: "Audio retention",
                policy: model.settings.audioRetention,
                onApply: { model.updateRetention($0, forAudio: true) }
            )

            Divider()

            Toggle("Save text history", isOn: Binding(
                get: { model.settings.saveText },
                set: { model.updateSaving(audio: nil, text: $0) }
            ))
            .tint(SaydropTheme.accent)
            .toggleStyle(.switch)

            RetentionSelector(
                title: "Text retention",
                policy: model.settings.textRetention,
                onApply: { model.updateRetention($0, forAudio: false) }
            )

            InfoNote("Turning storage off affects future sessions only. Existing content is not deleted. With audio saving off, a result may remain in memory for up to 60 seconds for playback or feedback.")

            if showsClearButton {
                Button("Clear existing local content…", role: .destructive) {
                    model.requestClearHistory()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct RetentionSelector: View {
    let title: String
    let policy: RetentionPolicy
    let onApply: (RetentionPolicy) -> Void

    @State private var selectedPreset: RetentionPreset = .sevenDays
    @State private var customDays = ""
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .foregroundStyle(SaydropTheme.ink)
                Spacer(minLength: 8)
                Picker(title, selection: $selectedPreset) {
                    ForEach(RetentionPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
            }

            if selectedPreset == .custom {
                HStack(spacing: 8) {
                    TextField("1–3650 days", text: $customDays)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 118)
                        .accessibilityLabel("Custom \(title)")
                    Button("Apply") {
                        applyCustomRetention()
                    }
                    .buttonStyle(.bordered)
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(SaydropTheme.warning)
                }
            } else if let chosenPolicy = selectedPreset.policy {
                HStack(spacing: 8) {
                    Text("Select and apply. Shortening retention shows the impact and asks for confirmation first.")
                        .font(.caption)
                        .foregroundStyle(SaydropTheme.secondary)
                    Spacer(minLength: 0)
                    Button("Apply") {
                        onApply(chosenPolicy)
                    }
                    .buttonStyle(.bordered)
                    .disabled(chosenPolicy == policy)
                }
            }
        }
        .onAppear {
            synchronize(with: policy)
        }
        .onChange(of: policy) { _, newPolicy in
            synchronize(with: newPolicy)
        }
        .onChange(of: selectedPreset) { _, newPreset in
            validationMessage = nil
            if newPreset == .custom, customDays.isEmpty, case .days(let days) = policy {
                customDays = String(days)
            }
        }
    }

    private func synchronize(with policy: RetentionPolicy) {
        selectedPreset = RetentionPreset(presenting: policy)
        if case .days(let days) = policy {
            customDays = String(days)
        } else {
            customDays = ""
        }
        validationMessage = nil
    }

    private func applyCustomRetention() {
        guard let chosenPolicy = RetentionPolicy.custom(customDays) else {
            validationMessage = "Enter a whole number of days from 1 to 3650. Invalid values are not saved."
            return
        }

        validationMessage = nil
        onApply(chosenPolicy)
    }
}

private enum RetentionPreset: String, CaseIterable, Identifiable {
    case oneDay
    case sevenDays
    case thirtyDays
    case forever
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneDay: "1 day"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .forever: "Forever"
        case .custom: "Custom"
        }
    }

    var policy: RetentionPolicy? {
        switch self {
        case .oneDay: .days(1)
        case .sevenDays: .days(7)
        case .thirtyDays: .days(30)
        case .forever: .forever
        case .custom: nil
        }
    }

    init(presenting policy: RetentionPolicy) {
        switch policy {
        case .days(1): self = .oneDay
        case .days(7): self = .sevenDays
        case .days(30): self = .thirtyDays
        case .days: self = .custom
        case .forever: self = .forever
        }
    }
}

struct CloudDisclosureContent: View {
    let showFullPrivacy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Cloud service is not configured", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(SaydropTheme.warning)

            Text("The transcription backend, recognition provider, feedback recipient, and retention policies are not configured. Candidate models and design examples in the documents are not treated as active services.")
                .font(.subheadline)
                .foregroundStyle(SaydropTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Only after configuration and a separate disclosure will audio be sent over HTTPS to the Saydrop backend and then to the selected recognition provider. Turning off local storage does not keep audio on this device.")
                .font(.subheadline)
                .foregroundStyle(SaydropTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("View privacy information") {
                showFullPrivacy()
            }
            .buttonStyle(.link)
        }
    }
}

struct PrivacyExplanationView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                BrandMark(size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cloud processing and privacy")
                        .font(.title2.weight(.semibold))
                    Text("Saydrop does not accept uploads until cloud processing is configured.")
                        .font(.subheadline)
                        .foregroundStyle(SaydropTheme.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let cloud = model.cloud {
                        CloudConnectionView(cloud: cloud, model: model)
                    }
                    privacySection(
                        title: "Current configuration",
                        icon: "gearshape.2",
                        text: "The transcription client is implemented. This page shows the actual connection and disclosure status. Uploads stay disabled when the provider, purpose, or retention policy is missing. Feedback requires its own recipient and policy, even if transcription is connected."
                    )

                    privacySection(
                        title: "Cloud transcription path",
                        icon: "lock.shield",
                        text: "After configuration and your explicit consent, audio is sent over HTTPS to the Saydrop backend and then to the selected recognition provider. Turning off local audio saving changes only local persistent storage. The backend keeps result text in process memory for at most 120 seconds; reading it does not extend that period. The provider's actual data handling and retention policy must be disclosed."
                    )

                    privacySection(
                        title: "Anonymous installation and quota",
                        icon: "person.crop.circle.badge.questionmark",
                        text: "Saydrop does not require an account. It obtains an anonymous credential for this installation and stores it securely on this Mac for quota, abuse prevention, and revocation. Daily quota is per installation, not per person. Saydrop does not use hardware serial numbers or hidden device fingerprints."
                    )

                    privacySection(
                        title: "Local storage",
                        icon: "internaldrive",
                        text: "Audio saving and text history are independent. Turning either off affects future sessions only and does not remove existing local content. With persistent audio saving off, a result may remain in memory for up to 60 seconds for playback or feedback. This is not history storage, and viewing the page does not extend the period."
                    )

                    privacySection(
                        title: "Feedback requires separate consent",
                        icon: "hand.raised",
                        text: "Positive feedback sends only a rating, request ID, and necessary version information when you explicitly submit it; no audio or transcript text is attached. Negative feedback shows the exact text or recording, recipient, purpose, and retention policy and requires separate confirmation each time. Cloud transcription consent does not cover feedback attachments."
                    )
                }
                .padding(24)
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") {
                    model.showPrivacy = false
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(SaydropTheme.accent)
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(SaydropTheme.background)
    }

    private func privacySection(title: String, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(SaydropTheme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(SaydropTheme.ink)
                Text(text)
                    .font(.body)
                    .foregroundStyle(SaydropTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    let alignment: VerticalAlignment
    let content: Content

    init(
        label: String,
        alignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: 16) {
            Text(label)
                .foregroundStyle(SaydropTheme.ink)
            Spacer(minLength: 12)
            content
        }
        .padding(.vertical, 11)
    }
}

struct PermissionStatusBadge: View {
    let status: PermissionStatus

    var body: some View {
        Label(status.title, systemImage: symbolName)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .accessibilityLabel("Permission status: \(status.title)")
    }

    private var symbolName: String {
        switch status {
        case .allowed: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined: "questionmark.circle.fill"
        case .restricted: "exclamationmark.triangle.fill"
        case .notRequired: "minus.circle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .allowed: SaydropTheme.accent
        case .denied: .red
        case .notDetermined, .restricted: SaydropTheme.warning
        case .notRequired: SaydropTheme.secondary
        }
    }
}

private struct PermissionSettingsRow: View {
    let title: String
    let detail: String
    let status: PermissionStatus
    let primaryActionTitle: String?
    let primaryAction: (() -> Void)?
    let settingsAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .foregroundStyle(SaydropTheme.ink)
                Spacer()
                PermissionStatusBadge(status: status)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(SaydropTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if let primaryActionTitle, let primaryAction {
                    Button(primaryActionTitle, action: primaryAction)
                        .buttonStyle(.bordered)
                }
                if let settingsAction {
                    Button("System Settings", action: settingsAction)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
