import AppKit
import SwiftUI
import XCTest
import SaydropCore
@testable import SaydropUI

@MainActor
final class ViewSnapshotTests: XCTestCase {
    func testNativeViewSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["SAYDROP_PREVIEW_DIR"] else {
            throw XCTSkip("\u{9700}\u{8981} SAYDROP_PREVIEW_DIR \u{624D}\u{6267}\u{884C}\u{79BB}\u{5C4F}\u{89C6}\u{56FE}\u{5FEB}\u{7167}；\u{666E}\u{901A}\u{6A21}\u{578B}\u{6D4B}\u{8BD5}\u{4E0D}\u{5199}\u{56FE}\u{7247}。")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let demo = AppModel(isDemo: true)
        try snapshot(MainWindowView(model: demo), size: NSSize(width: 1080, height: 720), to: output.appendingPathComponent("01-history-wide.png"))
        try snapshot(MainWindowView(model: demo), size: NSSize(width: 860, height: 600), to: output.appendingPathComponent("02-history-narrow.png"))
        demo.route = .settings
        try snapshot(MainWindowView(model: demo), size: NSSize(width: 1080, height: 900), to: output.appendingPathComponent("03-settings.png"))
        let empty = AppModel(isDemo: false, defaults: nil, backend: UnconfiguredSessionBackend(), feedbackAPI: UnconfiguredFeedbackAPI(), feedbackPolicy: nil)
        try snapshot(MainWindowView(model: empty), size: NSSize(width: 1080, height: 720), to: output.appendingPathComponent("04-empty.png"))
        try snapshot(FloatingBarView(model: demo), size: NSSize(width: 650, height: 110), to: output.appendingPathComponent("05-floating-idle.png"))
        try snapshot(OnboardingView(model: empty), size: NSSize(width: 660, height: 640), to: output.appendingPathComponent("06-onboarding.png"))
        demo.openFeedback(for: demo.records[0])
        try snapshot(FeedbackView(model: demo), size: NSSize(width: 620, height: 660), to: output.appendingPathComponent("07-feedback-edit.png"))
        demo.prepareFeedbackConsent()
        try snapshot(FeedbackView(model: demo), size: NSSize(width: 620, height: 660), to: output.appendingPathComponent("08-feedback-consent.png"))
        let id = UUID()
        var state = SessionState()
        let result = SessionResult(rawText: "\u{4ECA}\u{5929}\u{4E0B}\u{5348} three \u{70B9}\u{8DDF} Alice \u{5F00}\u{4F1A}", outputText: "\u{4ECA}\u{5929}\u{4E0B}\u{5348} three \u{70B9}\u{8DDF} Alice \u{5F00}\u{4F1A}", targetName: "\u{793A}\u{4F8B} · \u{5907}\u{5FD8}\u{5F55}")
        for event in [SessionEvent.begin(id, 0), .captureStarted(id, 0), .finish(id, 8), .stage(id, .uploading), .stage(id, .transcribing), .result(id, result, .targetChanged)] {
            state = SessionReducer.reduce(state, event).state
        }
        try snapshot(SafePreviewView(state: state, result: result, model: demo).foregroundStyle(.white).colorScheme(.dark), size: NSSize(width: 560, height: 430), to: output.appendingPathComponent("09-safe-preview.png"))
        state = SessionReducer.reduce(state, .insertion(id, .unknown)).state
        try snapshot(SafePreviewView(state: state, result: result, model: demo).foregroundStyle(.white).colorScheme(.dark), size: NSSize(width: 560, height: 430), to: output.appendingPathComponent("10-insertion-unknown.png"))
        try snapshot(CaptureCheckView(model: empty), size: NSSize(width: 680, height: 700), to: output.appendingPathComponent("11-capture-check-idle.png"))
        let configuration = try CloudConfiguration(baseURL: URL(string: "http://127.0.0.1:8000")!, permitsLoopbackHTTP: true)
        let cloud = CloudCoordinator(api: nil, configuration: configuration, disclosure: nil)
        empty.showOnboarding = false
        try snapshot(CloudConnectionView(cloud: cloud, model: empty).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(24).background(SaydropTheme.background), size: NSSize(width: 550, height: 480), to: output.appendingPathComponent("12-cloud-configuration.png"))
    }
    private func snapshot<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.light).tint(SaydropTheme.accent))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let bounds = NSRect(origin: .zero, size: size)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { return XCTFail("\u{89C6}\u{56FE}\u{4F4D}\u{56FE}\u{7F13}\u{5B58}\u{4E0D}\u{53EF}\u{7528}") }
        host.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return XCTFail("PNG \u{7F16}\u{7801}\u{5931}\u{8D25}") }
        XCTAssertGreaterThan(data.count, 1000)
        try data.write(to: url)
        window.close()
    }
}
