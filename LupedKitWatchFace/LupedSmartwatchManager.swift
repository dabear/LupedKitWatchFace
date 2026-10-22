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
/// forwarded to the watch right away. The watch alarms on its own using the
/// host's glucose alert settings, so it also receives its alert state and mute.
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
    @MainActor var latestAlertState: SmartwatchGlucoseAlertState?
    @MainActor var transportIfStarted: LupedTransport?

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
            await self?.lupedSnapshot()
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
    public func glucoseAlertStateDidUpdate(_ state: SmartwatchGlucoseAlertState) {
        latestAlertState = state
        // The first snapshot sends the alert state with it.
        if latestSnapshot != nil {
            Task { await transport.refresh() }
        }
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
            alerts: LupedAlertState(latestAlertState)
        )
    }

    func logDeviceCommunication(_ message: String, kind: LupedCommunicationLog.Kind) {
        let type: DeviceLogEntryType
        switch kind {
        case .toWatch: type = .send
        case .fromWatch: type = .receive
        case .error: type = .error
        case .info: type = .connection
        }
        smartwatchManagerDelegate?.deviceManager(self, logEventForDeviceIdentifier: settings.watchfaceUUID.uuidString.lowercased(), type: type, message: message, completion: nil)
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
            "* followAlertMute: \(settings.followAlertMute)",
            "* fullScreen: \(settings.fullScreen)",
        ].joined(separator: "\n")
    }
}

private extension LupedAlertState {
    init(_ state: SmartwatchGlucoseAlertState?) {
        self.init(
            configuration: state?.configuration.map { configuration in
                LupedAlertConfiguration(
                    urgentLowMgDL: configuration.urgentLowThreshold,
                    lowMgDL: configuration.lowThreshold,
                    highMgDL: configuration.highThreshold,
                    urgentLowEnabled: configuration.urgentLowEnabled,
                    lowEnabled: configuration.lowEnabled,
                    highEnabled: configuration.highEnabled,
                    urgentLowRepeat: configuration.urgentLowRepeatInterval,
                    lowRepeat: configuration.lowRepeatInterval,
                    highRepeat: configuration.highRepeatInterval
                )
            },
            hostAlertsActive: state?.hostAlertsActive ?? false,
            hostMuteEnd: state?.mutedUntil
        )
    }
}

private extension LupedTrend {
    init(_ trend: GlucoseTrend) {
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
