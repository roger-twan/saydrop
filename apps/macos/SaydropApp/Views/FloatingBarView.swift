import SwiftUI
import SaydropCore

public struct FloatingBarView: View {
    @ObservedObject public var model: AppModel
    public init(model: AppModel) { self.model = model }
    public var body: some View {
        Group {
            if model.session.phase == .previewing, let result = model.session.result {
                SafePreviewView(state: model.session, result: result, model: model)
            } else {
                VStack(spacing: 10) {
                    HStack(spacing: 14) {
                        SessionStatusView(phase: model.session.phase, isDemo: model.isDemo)
                        if [.recording, .paused].contains(model.session.phase) { Text(durationText(model.elapsed)).monospacedDigit().font(.system(size: 13, weight: .medium)) }
                        if model.session.phase == .recording, !model.isDemo {
                            LiveInputLevel(level: model.inputLevel, active: true).frame(width: 68, height: 18)
                        }
                        Spacer(minLength: 4)
                        if !model.currentSessionIsCaptureCheck {
                            ModeSelector(mode: model.session.mode, enabled: model.session.canSelectMode, onSelect: model.chooseMode)
                        }
                        actions
                        Button(action: model.closeOrCancelSession) { Image(systemName: "xmark").frame(width: 22, height: 26) }
                            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.65))
                            .help(model.session.phase.isActive ? "Cancel · Esc" : "Close")
                            .accessibilityLabel(model.session.phase.isActive ? "Cancel current session" : "Close floating bar")
                    }
                    Text(context).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).frame(maxWidth: .infinity, alignment: .leading)
                    if model.isDemo { Text("UI demo · Microphone always off · No upload or insertion").font(.system(size: 10, weight: .medium)).foregroundStyle(SaydropTheme.warning) }
                    if model.currentSessionIsCaptureCheck || model.localCaptureCheckEnabled {
                        Text("Local recording check · No upload, transcription, insertion, or history")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(SaydropTheme.warning)
                    }
                }.padding(.horizontal, 18).padding(.vertical, 15)
                    .frame(width: 650).background(SaydropTheme.panel, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 1))
            }
        }.foregroundStyle(.white).colorScheme(.dark).tint(Color(red: 0.72, green: 0.84, blue: 0.71))
    }
    @ViewBuilder private var actions: some View {
        switch model.session.phase {
        case .idle, .failed, .cancelled:
            Button(model.localCaptureCheckEnabled ? "Start check" : "Start", action: model.beginSession).buttonStyle(.borderedProminent)
                .help(model.startBlockReason ?? "Start a new session")
        case .recording:
            Button { model.pauseSession() } label: { Label("Pause", systemImage: "pause.fill") }.buttonStyle(.plain)
            Button("Finish", action: model.finishSession).buttonStyle(.borderedProminent)
        case .paused:
            Button { model.resumeSession() } label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(.bordered)
                .disabled(model.isResuming)
            Button("Finish", action: model.finishSession).buttonStyle(.borderedProminent)
        case .completed:
            if let text = model.session.result?.outputText { CopyTextButton(text: text, model: model).buttonStyle(.bordered) }
        case .captured:
            Button(model.playingRecordID == model.session.id ? "Stop playback" : "Play", action: model.playTemporaryAudio)
                .buttonStyle(.bordered).disabled(!model.hasTemporaryAudio)
            Button("Check again", action: model.beginSession).buttonStyle(.borderedProminent).disabled(!model.localCaptureCheckEnabled || !model.canStart)
        case .previewing: EmptyView()
        default: Button("Cancel", action: model.closeOrCancelSession).buttonStyle(.bordered)
        }
    }
    private var context: String {
        if let notice = model.notice { return notice }
        if let message = model.session.message { return message }
        switch model.session.phase {
        case .idle: return model.startBlockReason ?? "Microphone off · Press \(model.settings.shortcut) to start"
        case .recording: return "120-second maximum · Esc cancels · Output mode locks when recording ends"
        case .paused: return "Microphone off · Pause time remaining: \(durationText(model.session.pauseRemaining(at: model.now)))"
        case .finalizing: return "Capture stopped · Preparing audio · Output mode locked"
        case .uploading, .transcribing, .polishing: return "Microphone off · No automatic resend · Cancelled dispatched requests may still count"
        case .completed: return "No automatic sending · Esc only closes; it does not remove inserted text"
        case .captured: return model.hasTemporaryAudio ? "Microphone off · Temporary audio clears in \(Int(model.temporaryAudioRemaining.rounded(.up))) seconds" : "Microphone off · Temporary audio cleared"
        default: return "Microphone off"
        }
    }
}
struct SafePreviewView: View {
    let state: SessionState
    let result: SessionResult
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.shield").font(.system(size: 28)).foregroundStyle(SaydropTheme.warning)
                Text((state.previewReason ?? .rangeUnverifiable).title).font(.system(size: 19, weight: .semibold))
                Spacer()
                Label(state.mode.title, systemImage: "lock.fill").font(.caption).foregroundStyle(.white.opacity(0.6))
                Button(action: model.closeOrCancelSession) { Image(systemName: "xmark").frame(width: 24, height: 24) }.buttonStyle(.plain).help("Close preview · Esc")
            }
            Text((state.previewReason ?? .rangeUnverifiable).explanation).font(.system(size: 13)).foregroundStyle(.white.opacity(0.76)).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 10) {
                Text("Transcript").font(.caption).foregroundStyle(.white.opacity(0.55))
                ScrollView { Text(result.outputText).font(.system(size: 19)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 200)
            }
            if result.polishFallback { Text("Light polish was unavailable. The raw transcript was kept.").font(.caption).foregroundStyle(SaydropTheme.warning) }
            Text("Original target: \(result.targetName ?? "Could not capture reliably")").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 10) {
                CopyTextButton(text: result.outputText, model: model).buttonStyle(.borderedProminent)
                Button("Submit positive feedback", action: model.submitCurrentPositiveFeedback).buttonStyle(.bordered)
                Button("Report a transcription issue…", action: model.openCurrentFeedback).buttonStyle(.bordered)
            }.controlSize(.large)
            Text(model.isDemo ? "UI demo · Sample result, no recording, upload, or insertion" : "Copied does not mean inserted · Insertion is not retried automatically")
                .font(.caption).foregroundStyle(model.isDemo ? SaydropTheme.warning : .white.opacity(0.55))
        }.padding(24).frame(width: 560).background(SaydropTheme.panel, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.18), lineWidth: 1))
    }
}
/// Independent presentation catalog. These are labeled snapshots, not running capture/network states.
struct UIStateGalleryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Floating bar · State gallery").font(.title2.bold())
                InfoNote("These are static samples. They do not use the microphone, network, or external input fields. The real recording indicator appears only after capture starts successfully.")
                ForEach([SessionPhase.idle, .recording, .paused, .finalizing, .uploading, .transcribing, .polishing, .completed], id: \.rawValue) { phase in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(phase.title).font(.headline)
                        HStack(spacing: 18) {
                            SessionStatusView(phase: phase, isDemo: true)
                            if [.recording, .paused].contains(phase) { Text("00:18").monospacedDigit() }
                            Spacer()
                            ModeSelector(mode: phase == .polishing ? .lightPolish : .raw, enabled: [.idle, .recording, .paused].contains(phase), onSelect: { _ in })
                            Text(phase == .recording ? "Pause    Finish" : phase == .paused ? "Resume    Finish" : phase.isProcessing ? "Cancel" : phase == .idle ? "Start" : "Copy")
                        }.padding(18).frame(width: 650).background(SaydropTheme.panel, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white).colorScheme(.dark)
                    }
                }
                ForEach([PreviewReason.targetChanged, .accessibilityUnavailable, .secureInput, .rangeUnverifiable, .destinationUnknown, .insertionUnknown], id: \.rawValue) { reason in
                    VStack(alignment: .leading, spacing: 8) { Label(reason.title, systemImage: "exclamationmark.shield").font(.headline); Text(reason.explanation).foregroundStyle(.secondary) }.padding(16).frame(width: 650, alignment: .leading).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(24)
        }.frame(minWidth: 700, minHeight: 600).background(SaydropTheme.background)
    }
}
