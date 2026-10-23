//
//  LupedSmartwatchManager.swift
//  LupedKitWatchFace
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

@_exported import LupedKit
import Foundation
import LoopKit

/// Shows the host app's glucose on a Pebble running the Luped watchface, over
/// LupedKit's direct Bluetooth link.
///
/// The host sends a snapshot as soon as a new reading is stored; it is
/// forwarded to the watch right away. Alerts are host-issued: the host
/// evaluates its own alerts and forwards them, rather than the watch evaluating
/// thresholds itself.
public final class LupedSmartwatchManager: SmartwatchManager {
    public static let pluginIdentifier = "LupedSmartwatchManager"

    /// The host app's name, for status and log messages.
    public static var hostName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Loop"
    }
    public static let localizedTitle = LocalizedString("Pebble", comment: "Title of the Luped Pebble watch manager")

    public static var capabilities: SmartwatchCapabilities { [.glucose, .history, .alerts] }

    public var pluginIdentifier: String { Self.pluginIdentifier }
    public var localizedTitle: String { Self.localizedTitle }

    public weak var smartwatchManagerDelegate: SmartwatchManagerDelegate?

    public var delegateQueue: DispatchQueue! {
        get { lockedDelegateQueue.value }
        set { lockedDelegateQueue.value = newValue ?? .main }
    }
    private let lockedDelegateQueue = Locked<DispatchQueue>(.main)

    /// Luped's settings, saved in `rawState`. Changes apply to the watch link.
    public var settings: LupedSettings {
        get { lockedSettings.value }
        set {
            guard newValue != lockedSettings.value else { return }
            lockedSettings.value = newValue
            Task { @MainActor in
                self.transportIfStarted?.settings = newValue
            }
            smartwatchManagerDelegate?.smartwatchManagerDidUpdateState(self)
        }
    }
    private let lockedSettings: Locked<LupedSettings>

    @MainActor var latestSnapshot: SmartwatchStatusSnapshot?
    @MainActor var transportIfStarted: LupedTransport?

    /// Host-issued alerts currently showing, by identifier. The watch buzzes on
    /// the highest level; the plugin does not evaluate thresholds itself.
    @MainActor var activeAlerts: [SmartwatchAlertIdentifier: SmartwatchAlert] = [:]

    /// When this manager started tracking alerts. Alerts the host issued before
    /// then (for example before a relaunch) are only known once it issues them again.
    private let alertTrackingStarted = Date()

    /// The level the watch sees (DATA index 8): 0 none, 1 info, 2 warning, 3 critical.
    /// Zero while the user has turned watch alarms off, so the watch never buzzes.
    /// Host alert mute is followed on the host side (muted alerts aren't forwarded).
    @MainActor var hostAlertLevel: Int {
        guard settings.alarmsEnabled else { return 0 }
        return activeAlerts.values.map(\.level.watchLevel).max() ?? 0
    }

    /// Why `hostAlertLevel` is what it is, for the communication log.
    @MainActor var hostAlertReason: String {
        guard settings.alarmsEnabled else {
            return "Watch Alarms is turned off"
        }
        guard !activeAlerts.isEmpty else {
            let since = DateFormatter.localizedString(from: alertTrackingStarted, dateStyle: .none, timeStyle: .short)
            return "no active alerts from \(Self.hostName) since \(since); muted alerts aren't sent"
        }
        return activeAlerts.values
            .sorted { $0.level.watchLevel > $1.level.watchLevel }
            .map { $0.title ?? $0.identifier.value }
            .joined(separator: ", ")
    }

    public init(settings: LupedSettings = LupedSettings(isEnabled: true)) {
        lockedSettings = Locked(settings)
    }

    public init?(rawState: RawStateValue) {
        lockedSettings = Locked(LupedSettings(rawValue: rawState["settings"] as? LupedSettings.RawValue ?? [:]))
    }

    public var rawState: RawStateValue {
        ["settings": settings.rawValue]
    }

    public var isOnboarded: Bool { true }
    public var inSignalLoss: Bool { false }
    public var isInoperable: Bool { false }

    /// The watch link, started on first use.
    @MainActor
    public var transport: LupedTransport {
        if let transportIfStarted {
            return transportIfStarted
        }
        let transport = LupedTransport(hostName: Self.hostName, settings: settings)
        transport.diagnosticLog = { [weak self] kind, message in
            self?.logDeviceCommunication(message, kind: kind)
        }
        transport.snapshotProvider = { [weak self] in
            self?.lupedSnapshot()
        }
        transportIfStarted = transport
        transport.start()
        if !Self.hasBluetoothPeripheralBackgroundMode() {
            logDeviceCommunication("\(Self.hostName) was built without the bluetooth-peripheral background mode: the watch only updates while \(Self.hostName) is in the foreground", kind: .error)
        }
        return transport
    }

    /// Whether the app may keep the watch's Bluetooth service running in the background.
    public static func hasBluetoothPeripheralBackgroundMode(in bundle: Bundle = .main) -> Bool {
        (bundle.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("bluetooth-peripheral") == true
    }

    @MainActor
    public func watchDataDidUpdate(_ snapshot: SmartwatchStatusSnapshot) {
        latestSnapshot = snapshot
        Task { await transport.refresh() }
    }

    @MainActor
    public func watchAlertDidIssue(_ alert: SmartwatchAlert) {
        activeAlerts[alert.identifier] = alert
        logDeviceCommunication("Host alert issued [\(alert.level)]: \(alert.title ?? "") \(alert.body ?? "")", kind: .info)
        // Resend the snapshot so the watch sees the new alert level and buzzes.
        Task { await transport.refresh() }
    }

    @MainActor
    public func watchAlertDidRetract(_ identifier: SmartwatchAlertIdentifier) {
        guard activeAlerts.removeValue(forKey: identifier) != nil else { return }
        logDeviceCommunication("Host alert retracted: \(identifier.value)", kind: .info)
        Task { await transport.refresh() }
    }

    public func delete(completion: @escaping () -> Void) {
        Task { @MainActor in
            // Removes the Bluetooth service and stops retries.
            transportIfStarted?.settings.isEnabled = false
            notifyDelegateOfDeletion(completion: completion)
        }
    }

    @MainActor
    func lupedSnapshot() -> LupedSnapshot? {
        guard let snapshot = latestSnapshot else {
            return nil
        }
        let start = Date(timeIntervalSinceNow: -LupedPayload.historyInterval)
        let samples = snapshot.glucoseHistory.filter { $0.date >= start }
        let readings = samples
            .filter { !$0.wasUserEntered && !$0.isDisplayOnly }
            .map { sample in
                LupedReading(
                    date: sample.date,
                    milligramsPerDeciliter: sample.milligramsPerDeciliter,
                    trend: sample.trend.map(LupedTrend.init)
                )
            }
        return LupedSnapshot(
            readings: readings,
            storedSampleCount: samples.count,
            unit: snapshot.displayUnit == .millimolesPerLiter ? .millimolesPerLiter : .milligramsPerDeciliter,
            // Thresholds no longer travel to the watch; alerts are host-issued.
            hostAlertLevel: hostAlertLevel,
            hostAlertReason: hostAlertReason
        )
    }

    func logDeviceCommunication(_ message: String, kind: LupedCommunicationLog.Kind) {
        let type: SmartwatchDeviceLogEntry.EntryType
        switch kind {
        case .toWatch: type = .send
        case .fromWatch: type = .receive
        case .error: type = .error
        case .info: type = .connection
        }
        smartwatchManagerDelegate?.smartwatchManager(self, didLogEvent: SmartwatchDeviceLogEntry(type: type, message: message, deviceIdentifier: settings.watchfaceUUID.uuidString.lowercased()))
    }
}

