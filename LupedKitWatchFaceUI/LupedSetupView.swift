//
//  LupedSetupView.swift
//  LupedKitWatchFaceUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import LoopKitUI
import LupedKitWatchFace
import SwiftUI
import UIKit

/// Where to get the Luped CGM watchface.
let lupedWatchfaceStoreURL = URL(string: "https://apps.repebble.com/luped-cgm_d47105a3c7c1489895b067ff")!

/// Adds a Pebble. The Pebble app already pairs the watch, so setup only sets
/// expectations, adds the watch, and confirms that a reading reached it.
final class LupedSetupNavigationController: UINavigationController, SmartwatchManagerOnboarding, CompletionNotifying {
    weak var smartwatchManagerOnboardingDelegate: SmartwatchManagerOnboardingDelegate?
    weak var completionDelegate: CompletionDelegate?

    init() {
        super.init(nibName: nil, bundle: nil)
        let model = LupedSetupModel()
        model.didAdd = { [weak self] manager in
            // The watch manager is onboarded as soon as it exists; the host
            // starts sending it snapshots right away.
            self?.smartwatchManagerOnboardingDelegate?.smartwatchManagerOnboarding(didCreateSmartwatchManager: manager)
            self?.smartwatchManagerOnboardingDelegate?.smartwatchManagerOnboarding(didOnboardSmartwatchManager: manager)
        }
        let view = LupedSetupView(model: model) { [weak self] in
            guard let self else { return }
            self.completionDelegate?.completionNotifyingDidComplete(self)
        }
        setViewControllers([UIHostingController(rootView: view)], animated: false)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class LupedSetupModel: ObservableObject {
    @Published private(set) var manager: LupedWatchManager?
    var didAdd: (LupedWatchManager) -> Void = { _ in }

    func add() {
        guard manager == nil else { return }
        let manager = LupedWatchManager()
        self.manager = manager
        didAdd(manager)
    }
}

struct LupedSetupView: View {
    @ObservedObject var model: LupedSetupModel
    var finish: () -> Void

    var body: some View {
        if let manager = model.manager {
            LupedSetupProgressView(transport: manager.transport, status: manager.transport.status, finish: finish)
        } else {
            LupedSetupIntroView(add: model.add, cancel: finish)
        }
    }
}

/// What Loop sends to the watch, and what the user needs before adding it.
struct LupedSetupIntroView: View {
    var add: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(uiImage: PebbleArtwork.image)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 110)
                            .accessibilityHidden(true)
                        Text(LocalizedString("Loop sends each new glucose reading to your Pebble as soon as it arrives, and the watch vibrates for lows and highs.", comment: "Pebble setup introduction"))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section {
                    LupedChecklistRow(number: 1, text: LocalizedString("Pair your Pebble in the Pebble app.", comment: "Pebble setup checklist: pair the watch"))
                    LupedChecklistRow(number: 2, text: LocalizedString("Install the Luped CGM watchface.", comment: "Pebble setup checklist: install the watchface")) {
                        Link(LocalizedString("Get Luped CGM", comment: "Link to the Luped CGM watchface in the Pebble app store"), destination: lupedWatchfaceStoreURL)
                            .font(.subheadline.weight(.semibold))
                    }
                    LupedChecklistRow(number: 3, text: LocalizedString("Make Luped CGM your watchface.", comment: "Pebble setup checklist: select the watchface"))
                } header: {
                    Text(LocalizedString("Before You Start", comment: "Header for the Pebble setup checklist"))
                } footer: {
                    Text(LocalizedString("There is nothing to pair in Loop: the watch finds Loop over the Pebble app's Bluetooth connection.", comment: "Footer for the Pebble setup checklist"))
                }

                Section {
                    EmptyView()
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedString("Watch alarms use the thresholds from Loop's Glucose Alert Settings. You can turn them off for the watch alone later.", comment: "Pebble setup note about watch alarms"))
                        if !LupedWatchManager.hasBluetoothPeripheralBackgroundMode() {
                            Text(LocalizedString("This build of Loop updates the watch only while Loop is open. Build with LOOP_BLUETOOTH_PERIPHERAL_BACKGROUND_MODE = YES to update it in the background.", comment: "Pebble setup warning when the app lacks the bluetooth-peripheral background mode"))
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            .insetGroupedListStyle()

            Button(LocalizedString("Add Pebble", comment: "Button adding the Pebble watch"), action: add)
                .buttonStyle(ActionButtonStyle())
                .padding()
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(LocalizedString("Pebble", comment: "Title of the Pebble setup screen"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(LocalizedString("Cancel", comment: "Button cancelling Pebble setup"), action: cancel)
            }
        }
    }
}

struct LupedChecklistRow<Accessory: View>: View {
    var number: Int
    var text: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                accessory()
            }
        } icon: {
            Image(systemName: "\(number).circle")
                .foregroundColor(.accentColor)
        }
    }
}

extension LupedChecklistRow where Accessory == EmptyView {
    init(number: Int, text: String) {
        self.init(number: number, text: text) { EmptyView() }
    }
}

