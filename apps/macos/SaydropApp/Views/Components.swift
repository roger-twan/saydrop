import AppKit
import SwiftUI
import SaydropCore

public enum SaydropTheme {
    public static let background = Color(red: 245/255, green: 245/255, blue: 242/255)
    public static let ink = Color(red: 36/255, green: 42/255, blue: 41/255)
    public static let selection = Color(red: 221/255, green: 232/255, blue: 224/255)
    public static let accent = Color(red: 49/255, green: 92/255, blue: 72/255)
    public static let secondary = Color.secondary
    public static let panel = Color(red: 36/255, green: 42/255, blue: 41/255)
    public static let recording = Color(red: 96/255, green: 226/255, blue: 148/255)
    public static let warning = Color(red: 235/255, green: 186/255, blue: 78/255)
}
public struct BrandMark: View {
    public var size: CGFloat = 28
    public init(size: CGFloat = 28) { self.size = size }
    public var body: some View { Image(systemName: "waveform").font(.system(size: size, weight: .semibold)).foregroundStyle(SaydropTheme.accent).accessibilityHidden(true) }
}
public struct SectionCard<Content: View>: View {
    let title: String
    let content: Content
    public init(title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}
public struct InfoNote: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}
public struct ModeBadge: View {
    public let mode: OutputMode
    public init(mode: OutputMode) { self.mode = mode }
    public var body: some View {
        Text(mode.title).font(.system(size: 11, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(SaydropTheme.selection.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(SaydropTheme.ink)
    }
}
public struct QuotaView: View {
    public let quota: Quota?
    public let isDemo: Bool
    public init(quota: Quota?, isDemo: Bool) { self.quota = quota; self.isDemo = isDemo }
    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let quota {
                Text("Remaining today: \(quota.remaining) / \(quota.limit)").font(.system(size: 13, weight: .medium))
                Text(isDemo ? "Design sample · Not real quota" : "This installation").font(.caption).foregroundStyle(.secondary)
                Text("Next reset: \(resetDescription(quota.resetAt))").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Quota temporarily unavailable").font(.system(size: 13, weight: .medium))
                Text("This installation · No local count used").font(.caption).foregroundStyle(.secondary)
            }
            Text(SaydropDefaults.quotaTimeZone).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
    private func resetDescription(_ string: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: string) else { return string }
        let display = DateFormatter(); display.dateFormat = "MMM d, HH:mm"; display.timeZone = TimeZone(identifier: SaydropDefaults.quotaTimeZone)
        return display.string(from: date)
    }
}
public struct CopyTextButton: View {
    public let text: String
    @ObservedObject public var model: AppModel
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?
    public init(text: String, model: AppModel) { self.text = text; self.model = model }
    public var body: some View {
        Button {
            guard model.copyText(text) else { model.notice = "Copy failed. Try again."; return }
            copied = true; resetTask?.cancel()
            resetTask = Task { try? await Task.sleep(for: .seconds(1.8)); if !Task.isCancelled { copied = false } }
        } label: { Label(copied ? "Copied" : "Copy text", systemImage: copied ? "checkmark" : "doc.on.doc") }
        .help("Copies text only; it does not mean the original target was changed")
        .onDisappear { resetTask?.cancel() }
        .onChange(of: text) { _, _ in copied = false; resetTask?.cancel() }
    }
}
public struct AudioPlaybackView: View {
    public let record: HistoryRecord
    @ObservedObject public var model: AppModel
    public init(record: HistoryRecord, model: AppModel) { self.record = record; self.model = model }
    public var body: some View {
        HStack(spacing: 14) {
            Button { model.playAudio(record) } label: {
                Image(systemName: model.playingRecordID == record.id ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 36)
            }.buttonStyle(.borderedProminent).tint(SaydropTheme.accent).disabled(!record.hasAudio)
                .accessibilityLabel(model.playingRecordID == record.id ? "Stop playback" : "Play recording")
            VStack(alignment: .leading, spacing: 6) {
                Text(record.hasAudio ? "This recording" : "Recording unavailable").font(.system(size: 13, weight: .medium))
                ProgressView(value: model.playingRecordID == record.id ? model.playbackTime : 0, total: max(1, record.duration))
                    .accessibilityLabel("Playback progress")
            }
            Text("\(durationText(model.playingRecordID == record.id ? model.playbackTime : 0)) / \(durationText(record.duration))")
                .monospacedDigit().font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}
public func durationText(_ time: TimeInterval) -> String {
    let seconds = max(0, Int(time)); return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
struct SessionStatusView: View {
    let phase: SessionPhase
    let isDemo: Bool
    var body: some View {
        HStack(spacing: 8) {
            if phase.isProcessing { ProgressView().controlSize(.small).tint(.white) }
            else { Circle().fill(phase == .recording ? SaydropTheme.recording : phase == .paused ? SaydropTheme.warning : .gray).frame(width: 9, height: 9) }
            Text(phase.title + (isDemo && phase == .recording ? " (simulated)" : "")).font(.system(size: 13, weight: .semibold))
        }.accessibilityElement(children: .combine)
    }
}
struct ModeSelector: View {
    let mode: OutputMode
    let enabled: Bool
    let onSelect: (OutputMode) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(OutputMode.allCases) { item in
                Button { onSelect(item) } label: {
                    HStack(spacing: 4) { Text(item.title); if !enabled && item == mode { Image(systemName: "lock.fill").font(.caption2) } }
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(mode == item ? Color.white.opacity(0.14) : .clear, in: Capsule())
                }.buttonStyle(.plain).disabled(!enabled)
                    .accessibilityLabel(item.title + (item == mode ? ", selected" : "") + (!enabled ? ", mode locked for this session" : ""))
            }
        }.padding(3).background(Color.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}