// MARK: - CustomDebugStringConvertible

extension LupedSmartwatchManager {
    public var debugDescription: String {
        let settings = settings
        return [
            "## LupedSmartwatchManager",
            "* enabled: \(settings.isEnabled)",
            "* watchfaceUUID: \(settings.watchfaceUUID.uuidString.lowercased())",
            "* alarmsEnabled: \(settings.alarmsEnabled)",
            "* fullScreen: \(settings.fullScreen)",
        ].joined(separator: "\n")
    }
}

// MARK: - DeviceManager

// Loop places the watch under Settings → Devices and routes its logs and alert
// responses through the DeviceManager machinery. This conformance is kept out of
// the core SmartwatchManager protocol so the plugin also builds for hosts (such
// as Trio) that import it statically without a device seam.
extension LupedSmartwatchManager: DeviceManager {
    // Watches don't issue LoopKit alerts. Both AlertResponder forms are defaulted
    // so the plugin builds against LoopKit variants that declare either one.
    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier) async throws {}
    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) { completion(nil) }
    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }
}

private extension SmartwatchAlertLevel {
    /// Luped DATA index 8 value: 1 info, 2 warning, 3 critical.
    var watchLevel: Int {
        switch self {
        case .informational: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }
}

private extension LupedTrend {
    init(_ trend: SmartwatchGlucoseTrend) {
        switch trend {
        case .downDownDown: self = .doubleDown
        case .downDown: self = .singleDown
        case .down: self = .fortyFiveDown
        case .flat: self = .flat
        case .up: self = .fortyFiveUp
        case .upUp: self = .singleUp
        case .upUpUp: self = .doubleUp
        }
    }
}