/// Live progress after the watch is added, until the watch confirms a reading.
struct LupedSetupProgressView: View {
    let transport: LupedTransport
    @ObservedObject var status: LupedLinkStatus
    var finish: () -> Void

    private var progress: LupedSetupProgress { LupedSetupProgress(status) }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    VStack(spacing: 12) {
                        icon
                            .font(.system(size: 56, weight: .light))
                            .frame(height: 64)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(detail)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }

                Section {
                    LupedStepRow(done: true, text: LocalizedString("Loop is ready for the watch", comment: "Pebble setup step: Bluetooth service published"))
                    LupedStepRow(done: watchConnected, text: LocalizedString("Watch connected", comment: "Pebble setup step: watch connected"))
                    LupedStepRow(done: progress.isComplete, text: LocalizedString("Reading shown on the watch", comment: "Pebble setup step: reading delivered"))
                }

                if progress == .waitingForReading || progress == .watchfaceNotRunning {
                    Section {
                        Button(LocalizedString("Send Now", comment: "Button pushing the current reading to the Pebble watch"), action: transport.sendNow)
                        if progress == .watchfaceNotRunning {
                            Link(destination: lupedWatchfaceStoreURL) {
                                Label(LocalizedString("Get Luped CGM", comment: "Link to the Luped CGM watchface in the Pebble app store"), systemImage: "arrow.down.app")
                            }
                        }
                    } footer: {
                        if let result = status.lastResult {
                            Text(result)
                        }
                    }
                }
            }
            .insetGroupedListStyle()

            VStack(spacing: 8) {
                Button(LocalizedString("Done", comment: "Button finishing Pebble setup"), action: finish)
                    .buttonStyle(ActionButtonStyle(progress.isComplete ? .primary : .secondary))
                if !progress.isComplete {
                    Text(LocalizedString("You can finish now. Loop keeps connecting in the background, and Settings → Devices → Pebble shows the status.", comment: "Note below the Done button while Pebble setup is still in progress"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(LocalizedString("Pebble", comment: "Title of the Pebble setup screen"))
        .navigationBarBackButtonHidden(true)
        .animation(.default, value: progress)
    }

    private var watchConnected: Bool {
        status.link == .open || progress.isComplete
    }

    @ViewBuilder
    private var icon: some View {
        switch progress {
        case .delivered:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .bluetoothUnavailable, .watchfaceNotRunning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .waitingForWatch, .connecting, .waitingForReading:
            ProgressView().controlSize(.large)
        }
    }

    private var title: String {
        switch progress {
        case .bluetoothUnavailable:
            return LocalizedString("Bluetooth Is Off", comment: "Pebble setup title: Bluetooth unavailable")
        case .waitingForWatch:
            return LocalizedString("Waiting for Your Pebble", comment: "Pebble setup title: waiting for the watch")
        case .connecting:
            return LocalizedString("Connecting", comment: "Pebble setup title: connecting")
        case .waitingForReading:
            return LocalizedString("Connected", comment: "Pebble setup title: connected, no reading yet")
        case .watchfaceNotRunning:
            return LocalizedString("Open Luped CGM on Your Watch", comment: "Pebble setup title: watchface not running")
        case .delivered:
            return LocalizedString("Your Pebble Is Set Up", comment: "Pebble setup title: done")
        }
    }

    private var detail: String {
        switch progress {
        case .bluetoothUnavailable:
            return LocalizedString("Turn on Bluetooth and allow Loop to use it in the Settings app.", comment: "Pebble setup detail: Bluetooth unavailable")
        case .waitingForWatch:
            return LocalizedString("Keep the watch nearby with the Pebble app running. The watch finds Loop by itself; this can take a minute.", comment: "Pebble setup detail: waiting for the watch")
        case .connecting:
            return LocalizedString("The watch found Loop.", comment: "Pebble setup detail: connecting")
        case .waitingForReading:
            return LocalizedString("Loop sends the next glucose reading as soon as it arrives. Tap Send Now to send the latest one.", comment: "Pebble setup detail: connected, no reading yet")
        case .watchfaceNotRunning:
            return LocalizedString("The watch is connected, but Luped CGM isn't the active watchface, so it can't show readings. Select it on the watch; Loop tries again by itself.", comment: "Pebble setup detail: watchface not running")
        case .delivered(let readingDate):
            return String(format: LocalizedString("The reading from %@ is on your watch. New readings appear as soon as Loop receives them.", comment: "Pebble setup detail: done (1: reading time)"), Self.timeFormatter.string(from: readingDate))
        }
    }
}

struct LupedStepRow: View {
    var done: Bool
    var text: String

    var body: some View {
        Label {
            Text(text)
                .foregroundColor(done ? .primary : .secondary)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundColor(done ? .green : .secondary)
        }
        .accessibilityValue(done ? LocalizedString("Done", comment: "Accessibility value for a completed Pebble setup step") : LocalizedString("Not yet", comment: "Accessibility value for a pending Pebble setup step"))
    }
}
