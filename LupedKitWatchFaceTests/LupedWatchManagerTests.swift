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

        // The test runner has no background modes, so starting the link warns once.
        XCTAssertFalse(LupedWatchManager.hasBluetoothPeripheralBackgroundMode())
        XCTAssertEqual(delegate.logEntries.map(\.type), [.error])
        XCTAssertTrue(delegate.logEntries.first?.message.contains("bluetooth-peripheral") == true)
        delegate.logEntries.removeAll()

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

    /// Delete from the settings screen asks the host to remove the manager and
    /// switches the Bluetooth link off.
    func testDeleteRemovesTheManagerAndStopsTheLink() async {
        let manager = LupedWatchManager(settings: LupedSettings(isEnabled: true))
        let delegate = MockWatchManagerDelegate()
        manager.watchManagerDelegate = delegate
        manager.transportIfStarted = LupedTransport(hostName: "Loop", settings: manager.settings)

        let deleted = expectation(description: "delete completes")
        manager.delete { deleted.fulfill() }
        await fulfillment(of: [deleted], timeout: 2)

        XCTAssertEqual(delegate.deletions, 1)
        XCTAssertEqual(manager.transportIfStarted?.settings.isEnabled, false)
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
    var deletions = 0

    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        logEntries.append(LogEntry(deviceIdentifier: deviceIdentifier, type: type, message: message))
    }

    func watchManagerDidUpdateState(_ manager: WatchManager) { stateUpdates += 1 }
    func watchManagerWantsDeletion(_ manager: WatchManager) async { deletions += 1 }
    func watchManager(_ manager: WatchManager, glucoseSamplesSince start: Date) async throws -> [StoredGlucoseSample] { [] }
    func watchManagerRequestsRefresh(_ manager: WatchManager) {}
    func watchManager(_ manager: WatchManager, requestBolus request: WatchBolusRequest) async throws -> Double { throw WatchBolusError.notAllowed }

    func issueAlert(_ alert: Alert) async {}
    func retractAlert(identifier: Alert.Identifier) async {}
    func doesIssuedAlertExist(identifier: Alert.Identifier) async throws -> Bool { false }
    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    func recordRetractedAlert(_ alert: Alert, at date: Date) async throws {}
}

final class LupedSetupProgressTests: XCTestCase {
    private let reading = Date(timeIntervalSince1970: 1_800_000_000)

    private func progress(_ link: LupedLinkStatus.Link, delivered: Date? = nil, rejected: Date? = nil, paused: Bool = false) -> LupedSetupProgress {
        LupedSetupProgress(link: link, lastDelivery: delivered.map { (reading, $0) }, lastRejectedAt: rejected, paused: paused)
    }

    func testLinkStatesBeforeAnyReading() {
        XCTAssertEqual(progress(.off), .waitingForWatch)
        XCTAssertEqual(progress(.waitingForWatch), .waitingForWatch)
        XCTAssertEqual(progress(.connecting), .connecting)
        XCTAssertEqual(progress(.bluetoothUnavailable), .bluetoothUnavailable)
    }

    func testConnectedIsNotDoneUntilTheWatchAcknowledgesAReading() {
        XCTAssertEqual(progress(.open), .waitingForReading)
        XCTAssertFalse(progress(.open).isComplete)
        XCTAssertEqual(progress(.open, delivered: reading.addingTimeInterval(5)), .delivered(readingDate: reading))
        XCTAssertTrue(progress(.open, delivered: reading.addingTimeInterval(5)).isComplete)
    }

    func testRejectedOrPausedMeansTheWatchfaceIsNotRunning() {
        XCTAssertEqual(progress(.open, rejected: reading), .watchfaceNotRunning)
        XCTAssertEqual(progress(.open, paused: true), .watchfaceNotRunning)
    }

    func testTheNewestOfDeliveryAndRejectionWins() {
        let early = reading.addingTimeInterval(10)
        let late = reading.addingTimeInterval(20)
        XCTAssertEqual(progress(.open, delivered: late, rejected: early), .delivered(readingDate: reading))
        XCTAssertEqual(progress(.open, delivered: early, rejected: late), .watchfaceNotRunning)
    }

    func testADeliveredReadingStaysDoneAfterTheLinkDrops() {
        XCTAssertEqual(progress(.waitingForWatch, delivered: reading), .delivered(readingDate: reading))
    }
}
