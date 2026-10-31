import Foundation
import SwiftUI
import SaydropCore

/// Root app view: three columns on wide windows; history and details appear in steps on narrow windows.
struct MainWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                MainSidebar(model: model)
                    .frame(width: sidebarWidth(for: proxy.size.width))

                Divider()

                VStack(spacing: 0) {
                    if model.isDemo {
                        DemoModeBanner()
                    }

                    destination(isWideWindow: proxy.size.width >= 980)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(SaydropTheme.background)
    }

    @ViewBuilder
    private func destination(isWideWindow: Bool) -> some View {
        switch model.route {
        case .history:
            HistoryBrowserView(model: model, usesWideLayout: isWideWindow)
        case .settings:
            SettingsView(model: model)
        case .about:
            AboutView(model: model)
        }
    }

    private func sidebarWidth(for windowWidth: CGFloat) -> CGFloat {
        windowWidth < 920 ? 188 : 220
    }
}

/// History browser: list and details side by side when space allows, or sequentially on narrow windows.
struct HistoryBrowserView: View {
    @ObservedObject var model: AppModel

    private let usesWideLayout: Bool
    @State private var isShowingNarrowDetail = false

    init(model: AppModel, usesWideLayout: Bool = true) {
        self.model = model
        self.usesWideLayout = usesWideLayout
    }

    var body: some View {
        Group {
            if usesWideLayout {
                HStack(spacing: 0) {
                    historyList
                        .frame(minWidth: 300, idealWidth: 350, maxWidth: 390)

                    Divider()

                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if isShowingNarrowDetail, let record = selectedFilteredRecord {
                narrowDetail(for: record)
            } else {
                historyList
            }
        }
        .onChange(of: model.selectedRecordID) { _, _ in
            guard !usesWideLayout, selectedFilteredRecord != nil else { return }
            isShowingNarrowDetail = true
        }
        .onChange(of: model.searchText) { _, _ in
            if selectedFilteredRecord == nil {
                isShowingNarrowDetail = false
            }
        }
        .onChange(of: usesWideLayout) { _, isWideLayout in
            if isWideLayout {
                isShowingNarrowDetail = false
            }
        }
    }

    private var historyList: some View {
        HistoryListView(model: model) {
            guard !usesWideLayout else { return }
            isShowingNarrowDetail = selectedFilteredRecord != nil
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let record = selectedFilteredRecord {
            HistoryDetailView(record: record, model: model)
        } else {
            HistoryDetailPlaceholder()
        }
    }

    private func narrowDetail(for record: HistoryRecord) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    isShowingNarrowDetail = false
                } label: {
                    Label("Back to history", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(SaydropTheme.accent)
                .accessibilityHint("Return to the history list")

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)

            Divider()

            HistoryDetailView(record: record, model: model)
        }
    }

    private var selectedFilteredRecord: HistoryRecord? {
        guard let selectedRecordID = model.selectedRecordID else { return nil }
        return model.filteredRecords.first { $0.id == selectedRecordID }
    }
}

/// Shows only content actually saved for one record; no reinsertion or repolishing action.
struct HistoryDetailView: View {
    let record: HistoryRecord
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                insertionStatus

                SectionCard(title: "Transcript") {
                    if let text = visibleText {
                        Text(text)
                            .font(.system(size: 21, weight: .regular))
                            .foregroundStyle(SaydropTheme.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Transcript: \(text)")
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Audio recording · No text saved")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(SaydropTheme.ink)
                            Text("This record contains audio and metadata only. Transcript text was not saved.")
                                .foregroundStyle(SaydropTheme.secondary)
                        }
                    }
                }

                if record.hasAudio {
                    SectionCard(title: "Recording") {
                        AudioPlaybackView(record: record, model: model)
                    }
                }

