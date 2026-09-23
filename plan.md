# ZED-box install revamp — plan A

Executable by a session with no other context. Checkboxes flip to `[x]` when the step is
committed and verified; a fresh session resumes at the first unchecked box. Prose (`.md`)
and code in separate commits; one-line subjects <72 chars; no trailers.

Worktree: `.worktrees/zed-install-tarball` (branch `zed-install-tarball`, off `dev`).

## 1. Rulings from the design session (2026-09-23 — do not relitigate)

- **The box never touches the internet.** No NAT through the host, no gateway, no DNS on
  the box. Images, firmware, docker .debs all ship from the host over the cable. The box
  stays headless: no monitor, no keyboard, no internet, ever.
- **Default install mode = `docker save | ssh docker load`.** The host pulls/bakes, the box
  never pulls from a registry in default mode.
- **`--build` keeps the host-local registry untouched.** Layer-aware pulls across the
  cable are the iteration path for zed box logic; full tarballs per iteration are
  unacceptable. The registry + `insecure-registries` machinery stays.
- **Firmware ships from the host, extracted from a mirrored Stereolabs image.** Mirroring
  a standalone firmware `.bin` (or SDK installer) in CI is ruled out — that is standalone
  distribution of their proprietary binaries. Extracting the bin from the image we already
  mirror (and already publish publicly inside first-party images) adds no new distribution
  act. Legal notes: Docker Hub `stereolabs/zed` declares no license; `stereolabs/zed-docker`
  (recipes) is MIT; SDK binaries inside are proprietary under the installer EULA, whose
  public agreement explicitly permits SDK object code incorporated into applications and
  prohibits standalone distribution. The extraction path is the already-accepted posture.
- **Leftover NAT state is cleaned manually, once per host/box.** The new installer never
  creates it and never carries cleanup code — cleanup logic would be cruft after the fleet
  is migrated. Procedure in §7.
- **Cable-only topology.** The `--host` shared-LAN override that `zed-capture/AGENTS.md`
  documents never existed; the doc gets fixed, the flag is a follow-up (§8).
- **Networking spine = deterministic link-local.** Box holds static `169.254.0.1/16`
  (no gateway, no DNS). Host side is zero-config: an unconfigured port + cable
  auto-assigns an APIPA address (RFC 3927) after DHCP timeout (~45s/plug). Sandbox→box
  reachability rides the same COI forward+masquerade path that carries `100.64.0.1`
  traffic today; `169.254.0.0/16` is not in COI's RFC1918 deny set.
- **plan.md is tracked** on this branch (committed; unlike the extraction repo's untracked
  plan). Delete it when the last checkbox lands, same lifecycle discipline.

## 2. Target architecture

```
                 RFC 3927 link-local, no DHCP, no gateway, no NAT
 host laptop ──── ethernet cable ──── ZED Box (static 169.254.0.1/16)
 (APIPA addr,                          ├─ zed-capture + aoa stack (compose)
  zero config)                         ├─ images: docker load (default)
                                       │         or registry pull (--build)
 COI sandbox ─ forward+masq via host ──┘─ firmware: scp'd bin, offline open
```

Install flow (default mode): probe `169.254.0.1:22` → (first contact: APIPA discovery →
askpass bootstrap → scheduled flip to static, §5 P2) → sudoers refresh → docker .debs
scp'd + `dpkg -i` → nvidia-ctk → disable `nv-l4t-usb-device-mode` → appliance strip →
`/etc/hosts` entry → host pulls 5 images (arm64) → `docker save | gzip | ssh gunzip |
docker load` → firmware bin extracted from mirrored image, scp'd → compose + configs +
unit + `.env` → camera daemons → `compose up` → offline camera-open verification.

What the box no longer gets: default gateway, DNS, any route off-link. The offline
warmup can't download anything even if the SDK tries — that is the point.

## 3. File-level inventory

**Deletes**
- `host_setup.py` — entirely (NAT stack, NM profile ownership, `set_host_link_method`,
  no-auto-default fragment). No host-side networking code remains.
- `box_install.py`: `_claim_box_via_dhcp` (replaced by APIPA discovery), the
  box gateway/DNS `nmcli` block, `share_host_internet()` call in `orchestrator.py`.
- `constants.py`: `BOX_SUBNET`, `HOST_CABLE_CIDR`, `HOST_NM_CONNECTION`,
  `HOST_NO_AUTO_DEFAULT_CONF`, `HOST_SYSCTL_FILE`, `HOST_SYSCTL_CONTENT`. `BOX_IP` →
  `169.254.0.1`.

