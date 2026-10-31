import SwiftUI
import SaydropCore

struct CloudConnectionView: View {
    @ObservedObject var cloud: CloudCoordinator
    @ObservedObject var model: AppModel
    @State private var confirmAbandon = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(cloud.connected ? "Backend connection and anonymous quota ready" : "Cloud client available; configuration and connection required", systemImage: cloud.connected ? "network" : "exclamationmark.triangle")
                .font(.headline).foregroundStyle(cloud.connected ? SaydropTheme.accent : SaydropTheme.warning)
            Text(cloud.endpointTitle).font(.caption.monospaced()).textSelection(.enabled)
            if cloud.configuration?.baseURL.scheme == "http" {
                Text("HTTP is allowed only for local Debug use. Release and remote backends require HTTPS.").font(.caption).foregroundStyle(SaydropTheme.secondary)
            }
            if let disclosure = cloud.disclosure, disclosure.isConfigured {
                Text("Recipient: \(disclosure.receiver)").font(.subheadline)
                Text("Purpose: \(disclosure.purpose)").font(.subheadline)
                Text(disclosure.retention).font(.caption).foregroundStyle(SaydropTheme.secondary)
                Text("Turning off local storage does not keep audio on this device. Audio is submitted only after recording ends and is not resent automatically. The anonymous credential stays in this Mac's Keychain; no account or provider key is needed in the app.").font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if cloud.accepted {
                    HStack {
                        Button("Refresh connection and quota", action: cloud.connect)
                        Button("Stop new cloud transcription") { model.closeOrCancelSession(); cloud.revokeConsent() }
                    }.buttonStyle(.bordered).disabled(cloud.isBusy || model.session.phase.isActive)
                } else {
                    Button("I have read this; accept and initialize anonymous connection", action: cloud.acceptAndConnect)
                        .buttonStyle(.borderedProminent).disabled(cloud.isBusy || model.session.phase.isActive)
                }
            } else {
                Text("The address is configured, but the actual recognition recipient, purpose, and retention policy still need review. Candidate models are not treated as verified services; uploads and transcription initialization remain disabled.")
                    .font(.subheadline).foregroundStyle(SaydropTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Check health endpoint only", action: cloud.checkHealthOnly).disabled(cloud.isBusy || model.session.phase.isActive)
                Button("View privacy information") { model.showPrivacy = true }
            }.buttonStyle(.bordered)
            if cloud.isBusy { ProgressView().controlSize(.small) }
            if let message = cloud.message { Text(message).font(.caption).fixedSize(horizontal: false, vertical: true) }
            if let pending = cloud.pending {
                Divider()
                Text("Request to check: \(pending.id.uuidString)").font(.caption.monospaced()).textSelection(.enabled)
                Text(pending.locallyCancelled ? "Cancelled locally. Late text will not be recovered or inserted." : "The recording will not be resent. Check the same request first.")
                    .font(.caption).foregroundStyle(SaydropTheme.secondary)
                HStack {
                    Button("Check original request status", action: cloud.inspectOriginalRequest)
                    Button("Request cancellation of original task", action: cloud.cancelOriginalRequest)
                }.buttonStyle(.bordered).disabled(cloud.isBusy || model.session.phase.isActive)
                if cloud.canAbandonPending {
                    Button("Abandon recovery and allow a new session…") { confirmAbandon = true }
                        .buttonStyle(.bordered).disabled(cloud.isBusy || model.session.phase.isActive)
                }
            }
            if let result = cloud.recovered {
                Divider()
                Text("Recovered preview · Not inserted or saved to history").font(.subheadline.weight(.semibold))
                ScrollView { Text(result.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
                HStack {
                    Button("Copy text") { model.copyText(result.text) }
                    Button("Close preview", action: cloud.clearRecoveredResult)
                }.buttonStyle(.bordered)
                Text("The local preview lasts at most 60 seconds. Checking again does not extend it or recover audio.").font(.caption).foregroundStyle(SaydropTheme.secondary)
            }
        }
        .disabled(model.isDemo || model.showOnboarding)
        .confirmationDialog("Abandon recovery of the original request? This does not guarantee cancellation or quota restoration, and a new session may count again.", isPresented: $confirmAbandon, titleVisibility: .visible) {
            Button("Abandon recovery and allow new session", role: .destructive, action: cloud.abandonOriginalRequest)
            Button("Keep original request", role: .cancel) { }
        }
    }
}
