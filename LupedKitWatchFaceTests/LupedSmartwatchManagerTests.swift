//
//  LupedSmartwatchManagerTests.swift
//  LupedKitWatchFaceTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import LoopKit
@testable import LupedKitWatchFace

@MainActor
final class LupedSmartwatchManagerTests: XCTestCase {
    private let start = Date(timeIntervalSinceNow: -1_800)

    private func sample(_ mgdl: Double, minutes: Double, trend: SmartwatchGlucoseTrend? = .flat, wasUserEntered: Bool = false) -> SmartwatchGlucoseReading {
        SmartwatchGlucoseReading(
            date: start.addingTimeInterval(minutes * 60),
            milligramsPerDeciliter: mgdl,
            trend: trend,
            wasUserEntered: wasUserEntered
        )
    }

    func testRawStateRoundTrips() throws {
        let settings = LupedSettings(isEnabled: true, watchfaceUUID: UUID(), alarmsEnabled: false, fullScreen: true)
        let manager = LupedSmartwatchManager(settings: settings)
        let restored = try XCTUnwrap(LupedSmartwatchManager(rawState: manager.rawState))
        XCTAssertEqual(restored.settings, settings)
    }

    func testSettingsChangesSaveState() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        manager.settings.fullScreen = true
        XCTAssertEqual(delegate.stateUpdates, 1)
        manager.settings.fullScreen = true
        XCTAssertEqual(delegate.stateUpdates, 1, "An unchanged value is not saved again")
    }

    /// Luped's communication log reaches Loop's device log, keyed by the
    /// watchface UUID, with each kind mapped to its device log type.
    func testCommunicationLogReachesDeviceLog() async throws {
        let uuid = UUID()
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, watchfaceUUID: uuid))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        _ = manager.transport

        // The test runner has no background modes, so starting the link warns once.
        XCTAssertFalse(LupedSmartwatchManager.hasBluetoothPeripheralBackgroundMode())
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

    /// Host alert notes and the plugin's own alert lines show in the in-app log.
    /// Host notes are not echoed to the device log, which the host already wrote.
    func testAlertNotesShowInCommunicationLog() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        let log = manager.transport.communicationLog
        log.clear()
        delegate.logEntries.removeAll()

        manager.watchAlertDidIssue(SmartwatchAlert(identifier: SmartwatchAlertIdentifier("glucose.high"), level: .warning, title: "High Glucose", issuedAt: Date()))
        XCTAssertTrue(log.entries.last?.message.hasPrefix("Host alert issued [warning], event 1: High Glucose") == true, log.text)
        XCTAssertEqual(delegate.logEntries.count, 1)

        manager.watchHostDidLog("Next alert: from 11:25 if glucose stays above 10.0 mmol/L")
        XCTAssertEqual(log.entries.last?.message, "\(LupedSmartwatchManager.hostName): Next alert: from 11:25 if glucose stays above 10.0 mmol/L")
        XCTAssertEqual(log.entries.last?.kind, .info)
        XCTAssertEqual(delegate.logEntries.count, 1, "The host already logged its note")
    }

    /// Delete from the settings screen asks the host to remove the manager and
    /// switches the Bluetooth link off.
    func testDeleteRemovesTheManagerAndStopsTheLink() async {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        manager.transportIfStarted = LupedTransport(hostName: LupedSmartwatchManager.hostName, settings: manager.settings)

        let deleted = expectation(description: "delete completes")
        manager.delete { deleted.fulfill() }
        await fulfillment(of: [deleted], timeout: 2)

        XCTAssertEqual(delegate.deletions, 1)
        XCTAssertEqual(manager.transportIfStarted?.settings.isEnabled, false)
    }

    func testSnapshotBecomesLupedSnapshot() throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        XCTAssertNil(manager.lupedSnapshot(), "Nothing to send before the first snapshot")

        let history = [
            sample(100, minutes: 0),
            sample(250, minutes: 2, wasUserEntered: true),
            sample(110, minutes: 5, trend: .upUp),
        ]
        manager.latestSnapshot = SmartwatchStatusSnapshot(displayUnit: .millimolesPerLiter, glucose: history.last, glucoseHistory: history)

        let snapshot = try XCTUnwrap(manager.lupedSnapshot())
        XCTAssertEqual(snapshot.unit, .millimolesPerLiter)
        XCTAssertEqual(snapshot.storedSampleCount, 3)
        XCTAssertEqual(snapshot.readings.map(\.milligramsPerDeciliter), [100, 110], "User-entered samples are not CGM readings")
        XCTAssertEqual(snapshot.readings.last?.trend, .singleUp)
        // Alerts are host-issued: no alert has fired yet.
        XCTAssertEqual(snapshot.hostAlertLevel, 0)
        XCTAssertEqual(snapshot.alertEvent, 0)
    }

    /// Loop status, therapy context and URLs are optional: Luped declares none of
    /// them, ignores therapy a host sends anyway, and handles no URL. It declares
    /// `.remoteMute`, `.bolus` and `.remoteCarbs` for testing the watch's requests.
    func testOptionalHostFeaturesStayOff() throws {
        XCTAssertEqual(LupedSmartwatchManager.capabilities, [.glucose, .history, .alerts, .remoteMute, .bolus, .remoteCarbs])
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        let reading = sample(120, minutes: 5)
        manager.latestSnapshot = SmartwatchStatusSnapshot(displayUnit: .milligramsPerDeciliter, glucose: reading, glucoseHistory: [reading])
        let plain = try XCTUnwrap(manager.lupedSnapshot())
        manager.latestSnapshot = SmartwatchStatusSnapshot(
            displayUnit: .milligramsPerDeciliter, glucose: reading, glucoseHistory: [reading],
            insulinOnBoard: 1.2, carbsOnBoard: 15,
            therapy: SmartwatchTherapyContext(tempBasalRate: 0.4, insulinSensitivity: 45, correctionRange: 100...110, activePresetName: "Exercise")
        )
        let withExtras = try XCTUnwrap(manager.lupedSnapshot())
        XCTAssertEqual(withExtras.readings, plain.readings)
        XCTAssertEqual(withExtras.unit, plain.unit)
        XCTAssertFalse(manager.watchHostDidReceiveURL(URL(string: "trio://smartwatch/callback")!))
    }

    /// A host-issued alert raises the level the watch sees (DATA index 8), the
    /// highest active alert wins, and retracting falls back; each is logged.
    func testHostIssuedAlertSetsLevel() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        XCTAssertEqual(manager.hostAlertLevel, 0)

        manager.watchAlertDidIssue(SmartwatchAlert(identifier: SmartwatchAlertIdentifier("low"), level: .warning, title: "Low Glucose", body: nil, issuedAt: Date()))
        XCTAssertEqual(manager.hostAlertLevel, 2, "Warning maps to level 2")
        XCTAssertTrue(delegate.logEntries.contains { $0.type == .connection && $0.message.contains("Low Glucose") })

        manager.watchAlertDidIssue(SmartwatchAlert(identifier: SmartwatchAlertIdentifier("pump"), level: .critical, title: "Pump", body: nil, issuedAt: Date()))
        XCTAssertEqual(manager.hostAlertLevel, 3, "The highest active alert wins")
        manager.watchAlertDidRetract(SmartwatchAlertIdentifier("pump"))
        XCTAssertEqual(manager.hostAlertLevel, 2, "Falls back to the remaining alert")
        manager.watchAlertDidRetract(SmartwatchAlertIdentifier("low"))
        XCTAssertEqual(manager.hostAlertLevel, 0)
    }

    /// Turning watch alarms off keeps the level at 0 so the watch never buzzes,
    /// whatever the host forwards.
    func testWatchAlarmsOffSuppressesHostAlertLevel() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true, alarmsEnabled: false))
        manager.smartwatchManagerDelegate = MockSmartwatchManagerDelegate()
        manager.watchAlertDidIssue(SmartwatchAlert(identifier: SmartwatchAlertIdentifier("low"), level: .critical, title: nil, body: nil, issuedAt: Date()))
        XCTAssertEqual(manager.hostAlertLevel, 0)
    }

    /// A repeat of an active alert keeps the level but advances the alert event,
    /// which is saved so a relaunch continues from it.
    func testAlertEventAdvancesOnEveryFireAndIsSaved() throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        let urgentLow = SmartwatchAlert(identifier: SmartwatchAlertIdentifier("glucose.urgentLow"), level: .critical, title: "Urgent Low", body: nil, issuedAt: Date())

        manager.watchAlertDidIssue(urgentLow)
        XCTAssertEqual(manager.alertEvent, 1)
        XCTAssertEqual(manager.hostAlertLevel, 3)

        manager.watchAlertDidIssue(urgentLow)  // the host's repeat fire
        XCTAssertEqual(manager.alertEvent, 2)
        XCTAssertEqual(manager.hostAlertLevel, 3, "A repeat doesn't change the level")
        XCTAssertEqual(delegate.stateUpdates, 2, "Each fire saves the new event")

        let restored = try XCTUnwrap(LupedSmartwatchManager(rawState: manager.rawState))
        XCTAssertEqual(restored.alertEvent, 2)
    }

    /// The event advances while watch alarms are off, so turning them back on
    /// doesn't replay an alert the watch was told to ignore.
    func testAlertEventAdvancesWhileWatchAlarmsOff() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true, alarmsEnabled: false))
        manager.smartwatchManagerDelegate = MockSmartwatchManagerDelegate()
        manager.watchAlertDidIssue(SmartwatchAlert(identifier: SmartwatchAlertIdentifier("glucose.low"), level: .warning, title: nil, body: nil, issuedAt: Date()))
        XCTAssertEqual(manager.alertEvent, 1)
        XCTAssertEqual(manager.hostAlertLevel, 0)
    }

    /// The last watch diagnostics report is saved with the state, so the watch
    /// info shows after a relaunch instead of waiting for the next hourly report.
    func testWatchDiagnosticsSurviveRelaunch() throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        let json = "[2,1792957000000,85,1792950000000,1,0,0,0,0,0,0,0,0,12,3]"
        let receivedAt = Date(timeIntervalSince1970: 1_792_957_000)
        manager.transport.diagnosticsDidArrive?(json, receivedAt)
        XCTAssertEqual(delegate.stateUpdates, 1, "A new report saves the state")

        let restored = try XCTUnwrap(LupedSmartwatchManager(rawState: manager.rawState))
        XCTAssertEqual(restored.savedDiagnostics, .init(json: json, receivedAt: receivedAt))
        let shown = try XCTUnwrap(restored.transport.status.diagnostics, "Shown as soon as the link starts")
        XCTAssertEqual(shown.battery, 85)
        XCTAssertEqual(shown.receivedAt, receivedAt)
    }

    func testAlertEventWraps() throws {
        let manager = try XCTUnwrap(LupedSmartwatchManager(rawState: ["alertEvent": LupedSmartwatchManager.alertEventModulus - 1]))
        manager.smartwatchManagerDelegate = MockSmartwatchManagerDelegate()
        manager.watchAlertDidIssue(SmartwatchAlert(identifier: SmartwatchAlertIdentifier("glucose.high"), level: .warning, title: nil, body: nil, issuedAt: Date()))
        XCTAssertEqual(manager.alertEvent, 0)
    }
}

private final class MockSmartwatchManagerDelegate: SmartwatchManagerDelegate {
    var logEntries: [SmartwatchDeviceLogEntry] = []
    var stateUpdates = 0
    var deletions = 0
    var acknowledgedAlerts: [SmartwatchAlertIdentifier] = []

    func smartwatchManagerDidUpdateState(_ manager: SmartwatchManager) { stateUpdates += 1 }
    func smartwatchManagerWantsDeletion(_ manager: SmartwatchManager) async { deletions += 1 }
    func smartwatchManager(_ manager: SmartwatchManager, glucoseSamplesSince start: Date) async throws -> [SmartwatchGlucoseReading] { [] }
    func smartwatchManagerRequestsRefresh(_ manager: SmartwatchManager) {}
    func smartwatchManager(_ manager: SmartwatchManager, didLogEvent event: SmartwatchDeviceLogEntry) { logEntries.append(event) }
    func smartwatchManager(_ manager: SmartwatchManager, didAcknowledgeAlert identifier: SmartwatchAlertIdentifier) async { acknowledgedAlerts.append(identifier) }
    func smartwatchManager(_ manager: SmartwatchManager, requestBolus request: SmartwatchBolusRequest) async throws -> Double { throw SmartwatchBolusError.notAllowed }
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