**Kept verbatim**
- `--build` registry flow (`_acquire_images` build branch, `REGISTRY_*`, insecure-registries
  diff/rewrite — rekeyed to the host's current APIPA address on the cable NIC, rewritten on
  change), `_ensure_arm64_emulation`, `_bootstrap_box_access` askpass dance +
  `SUDOERS_RULE` dormancy coupling, appliance strip, USB device-mode disable, `/etc/hosts`
  entry, deb-pinned docker install, `ZED_BOX_ID` from device-tree serial, SSH control-master,
  V4L2 choreography (`restart: "no"`, `wait_for_zed_camera`, unit-as-sole-starter), the
  `systemd-run --on-active` renumber pattern (reused for the static-link-local flip).

**Changes**
- `_box_reachable_at_static_ip` probe window: ~75s (covers host APIPA convergence on plug).
- First contact: discover factory box by ARP scan (`ping -I <if> -b 169.254.255.255` →
  `ip neigh` → try `:22`) on carrier-up ethernet interfaces that hold an APIPA address;
  bootstrap at the discovered address; scheduled flip to `manual 169.254.0.1/16`,
  gateway/DNS cleared.
- Default-mode image acquisition: host pulls + `save | load` (§5 P3). Stock loki/alloy
  refs move from index digests to **per-arch (arm64) manifest digests** in `.env.lock` —
  no runtime platform selection anywhere.
- Warmup: offline verification, not a downloader (§5 P4).
- `compose.rig.yml`: likely gains a `/usr/local/zed/firmware` bind mount (P4 verification
  decides the exact path the SDK reads).

## 4. Verified vs open

**Verified this session (no box needed)**
- `docker save | docker load` preserves tags and `RepoDigests` (docker 29).
- Platform selection is NOT hand-wave-safe: on a containerd-image-store daemon,
  `docker pull --platform linux/arm64` behaved deceptively (empty arch on inspect, amd64
  execution). Operator-host docker (classic store) is expected to differ — but the plan
  removes the dependency on `--platform` entirely via per-arch digests; only first-party
  pulls remain platform-blind-safe (single-platform arm64 tags — assert once at P6).
- COI sandbox egress: direct TCP works (public IPs), private ranges rejected on this
  *runner* host — inconclusive for the operator laptop (no box attached here; reject may
  be upstream). The authoritative rule shape (deny RFC1918 only) passes `169.254.0.0/16`.
- mDNS is off inside sandboxes — irrelevant: the box address is deterministic, no name
  resolution needed anywhere.
- ZED SDK 5.3 release notes: calibration stored on EEPROM, SDK falls back to it when the
  downloaded local file is absent and there is no internet. ZED X on 5.2 expected to match
  (verify at bench). Firmware updates: `.bin` files, `ZED_Explorer --updatefw <file>`
  headless-capable; firmware files live under `/usr/local/zed/firmware` in SDK installs.

**Open — bench verification gate (P1, operator + box; items gate their phases)**
1. Operator-host sandbox → `169.254.0.1` reachability (COI filter + forward + masquerade
   out the cable NIC). **Gates P2.** If it fails: fallback = documented one-time manual NM
   profile on the host (option 2 from the design session), never built into the installer.
2. Host APIPA timing: unconfigured port + cable + box → address assigned within ~60s;
   factory box likewise falls back to APIPA on DHCP failure. **Gates P2.**
3. Firmware bin presence: `docker run --rm --platform linux/arm64 <zed-base> ls -R
   /usr/local/zed/firmware` (pull via the mirror ref from `.env.lock`). If the lean
   `5.2-runtime-jetson-jp6.1.0` image lacks it, mirror the `5.2-tools-devel-jetson-jp6.1.0`
   tag the same way (new `.env.lock` entry + `x-base-images` row so mirror-images carries
   it; same legal footing). Also determine whether `Camera.open()` auto-applies a bin found
   in that directory, or whether `ZED_Explorer --updatefw` must run (via an on-box
   `docker run` of the tools image). **Gates P4.**
4. Offline open on SDK 5.2 + ZED X: `Camera.open()` succeeds with no default route,
   calibration served from EEPROM, no download attempted. **Gates P4.**
5. `docker save` of a first-party tree-SHA tag on the host → `docker load` on box →
   `docker image inspect` reports `arm64` (single-platform manifest assertion). **Gates P3
   sign-off.**