                SectionCard(title: "Local retention") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(retentionMessages.enumerated()), id: \.offset) { _, message in
                            Text(message)
                                .foregroundStyle(SaydropTheme.secondary)
                        }
                        InfoNote("Viewing, copying, and playing back do not extend retention.")
                    }
                }

                SectionCard(title: "Feedback") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Feedback uses only content still available in this record. It will not transcribe, polish, or insert again.")
                            .foregroundStyle(SaydropTheme.secondary)

                        HStack(spacing: 10) {
                            Button {
                                model.submitPositiveFeedback(for: record)
                            } label: {
                                Label("Submit positive feedback", systemImage: "hand.thumbsup")
                            }

                            Button {
                                model.openFeedback(for: record)
                            } label: {
                                Label("Report an issue…", systemImage: "bubble.left")
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(SaydropTheme.background)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcript details")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(SaydropTheme.ink)

                HStack(spacing: 7) {
                    Text(HistoryPresentation.detailDate.string(from: record.createdAt))
                    Text("·")
                    ModeBadge(mode: record.outputMode)
                }
                .font(.system(size: 13))
                .foregroundStyle(SaydropTheme.secondary)
            }

            Spacer(minLength: 8)

            if let text = visibleText {
                CopyTextButton(text: text, model: model)
            }

            Menu {
                Button(role: .destructive) {
                    model.requestDelete(record)
                } label: {
                    Label("Delete this record…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .frame(minWidth: 32, minHeight: 30)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("More actions")
        }
    }

    @ViewBuilder
    private var insertionStatus: some View {
        switch record.insertionOutcome {
        case .confirmed:
            statusPanel(
                title: "Inserted at the original input",
                detail: targetDescription(prefix: "Target at recording start"),
                symbol: "checkmark.circle.fill",
                tint: SaydropTheme.accent
            )
        case .preview:
            statusPanel(
                title: "Not inserted automatically",
                detail: "Copy and choose the input location manually. \(targetDescription(prefix: "Original input target"))",
                symbol: "exclamationmark.triangle.fill",
                tint: SaydropTheme.warning
            )
        case .unknown:
            statusPanel(
                title: "Insertion status unknown",
                detail: "Check the original input before pasting again. \(targetDescription(prefix: "Original input target"))",
                symbol: "questionmark.circle.fill",
                tint: SaydropTheme.warning
            )
        }
    }

    private func statusPanel(title: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SaydropTheme.ink)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(SaydropTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var visibleText: String? {
        if let outputText = record.outputText, !outputText.isEmpty {
            return outputText
        }
        if let rawText = record.rawText, !rawText.isEmpty {
            return rawText
        }
        return nil
    }

    private var retentionMessages: [String] {
        var messages: [String] = []

        if visibleText != nil {
            messages.append(expirationMessage(for: record.textExpiresAt, content: "Text"))
        }
        if record.hasAudio {
            messages.append(expirationMessage(for: record.audioExpiresAt, content: "Audio"))
        }
        if messages.isEmpty {
            messages.append("Only necessary metadata remains for this record.")
        }

        return messages
    }

    private func expirationMessage(for date: Date?, content: String) -> String {
        guard let date else { return "\(content) saved indefinitely" }
        return "\(content) retained until \(HistoryPresentation.expirationDate.string(from: date))"
    }

    private func targetDescription(prefix: String) -> String {
        guard let targetName = record.targetName, !targetName.isEmpty else { return "" }
        return "\(prefix)：\(targetName)"
    }
}

/// About page describes configured local behavior and safety boundaries without claiming untested uploads work.
struct AboutView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 14) {
                    BrandMark(size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Saydrop")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(SaydropTheme.ink)
                        Text("Voice input for macOS with safety first")
                            .foregroundStyle(SaydropTheme.secondary)
                    }
                }

                SectionCard(title: "How it works") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The microphone is off while idle and captures audio only during a session you start or resume.")
                        Text("Saydrop inserts the result only when the original input target remains verifiably safe. Otherwise it offers a preview and manual copy.")
                    }
                    .foregroundStyle(SaydropTheme.secondary)
                }

                SectionCard(title: "Local history and feedback") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Audio and text history follow separate local storage settings. Viewing, copying, playback, and feedback do not extend expiration.")
                        Text("Turning off local audio saving does not prevent audio from leaving the device for cloud transcription. Temporary audio used for feedback remains subject to its time limit.")
                        Text("Positive and issue feedback are separate actions and submit only available content that you explicitly choose.")
                    }
                    .foregroundStyle(SaydropTheme.secondary)
                }

                SectionCard(title: "Cloud processing") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recipients, authentication, and retention policies for transcription and feedback depend on deployment configuration and integration testing. An unconfigured interface does not mean an upload succeeded.")
                        Text("Saydrop does not require an account. Quota is counted per installation, not per person.")
                    }
                    .foregroundStyle(SaydropTheme.secondary)
                }

                HStack(spacing: 12) {
                    Button("View privacy information") {
                        model.showPrivacy = true
                    }

                    Button("Show floating bar") {
                        model.showFloatingBar()
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(28)
        }
        .background(SaydropTheme.background)
    }
}

private struct MainSidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BrandMark(size: 33)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Saydrop")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(SaydropTheme.ink)
                    Text("App window")
                        .font(.system(size: 12))
                        .foregroundStyle(SaydropTheme.secondary)
                }
            }
            .padding(.bottom, 14)

            SidebarNavigationItem(
                title: "History",
                systemImage: "doc.text",
                isSelected: isHistorySelected
            ) {
                model.route = .history
            }

            SidebarNavigationItem(
                title: "Settings",
                systemImage: "gearshape",
                isSelected: isSettingsSelected
            ) {
                model.route = .settings
            }

            SidebarNavigationItem(
                title: "About",
                systemImage: "info.circle",
                isSelected: isAboutSelected
            ) {
                model.route = .about
            }

            Spacer(minLength: 18)

            Divider()
                .padding(.vertical, 6)

            QuotaView(quota: model.quota, isDemo: model.isDemo)

            Text("Return to the input field and press \(model.settings.shortcut) to start.")
                .font(.system(size: 12))
                .foregroundStyle(SaydropTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var isHistorySelected: Bool {
        if case .history = model.route { return true }
        return false
    }

    private var isSettingsSelected: Bool {
        if case .settings = model.route { return true }
        return false
    }

    private var isAboutSelected: Bool {
        if case .about = model.route { return true }
        return false
    }
}

