# ZED box offline model install: closing the loop

Goal of the follow-up session: make the ZED box fully installable with zero
internet, including every ZED SDK model file the service's runtime config
needs. Today the loop is open: SDK models are download-on-demand, the box is
offline by design, and only the two depth models were ever obtained (fetched
manually during the June 1 setup of this box). The tracker models for
`POSITIONAL_TRACKING_MODE.GEN_2`/`GEN_3` have never been on the box, so
`enable_positional_tracking` fails on every capture start.

History: the previously-working box never solved this either — it worked
because its install threaded internet through the micro-USB gadget link from
the host, letting the SDK pull models on demand. The current box
(GTW-ONX1-D2YDITC1, ZED Box Mini / Orin NX 16GB, ZED X S/N 43684417 over
GMSL2, camera FW 2001) has never had internet and has never completed a
capture.

## Established facts (evidence from the 2026-11-06 session)

Parameter matrix run in the deployed container via
`ssh zed-box 'sudo docker exec -i placeframe-zed-capture-1 python -'` (hold
off pressing Start on the phone while it runs — the camera is exclusive):

| mode  | imu | depth       | enable result                  |
|-------|-----|-------------|--------------------------------|
| GEN_3 | on  | NEURAL_LIGHT | FAILURE                        |
| GEN_3 | on  | NONE         | FAILURE                        |
| GEN_3 | off | NEURAL_LIGHT | FAILURE                        |
| GEN_3 | off | NONE         | FAILURE                        |
| GEN_2 | any | any          | CORRUPTED SDK INSTALLATION (+ CUDA error on close) |
| GEN_1 | on  | NEURAL_LIGHT | SUCCESS, tracking state OK     |
| GEN_1 | off | NEURAL_LIGHT | SUCCESS, tracking state OK     |
| GEN_1 | any | NONE         | INVALID FUNCTION CALL (GEN_1 is depth-based) |

- Scene quality, IMU fusion, and depth mode are all exonerated for the GEN_3
  failure; the missing variable is model resources.
- Image archaeology (`sudo docker run --rm --network none --entrypoint ls
  <image> -la /usr/local/zed/resources`): every recent image — tree-9c43d829
  (2026-09-24), tree-4aae80af (2026-10-30), tree-984c655b (2026-11-06) — is
  SDK 5.2.3 with an **empty** `/usr/local/zed/resources`. The Stereolabs
  runtime base ships no models; everything is download-on-demand.
- `compose.rig.yml` bind-mounts host `/usr/local/zed/settings` and
  `/usr/local/zed/resources` over the image's empty dirs. Host resources
  contains only: `neural_depth_5.3.model`, `neural_depth_light_5.2.model`
  (both Jun 1 2026, fetched manually), `.a100300_timing_cache`, and the two
  `.model_optimized-*` TensorRT engines (built on-box; the NEURAL_LIGHT one
  on 2026-11-06). The engines are GPU-specific (Orin NX) and persist via the
  bind.
- Offline posture is deliberate and tripwired: `ZED_SDK_DISABLE_DOWNLOAD=1`
  in compose; install-zed blanks the gadget default route and aborts if
  `ip route show default` is non-empty.
- SDK version is consistent: host install 5.2.3 (June 1), container 5.2.3,
  daemon sockets (nvscsock/camsock = ZEDX_Daemon, imu_daemon.sock = IMU_Daemon,
  argus_socket = nvargus) all connectable from inside the container.
- The service's exact open path is `build_init_parameters()` in
  `workloads/zed-capture/src/zed/zed_wrapper.py` — the single source of SDK
  open parameters, shared with install-zed's closing assertion
  (`src/open_camera_probe.py`, exec'd in-container as
  `uv run --no-sync python -m src.open_camera_probe`). Tracker mode is set
  separately in `Zed._start()` (`POSITIONAL_TRACKING_MODE.GEN_3`).
- Stereolabs forum context (research, 2026-11-06): GEN_3 became the default
  in 5.2; it has a documented open issue with `enable_imu_fusion=True`
  ("GEN 3 Positional Tracking does not work if tracking_parameters
  .enable_imu_fusion is set to True", community.stereolabs.com/t/11361,
  still broken for the reporter on 5.3.1), plus 5.2.0/5.2.1-era low-texture
  deadlocks. GEN_1+NEURAL_LIGHT is the field-proven pre-June configuration.