## 5. Phases

### P1 — bench verification gate (no repo commits; record results in §4)

- [ ] 1.1 Items 1–2 above (networking spine). Fallback if 1 fails: option-2 manual
      profile documented in `scripts/AGENTS.md`, spine degrades to "static profile owned
      by operator", P2 adjusted accordingly.
- [ ] 1.2 Items 3–4 (firmware + offline open).
- [ ] 1.3 Item 5 plus: resolve per-arch arm64 manifest digests for loki/alloy
      (`docker buildx imagetools inspect <mirror-ref>` → `linux/arm64` manifest digest)
      and have the new `.env.lock` values ready.

### P2 — networking rework (code commit: `Rework install networking to deterministic link-local`)

- [ ] 2.1 `constants.py`: `BOX_IP = "169.254.0.1"`, delete host-side constants, add
      discovery constants (probe window, ARP-scan bits).
- [ ] 2.2 Delete `host_setup.py`; `orchestrator.py` drops `share_host_internet()`.
- [ ] 2.3 `box_install.py`: replace DHCP claim with APIPA discovery + askpass bootstrap
      at the discovered address + scheduled flip to `manual 169.254.0.1/16` (gateway/DNS
      cleared; reuse the `systemd-run` pattern). Extend the static-IP probe window.
- [ ] 2.4 Delete the box gateway/DNS block. The box ends install with: one static
      link-local address, no default route.
- [ ] 2.5 ruff + basedpyright green; `bashrun` guard on new shell lines (no `||`/pipes
      outside `bash_pipe`).

### P3 — image acquisition (code commit: `Ship box images from the host instead of the box pulling`)

- [ ] 3.1 `.env.lock`: `LOKI_DIGEST`/`ALLOY_DIGEST` become the per-arch arm64 manifest
      digests from 1.3. Update the lock-update procedure note (scripts/AGENTS.md, P5).
- [ ] 3.2 Default mode `_acquire_images`: host pulls the three first-party tree-SHA tags
      + two stock per-arch-digest refs from the mirror, then
      `docker save <all five> | gzip | ssh … 'gunzip | docker load'` (one tar, gzip —
      guaranteed on the box). Compose `.env` image refs unchanged (same tags/digests).
- [ ] 3.3 `--build` branch: unchanged except the registry address is the host's current
      APIPA address on the cable NIC (discover at run time), and the insecure-registries
      diff/rewrite already handles churn-on-change.
- [ ] 3.4 Delete `_pull_image_on_box` (no box-side pulls in default mode).

### P4 — firmware + offline warmup (code commit: `Pre-seed ZED firmware and verify camera open offline`)

- [ ] 4.1 Per 1.2 results: extract firmware bin(s) on the host from the (already-mirrored)
      Stereolabs image — `docker create` + `docker cp /usr/local/zed/firmware` — and scp
      to the box path the SDK reads (likely needs the `compose.rig.yml` bind mount added).
- [ ] 4.2 If `ZED_Explorer --updatefw` is required (1.2): on-box
      `docker run --rm <tools-image> ZED_Explorer --updatefw <bin>` with GMSL device
      access, once at install, idempotent (SDK reports current).
- [ ] 4.3 Warmup step stays but is now an offline assertion: camera open must succeed with
      no default route. Failure is loud, names the missing artifact (firmware/calibration),
      and blocks install completion (no silent deferral to first capture). Non-fatal
      degradation only if 1.2 surfaced a legitimate offline-blocking case — then the error
      message carries the exact SDK demand and the bench procedure.

### P5 — docs (prose commits: `Update agent docs and README for offline link-local installs`)

- [ ] 5.1 `scripts/AGENTS.md`: rewrite image-acquisition + constraints sections —
      delete host-networking-ownership and RFC 6598 lines; add zero-host-config link-local
      spine, APIPA timing, discovery flow, per-arch-digest lock procedure, firmware
      extraction; sudoers-dormancy / USB device-mode / control-master lines stay.
- [ ] 5.2 `docker/zed-capture/AGENTS.md`: networking section rewrite (two paths:
      laptop link-local deploy + AOA; delete "outbound internet" claims, the RFC 6598
      paragraph, and the `--host` ghost). While in the file: fix the restart-policy drift
      (doc says `on-failure`; compose.rig.yml says `restart: "no"` with the newer
      dockerd-auto-start rationale — doc updates to match code).
