# ZED-box AOA diagnosis handoff (sessions of 2026-10-30 evening)

Status: **root causes found — two, both box-side, both broken-from-birth.** The gateway
fix is committed; the deploy is deliberately deferred until docker-devkit's
artifact-identity plan delivers the platform-resolved lock (ADR Part 0, cluster
P0+P1) and this repo relocks onto it (operator decision — no hand-patching, no
fast-track release). Phone-side evidence from the first session is fully
explained; nothing further to chase on the phone.

## Finding 1: aoa-gateway has never started (Caddyfile h2c-without-h1)

`workloads/aoa-gateway/Caddyfile` declared `protocols h2c`; caddy refuses to provision
("cannot enable HTTP/2 or H2C without enabling HTTP/1.1") and exits 1 on every boot,
stays dead (`restart: "no"`). Nothing has ever listened on 127.0.0.1:9000, so aoa-bridge
forwards AOA bytes into the void → the phone's 60 s silences → `AOA threw` forever →
Record never enables. This alone explains every phone-side fact in the first session's
record below.

Fix committed: `6398426` "Enable h1 alongside h2c in the aoa-gateway Caddyfile"
(branch `compose-bundles`). Add-not-remove is right: the phone's OkHttp is
H2_PRIOR_KNOWLEDGE-only (`AoaAccessoryClient.java:282`), h2 stream multiplexing is
load-bearing over the single accessory FD (h1 would allow one in-flight request), and
caddy implements h2c as a wrapper over its h1 listener — h1 is structurally required.
Not pushed (sandbox App token has no Contents:write) but the host sees it: this
sandbox's /workspace is the host's `~/repos` bind mount.

## Finding 2: aoa-loki + aoa-alloy have never started (amd64 images on an arm64 box)

Both exit 255 instantly: `exec /usr/bin/loki: exec format error` / `exec /bin/alloy:
exec format error`. The images shipped to the box are **amd64** — the box's RepoDigests
are save/load-synthesized, but architecture travels with the content.

