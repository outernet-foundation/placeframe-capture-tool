# Placeframe Capture Tool

The capture tool for [Placeframe](https://github.com/outernet-foundation/placeframe): a Unity Android app for capturing and submitting map data to a Placeframe backend, and for validating reconstructed localization maps by localizing against them.

With this application, you can log in to your Placeframe backend, capture data of your environment (we recommend walking the perimeter of the environment with camera facing inwards), submit that data to the backend for localization map reconstruction, and finally validate that map by localizing against it. A few moments after starting relocalization, you will see a point cloud in your environment, tracking your environment.

**NOTE:** In this application, relocalization runs at a higher frequency than is ideal for real applications. Placeframe defers to the device's native world tracking for high-precision, low-latency localization, only intervening to correct drift against its canonical reference frame, by filtering out low-confidence and low-novelty relocalization results. However, this filtering is currently fairly primitive — more sophisticated tools for controlling this behavior will ship in a future release.

## Getting the App

Stable builds of the APK are available on the [releases page](https://github.com/outernet-foundation/placeframe-capture-tool/releases/latest). Per-commit development builds are appended to the `dev-builds` draft release.

You will need an ARCore-compatible Android phone, and a Placeframe backend deployment to point the app at (see the Placeframe repo's Quick Start).

## Building from Source

Requirements:

- [uv](https://docs.astral.sh/uv/getting-started/installation/)
- Unity 6000.0.66f1, with Android build support
- An Android phone attached to your machine via `adb`

To build the APK and install it on the attached phone, run from the repo root:

```
uv run install --build --project CaptureTool
```

For a build-only sanity check:

```
uv run build-unity --project CaptureTool --platform AndroidMobile
```

# Acknowledgements

Built in association with [The Outernet](https://outernet.nyc), and made possible by a generous donation from The Robert Halper Foundation.

Powered by [epjecha](https://github.com/epjecha)'s awesome [Stateful](https://github.com/epjecha/StatefulUnity), [ObserveThing](https://github.com/outernet-foundation/ObserveThing), and [Nessle](https://github.com/outernet-foundation/Nessle) Unity packages, for reactive state management and declarative UI in Unity.
