//
//  LupedKitWatchFacePlugin.swift
//  LupedKitWatchFacePlugin
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import os.log
import LoopKitUI
import LupedKitWatchFace
import LupedKitWatchFaceUI

class LupedKitWatchFacePlugin: NSObject, SmartwatchManagerUIPlugin {
    private let log = OSLog(subsystem: "org.loopkit.LupedKitWatchFace", category: "LupedKitWatchFacePlugin")

    public var smartwatchManagerType: SmartwatchManagerUI.Type? {
        return LupedWatchManager.self
    }

    override init() {
        super.init()
        os_log("Instantiated", log: log, type: .default)
    }
}
