import SwiftUI
import SaydropCore

public struct FeedbackView: View {
    @ObservedObject public var model: AppModel
    public init(model: AppModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Transcription issue feedback").font(.system(size: 22, weight: .semibold))
                    Text("Opening this panel does not upload · Feedback does not use transcription quota").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: model.closeFeedback).keyboardShortcut(.cancelAction)
            }
            Divider()
            if let feedback = model.feedback {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if feedback.state == .editing { editor(feedback.draft) }
                        else if feedback.state == .awaitingConsent { consent(feedback.draft) }
                        else { status(feedback) }
                        if let message = feedback.message { InfoNote(message) }
                        if model.feedbackPolicy == nil {
                            InfoNote("The service endpoint, authentication, and actual retention/deletion policy are not configured. You can review this form and content, but nothing will be uploaded or reported as submitted.")
                        }
                        if model.isDemo { InfoNote("This is a UI demo. History and text are samples, not real recordings or transcripts.") }
                    }.padding(.trailing, 4)
                }
                Divider()
                HStack {
                    Text("Only content actually available for this session is used").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if feedback.state == .editing {
                        Button("Preview upload content", action: model.prepareFeedbackConsent).buttonStyle(.borderedProminent)
                    } else if feedback.state == .awaitingConsent {
                        Button("Back to edit", action: model.returnToFeedbackEditing)
                        Button("Confirm upload", action: model.confirmAndSubmitFeedback).buttonStyle(.borderedProminent)
                    } else if feedback.state == .submissionUnknown {
                        Button("Check original feedback status", action: model.queryFeedbackReceipt).disabled(feedback.receiptID == nil)
                        Button("Back to edit content", action: model.returnToFeedbackEditing)
                    } else if feedback.state == .failed { Button("Review and confirm again", action: model.returnToFeedbackEditing) }
                }
            }
        }.padding(24).frame(width: 620, height: 660).background(SaydropTheme.background).tint(SaydropTheme.accent)
    }
    @ViewBuilder private func editor(_ draft: FeedbackDraft) -> some View {
        SectionCard(title: "Session content") {
            Toggle("Include transcript text", isOn: binding(\.includeText)).disabled(draft.rawText == nil && draft.outputText == nil)
            textMaterial("Raw transcript", draft.rawText)
            textMaterial("Final output", draft.outputText)
            Divider().padding(.vertical, 12)
            Toggle("Include this recording (\(durationText(draft.duration)))", isOn: binding(\.includeAudio)).disabled(draft.audio == nil)
            Text(draft.audio == nil ? "Recording unavailable; no attachment will be recovered or fabricated." : "The recording uses only data still held for this session. No extra copy is saved.").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            if let deadline = draft.audioDeadline {
                Text("Temporary audio clears in \(max(0, Int(deadline - model.now))) seconds. Opening or submitting this panel does not extend the timer.").font(.caption).foregroundStyle(SaydropTheme.accent).padding(.top, 6)
            }
        }
        SectionCard(title: "Issue details") {
            Text("Reason (up to 2,000 characters)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: binding(\.reason)).frame(height: 65).border(Color.primary.opacity(0.1)).disabled(!draft.includeText)
            Text("Corrected text (optional, up to 32,000 characters)").font(.caption).foregroundStyle(.secondary).padding(.top, 12)
            TextEditor(text: binding(\.correctedText)).frame(height: 75).border(Color.primary.opacity(0.1)).disabled(!draft.includeText)
            if draft.reason.count > 2000 || draft.correctedText.count > 32000 { Text("Content exceeds a limit. Shorten it before confirming; it will not be truncated silently.").font(.caption).foregroundStyle(.red) }
            if !draft.includeText { Text("When text is excluded, the raw transcript, output, reason, and corrected text are not sent.").font(.caption).foregroundStyle(.secondary).padding(.top, 6) }
        }
    }
    @ViewBuilder private func consent(_ draft: FeedbackDraft) -> some View {
        Text("Confirm the content to upload").font(.headline)
        InfoNote("A request is sent only after you click Confirm upload. Changing any content or the recipient requires confirmation again.")
        SectionCard(title: "Data to send") {
            LabeledContent("Rating", value: "Negative feedback")
            LabeledContent("Request ID", value: draft.requestID.uuidString).font(.caption).textSelection(.enabled).padding(.vertical, 6)
            LabeledContent("Output mode", value: draft.outputMode.title)
            LabeledContent("Version", value: SaydropDefaults.version).padding(.top, 6)
            if draft.includeAudio, let audio = draft.audio {
                LabeledContent("Audio attachment", value: "\(durationText(draft.duration)) · \(audio.count) bytes WAV").padding(.top, 6)
            } else { Text("No audio attached").foregroundStyle(.secondary).padding(.top, 6) }
            if draft.includeText {
                textMaterial("Raw transcript", draft.rawText); textMaterial("Final output", draft.outputText)
                if !draft.reason.isEmpty { textMaterial("Reason", draft.reason) }
                if !draft.correctedText.isEmpty { textMaterial("Corrected text", draft.correctedText) }
            } else { Text("No transcript text or issue details attached").foregroundStyle(.secondary).padding(.top, 6) }
        }
        SectionCard(title: "Recipient and separate policy") {
            if let policy = model.feedbackPolicy {
                Text("Recipient: \(policy.recipient)"); Text("Address: \(policy.baseURL.absoluteString)").font(.caption).textSelection(.enabled)
                Text("Purpose: \(policy.purpose)").padding(.top, 8)
                Text("Retention policy: \(policy.retention)").padding(.top, 8)
                Text("Deletion/contact: \(policy.deletionContact)").padding(.top, 8)
                Text("Policy version: \(policy.version)").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            } else { Text("The actual recipient, authentication, and policy are not configured. Upload is unavailable.").foregroundStyle(.secondary) }
        }
        InfoNote("Turning off local storage does not prevent cloud feedback you explicitly consent to, but no local copy or upload queue is created. Local deletion does not delete cloud feedback; cancelling an upload may not retract data already sent.")
    }
    @ViewBuilder private func status(_ presentation: FeedbackPresentation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if presentation.state == .uploading { HStack { ProgressView().controlSize(.small); Text("Uploading / Checking receipt").font(.headline) } }
            else if presentation.state == .submitted { Label("Feedback submitted", systemImage: "checkmark.circle.fill").font(.title3).foregroundStyle(SaydropTheme.accent) }
            else if presentation.state == .failed { Label("Submission failed", systemImage: "exclamationmark.circle").font(.title3) }
            else { Label("Submission status unknown", systemImage: "questionmark.circle").font(.title3) }
            if let id = presentation.receiptID { Text("feedbackId：\(id.uuidString)").font(.caption).textSelection(.enabled) }
            Text("This does not change inserted text or call transcription or polishing again.").foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private func textMaterial(_ title: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text ?? "Not saved / Currently unavailable").textSelection(.enabled).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 12)
    }
    private func binding<Value>(_ key: WritableKeyPath<FeedbackDraft, Value>) -> Binding<Value> {
        let fallback = model.feedback!.draft[keyPath: key]
        return Binding(get: { model.feedback?.draft[keyPath: key] ?? fallback }, set: { newValue in model.editFeedback { $0[keyPath: key] = newValue } })
    }
}