## Follow-up investigation

1. **Enumerate the required model set for the target tracker mode.** On any
   internet-connected machine, install/extract SDK 5.2.3 (same version as the
   lock pin — the base image is `docker.io/stereolabs/zed:5.2-runtime-jetson-
   jp6.1.0`, digest-pinned in `boatyard.lock.yml`), snapshot
   `/usr/local/zed/resources`, then run an open + `enable_positional_tracking`
   with GEN_3 (the container base works: `docker run --network` with egress,
   pyzed installed via `/usr/local/zed/get_python_api.py`). Diff the resources
   dir to capture exactly what the SDK fetches (host + URL), including whether
   GEN_3 needs a first-use TensorRT optimization like the depth models do.
2. **Seed via install-zed, calibration-style.** The pattern already exists:
   `_seed_camera_calibration()` in
   `scripts/src/scripts/install_zed/box_install.py` fetches a per-SN conf from
   `https://calib.stereolabs.com/?SN=…` on the host once and `sudo install`s
   it into the bind-mount source. Model files want the same treatment: fetch
   on the host (cache them in the repo or a bucket — decide), ship into
   `/usr/local/zed/resources`. The resources bind is a directory mount, so a
   post-`up` seed is visible without a container recreate.
3. **First-use optimization.** If GEN_3 needs on-device optimization, extend
   `open_camera_probe.py` (or add a second install-time step) to also enable
   tracking so the engine build lands at install time, not the first field
   start. `54b05da` is the precedent for exactly this pattern on the depth
   model.
4. **Version coupling + assertion.** Model files are SDK-version-suffixed
   (`neural_depth_5.2` vs `5.3` naming). The model set must match the locked
   SDK digest; add an install assertion that the seeded set is the one the
   locked SDK expects.
5. **Decide the target config.** Either GEN_3 with seeded models (then
   validate the forum's GEN_3+IMU bug on 5.2.3 — matrix on this box can A/B
   `enable_imu_fusion`), or fall back to GEN_1+NEURAL_LIGHT (works on this
   box today; one-line pin change in `Zed._start()` plus rewriting the
   "Run with DEPTH_MODE.NONE…" constraint section in
   `workloads/zed-capture/AGENTS.md`, which is already flagged as
   violated-in-code and wants a rewrite regardless).
6. Minor cleanup while in there: the box's `zed_x_daemon.service` unit has an
   unknown `sync_mode` key systemd warns about on every reload; two pre-fix
   orphan capture dirs live under the box's `/root/captures/`
   (`2d9d1229-*`, `0513d7ea-*`) and can be deleted.

## Closeout (2026-11-06, later session)

Loop closed; GEN_3 is the validated configuration.

- The GEN_3 (and GEN_2) tracker model set for SDK 5.2.3 is exactly one
  file: `http://download.stereolabs.com/tracking_model/positional_tracking_2_2`
  (33,279,104 bytes, sha256
  `21ff75426ea1d66bc52b6cd978eef4c30153d9afc0c1f8fa6fcd001448f80554`),
  which the SDK stores as `/usr/local/zed/resources/positional_tracking_2.2.model`.
  No GEN_3_SLAM_parameters.json or vocabulary download happens (embedded);
  no TensorRT engine is built for tracking (unlike the depth models).
  Derived behaviorally: SSH reverse tunnel → logging passthrough → real
  `enable_positional_tracking` on the real box, proxy log = URL set.
- Offline validation on the box with downloads disabled: GEN_3 imu=on,
  GEN_3 imu=off, GEN_2 all SUCCESS with 10/10 OK tracking states. The
  forum's GEN_3+IMU-fusion bug does not reproduce on 5.2.3 with the model
  present. GEN_2's old "CORRUPTED SDK INSTALLATION" was the same missing
  model.
- Codified: `build_positional_tracking_parameters()` in zed_wrapper is the
  single source (actor + probe); `open_camera_probe.py` enables tracking;
  `install-zed` seeds the sha-pinned model into `/usr/local/zed/resources`
  and asserts the pin against what's already on the box (SDK-version
  coupling; re-pin procedure in constants.py).
- Cleanup done: `sync_mode` line removed from the box's zed_x_daemon unit;
  both orphan capture dirs deleted from the captures volume.
