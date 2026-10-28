//
//  LupedWatchSettingsView.swift
//  LupedKitWatchFaceUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import LoopKitUI
import LupedKitWatchFace
import SwiftUI

/// Publishes the manager's settings to SwiftUI and saves edits back to it.
@MainActor
final class LupedSettingsModel: ObservableObject {
    let manager: LupedSmartwatchManager
    /// The host's debug builds show test tools, such as sending a test RESULT.
    let allowDebugFeatures: Bool

    @Published var settings: LupedSettings {
        didSet { manager.settings = settings }
    }

    init(manager: LupedSmartwatchManager, allowDebugFeatures: Bool = false) {
        self.manager = manager
        self.allowDebugFeatures = allowDebugFeatures
        settings = manager.settings
    }
}

/// Settings → Devices → Pebble: controls the Pebble watchface transport.
struct LupedWatchSettingsView: View {
    @ObservedObject var model: LupedSettingsModel
    var didFinish: () -> Void
    @State private var confirmingDelete = false

    private var transport: LupedTransport { model.manager.transport }

    var body: some View {
        List {
            LupedLinkStatusSection(transport: transport, status: transport.status)

            Section {
                Toggle(LocalizedString("Full-Screen Ring", comment: "Toggle showing the Pebble glucose ring full screen"), isOn: $model.settings.fullScreen)
            } header: {
                Text(LocalizedString("Display", comment: "Header for the Pebble display settings"))
            } footer: {
                Text(LocalizedString("Show a large glucose ring with the reading time inside it instead of the ring with a trend graph.", comment: "Footer for the Pebble full-screen ring toggle"))
            }

            Section {
                Picker(LocalizedString("Status Line", comment: "Picker choosing what the Pebble status line shows"), selection: $model.settings.statusLine) {
                    ForEach(LupedStatusLine.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
            } footer: {
                Text(String(format: LocalizedString("The black line under the glucose ring. IOB and COB dim when %1$@ hasn't looped for 16 minutes. Not shown with the full-screen ring.", comment: "Footer for the Pebble status line picker (1: app name)"), LupedSmartwatchManager.hostName))
            }

            Section {
                Toggle(LocalizedString("Watch Alarms", comment: "Toggle enabling Pebble watch vibration alarms"), isOn: $model.settings.alarmsEnabled)
            } header: {
                Text(LocalizedString("Alarms", comment: "Header for the Pebble alarm settings"))
            } footer: {
                Text(String(format: LocalizedString("The watch buzzes when %1$@ raises a glucose alert, and again each time %1$@ repeats it. While %1$@'s alerts are muted the watch stays silent too, critical alerts included. Turning Watch Alarms off silences the watch only; %1$@'s own alerts are unaffected.", comment: "Footer for the Pebble alarm settings (1: app name)"), LupedSmartwatchManager.hostName))
            }

            Section {
                NavigationLink(destination: LupedDiagnosticsView(transport: transport, allowDebugFeatures: model.allowDebugFeatures)) {
                    Text(LocalizedString("Diagnostics", comment: "Row opening Pebble diagnostics"))
                }
                NavigationLink(destination: LupedAdvancedSettingsView(model: model)) {
                    Text(LocalizedString("Advanced", comment: "Row opening advanced Pebble settings"))
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Text(LocalizedString("Delete Pebble", comment: "Button removing the Pebble smartwatch"))
                        .foregroundColor(.red)
                }
            } footer: {
                Text(String(format: LocalizedString("%@ sends glucose readings and its glucose alerts to a Pebble watchface over Bluetooth while the watch is paired with the Pebble app.", comment: "Footer explaining the Pebble smartwatch device (1: app name)"), LupedSmartwatchManager.hostName))
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(LocalizedString("Pebble", comment: "Title of the Pebble smartwatch settings screen"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(LocalizedString("Done", comment: "Button closing the Pebble settings"), action: didFinish)
            }
        }
        .confirmationDialog(LocalizedString("Are you sure you want to delete this Pebble?", comment: "Delete Pebble confirmation title"), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(LocalizedString("Delete Pebble", comment: "Button removing the Pebble smartwatch"), role: .destructive) {
                model.manager.delete {
                    DispatchQueue.main.async(execute: didFinish)
                }
            }
        } message: {
            Text(String(format: LocalizedString("%@ stops sending to the watch and removes the Pebble settings. You can add it again under Devices.", comment: "Delete Pebble confirmation message (1: app name)"), LupedSmartwatchManager.hostName))
        }
    }
}

/// Watch info and the communication log, for troubleshooting.
struct LupedDiagnosticsView: View {
    let transport: LupedTransport
    var allowDebugFeatures = false

    /// Test tools for watch requests (Send Test Result). Off by default; set to
    /// true to show them, and only in the host's debug builds.
    static let showsTestTools = false

    /// Sample replies for testing how the watchface shows a request's outcome.
    private static let testResults = ["bolus:ok", "bolus:refused", "forcedbolus:ok", "carbs:ok", "carbs:failed", "mute:ok", "mute:ignored"]

    var body: some View {
        List {
            LupedWatchInfoSection(transport: transport, status: transport.status)

            Section {
                NavigationLink(destination: LupedCommunicationLogView(log: transport.communicationLog)) {
                    Text(LocalizedString("Communication Log", comment: "Row opening the Pebble communication log"))
                }
            } footer: {
                Text(String(format: LocalizedString("Everything %1$@ sends to and receives from the watch since %1$@ started, newest first. The same lines are kept in %1$@'s device log for issue reports.", comment: "Footer for the Pebble log section (1: app name)"), LupedSmartwatchManager.hostName))
            }

            if Self.showsTestTools && allowDebugFeatures {
                Section {
                    Menu(LocalizedString("Send Test Result", comment: "Debug menu sending a sample RESULT to the Pebble watch")) {
                        ForEach(Self.testResults, id: \.self) { result in
                            Button(result) { transport.sendResult(result) }
                        }
                    }
                } header: {
                    Text(LocalizedString("Debug", comment: "Header for the Pebble debug tools"))
                } footer: {
                    Text(LocalizedString("Sends a sample outcome of a watch request (RESULT) so you can see how the watchface shows it. Nothing is requested or delivered.", comment: "Footer for the Pebble test result menu"))
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(LocalizedString("Diagnostics", comment: "Title of the Pebble diagnostics screen"))
    }
}

/// The watchface UUID, which most people never change.
struct LupedAdvancedSettingsView: View {
    @ObservedObject var model: LupedSettingsModel
    @State private var draft = ""

    private var defaultUUID: String { LupedSettings.defaultWatchfaceUUID.uuidString.lowercased() }

    private var draftUUID: UUID? {
        UUID(uuidString: draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var hasUnsavedDraft: Bool {
        draftUUID != model.settings.watchfaceUUID
    }

    var body: some View {
        List {
            Section {
                TextField(defaultUUID, text: $draft)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(save)
                if hasUnsavedDraft {
                    Button(LocalizedString("Save", comment: "Button saving the Pebble watchface UUID"), action: save)
                        .disabled(draftUUID == nil)
                }
                if model.settings.watchfaceUUID != LupedSettings.defaultWatchfaceUUID {
                    Button(LocalizedString("Use Luped CGM", comment: "Button restoring the default Pebble watchface UUID")) {
                        draft = defaultUUID
                        save()
                    }
                }
            } header: {
                Text(LocalizedString("Watchface UUID", comment: "Header for the Pebble watchface UUID"))
            } footer: {
                if draftUUID == nil {
                    Text(String(format: LocalizedString("Enter a UUID such as %@.", comment: "Footer shown for an invalid Pebble watchface UUID (1: example UUID)"), defaultUUID))
                        .foregroundColor(.red)
                } else {
                    Text(LocalizedString("The UUID from the watchface's package.json. The watchface must use Luped's AppMessage keys and must not use PebbleKit JS.", comment: "Footer explaining the Pebble watchface UUID"))
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(LocalizedString("Advanced", comment: "Title of the advanced Pebble settings screen"))
        .onAppear { draft = model.settings.watchfaceUUID.uuidString.lowercased() }
    }

    private func save() {
        guard let uuid = draftUUID else { return }
        model.settings.watchfaceUUID = uuid
        draft = uuid.uuidString.lowercased()
    }
}

/// Whether Loop is connected to the watch and when it last delivered a reading.
struct LupedLinkStatusSection: View {
    let transport: LupedTransport
    @ObservedObject var status: LupedLinkStatus

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private var watchfaceRejected: Bool {
        guard let rejected = status.lastRejectedAt else { return false }
        return rejected > (status.lastDelivery?.deliveredAt ?? .distantPast)
    }

    private var headline: String {
        switch status.link {
        case .off: return LocalizedString("Off", comment: "Pebble link status: disabled")
        case .bluetoothUnavailable: return LocalizedString("Bluetooth unavailable", comment: "Pebble link status: Bluetooth off or unauthorized")
        case .waitingForWatch: return LocalizedString("Waiting for the watch", comment: "Pebble link status: no watch session")
        case .connecting: return LocalizedString("Connecting", comment: "Pebble link status: session handshake in progress")
        case .open:
            if status.paused {
                return LocalizedString("Connected · paused, watchface not running", comment: "Pebble link status: sending paused after repeated rejections")
            }
            return watchfaceRejected
                ? LocalizedString("Connected · watchface not running", comment: "Pebble link status: connected but the watch rejected the reading")
                : LocalizedString("Connected", comment: "Pebble link status: session open")
        }
    }

    private var color: Color {
        switch status.link {
        case .open: return status.paused || watchfaceRejected ? .orange : .green
        case .connecting, .waitingForWatch: return .orange
        case .bluetoothUnavailable: return .red
        case .off: return .secondary
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status.link {
        case .connecting, .waitingForWatch:
            ProgressView()
        case .open where !status.paused && !watchfaceRejected:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .off:
            Image(systemName: "minus.circle").foregroundColor(.secondary)
        default:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(color)
        }
    }

    /// Device card like the CGM and pump settings screens: picture, model and link state.
    private var deviceCard: some View {
        HStack(spacing: 16) {
            Image(uiImage: PebbleArtwork.image)
                .resizable()
                .scaledToFit()
                .frame(height: 76)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(LupedSmartwatchManager.localizedTitle)
                    .font(.title3.bold())
                HStack(spacing: 6) {
                    statusIcon
                    Text(headline)
                        .font(.subheadline)
                        .foregroundColor(status.link == .open && !status.paused && !watchfaceRejected ? .primary : color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 6)
    }

    var body: some View {
        Section {
            deviceCard
            if let delivery = status.lastDelivery {
                LabeledContent(LocalizedString("Last Reading", comment: "Pebble status row: time of the last delivered glucose reading"), value: Self.timeFormatter.string(from: delivery.readingDate))
                LabeledContent(LocalizedString("Delivered", comment: "Pebble status row: when the watch acknowledged the reading"), value: Self.timeFormatter.string(from: delivery.deliveredAt))
                LabeledContent(LocalizedString("Round Trip", comment: "Pebble status row: send to acknowledgement time"), value: String(format: LocalizedString("%d ms", comment: "Pebble round trip in milliseconds (1: milliseconds)"), delivery.milliseconds))
            }
            if let retryAt = status.retryAt {
                LabeledContent(LocalizedString("Next Retry", comment: "Pebble status row: time of the next delivery attempt"), value: Self.timeFormatter.string(from: retryAt))
            }
            Button(LocalizedString("Send Now", comment: "Button pushing the current reading to the Pebble watch")) {
                transport.sendNow()
            }
            .disabled(status.link == .off || status.link == .bluetoothUnavailable)
            if let result = status.lastResult {
                Text(result)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text(LocalizedString("Status", comment: "Header for the Pebble link status section"))
        }
    }
}

/// Battery and counters reported by the watchface.
struct LupedWatchInfoSection: View {
    let transport: LupedTransport
    @ObservedObject var status: LupedLinkStatus

    var body: some View {
        Section {
            if let info = status.diagnostics {
                row(LocalizedString("Battery", comment: "Pebble watch info: battery"), info.battery.map { "\($0)%" })
                row(LocalizedString("Readings received", comment: "Pebble watch info: DATA messages received"), info.readingsReceived.map(String.init))
                row(LocalizedString("Refresh requests", comment: "Pebble watch info: refresh requests sent"), info.refreshRequests.map(String.init))
                row(LocalizedString("Stale data events", comment: "Pebble watch info: stale transitions"), info.staleTransitions.map(String.init))
                row(LocalizedString("Phone disconnects", comment: "Pebble watch info: disconnects and total time"), disconnects(info))
                row(LocalizedString("Counting since", comment: "Pebble watch info: diagnostics window start"), info.countingSince.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) })
                row(LocalizedString("Updated", comment: "Pebble watch info: time the snapshot arrived"), updatedText(info.receivedAt))
            } else {
                Text(LocalizedString("The watch sends its battery and counters about once an hour.", comment: "Shown before the Pebble watch has sent its first diagnostics report"))
                    .foregroundColor(.secondary)
            }
            if let note = status.watchInfoNote {
                Text(note)
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
            Button(LocalizedString("Refresh Watch Info", comment: "Button requesting Pebble watch diagnostics")) {
                transport.requestDiagnostics()
            }
            .disabled(status.link != .open)
        } header: {
            Text(LocalizedString("Watch", comment: "Header for the Pebble watch info section"))
        } footer: {
            Text(String(format: LocalizedString("The watchface reports this about once an hour, and again when you open this screen if it can answer right away. Refresh Watch Info asks now; after %@ reconnects, the watchface restarts for a moment so it can reply. Counters cover at most the last 48 hours.", comment: "Footer for the Pebble watch info section (1: app name)"), LupedSmartwatchManager.hostName))
        }
        .onAppear {
            // Fresh numbers without a tap, but never at the cost of restarting the watchface.
            transport.requestDiagnosticsIfReachable()
        }
    }

    private func updatedText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            : DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            LabeledContent(label, value: value)
        }
    }

    private func disconnects(_ info: LupedWatchDiagnostics) -> String? {
        guard let count = info.phoneDisconnects else { return nil }
        let seconds = info.phoneDisconnectedSeconds ?? 0
        return String(format: LocalizedString("%1$d (%2$d min total)", comment: "Pebble watch info: disconnect count and total minutes"), count, seconds / 60)
    }
}

/// The watch communication log, newest first.
struct LupedCommunicationLogView: View {
    @ObservedObject var log: LupedCommunicationLog

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        List {
            if log.entries.isEmpty {
                Text(LocalizedString("No watch communication yet.", comment: "Shown when the Pebble communication log is empty"))
                    .foregroundColor(.secondary)
            }
            ForEach(log.entries.reversed()) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(for: entry.kind))
                        .foregroundColor(color(for: entry.kind))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.timeFormatter.string(from: entry.date))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                        // First line is the headline; the rest are aligned detail rows.
                        let lines = entry.message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                        Text(lines.first.map(String.init) ?? entry.message)
                            .font(.caption.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        if lines.count > 1 {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(lines[1].split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                                    LupedLogDetailLine(line: String(line))
                                }
                            }
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(LocalizedString("Communication Log", comment: "Title of the Pebble communication log"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                ShareLink(item: log.text)
                    .disabled(log.entries.isEmpty)
                Button(role: .destructive) {
                    log.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(log.entries.isEmpty)
            }
        }
    }

    private func symbol(for kind: LupedCommunicationLog.Kind) -> String {
        switch kind {
        case .toWatch: return "arrow.up.right"
        case .fromWatch: return "arrow.down.left"
        case .info: return "info.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private func color(for kind: LupedCommunicationLog.Kind) -> Color {
        switch kind {
        case .toWatch: return .blue
        case .fromWatch: return .green
        case .info: return .secondary
        case .error: return .red
        }
    }
}

/// One detail line of a log entry. Aligned rows (`  label  value` and
/// `   0:  value  description`) keep their last column in a hanging indent, so a
/// line that wraps on a narrow screen stays in its column instead of running
/// back under the index.
struct LupedLogDetailLine: View {
    let line: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let (lead, last) = Self.columns(line) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    Text(lead)
                    Text(last).padding(.leading, 24)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(lead).fixedSize()
                    Text(last).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text(line)
        }
    }

    private static let gap = try! NSRegularExpression(pattern: "\\S( {2,})(?=\\S)")

    /// Splits at the last gap of two or more spaces between columns; nil for
    /// lines without columns, such as `raw [`.
    static func columns(_ line: String) -> (String, String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = gap.matches(in: line, range: range).last,
              let cut = Range(match.range(at: 1), in: line)?.upperBound
        else {
            return nil
        }
        return (String(line[..<cut]), String(line[cut...]))
    }
}

extension LupedStatusLine {
    /// The name shown in the Status Line picker.
    var title: String {
        switch self {
        case .iobAndCob: LocalizedString("IOB & COB", comment: "Pebble status line choice: insulin and carbs on board")
        case .tempBasal: LocalizedString("Temp Basal", comment: "Pebble status line choice: current temp or scheduled basal rate")
        case .eventualGlucose: LocalizedString("Eventual Glucose", comment: "Pebble status line choice: predicted eventual glucose")
        case .sensitivityAndTarget: LocalizedString("ISF & Target", comment: "Pebble status line choice: insulin sensitivity and correction range")
        }
    }
}
