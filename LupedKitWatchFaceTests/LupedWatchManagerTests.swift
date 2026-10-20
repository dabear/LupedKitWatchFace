//
//  LupedWatchManagerTests.swift
//  LupedKitWatchFaceTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import LoopAlgorithm
import LoopKit
@testable import LupedKitWatchFace

@MainActor
final class LupedWatchManagerTests: XCTestCase {
    private let start = Date(timeIntervalSinceNow: -1_800)

    private func sample(_ mgdl: Double, minutes: Double, trend: GlucoseTrend? = .flat, wasUserEntered: Bool = false) -> StoredGlucoseSample {
        StoredGlucoseSample(
            startDate: start.addingTimeInterval(minutes * 60),
            quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl),
            trend: trend,
            wasUserEntered: wasUserEntered
        )
    }

    func testRawStateRoundTrips() throws {
        let settings = LupedSettings(isEnabled: true, watchfaceUUID: UUID(), alarmsEnabled: false, followAlertMute: false, fullScreen: true)
        let manager = LupedWatchManager(settings: settings)
        let restored = try XCTUnwrap(LupedWatchManager(rawState: manager.rawState))
        XCTAssertEqual(restored.settings, settings)
    }

    func testSettingsChangesSaveState() {
        let manager = LupedWatchManager(settings: LupedSettings(isEnabled: false))
        let delegate = MockWatchManagerDelegate()
        manager.watchManagerDelegate = delegate
        manager.settings.fullScreen = true
        XCTAssertEqual(delegate.stateUpdates, 1)
        manager.settings.fullScreen = true
        XCTAssertEqual(delegate.stateUpdates, 1, "An unchanged value is not saved again")
    }

    /// Luped's communication log reaches Loop's device log, keyed by the
    /// watchface UUID, with each kind mapped to its device log type.
    func testCommunicationLogReachesDeviceLog() async throws {
        let uuid = UUID()
        let manager = LupedWatchManager(settings: LupedSettings(isEnabled: false, watchfaceUUID: uuid))
        let delegate = MockWatchManagerDelegate()
        manager.watchManagerDelegate = delegate
        _ = manager.transport

        // A settings change is recorded by LupedTransport itself.
        manager.settings.alarmsEnabled = false
        for _ in 0..<50 where delegate.logEntries.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let entry = try XCTUnwrap(delegate.logEntries.first)
        XCTAssertEqual(entry.deviceIdentifier, uuid.uuidString.lowercased())
        XCTAssertEqual(entry.type, .connection)
        XCTAssertEqual(entry.message, "Watch alarms disabled")

        delegate.logEntries.removeAll()
        manager.logDeviceCommunication("to", kind: .toWatch)
        manager.logDeviceCommunication("from", kind: .fromWatch)
        manager.logDeviceCommunication("error", kind: .error)
        manager.logDeviceCommunication("info", kind: .info)
        XCTAssertEqual(delegate.logEntries.map(\.type), [.send, .receive, .error, .connection])
    }

    func testSnapshotBecomesLupedSnapshot() throws {
        let manager = LupedWatchManager(settings: LupedSettings(isEnabled: false))
        XCTAssertNil(manager.lupedSnapshot(), "Nothing to send before the first snapshot")

        let history = [
            sample(100, minutes: 0),
            sample(250, minutes: 2, wasUserEntered: true),
            sample(110, minutes: 5, trend: .upUp),
        ]
        manager.latestSnapshot = WatchStatusSnapshot(displayUnit: .millimolesPerLiter, glucose: history.last, glucoseHistory: history)
        manager.latestAlertState = WatchGlucoseAlertState(
            configuration: .init(urgentLowThreshold: 55, lowThreshold: 70, highThreshold: 180, urgentLowEnabled: true, lowEnabled: true, highEnabled: false, urgentLowRepeatInterval: 300, lowRepeatInterval: nil, highRepeatInterval: 3_600),
            loopAlertsActive: true,
            mutedUntil: nil
        )

        let snapshot = try XCTUnwrap(manager.lupedSnapshot())
        XCTAssertEqual(snapshot.unit, .millimolesPerLiter)
        XCTAssertEqual(snapshot.storedSampleCount, 3)
        XCTAssertEqual(snapshot.readings.map(\.milligramsPerDeciliter), [100, 110], "User-entered samples are not CGM readings")
        XCTAssertEqual(snapshot.readings.last?.trend, .singleUp)
        XCTAssertEqual(snapshot.alerts.configuration?.lowMgDL, 70)
        XCTAssertNil(snapshot.alerts.configuration?.lowRepeat)
        XCTAssertTrue(snapshot.alerts.hostAlertsActive)
    }
}

private final class MockWatchManagerDelegate: WatchManagerDelegate {
    struct LogEntry {
        let deviceIdentifier: String?
        let type: DeviceLogEntryType
        let message: String
    }

    var logEntries: [LogEntry] = []
    var stateUpdates = 0

    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        logEntries.append(LogEntry(deviceIdentifier: deviceIdentifier, type: type, message: message))
    }

    func watchManagerDidUpdateState(_ manager: WatchManager) { stateUpdates += 1 }
    func watchManagerWantsDeletion(_ manager: WatchManager) async {}
    func watchManager(_ manager: WatchManager, glucoseSamplesSince start: Date) async throws -> [StoredGlucoseSample] { [] }
    func watchManagerRequestsRefresh(_ manager: WatchManager) {}

    func issueAlert(_ alert: Alert) async {}
    func retractAlert(identifier: Alert.Identifier) async {}
    func doesIssuedAlertExist(identifier: Alert.Identifier) async throws -> Bool { false }
    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    func recordRetractedAlert(_ alert: Alert, at date: Date) async throws {}
}
