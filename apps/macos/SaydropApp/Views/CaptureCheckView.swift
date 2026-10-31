import SwiftUI
import SaydropCore

struct CaptureCheckView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Local recording and shortcut check", systemImage: "mic.badge.plus").font(.title2.bold())
                InfoNote("This development check records only after you start it. Nothing is uploaded, transcribed, inserted, or saved to history. Audio remains in memory for at most 60 seconds after completion for playback. Closing this window cancels the check and clears temporary audio.")
                Toggle("Enable local check; global shortcut records locally only", isOn: Binding(
                    get: { model.localCaptureCheckEnabled }, set: model.setLocalCaptureCheckEnabled))
                    .toggleStyle(.switch).disabled(model.isDemo)
                HStack {
                    Text("Shortcut: \(model.settings.shortcut)").font(.body.monospaced())
                    Spacer()
                    Text(model.settings.recordingMode == .hold ? "Hold to talk" : "Toggle").foregroundStyle(.secondary)
                }
                Text(model.shortcutStatus).font(.caption).foregroundStyle(.secondary)
                SectionCard(title: "Actual capture status") {
                    HStack(spacing: 14) {
                        Circle().fill(model.session.microphoneActive && !model.isDemo ? SaydropTheme.recording : .gray).frame(width: 10, height: 10)
                        Text(model.currentSessionIsCaptureCheck ? model.session.phase.title : "Ready · Microphone not continuously active")
                        Spacer()
                        Text(durationText(model.elapsed)).monospacedDigit()
                    }.padding(.bottom, 14)
                    LiveInputLevel(level: model.inputLevel, active: model.session.microphoneActive && !model.isDemo)
                        .frame(height: 28).padding(.bottom, 14)
                    HStack {
                        if model.session.phase == .recording {
                            Button("Pause", action: model.pauseSession)
                            Button("Finish check", action: model.finishSession).buttonStyle(.borderedProminent)
                        } else if model.session.phase == .paused {
                            Button(model.isResuming ? "Resuming…" : "Resume", action: model.resumeSession).disabled(model.isResuming)
                            Button("Finish check", action: model.finishSession)
                        } else {
                            Button("Start local recording", action: model.beginSession).buttonStyle(.borderedProminent)
                                .disabled(!model.localCaptureCheckEnabled || !model.canStart)
                        }
                        if model.session.phase.isActive { Button("Cancel", action: model.closeOrCancelSession) }
                    }
                    if let reason = model.startBlockReason, !model.session.phase.isActive {
                        Text(reason).font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                    }
                }
                HStack {
                    Text("Microphone: \(model.permissions.microphone.title)")
                    Spacer()
                    if model.permissions.microphone == .notDetermined { Button("Allow microphone", action: model.requestMicrophonePermission) }
                    Button("System Settings") { model.openPermissionSettings(.microphone) }
                    Button("Check again", action: model.refreshPermissions)
                }.font(.caption)
                HStack {
                    Text(model.globalEscapeAvailable ? "Global Esc enabled (listens only during this session)" : "Global Esc unavailable; cancel from the bar or window")
                    Spacer()
                    Button("Configure Esc permission", action: model.requestGlobalEscapePermission)
                }.font(.caption)
                if let summary = model.captureCheckSummary {
                    SectionCard(title: "Actual WAV check result") {
                        Text("16 kHz · Mono · 16-bit PCM").font(.body)
                        Text(String(format: "%.2f seconds · %d frames · %d bytes", summary.duration, summary.frameCount, summary.bytes)).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                        Text(model.hasTemporaryAudio ? "Temporary audio clears in \(Int(model.temporaryAudioRemaining.rounded(.up))) seconds" : "Temporary audio cleared").font(.caption).padding(.vertical, 10)
                        HStack {
                            Button(model.playingRecordID == model.session.id ? "Stop playback" : "Play this recording", action: model.playTemporaryAudio).disabled(!model.hasTemporaryAudio)
                            Button("Clear temporary audio", action: model.discardCaptureCheckAudio)
                        }
                    }
                }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                Text("This check does not use transcription quota. Local capture does not verify cloud transcription, Accessibility insertion, or encrypted history.").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.frame(minWidth: 640, minHeight: 560).background(SaydropTheme.background)
            .tint(SaydropTheme.accent).preferredColorScheme(.light)
    }
}

/// An input LEVEL meter, not an invented animated waveform or a saved audio trace.
struct LiveInputLevel: View {
    let level: Double
    let active: Bool
    private var value: Double { active && level.isFinite ? min(1, max(0, level * 6)) : 0 }
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<16, id: \.self) { index in
                Capsule().fill(value > Double(index) / 16 ? SaydropTheme.recording : Color.gray.opacity(0.22))
            }
        }.accessibilityLabel(active ? "Actual microphone input level" : "Microphone off")
            .accessibilityValue("\(Int(value * 100))%")
    }
}