Cause chain: `docker-devkit.lock`'s LOKI/ALLOY entries are **multi-platform index
digests** (e.g. loki `sha256:4c431d2e…` is the tag's manifest list), not the per-arch
arm64 manifests that `scripts/AGENTS.md` documents. `_pull_image_on_host` pulls the
stock refs by digest with **no `--platform` flag** (the doc's "platform-unambiguous"
claim only holds for per-arch digests), so the amd64 build host resolves the index to
amd64 and ships that. The pinned resolver reproduces the defect: `uv run build
--lock-only` with docker-devkit 0.4.9.dev165 exits 0 and writes the identical index
digests — the bug is in the devkit package (PyPI pin; floor declared in
`docker-devkit.yaml` `requires >= 0.4.9.dev165`), not in this repo. First-party images
are unaffected: their base-image ARGs also carry index digests, but buildx resolves
them against `platforms: [linux/arm64]` at build time.

Verified arm64 children exist in the org-mirror indexes (recorded as evidence, do not
hand-patch the lock with them): loki 3.5.0 → `sha256:4c28f6be7853785ca90273ce2a9f6ce0e
7e4b55e2bfbdcf771a390c4a88da507`, alloy v1.9.0 → `sha256:08b4fe15d159a1c3114a3939c4099
ce8c2868ca0877a56f1d2efd48a9a601011`. Cross-checking digests: use
`docker buildx imagetools inspect --raw <index-ref> | jq '.manifests[] | select
(.platform.architecture=="arm64")'` — `docker manifest inspect --verbose` fails
"manifest verification" on child digests and is useless here.

## Why no deploy happened this session

- **Sandbox cross-build is not viable — don't retry it.** This Incus container runs its
  own dockerd, and `binfmt_misc` mounts get private per-mount instances: tonistiigi/binfmt
  `--install` lands in the installer container's own instance and dies with it;
  registering from the sandbox shell EINVALs; `/proc/sys/fs/binfmt_misc` flaps between
  commands. `install-zed --build` aborts at `_ensure_arm64_emulation` (no
  `qemu-aarch64` handler file) before any bake. Emulation aside, the sandbox-side
  `--build` ship path would actually work: the box CAN reach sandbox-published ports at
  the masqueraded gadget address (probed: HTTP 200 from `192.168.55.100:5000`). The
  blocker is purely the bake.
- **Deploy is deferred pending the devkit fix** (operator decision): one host-side
  `install-zed --build` should land both fixes at once (fixed gateway + arm64 stock
  images), rather than shipping the gateway fix with amd64 loki/alloy again.

## Next-session plan (in order)

1. Wait on docker-devkit: the lock fix is Part 0 of its artifact-identity ADR
   (`plan-artifact-identity.md`), delivered by the implementation plan
   (`plan-artifact-identity-implementation.md`, cluster P0+P1, phases 1-7);
   that plan links back to this doc. Nothing to do in this repo until the
   cluster-P0+P1 devkit release exists.
2. On that release: repin docker-devkit (exact pin in `pyproject.toml` plus
   the `requires` floor in `docker-devkit.yaml`), then relock —
   `env -u UV_PYTHON PATH="$HOME/.local/bin:$PATH" uv run build --lock-only`
   from the repo root (sandbox is fine — registry queries only). Verify the
   structured YAML lock lands with arm64 manifest dishes for LOKI/ALLOY, and
   spot-check one dish resolves to a manifest, not an index. Commit the
   relock (generated artifact; own commit).
3. Deploy from the **host shell**: `uv run install-zed --build` at
   `~/repos/placeframe-capture-tool` on branch `compose-bundles` (6398426 + the
   repin/relock commits). Host binfmt/bake is the proven path (the current arm64 first-party images
   on the box were baked that way); zed-capture/aoa-bridge layers are warm-cached.
4. Verify on the box over ssh:
   - `sudo docker ps` — all five Up (gateway no longer exit-1; loki/alloy no longer 255)
   - `wget -qO- http://127.0.0.1:9001/status` (uvicorn direct) and the h2c terminator
     on :9000 (`curl --http2-prior-knowledge` if the box curl supports http2)
   - `sudo docker logs placeframe-aoa-gateway-1` — provisioned cleanly, `protocols
     h1 h2c` in the adapted-config debug line
5. Live repro: phone on the box's USB-A, CaptureTool → ZED mode; watch for `AOA res`
   in `{app="capture-tool"} | json | logGroup="Zed"` and Record enabling after the
   first `/status` 200.
6. Then the queued phone-side amplifier fix (fact 5 below) — kept out of this session
   deliberately so the box verification runs against a single changed variable.

## Reaching the box (unchanged, proven)

```
ssh -F /dev/null -i /workspace/placeframe-capture-tool/.placeframe/ssh/id_ed25519 \
  -o IdentitiesOnly=yes -o UserKnownHostsFile=/workspace/placeframe-capture-tool/.placeframe/ssh/known_hosts \
  -o StrictHostKeyChecking=accept-new user@192.168.55.1
```

Box: `GTW-ONX1-D2YDITC1` (ZED Box Mini, Orin NX, L4T 5.15.148-tegra). The port-22 coi
hole was present for both sessions this evening (either the permanent `coi_ports`
landed or the host rule persists); `timeout 5 bash -c '</dev/tcp/192.168.55.1/22'`
tells you in one shot. Firewall hole still needed if refused:
`coi hosts add <container> 192.168.55.1 zed-box --ports 22` on the host.

## Phone-side amplifier bug (unchanged, queued behind the box fix)

The health poll's 2 s CTS never reaches the Java OkHttp call —
`AndroidAoaHttpHandler.ExecuteOverAoa` (`apps/CaptureTool/Assets/Scripts/Android/
AndroidAoaHttpHandler.cs:112`) takes no CancellationToken, so a hung `/status` blocks
the poll loop for the full 60 s Java timeout. Secondary; fix after the box answers.

## Gotchas (from workloads/aoa-bridge/AGENTS.md, still true)

Never unbind/rebind `tegra-xusb` (crashes xHCI, needs physical reboot); the handshake
cycles ~20 s when something is wrong, so stream journalctl rather than sampling lsusb;
FUSB301 / usb-role-switch noise is the micro-B port, not the phone's port.

## Do not confuse with (separate open items)

- The ML2/make-it-sing `{}`-body Loki push 422s (`/workspace/ml2-loki-422-handoff.md`)
  — different app, unrelated repo.
- The `DEPTH_MODE.NEURAL_LIGHT` vs `NONE` doc/code disagreement
  (`workloads/zed-capture/AGENTS.md`) — pre-existing, wants its own investigation.

## Errors hit this session (so the next one doesn't re-pay them)

- `tonistiigi/binfmt --install arm64` reports success inside its privileged container
  but the handler is invisible to dockerd's containers (per-mount private binfmt
  instances under this Incus kernel 6.17); `--privileged` registration is a dead end
  here. Manual `binfmt_misc` registration from the sandbox shell returns EINVAL.
- `install-zed --build` in the sandbox aborts at the `_ensure_arm64_emulation` gate
  with the QEMU hint — the check is correct; the environment can't satisfy it.
- `docker manifest inspect --verbose <child-digest>` → "manifest verification failed";
  use `buildx imagetools inspect --raw` + jq instead. Also: never let a grep swallow
  stderr on registry probes — two verifications this session silently returned empty
  because `2>/dev/null` hid the actual errors.
