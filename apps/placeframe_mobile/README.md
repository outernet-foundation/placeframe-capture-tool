# Placeframe mobile (Flutter)

A lightweight Placeframe client for iOS and Android without Unity: **localization** and **capture**, no AR view.
Almost all code is shared Dart; each platform adds one small native module that streams camera frames from the
platform's AR tracking (ARKit / ARCore), because localization needs the camera intrinsics and capture needs a pose
for every frame.
Unlike `apps/CaptureTool` (Unity, which captures with the ZED box), it needs only the phone.

## What it does

- **Log in** to a Placeframe server (Keycloak password grant, client `placeframe-api`, realm `placeframe-dev`; the
  same flow as the Unity client).
- **Localize**: choose maps near your GPS position (`GET /localization-maps` with position + radius) or from all
  maps, then localize live, one request in flight at a time. With a server that offers tracked localization
  (`POST /localize/track`, frames sent with their AR odometry pose and a session id), the server keeps the
  candidate places and returns the most probable pose; otherwise the app uses single-frame `POST /localize` and
  aligns each match to the AR odometry itself. Shows a top-down view: the map's points near the phone's height
  (`GET /reconstructions/{id}/points`), the phone's path registered to the map, and the localizations; the pose
  updates at 10 Hz from AR odometry between localizations.
- **Capture**: record frames + AR poses + the best GPS fix while walking, then upload (`POST /capture_sessions`),
  build (`POST /reconstructions`), follow the build status and create a map when it succeeds. The capture includes
  `location.json`, so Placeframe places the new map on the globe and **Nearby** finds it.

## Layout

| Path | What |
|---|---|
| `lib/main.dart` | UI: login, Localize, Capture, Settings |
| `lib/api.dart` | Placeframe API calls |
| `lib/auth.dart` | Keycloak login and token refresh |
| `lib/capture.dart` | Capture recording in Placeframe's capture format, tar packaging |
| `lib/ar_frames.dart` | Platform channel to the native AR frame streamers |
| `lib/geo.dart` | GPS → ECEF, poses, ARKit/ARCore → OpenCV camera axes |
| `android/.../ArFrameStreamer.kt` | ARCore session without a view (offscreen EGL), CPU image → JPEG |
| `ios/Runner/AppDelegate.swift` | `ArFramesPlugin`: ARKit session without a view, captured image → JPEG |

Both native modules send the same message per frame: `jpeg`, `width`, `height`, `fx`, `fy`, `cx`, `cy` (pixels, of
that image), `pose` (camera-to-world, column-major 4x4, ARKit/ARCore camera axes), `timestamp`, `tracking`.
Images are sent in sensor orientation (`orientation: TOP_LEFT`); the Dart side converts poses to Placeframe's
`OPENCV` axis convention.

## Capture format

```
manifest.json          axis_convention OPENCV, one rig, one camera (intrinsics of the first frame)
rig0/frames.csv        timestamp,tx,ty,tz,qx,qy,qz,qw  (world-from-camera, OpenCV camera axes, AR world y-up)
rig0/camera0/<ts>.jpg
location.json          best GPS fix: latitude, longitude, altitude, horizontal_accuracy, map_up_axis "y"
```

Frames with limited tracking are not recorded. Builds use Placeframe's default options unless "Use AR poses as
position priors" is on (`use_prior_position`, 2 m sigma).

## Build

Requires Flutter (stable) and, for Android, JDK 17 and the Android SDK with API 37.

```bash
flutter pub get
flutter build apk --debug          # Android (ARCore device; installs Google Play Services for AR if missing)
flutter run                        # with a device attached
```

iOS needs a Mac with Xcode (or a cloud build service) and an Apple developer account to install on a device;
ARKit world tracking requires an iPhone/iPad with an A12 chip or newer.

## Status

- Android: compiles (`flutter build apk --debug`); not yet run on a device.
- iOS: written but not compiled (no macOS build host was available).
- Not included: an AR view, AR content, map placement editing.
