//
//  LupedWatchManager+UI.swift
//  LupedKitWatchFaceUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import LoopKit
import LoopKitUI
import LupedKitWatchFace
import SwiftUI
import UIKit

extension LupedWatchManager: WatchManagerUI {
    public static var onboardingImage: UIImage? {
        UIImage(systemName: "watch.analog")
    }

    public var smallImage: UIImage? {
        UIImage(systemName: "watch.analog")
    }

    /// Adding the watch needs no setup: the Pebble app pairs the watch, and the
    /// watchface finds the phone once Loop publishes the Bluetooth service.
    @MainActor
    public static func setupViewController(bluetoothProvider: BluetoothProvider, displayGlucosePreference: DisplayGlucosePreference, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> SetupUIResult<WatchManagerViewController, WatchManagerUI> {
        .createdAndOnboarded(LupedWatchManager())
    }

    @MainActor
    public func settingsViewController(bluetoothProvider: BluetoothProvider, displayGlucosePreference: DisplayGlucosePreference, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> WatchManagerViewController {
        LupedSettingsNavigationController(manager: self)
    }

    public var watchStatusHighlight: DeviceStatusHighlight? { nil }
}

/// Hosts the Pebble settings screens.
final class LupedSettingsNavigationController: UINavigationController, WatchManagerOnboarding, CompletionNotifying {
    weak var watchManagerOnboardingDelegate: WatchManagerOnboardingDelegate?
    weak var completionDelegate: CompletionDelegate?

    init(manager: LupedWatchManager) {
        super.init(nibName: nil, bundle: nil)
        let model = LupedSettingsModel(manager: manager)
        let view = LupedWatchSettingsView(model: model) { [weak self] in
            guard let self else { return }
            self.completionDelegate?.completionNotifyingDidComplete(self)
        }
        setViewControllers([UIHostingController(rootView: view)], animated: false)
        navigationBar.prefersLargeTitles = true
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
