import SwiftUI
import SaydropCore

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep = 0

    private let steps = [
        ("Local storage", "Choose what stays on this Mac"),
        ("Microphone", "Used only when you start or resume recording"),
        ("Safe insertion", "Accessibility is optional; copying is always available"),
        ("Cloud processing", "Uploads stay disabled until configuration is complete")
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    stepProgress
                    stepContent
                }
                .padding(24)
            }

            Divider()

            footer
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(SaydropTheme.background)
        .sheet(isPresented: $model.showPrivacy) {
            PrivacyExplanationView(model: model)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            BrandMark(size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Saydrop")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(SaydropTheme.ink)
                Text("After this introduction, the app remains ready with the microphone off.")
                    .font(.subheadline)
                    .foregroundStyle(SaydropTheme.secondary)
            }
            Spacer()
        }
        .padding(24)
    }

    private var stepProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Step \(currentStep + 1) of \(steps.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(SaydropTheme.secondary)
                Spacer()
                Text(steps[currentStep].0)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SaydropTheme.accent)
            }
            ProgressView(value: Double(currentStep + 1), total: Double(steps.count))
                .tint(SaydropTheme.accent)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0:
            localStorageStep
        case 1:
            microphoneStep
        case 2:
            accessibilityStep
        default:
            cloudDisclosureStep
        }
    }

    private var localStorageStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            onboardingTitle(
                title: "Choose local storage",
                subtitle: "Audio and text history can be saved independently or turned off. Both default to 7 days; these settings are saved locally right away."
            )

            SectionCard(title: "Local storage") {
                LocalStorageSettingsContent(model: model, showsClearButton: false)
            }

            InfoNote("Turning storage off affects future sessions only. Even with audio saving off, a result may remain in memory for up to 60 seconds for playback or feedback.")
        }
    }

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            onboardingTitle(
                title: "The microphone is used only during an active session",
                subtitle: "Saydrop does not continuously capture audio while idle, paused, uploading, transcribing, or running in the background."
            )

            SectionCard(title: "Microphone permission") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        PermissionStatusBadge(status: model.permissions.microphone)
                        Spacer()
                    }

                    Text("The system permission prompt appears only after you choose Request microphone access. Without permission, recording cannot start; you can change it later in System Settings and check again.")
                        .font(.subheadline)
                        .foregroundStyle(SaydropTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        microphoneRequestButton
                        Button("System Settings") {
                            model.openPermissionSettings(.microphone)
                        }
                        .buttonStyle(.bordered)

                        Button("Check again") {
                            model.refreshPermissions()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var microphoneRequestButton: some View {
        switch model.permissions.microphone {
        case .notDetermined:
            Button("Request microphone access") {
                model.requestMicrophonePermission()
            }
            .buttonStyle(.borderedProminent)
            .tint(SaydropTheme.accent)
        case .allowed, .denied, .restricted, .notRequired:
            EmptyView()
        }
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            onboardingTitle(
                title: "Automatic insertion is optional",
                subtitle: "Accessibility captures the original input target when recording starts and inserts text only if the target can still be verified."
            )

            SectionCard(title: "Accessibility") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        PermissionStatusBadge(status: model.permissions.accessibility)
                        Spacer()
                    }

                    Text("Without Accessibility, you can still transcribe and copy when microphone and network requirements are met. Automatic insertion will be unavailable and will not write into a newly focused app.")
                        .font(.subheadline)
                        .foregroundStyle(SaydropTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Accessibility Settings") {
                            model.openPermissionSettings(.accessibility)
                        }
                        .buttonStyle(.bordered)

                        Button("Check again") {
                            model.refreshPermissions()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            SectionCard(title: "Input Monitoring (when needed)") {
                VStack(alignment: .leading, spacing: 10) {
                    PermissionStatusBadge(status: model.permissions.inputMonitoring)
                    Text("Input Monitoring is not always required. If the global shortcut or Esc listener needs it, Saydrop explains and requests it when that feature is enabled. This introduction does not request it.")
                        .font(.subheadline)
                        .foregroundStyle(SaydropTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var cloudDisclosureStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            onboardingTitle(
                title: "Cloud processing requires completed configuration",
                subtitle: "This step only explains data handling. It does not grant upload consent or make a network request."
            )

            SectionCard(title: "Cloud transcription") {
                CloudDisclosureContent {
                    model.showPrivacy = true
                }
            }

            SectionCard(title: "Feedback requires separate consent") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Submitting positive feedback is a separate action. It sends a rating, request ID, and necessary version details without audio or transcript text. For negative feedback, Saydrop shows the exact text or recording, recipient, purpose, and retention policy and asks for confirmation each time.")
                        .font(.subheadline)
                        .foregroundStyle(SaydropTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The feedback recipient and policy are not configured. Saydrop will not report a submission that did not happen.")
                        .font(.caption)
                        .foregroundStyle(SaydropTheme.warning)
                }
            }

            InfoNote("Completing this introduction only records that you viewed local settings and interface information. Cloud uploads remain disabled until deployment configuration and a separate disclosure are available.")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Set up later") {
                cancelOnboarding()
            }
            .buttonStyle(.bordered)

            Spacer()

            if currentStep > 0 {
                Button("Back") {
                    currentStep -= 1
                }
                .buttonStyle(.bordered)
            }

            if currentStep == steps.count - 1 {
                Button("Finish introduction") {
                    model.completeOnboarding()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(SaydropTheme.accent)
            } else {
                Button("Continue") {
                    currentStep += 1
                }
                .buttonStyle(.borderedProminent)
                .tint(SaydropTheme.accent)
            }
        }
        .padding(20)
    }

    private func onboardingTitle(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SaydropTheme.ink)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(SaydropTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cancelOnboarding() {
        model.showOnboarding = false
        dismiss()
    }
}
