# placeframe-capture-tool

The capture tier of [Placeframe](https://github.com/outernet-foundation/placeframe): everything you need to walk a physical space and record stereo capture data for spatial-localization map building — an Android phone app and a ZED Box appliance, linked by a single USB cable.

One repo holds both halves because they deploy as a pair: the phone app speaks to the box over an Android Open Accessory (AOA) USB link, and the API client they share (`PlaceframeZedCaptureClient`, on npm and nuget) is generated from the box's committed OpenAPI spec. Phone and box ship together; you never need to match versions by hand.

## Hardware to buy

| Component | Requirement | Notes |
|---|---|---|
| Stereo camera | ZED X (global shutter) | GMSL2 connection to the box. Global shutter is mandatory — rolling shutter produces unusable captures. |
| Compute | ZED Box (Orin-based Jetson) | Runs the capture service, AOA bridge, and on-box observability. |
| Power | USB-C power bank (65 W+) | Field operation; the box + camera draw ~25 W. |
| Phone | Android device, USB-C | Any reasonably modern device; needs to support USB accessory mode. |

The camera is a swappable implementation detail behind the output contract (stereo JPEG pairs + `frames.csv` poses + factory calibration) — any rig with global shutter, factory stereo calibration, and hardware sync could replace the ZED X.

## Quick start

### 1. Set up the box

From a Linux host connected to the box by a direct ethernet cable (zero configuration on either end: the box holds a fixed link-local address and the host's port self-assigns one — allow ~45s after plugging in):

```bash
git clone https://github.com/outernet-foundation/placeframe-capture-tool.git
cd placeframe-capture-tool
uv sync
uv run install-zed
```

`install-zed` bootstraps a virgin Stereolabs box end-to-end — SSH access, Docker, the NVIDIA container runtime, an appliance strip of the stock desktop, and the capture stack (images pulled on the host and shipped over the cable; the box itself never touches the internet). It prompts once for the camera's serial number (on the camera's label) to seed the factory calibration. A `--build` flag cross-compiles the images locally instead. Re-runs are idempotent; see `scripts/AGENTS.md` for the full picture.

### 2. Install the phone app

Grab the APK from [GitHub Releases](https://github.com/outernet-foundation/placeframe-capture-tool/releases) and install it (`adb install capture-tool.apk`), or build from source with Unity 6:

```bash
uv run compile-unity --project CaptureTool --build android-mobile
adb install -r apps/CaptureTool/Build/*.apk
adb shell pm grant com.outernet.captureapp android.permission.READ_LOGS
```

### 3. Capture

1. Connect the phone to the box's USB-A port with a USB-C cable. The app auto-launches via the accessory handshake.
2. Wait for the tracker warm-up banner ("hold still and level") to clear — the first persisted frame always comes from a converged tracker.
3. Press record and walk the space; the box writes stereo JPEGs + gravity-stamped poses per frame.
4. Stop; the session is packaged as a tar on the box, ready to stream to a Placeframe server for reconstruction.

## Artifacts

- **APK** — [GitHub Releases](https://github.com/outernet-foundation/placeframe-capture-tool/releases) (tag prefix `capture-tool-v*`)
- **Box images** — `ghcr.io/outernet-foundation/placeframe-capture-tool/{zed-capture,aoa-bridge,aoa-gateway}` (public)
- **API client** — `PlaceframeZedCaptureClient` ([nuget](https://www.nuget.org/packages/PlaceframeZedCaptureClient)), `org.outernet.placeframe.zedcaptureclient` ([npm](https://www.npmjs.com/package/org.outernet.placeframe.zedcaptureclient))
- **Server side** — the [Placeframe](https://github.com/outernet-foundation/placeframe) repo (reconstructor, localizer, API)

## License

Apache-2.0 (see `LICENSE`; third-party notices for the vendored jars sit beside them in `apps/CaptureTool/Assets/Plugins/Android/aoa-accessory-filter.androidlib/libs/`). The `zed-capture` image derives from Stereolabs' ZED SDK base image; the SDK EULA binds each runner of that image.
