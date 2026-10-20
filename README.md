# LupedKitWatchFace

A Loop `WatchManager` plugin that shows Loop's glucose on a Pebble running the
[Luped CGM watchface](https://github.com/dabear/CrimsonBearPebbleWatchFace),
over [elbbepTransport](https://github.com/dabear/elbbepTransport)'s direct
Bluetooth link (no PebbleKit JS, no phone-side Pebble SDK).

It is the first plugin for the `WatchManager` plugin type proposed for
[LoopKit/Loop#2568](https://github.com/LoopKit/Loop/pull/2568). Loop sends the
plugin a `WatchStatusSnapshot` as soon as a new glucose reading is stored,
before the loop runs, and the plugin pushes it to the watch right away. The
watch alarms on its own, so the plugin also receives Loop's glucose alert
settings and alert mute.

## Targets

| Target | What it holds |
|---|---|
| `LupedKitWatchFace` | `LupedWatchManager: WatchManager`. Turns snapshots into LupedKit payloads, keeps Luped's settings in `rawState`, and forwards the watch communication log to Loop's device log. Re-exports `LupedKit`. |
| `LupedKitWatchFaceUI` | `WatchManagerUI` conformance and the Settings → Devices → Pebble screens: status, display, alarms, diagnostics, communication log, watchface UUID. |
| `LupedKitWatchFacePlugin` | The `.loopplugin` principal class and Info.plist keys (`com.loopkit.Loop.WatchManagerIdentifier`). |
| `LupedKitWatchFaceTests` | Unit tests, including the device-log mapping. |

Capabilities: `.glucose`, `.history`, `.alerts`.

## Device log

Every line LupedKit writes to its communication log also goes to
`DeviceManagerDelegate.deviceManager(_:logEventForDeviceIdentifier:type:message:completion:)`,
keyed by the watchface UUID, so it appears in Loop's issue report and critical
event log export:

| LupedKit kind | Device log type |
|---|---|
| `toWatch` | `.send` |
| `fromWatch` | `.receive` |
| `error` | `.error` |
| `info` | `.connection` |

## Building

The plugin needs a LoopKit and Loop that include the `WatchManager` plugin type,
and builds inside a LoopWorkspace. The `watch-manager` branch of
[dabear/LoopWorkspace](https://github.com/dabear/LoopWorkspace/tree/watch-manager)
has everything wired up:

```sh
git clone --branch watch-manager --recurse-submodules https://github.com/dabear/LoopWorkspace.git
cd LoopWorkspace
xed LoopWorkspace.xcworkspace
```

Build the `LoopWorkspace` scheme. To run the plugin's tests:

```sh
xcodebuild test -workspace LoopWorkspace.xcworkspace -scheme LupedKitWatchFace \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

In Loop, add the watch under Settings → Devices → Add Watch → Pebble. The
Pebble must be paired with the Pebble app and running the Luped watchface.