- Not done (out of scope): the DEPTH_MODE.NONE-vs-NEURAL_LIGHT rewrite of
  the zed-capture AGENTS.md constraint section (still flagged in place);
  the boatyard `--push-to` cache-ref bug (see
  install-zed-build-failure-handoff.md — needs a boatyard release + repin).
- Box state: model seeded and validated; stack untouched otherwise. Tunnels
  and probe residue removed. Box still runs tree-984c655b image-wise, but the
  three changed service files were docker-cp'd into the running container and
  the NEW probe (open + GEN_3 tracking enable) passes there offline, exit 0 —
  the exact install-zed closing assertion, validated end-to-end short of a
  full image rebuild.
- Host regression found: arm64 binfmt emulation on coi-pulsar (kernel 6.17)
  died mid-session — `tonistiigi/binfmt --install` from the SANDBOX reports
  success but lands in a per-userns binfmt_misc instance the docker
  daemon's containers don't consult; it likely also unregistered the
  operator's working global registration in the process. `install-zed
  --build` from the sandbox is blocked until the operator re-registers from
  the HOST shell (`docker run --privileged --rm tonistiigi/binfmt --install
  arm64`). install-zed's guard now probes the daemon itself (64e9b53), so
  it reports this honestly.
- Depth models folded into the seeded set (follow-up ask). The NEURAL_LIGHT
  model URL is `http://download.stereolabs.com/ai/model/
  neural_depth_light_5.2.model` (8,636,419 B, sha256 `d1194189…3163f`) and
  the CDN bytes are identical to the June 1 hand-fetch. Two SDK behaviors
  surfaced: a prebuilt-engine download is attempted first
  (`ai_model_optimized/…`, 403 on this GPU class) before the model +
  on-device build fallback; and an existing engine alone satisfies open
  (the model file is only needed to build it). `neural_depth_5.3.model`
  (full NEURAL) is never fetched for the service's path — deleted from the
  box as dead weight. `_seed_tracking_model` generalized to `_seed_sdk_models`
  over an `SDK_MODELS` spec tuple in constants.py.
- Fresh-box simulation validated on the real box: resources wiped to just
  the timing cache → both models seeded over SSH per the pins (box took no
  network) → offline probe built the engine from the seeded model and
  exited 0. Box resources dir now: the two seeded models + the derived
  engine + timing cache.
- Validation gap that remains: `install-zed --build` end-to-end was not run
  (binfmt above); pull mode can't ship unpushed commits. Next operator
  deploy from the host exercises the full flow: build → ship → already-seeded
  sha assertions → new probe with tracking.

## Session state (2026-11-06, branch `compose-bundles`, unpushed)

- `54b05da` — install warms the service's exact open path (probe module);
  failed starts tear down the camera and remove the orphan dir; non-open
  errors stay latched in `/status` until the next start attempt.
- `e35aa88` — AGENTS.md updates for the above.
- `3126f95` — boatyard as local path source (dev convenience; drop before
  merge if CI has no sibling checkout).
- `936f5a6` — ignore buildx `metadata.json`.
- `0a3689c` — phone client: record stays enabled under DegradedError, failed
  start/stop no longer wedge `captureStatus`, banner shows the box's failure
  reason. APK (debug-signed) installed on the Pixel (`48270DLAQ00BSQ`), fresh
  install so READ_LOGS was re-granted.
- Box runs `192.168.55.100:5000/zed-capture:tree-984c655b…` (includes the
  service fixes). Box time is 1970-epoch per boot — read timestamps
  accordingly.
- Backend placeframe stack is DOWN (taken down mid-session); bring up from
  `/workspace/placeframe` with `~/.local/bin/uv run boatyard up --quiet-pull`
  (system uv is 0.11.14, shadowing the pinned 0.12.15 at
  `~/.local/bin/uv`). Drained box logs are queryable there via Loki
  (`{service_name="zed-capture"}`; container is `placeframe-core-cuda-loki-1`
  under the core-cuda bundle — the `loki-query` tool hard-codes
  `placeframe-loki-1` and needs adjusting or a direct query).
- Box SSH: `ssh zed-box` (sandbox key at `~/.ssh-targets/zed-box/`);
  passwordless sudo covers docker/systemctl/etc (`SUDOERS_RULE` in
  `scripts/src/scripts/install_zed/constants.py`) — `journalctl` works
  unsudoed, `dmesg` does not.