private struct SidebarNavigationItem: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? SaydropTheme.ink : SaydropTheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(
                    isSelected ? SaydropTheme.selection : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DemoModeBanner: View {
    var body: some View {
        Label("Demo mode: content is for display only. Recording and uploads are disabled.", systemImage: "info.circle")
            .font(.system(size: 13))
            .foregroundStyle(SaydropTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(SaydropTheme.selection.opacity(0.75))
            .accessibilityElement(children: .combine)
    }
}

private struct HistoryListView: View {
    @ObservedObject var model: AppModel
    let onSelect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("History")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(SaydropTheme.ink)

                Spacer()

                searchField
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            if dayGroups.isEmpty {
                HistoryEmptyState(
                    title: emptyTitle,
                    detail: emptyDetail,
                    systemImage: emptySystemImage
                )
            } else {
                List(selection: $model.selectedRecordID) {
                    ForEach(dayGroups) { group in
                        Section {
                            ForEach(group.records) { record in
                                HistoryRecordRow(record: record)
                                    .tag(record.id)
                            }
                        } header: {
                            Text(HistoryPresentation.groupTitle(for: group.day))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SaydropTheme.secondary)
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.inset)
                .accessibilityLabel("History list")
            }
        }
        .background(SaydropTheme.background)
        .onChange(of: model.selectedRecordID) { _, selectedRecordID in
            if selectedRecordID != nil {
                onSelect()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SaydropTheme.secondary)

            TextField("Search saved local text", text: $model.searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search saved local text")

            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SaydropTheme.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: 235)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SaydropTheme.selection, lineWidth: 1)
        }
    }

    private var dayGroups: [HistoryDayGroup] {
        let calendar = Calendar.autoupdatingCurrent
        let sortedRecords = model.filteredRecords.sorted { $0.createdAt > $1.createdAt }
        let recordsByDay = Dictionary(grouping: sortedRecords) {
            calendar.startOfDay(for: $0.createdAt)
        }

        return recordsByDay.keys
            .sorted(by: >)
            .map { day in
                HistoryDayGroup(day: day, records: recordsByDay[day] ?? [])
            }
    }

    private var emptyTitle: String {
        if model.records.isEmpty, !model.hasHistoryEnabled {
            return "Local history is off"
        }
        if !model.searchText.isEmpty {
            return "No matching local text"
        }
        return "No records yet"
    }

    private var emptyDetail: String {
        if model.records.isEmpty, !model.hasHistoryEnabled {
            return "You can still preview and copy this session's result."
        }
        if !model.searchText.isEmpty {
            return "Search covers saved local text only."
        }
        return "Return to the input field and press \(model.settings.shortcut) to start."
    }

    private var emptySystemImage: String {
        model.records.isEmpty && !model.hasHistoryEnabled ? "archivebox" : "doc.text"
    }
}

private struct HistoryRecordRow: View {
    let record: HistoryRecord

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: record.hasAudio ? "waveform" : "doc.text")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(SaydropTheme.accent)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 6) {
                Text(summary)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SaydropTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text(HistoryPresentation.time.string(from: record.createdAt))
                    Text("·")
                    Text(HistoryPresentation.duration(record.duration))
                    ModeBadge(mode: record.outputMode)
                }
                .font(.system(size: 12))
                .foregroundStyle(SaydropTheme.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary), \(HistoryPresentation.time.string(from: record.createdAt)), duration \(HistoryPresentation.duration(record.duration)), \(record.outputMode.title)")
    }

    private var summary: String {
        guard record.rawText != nil || record.outputText != nil else {
            return "Audio recording · No text saved"
        }
        if !record.summary.isEmpty {
            return record.summary
        }
        return record.outputText ?? record.rawText ?? "Audio recording · No text saved"
    }
}

private struct HistoryDetailPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(SaydropTheme.secondary)
            Text("Select a history record")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SaydropTheme.ink)
            Text("View the transcript, retention details, and feedback actions here.")
                .font(.system(size: 13))
                .foregroundStyle(SaydropTheme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryEmptyState: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundStyle(SaydropTheme.secondary)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SaydropTheme.ink)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(SaydropTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryDayGroup: Identifiable {
    let day: Date
    let records: [HistoryRecord]

    var id: Date { day }
}

private enum HistoryPresentation {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let detailDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    static let expirationDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MMM d, yyyy HH:mm"
        return formatter
    }()

    static func groupTitle(for day: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(day) {
            return "Today"
        }
        if calendar.isDateInYesterday(day) {
            return "Yesterday"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: day)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