- [ ] 5.3 `README.md:22` "the install tooling configures the link" → the tooling
      configures nothing on the host; plug in a cable. Root `AGENTS.md`: adjust the
      `install-zed` line if it implies host networking.
- [ ] 5.4 Record P1 bench results (§4) as resolved.

### P6 — bench validation + migration (no repo commits beyond checkbox flips)

- [ ] 6.1 Fresh-virgin-box install in default mode; then `--build` install. Checklist
      mirrors the extraction plan's gate: stack healthy, box-Loki queryable on-box, phone
      AOA link + log drain functional, warmup passed offline, box has no default route
      (`ip route` shows only `169.254.0.0/16 dev …`).
- [ ] 6.2 Migration of the existing box + host per §7 (one time).
- [ ] 6.3 Operator: update pulsar config `ssh_targets.zed-box.host` → `169.254.0.1`,
      re-run `uv run sandbox authorize zed-box`, confirm `ssh zed-box` from a sandbox.

## 6. Hazards

- **Sandbox pushes**: App token is read-only — commit locally, hand branch + SHA to the
  operator. Never `gh run watch`.
- **Sandbox docker ≠ operator docker** (containerd image store here): platform behaviors
  verified only on the operator host count.
- **`--platform` anywhere** is a smell: per-arch digests are the sanctioned mechanism.
- **Host APIPA latency** (~45s/plug) is expected UX, not a bug — probe windows cover it;
  document in README so operators don't conclude the cable is dead.
- **Existing box at `100.64.0.1`** is unreachable once the host's `zedbox` profile is
  deleted — migrate per §7 before or during cleanup; don't strand the box.
- **pylock/lint bounds** (extraction plan §13): ruff/basedpyright version ceilings still
  apply to the moved code; don't bump tools in this initiative.
- `docker compose` for the rig is only ever rendered (scratch) — never `up`'d from the repo.

## 7. Manual NAT cleanup + box migration (operator, once per host/box)

Host (run once, after the last old-style box is migrated):

```bash
sudo nmcli con delete zedbox
sudo rm /etc/NetworkManager/conf.d/zedbox-no-auto-default.conf && sudo nmcli general reload
sudo rm /etc/sysctl.d/99-zedbox.conf && sudo sysctl --system
sudo firewall-cmd --permanent --zone=trusted --remove-source=100.64.0.0/24
sudo firewall-cmd --permanent --zone=public --remove-masquerade
sudo firewall-cmd --reload
sudo iptables -D DOCKER-USER -s 100.64.0.0/24 -j ACCEPT
sudo iptables -D DOCKER-USER -d 100.64.0.0/24 -j ACCEPT
```

Box migration (while the old path still exists; the temporary profile restores it once):

```bash
sudo nmcli con add type ethernet con-name zedbox-migrate ifname <nic> \
  ipv4.method manual ipv4.addresses 100.64.0.2/24
ssh user@100.64.0.1 'sudo systemd-run --on-active=3 /bin/sh -c "\
  nmcli con mod <boxconn> ipv4.method manual ipv4.addresses 169.254.0.1/16 \
  ipv4.gateway \"\" ipv4.dns \"\"; nmcli con up <boxconn>"'
sudo nmcli con delete zedbox-migrate
```

Then the new installer reaches the box at `169.254.0.1` forever.

## 8. Follow-ups deliberately not built

- `--host <target>` shared-LAN override (doc ghost removed in P5; build only if needed).
- Option-2 manual NM profile fallback (exists only if P1 item 1 fails).
- Pulsar `messages.py` ssh-targets example still says `100.64.0.1` — cross-repo, operator
  touch-up whenever convenient.

## 9. Planning decisions (recorded so they aren't re-derived)

- Registry for `--build` kept after initially being slated for deletion — operator
  overrode on iteration-cost grounds; tarball-everything was rejected mid-session.
- Firmware via image extraction rather than host-side URL fetch: hermetic (CI mirrors the
  image already), no new legal surface, no Stereolabs-on-the-internet dependency.
- Standalone mirroring of Stereolabs binaries ruled out on licensing; extraction ruled in
  on status-quo distribution grounds.
- Per-arch digests over `--platform` after the containerd-store platform surprise.
- Cleanup is manual-by-ruling: installer code that removes installer-created state would
  outlive its purpose.
- `plan.md` tracked on the branch (operator ruling; differs from the extraction repo's
  untracked convention). Delete when the last checkbox lands.
