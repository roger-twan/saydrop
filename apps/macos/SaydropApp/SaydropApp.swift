import AppKit
import SwiftUI
import SaydropCore

@main
struct SaydropApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var model = AppModel(isDemo: ProcessInfo.processInfo.arguments.contains("--ui-demo"))
    var body: some Scene {
        let _ = lifecycle.install(model: model)
        Window("Saydrop", id: "main") {
            AppRootView(model: model)
                .onAppear { lifecycle.install(model: model) }
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) { ShowRouteButton(title: "About Saydrop…", route: .about, model: model) }
            CommandGroup(replacing: .appSettings) { ShowRouteButton(title: "Settings…", route: .settings, model: model).keyboardShortcut(",", modifiers: .command) }
            CommandGroup(after: .windowArrangement) {
                ShowRouteButton(title: "History…", route: .history, model: model)
                Button("Show floating bar", action: model.showFloatingBar)
                Button("Local recording check (no upload)…") { model.presentCaptureCheckWindow?() }
                Button("UI state gallery (no recording)…", action: lifecycle.showGallery)
            }
        }
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: { Image(systemName: "waveform").accessibilityLabel("Saydrop，\(model.session.phase.title)") }
        .menuBarExtraStyle(.menu)
    }
}
struct ShowRouteButton: View {
    let title: String
    let route: AppRoute
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(title) { model.route = route; openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
    }
}
struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Text("Saydrop · \(model.session.phase.title)")
        Text(model.isDemo ? "UI demo · Microphone always off" : model.session.microphoneActive ? "Recording" : "Microphone off")
        Divider()
        if model.session.phase == .recording { Button("Finish recording", action: model.finishSession) }
        else if model.session.phase == .paused { Button("Resume recording", action: model.resumeSession) }
        else if model.session.phase.isProcessing { Button("Processing") {}.disabled(true) }
        else { Button(model.isDemo ? "Start UI demo session" : model.localCaptureCheckEnabled ? "Start local recording check" : "Start recording", action: model.beginSession).disabled(!model.canStart) }
        if model.localCaptureCheckEnabled { Text("Local check · No upload or transcription") }
        Button("Show floating bar", action: model.showFloatingBar)
        if model.session.phase.isActive { Button("Cancel session", action: model.closeOrCancelSession) }
        Divider()
        ShowRouteButton(title: "History…", route: .history, model: model)
        ShowRouteButton(title: "Settings…", route: .settings, model: model).keyboardShortcut(",", modifiers: .command)
        ShowRouteButton(title: "About Saydrop…", route: .about, model: model)
        Button("Local recording check (no upload)…") { model.presentCaptureCheckWindow?() }
        Divider()
        if let quota = model.quota { Text("Remaining today: \(quota.remaining) / \(quota.limit)\(model.isDemo ? " (sample)" : "")"); Text("Next reset: \(quota.resetAt)") }
        else { Text("Quota temporarily unavailable") }
        Text("This installation · Asia/Shanghai")
        Divider()
        Button("Quit Saydrop") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
    }
}
struct AppRootView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        MainWindowView(model: model)
            .frame(minWidth: 860, minHeight: 600)
            .tint(SaydropTheme.accent)
            .preferredColorScheme(.light)
            .sheet(isPresented: $model.showOnboarding) { OnboardingView(model: model) }
            .sheet(isPresented: Binding(get: { model.showPrivacy && !model.showOnboarding }, set: { model.showPrivacy = $0 })) { PrivacyExplanationView(model: model) }
            .alert(model.confirmation?.title ?? "Confirm", isPresented: Binding(get: { model.confirmation != nil }, set: { _ in })) {
                Button("Cancel", role: .cancel, action: model.cancelLocalChange)
                Button("Confirm", role: .destructive, action: model.confirmLocalChange)
            } message: { Text(model.confirmation?.message ?? "") }
            .alert("Saydrop", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                Button("Got it", role: .cancel) { model.notice = nil }
            } message: { Text(model.notice ?? "") }
    }
}
