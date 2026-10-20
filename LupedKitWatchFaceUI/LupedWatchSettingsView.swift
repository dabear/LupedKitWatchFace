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
    let manager: LupedWatchManager

    @Published var settings: LupedSettings {
        didSet { manager.settings = settings }
    }

    init(manager: LupedWatchManager) {
        self.manager = manager
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
                Toggle(LocalizedString("Watch Alarms", comment: "Toggle enabling Pebble watch vibration alarms"), isOn: $model.settings.alarmsEnabled)
                if model.settings.alarmsEnabled {
                    Toggle(LocalizedString("Follow Loop Alert Mute", comment: "Toggle muting Pebble watch alarms while Loop's alerts are muted"), isOn: $model.settings.followAlertMute)
                }
            } header: {
                Text(LocalizedString("Alarms", comment: "Header for the Pebble alarm settings"))
            } footer: {
                Text(LocalizedString("The watch vibrates using the thresholds, on/off switches and repeat intervals from Glucose Alert Settings. Turning Watch Alarms off silences the watch only; Loop's alerts are unaffected. With Follow Loop Alert Mute, the watch stays silent while Loop's alerts are muted and resumes when the mute ends.", comment: "Footer for the Pebble alarm settings"))
            }

            Section {
                NavigationLink(destination: LupedDiagnosticsView(transport: transport)) {
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
                Text(LocalizedString("Loop sends glucose readings and glucose alert settings to a Pebble watchface over Bluetooth while the watch is paired with the Pebble app.", comment: "Footer explaining the Pebble smartwatch device"))
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
            Text(LocalizedString("Loop stops sending to the watch and removes the Pebble settings. You can add it again under Devices.", comment: "Delete Pebble confirmation message"))
        }
    }
}

/// Watch info and the communication log, for troubleshooting.
struct LupedDiagnosticsView: View {
    let transport: LupedTransport

    var body: some View {
        List {
            LupedWatchInfoSection(transport: transport, status: transport.status)

            Section {
                NavigationLink(destination: LupedCommunicationLogView(log: transport.communicationLog)) {
                    Text(LocalizedString("Communication Log", comment: "Row opening the Pebble communication log"))
                }
            } footer: {
                Text(LocalizedString("Everything Loop sends to and receives from the watch since Loop started, newest first. The same lines are kept in Loop's device log for issue reports.", comment: "Footer for the Pebble log section"))
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

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(headline).bold()
            }
            if let delivery = status.lastDelivery {
                Text(String(format: LocalizedString("Last reading %1$@ delivered at %2$@ in %3$d ms", comment: "Pebble status detail (1: reading time, 2: delivery time, 3: round trip)"), Self.timeFormatter.string(from: delivery.readingDate), Self.timeFormatter.string(from: delivery.deliveredAt), delivery.milliseconds))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if let retryAt = status.retryAt {
                Text(String(format: LocalizedString("Next retry at %@", comment: "Pebble status detail (1: retry time)"), Self.timeFormatter.string(from: retryAt)))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Button(LocalizedString("Send Now", comment: "Button pushing the current reading to the Pebble watch")) {
                transport.sendNow()
            }
            .disabled(status.link == .off)
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
                row(LocalizedString("Alarms (urgent low / low / high)", comment: "Pebble watch info: alarm counts"), alarmCounts(info))
                row(LocalizedString("Stale data events", comment: "Pebble watch info: stale transitions"), info.staleTransitions.map(String.init))
                row(LocalizedString("Phone disconnects", comment: "Pebble watch info: disconnects and total time"), disconnects(info))
                row(LocalizedString("Counting since", comment: "Pebble watch info: diagnostics window start"), info.countingSince.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) })
                row(LocalizedString("Updated", comment: "Pebble watch info: time the snapshot arrived"), DateFormatter.localizedString(from: info.receivedAt, dateStyle: .none, timeStyle: .medium))
            } else {
                Text(LocalizedString("No watch info yet.", comment: "Shown before the Pebble watch has sent diagnostics"))
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
            Text(LocalizedString("Reported by the watchface when you tap Refresh Watch Info. After Loop reconnects, the watchface restarts for a moment so it can reply. Counters cover at most the last 48 hours.", comment: "Footer for the Pebble watch info section"))
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            LabeledContent(label, value: value)
        }
    }

    private func alarmCounts(_ info: LupedWatchDiagnostics) -> String? {
        guard let urgentLow = info.urgentLowAlarms, let low = info.lowAlarms, let high = info.highAlarms else { return nil }
        return "\(urgentLow) / \(low) / \(high)"
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
                        Text(entry.message)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(LocalizedString("Communication Log", comment: "Title of the Pebble communication log"))
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
