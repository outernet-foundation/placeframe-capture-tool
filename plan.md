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
- **Stereolabs proprietary bits ride inside mirrored images, never standalone.** Originated
  as a firmware-extraction ruling; ZED X firmware turned out not to exist (§4), so the
  ruling now governs the `.isp` profiles baked via the devel build stage. Mirroring a
  standalone Stereolabs binary in CI is ruled out — that is standalone distribution of
  their proprietary files. Copying bits out of images we already mirror (and already
  publish publicly inside first-party images) adds no new distribution act. Legal notes:
  Docker Hub `stereolabs/zed` declares no license; `stereolabs/zed-docker` (recipes) is
  MIT; SDK binaries inside are proprietary under the installer EULA, whose public
  agreement explicitly permits SDK object code incorporated into applications and
  prohibits standalone distribution. The extraction path is the already-accepted posture.
- **Leftover NAT state is cleaned manually, once per host/box.** The new installer never
  creates it and never carries cleanup code — cleanup logic would be cruft after the fleet
  is migrated. Procedure in §7.
- **Cable-only topology.** The `--host` shared-LAN override that `zed-capture/AGENTS.md`
  documents never existed; the doc gets fixed, the flag is a follow-up (§8).
- **Networking spine = deterministic link-local.** Box holds static `169.254.0.1/16`
      (no gateway, no DNS). Host side is zero-config: an unconfigured port + cable
      auto-assigns an APIPA address (RFC 3927) after DHCP timeout (~45s/plug) — sufficient
      for host-shell deploys, which are the primary path. Sandbox→box needs a documented
      one-time host rule pair (forward accept + masquerade, §7b): coi's restricted mode
      explicitly rejects sandbox traffic to `169.254.0.0/16`, and today's `100.64.0.1` path
      never carried sandbox-originated deploys either (§4).
      **Superseded 2026-09-23 by the micro-B-only transport ruling (§9, P7)** — kept for
      context only; P7 replaces the spine. The host-APIPA premise also failed on the bench
      (§4).
- **plan.md is tracked** on this branch (committed; unlike the extraction repo's untracked
  plan). Delete it when the last checkbox lands, same lifecycle discipline.

## 2. Target architecture

```
                 RFC 3927 link-local, no DHCP, no gateway, no NAT
 host laptop ──── ethernet cable ──── ZED Box (static 169.254.0.1/16)
 (APIPA addr,                          ├─ zed-capture + aoa stack (compose)
  zero config)                         ├─ images: docker load (default)
                                       │         or registry pull (--build)
  COI sandbox ─ fwd+masq rule pair ─┘─ calibration: host-fetched conf, scp'd
```

Install flow (default mode): probe `169.254.0.1:22` → (first contact: APIPA discovery →
askpass bootstrap → scheduled flip to static, §5 P2) → sudoers refresh → docker .debs
scp'd + `dpkg -i` → nvidia-ctk → disable `nv-l4t-usb-device-mode` → appliance strip →
`/etc/hosts` entry → host pulls 5 images (arm64, `--platform` or digest-pinned) →
`docker save | gzip | ssh gunzip | docker load` → calibration conf fetched on host,
scp'd → compose + configs + unit + `.env` → camera daemons → `compose up` → offline
camera-open verification.

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
- `compose.rig.yml`: gains a `/usr/local/zed/settings` bind mount (seeded per-SN
  calibration conf) + `ZED_SDK_DISABLE_DOWNLOAD=1` in the zed service env (§5 P4).

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
- **No ZED X firmware exists to ship** (2026-09-23, resolves open item 3): Stereolabs staff
  confirm ZED X / X Mini / X One have no firmware updates at all
  (`community.stereolabs.com/t/zedx-firmware-update/8527`) — the update UI on GMSL cameras
  is a known display bug. Verified in the images: `5.2-runtime-jetson-jp6.1.0` (pulled by
  per-arch manifest digest `6d1a76e8…`, create+cp, no exec) has no
  `/usr/local/zed/firmware` directory whatsoever; `5.2-tools-devel-jetson-jp6.1.0` (full
  rootfs listing) carries only USB-model bins (`ZED`, `ZED-M`, `ZED2`, `ZED2i`) plus two
  ZEDX `.isp` sensor profiles. P4's extract-and-flash mechanism is moot; the devel-image
  mirror fallback is not needed (no new `.env.lock` entry).
- **Per-arch arm64 manifest digests resolved** (for P3.1): loki `3.5.0` →
  `@sha256:4c28f6be7853785ca90273ce2a9f6ce0e7e4b55e2bfbdcf771a390c4a88da507`, alloy
  `v1.9.0` → `@sha256:08b4fe15d159a1c3114a3939c4099ce8c2868ca0877a56f1d2efd48a9a601011`.
- Pull-by-per-arch-digest is clean on this containerd daemon (no `--platform` involved);
  the ZED base index (`6923135d…`) holds exactly one real manifest (linux/arm64 +
  attestation), so base-image pulls are platform-unambiguous by construction. Direct
  docker.io pulls work from this sandbox.
- **COI egress filter is harsher than assumed** (probe from the `coi-pulsar` sandbox,
  2026-09-23): RFC1918, `100.64.0.0/10`, **and** `169.254.0.0/16` all get an instant
  TCP-RST reject; a public IP connects; a public bogon (TEST-NET) drops silently.
  (100.64's instant reject is explained by NM's shared-mode chain, not coi — see the
  laptop-ruleset bullet below.) `authorize_sandbox_target` only ssh-copy-ids; it creates
  no network path.
- **Laptop ruleset read resolves open item 1 — NO by default** (2026-09-23; the
  operator pasted `sudo nft list ruleset` from the laptop, which hosts this very
  sandbox — probe counters match). Findings: (a) coi restricted mode keeps an explicit
  `ip saddr <sandbox> ip daddr 169.254.0.0/16 reject` (besides RFC1918) in the iptables
  FORWARD chain, regenerated per session; (b) today's 100.64 path never carried
  sandbox-originated deploys either — NetworkManager's shared-mode forward chain
  (`nm-sh-fw-enp5s0`) rejects NEW forwarded connections out the cable NIC, and its
  reject counter contains exactly this sandbox's three probe SYNs (the 47k established
  packets are host-originated; host traffic bypasses FORWARD); (c) a per-target
  accept+masquerade pair for `10.0.0.1:22` exists but sits AFTER the range rejects with
  zero counters (shadowed) — whether coi generates it from `ssh_targets` and mis-orders
  it, or it was hand-added, is unverified; (d) masquerade is mandatory for any
  sandbox→box flow (the box has no route back to `10.250.250.0/24`). Consequence:
  **deploys default to the host shell** (zero new plumbing — host APIPA + host OUTPUT
  path suffice); sandbox→box = documented one-time rule pair (§7b).
- **Host APIPA timing resolved by docs**: NetworkManager's default DHCP timeout is 45s
  (NM reference manual + RHEL docs); a `method=auto` ethernet connection falls back to
  a `169.254.x.y/16` address when DHCP fails (classic NM behavior; explicit
  `ipv4.link-local=fallback` enum exists since NM 1.52). The ~60s expectation and the
  installer's ~75s probe window are correctly sized. Factory-box half: JP6/Ubuntu 22.04
  on the ZED Box is NetworkManager-managed and expected to APIPA on DHCP failure, but
  Stereolabs docs don't state it (default creds `user`/`admin` confirmed); residual
  bench observation, cheap to watch during first-contact testing.
- **Offline camera open on SDK 5.2 is NOT safe stock** — and the fix is seeding, not
  firmware. SDK 5.3 release notes: (a) EEPROM-backed calibration is a 5.3 feature, and
  reading it requires cameras produced after May 2026 (except ZED Mini); (b) 5.3 fixed a
  GMSL bug where ZED X with no local calibration file and no internet failed
  `open()` with `CALIBRATION_FILE_NOT_AVAILABLE` instead of falling back to EEPROM —
  our 5.2 runtime image has exactly that bug's preconditions. Calibration source
  priority: local `settings/SN*.conf` file → EEPROM → download. Deterministic offline
  design: the host fetches the factory calibration once from
  `https://calib.stereolabs.com/?SN=<serial>` (tiny conf) and ships it to the box,
  mounted at `/usr/local/zed/settings/` (the pattern Stereolabs' own docker guide
  recommends). `ZED_SDK_DISABLE_DOWNLOAD=1` (env var present in `libsl_zed.so`) then
  hard-disables any download attempt. The two ZEDX `.isp` sensor profiles
  (`zedx_ar0234.isp`, `zedx_imx678.isp`, ~200 KB total, absent from the runtime image,
  present in devel) should ship the same way — the names are compiled into
  `libsl_zed.so`, and shipping them removes the download question. AI-model downloads
  only trigger on NEURAL depth modes — depth NONE (the standing constraint) keeps the
  offline box clean.
- **Save→load arm64 assertion effectively resolved**: in-sandbox `docker save`→`rmi`→
  `docker load` of the arm64 ZED image round-trips with `Architecture=arm64` intact
  (docker 29). Docs: `docker load` restores images+tags; `pull --platform` on the
  classic store is honored (the sandbox platform deception is containerd-store
  specific). New P3 requirement discovered: pulling our arm64-only tree-SHA tags on the
  amd64 host errors without `--platform linux/arm64` (or a digest pin) — default-mode
  image acquisition must use one of the two. Nuance: a digest-ref-only image loses
  `RepoDigests` metadata through save/load; the tree-SHA *tagged* flow is unaffected.
- **ZED devel per-arch digest resolved and COPY source verified** (for P4.1):
  `5.2-tools-devel-jetson-jp6.1.0` index is `d23d3300…`, linux/arm64 manifest is
  `bb950068…`; pulling it and listing (create+cp) shows
  `/usr/local/zed/firmware/ZEDX/` holds exactly `zedx_ar0234.isp` +
  `zedx_imx678.isp` — the multi-stage COPY source is confirmed on the real image.
- **calib.stereolabs.com serves HTTP 200 placeholders for unknown serials** (for
  P4.2, verified 2026-09-23): a bogus SN returns 200 with a 169-byte all-zero conf,
  so `curl -f` cannot validate the serial. The installer validates the fetched conf
  directly — a non-zero `fx` in any section — and rejects the placeholder loudly.
- **ZED Box Mini port map** (researched 2026-09-23 from Stereolabs docs + store):
  2× GMSL2 FAKRA-Z, 1× USB 3.0 Type-A (host-only, 5 Gbps), 1× GbE RJ45, 1× micro-USB
  2.0 Type-B ("system flashing & OTG"; serial console in non-recovery mode per docs),
  1× HDMI 1.4, sync in/out, CAN/UART/GPIO header. **No USB-C port exists** — the
  zed-capture AGENTS "USB-C OTG" phone-link claim is a doc error (P7.3 fixes); the
  README's "phone → USB-A" is the plausible bench truth (7.1b confirms). The micro-USB
  cable ships in the box with every unit.
- **Host APIPA fallback failed on the operator laptop** (bench, 2026-09-23): after
  deleting the `zedbox` profile, NM created no auto ethernet profile and `enp5s0` held
  no address for minutes (carrier up, no connection). The "host half resolved by docs"
  claim for open item 2 is disproven by observation — real hosts may never self-assign.
  This, plus the public-kit goal, is the root cause of the P7 transport pivot.

**Open — bench verification gate (P1, operator + box; items gate their phases)**
1. ~~Operator-host sandbox → `169.254.0.1` reachability~~ **Resolved — NO by default**
   (laptop ruleset read, verified list): coi explicitly rejects sandbox→link-local per
   session, and the old 100.64 path never carried sandbox deploys either (nm-shared
   FORWARD blocks new forwarded connections). Deploy path = host shell, zero plumbing;
   sandbox→box = one-time rule pair (§7b). The item-1 manual-NM-profile fallback is not
   needed for host deploys — host APIPA requires no profile at all.
2. Host APIPA timing: unconfigured port + cable + box → address assigned within ~60s;
   factory box likewise falls back to APIPA on DHCP failure. **Gates P2.**
   Status: host half resolved by docs (45s DHCP timeout + link-local fallback). Factory
   box half: expected yes (NM on JP6), unconfirmed — observe during first-contact testing.
3. ~~Firmware bin presence~~ **Resolved — no ZED X firmware exists** (see verified list);
        nothing to extract or flash. What remains of this item is the offline-open half,
        which is open item 4 unchanged.
4. Offline open on SDK 5.2 + ZED X: `Camera.open()` succeeds with no default route,
   calibration served from EEPROM, no download attempted. **Gates P4.**
   Status: mechanism resolved by research (verified list) — stock 5.2 fails offline; with
   a seeded `settings/SN*.conf` + the two `.isp` files + `ZED_SDK_DISABLE_DOWNLOAD=1` it
   is expected to pass on any SDK/camera vintage. Bench item reduces to: confirm open()
   offline with seeded artifacts (one container run, no install).
5. `docker save` of a first-party tree-SHA tag on the host → `docker load` on box →
   `docker image inspect` reports `arm64` (single-platform manifest assertion). **Gates P3
   sign-off.**
   Status: resolved by docs + in-sandbox round trip (verified list); box-side load is
   native-arch and trivial — observe as a formality during P6. Note the new P3
   requirement: host pulls of arm64-only tags need `--platform linux/arm64` or digest
   pins.

## 5. Phases

### P1 — bench verification gate (no repo commits; record results in §4)

- [x] 1.1 Items 1–2 above (networking spine). Fallback if 1 fails: option-2 manual
      profile documented in `scripts/AGENTS.md`, spine degrades to "static profile owned
      by operator", P2 adjusted accordingly.
      Resolved: item 1 — sandbox→box is NO by default; deploys run from the host shell,
      sandbox path = §7 rule pair, no NM profile needed anywhere (option-2 fallback moot,
      §8). Item 2 — host half resolved by docs (45s DHCP timeout + APIPA fallback); the
      factory-box APIPA observation is re-homed to first contact at P6.1 and is
      non-blocking: if a factory box does NOT self-assign, virgin-box discovery gets a
      documented one-time manual step instead of the ARP scan. P2 proceeds.
- [x] 1.2 Items 3–4 (firmware + offline open).
      Resolved: item 3 — no ZED X firmware exists (§4); item 4 — risk retired by the
      seeding design (calibration source #1 + `ZED_SDK_DISABLE_DOWNLOAD`); the seeded
      offline-open confirm is re-homed to P6.
- [x] 1.3 Item 5 plus: resolve per-arch arm64 manifest digests for loki/alloy
      (`docker buildx imagetools inspect <mirror-ref>` → `linux/arm64` manifest digest)
      and have the new `.env.lock` values ready.
      Resolved: digests recorded in §4 (loki `4c28f6be…`, alloy `08b4fe15…`); item 5
      resolved by docs + in-sandbox round trip — the box-side observation rides P6.

### P2 — networking rework (code commit: `Rework install networking to deterministic link-local`)

- [x] 2.1 `constants.py`: `BOX_IP = "169.254.0.1"`, delete host-side constants, add
      discovery constants (probe window, ARP-scan bits).
- [x] 2.2 Delete `host_setup.py`; `orchestrator.py` drops `share_host_internet()`.
- [x] 2.3 `box_install.py`: replace DHCP claim with APIPA discovery + askpass bootstrap
      at the discovered address + scheduled flip to `manual 169.254.0.1/16` (gateway/DNS
      cleared; reuse the `systemd-run` pattern). Extend the static-IP probe window.
- [x] 2.4 Delete the box gateway/DNS block. The box ends install with: one static
      link-local address, no default route.
- [x] 2.5 ruff + basedpyright green; `bashrun` guard on new shell lines (no `||`/pipes
      outside `bash_pipe`).

### P3 — image acquisition (code commit: `Ship box images from the host instead of the box pulling`)

- [x] 3.1 `.env.lock`: `LOKI_DIGEST`/`ALLOY_DIGEST` become the per-arch arm64 manifest
      digests from 1.3. Update the lock-update procedure note (scripts/AGENTS.md, P5).
- [x] 3.2 Default mode `_acquire_images`: host pulls the three first-party tree-SHA tags
      + two stock per-arch-digest refs from the mirror (all five with
      `--platform linux/arm64` or as digest refs — plain tag pulls error on the amd64
      host), then `docker save <all five> | gzip | ssh … 'gunzip | docker load'` (one
      tar, gzip — guaranteed on the box). Compose `.env` image refs unchanged (same
      tags/digests).
- [x] 3.3 `--build` branch: unchanged except the registry address is the host's current
      APIPA address on the cable NIC (discover at run time), and the
      insecure-registries diff/rewrite already handles churn-on-change.
- [x] 3.4 Delete `_pull_image_on_box` (no box-side pulls in default mode).

### P4 — SDK artifact seeding + offline warmup (code commit: `Seed calibration and ISP profiles for offline camera open`)

- [x] 4.1 Bake the ZEDX `.isp` sensor profiles into the service image: add the
      `5.2-tools-devel-jetson-jp6.1.0` tag to `x-base-images` (new `.env.lock` key
      `ZED_DEVEL_DIGEST`, per-arch arm64 manifest digest — mirror-images then carries
      it; same distribution posture as the SDK already inside our public images) and
      multi-stage `COPY --from=<devel-stage> /usr/local/zed/firmware/ZEDX/` into the
      zed-capture image at the same path.
- [x] 4.2 Seed the per-camera calibration at install: read the camera serial on the box
      (physical label or an on-box diagnostic run — settle at implementation), fetch
      `https://calib.stereolabs.com/?SN=<serial>` on the host (which has internet),
      scp beside the other seeded files; `compose.rig.yml` bind-mounts it at
      `/usr/local/zed/settings/` and sets `ZED_SDK_DISABLE_DOWNLOAD=1` in the zed
      service environment. No SDK 5.3 bump and no firmware steps — no ZED X firmware
      exists, and the seeded file is calibration source #1 on every SDK version (§4).
- [x] 4.3 Warmup step stays as an offline assertion: camera open must succeed with no
      default route. Failure is loud, names the missing artifact (calibration), and
      blocks install completion (no silent deferral to first capture).

### P5 — docs (prose commits: `Update agent docs and README for offline link-local installs`)

- [x] 5.1 `scripts/AGENTS.md`: rewrite image-acquisition + constraints sections —
      delete host-networking-ownership and RFC 6598 lines; add zero-host-config link-local
      spine, APIPA timing, discovery flow, per-arch-digest lock procedure, calibration
      seeding; sudoers-dormancy / USB device-mode / control-master lines stay.
- [x] 5.2 `docker/zed-capture/AGENTS.md`: networking section rewrite (two paths:
      laptop link-local deploy + AOA; delete "outbound internet" claims, the RFC 6598
      paragraph, and the `--host` ghost). While in the file: fix the restart-policy drift
      (doc says `on-failure`; compose.rig.yml says `restart: "no"` with the newer
      dockerd-auto-start rationale — doc updates to match code).
- [x] 5.3 `README.md:22` "the install tooling configures the link" → the tooling
      configures nothing on the host; plug in a cable. Root `AGENTS.md`: adjust the
      `install-zed` line if it implies host networking.
      Resolved: root `AGENTS.md`'s install-zed line makes no host-networking claim —
      no change needed there. `docker/aoa-bridge/AGENTS.md` also carried a stale
      `100.64.0.1` ssh example and a local-registry-only shipping claim — both fixed
      in the P5 commit.
- [x] 5.4 Record P1 bench results (§4) as resolved.

### P6 — bench validation + migration (no repo commits beyond checkbox flips)

**Superseded 2026-09-23 by P7** — this phase validated the ethernet topology the micro-B
ruling retires. The surviving items are folded into 7.4 (validation, reshaped for
micro-B) and 7.3 (pulsar ssh_targets touch-up). 6.2's box migration is moot for
micro-B-only boxes; its host-cleanup half rides with `migrate-zed-box.sh` until the
operator's laptop is confirmed clean (7.3).

- [ ] 6.1 Fresh-virgin-box install in default mode; then `--build` install. Checklist
      mirrors the extraction plan's gate: stack healthy, box-Loki queryable on-box, phone
      AOA link + log drain functional, warmup passed offline (this is the seeded
      offline-open confirm from 1.2), box has no default route (`ip route` shows only
      `169.254.0.0/16 dev …`). First contact doubles as the factory-box APIPA
      observation from 1.1: note whether the ARP-scan discovery finds the virgin box.
- [ ] 6.2 Migration of the existing box + host per §7 (one time).
- [ ] 6.3 Operator: update pulsar config `ssh_targets.zed-box.host` → `169.254.0.1`,
      re-run `uv run sandbox authorize zed-box`, confirm `ssh zed-box` from a sandbox —
      via the §7 rule pair if the coi-generated target rules don't materialize or
      arrive shadowed. Deploys themselves run from the host shell (§9).

### P7 — micro-B-only transport pivot (supersedes the ethernet spine; a fresh session starts here)

The install/deploy channel becomes the micro-B OTG port in CDC-ethernet gadget mode:
the box configures the host (driverless NIC, deterministic gadget address, DHCP served
by the box), so no host-side networking state — NM profiles, APIPA fallback, VPNs,
link-local quirks — can ever block an install. Rationale and ruling in §9. Everything
downstream of "can I ssh the box" (askpass bootstrap, sudoers, deb-pinned docker,
appliance strip, save|gzip|ssh load shipping, calibration seeding, offline-open
assertion) carries over unchanged. The factory box currently on the operator's bench
(the one that exposed the host-APIPA failure, §4) is the 7.1 subject.

- [ ] 7.1 Bench gate on the physical box (operator; no repo commits; record in §4;
      items gate their phases).
      a. Stock JP6.1 micro-B gadget behavior: what `nv-l4t-usb-device-mode.service`
      actually brings up on the Mini (serial only / mass-storage / CDC `usb0`
      @192.168.55.1) and what a laptop sees. Decide the gadget config we persist:
      CDC function choice (NCM preferred for cross-OS, ECM fallback), keep the serial
      console if the composite allows it, and the subnet — stock 192.168.55.0/24 is
      RFC1918, which coi restricted mode blocks for sandbox-originated deploys; rekeying
      the gadget to non-RFC1918 (e.g. 100.64.0.1/24) preserves that option — operator
      picks (public users are unaffected either way).
      b. AOA port truth: confirm the phone operates from the Type-A port (README's
      claim; the zed-capture doc's "USB-C" is a ghost — no such port exists) and that
      AOA on Type-A coexists with the gadget service left permanently ENABLED on
      micro-B (the disable step's original rationale is devkit-era or misattributed).
      If AOA actually requires the micro-B port, STOP — one port cannot do gadget and
      AOA host simultaneously; escalate to the operator before any code.
      c. First contact over micro-B from the laptop: host NIC appears, host gets an
      address from the box, `ssh user@<gadget-ip>` succeeds with factory creds; time
      the link bring-up.
- [ ] 7.2 Code (commit: `Pivot install transport to the micro-B gadget port`):
      constants rekey (gadget address → `BOX_SSH_TARGET`, seconds-scale probe window);
      `_box_reachable_at_static_ip` → gadget-address probe (loop shape unchanged);
      ethernet discovery deleted wholesale — `_claim_box_via_apipa`,
      `_apipa_interfaces`, `_discover_box_address`, `_scan_for_box`, the scheduled
      flip + `NO_BOX_WIRED_CONNECTION` machinery, discovery constants, and its three
      messages (~150 lines); the box's ethernet keeps factory state (no static
      link-local config anywhere); stop disabling `nv-l4t-usb-device-mode` — replace
      with the 7.1a gadget configure-and-persist; `--build` registry path unchanged
      (`host_ip` = `$SSH_CLIENT` over `usb0`); keep the no-default-route tripwire and
      the offline camera-open assertion; ruff + basedpyright green.
- [ ] 7.3 Docs (commit: `Document micro-B installs; retire the ethernet spine`):
      README quick start (the cable ships in the box, zero host configuration, delete
      the APIPA-latency paragraph), `scripts/AGENTS.md` (delete spine/discovery/APIPA
      timing sections; add the gadget section incl. `--build`-over-USB2 iteration
      cost), `docker/zed-capture/AGENTS.md` (fix the "USB-C OTG" ghost; phone =
      Type-A; micro-B = deploy + serial console; delete the link-local deploy path),
      root `AGENTS.md` install-zed line stays accurate; pulsar `ssh_targets.zed-box`
      example → gadget address (§8 follow-up); delete `migrate-zed-box.sh` +
      `diagnose-zed-box.sh` once the operator's laptop cleanup is confirmed (until
      then the migrate script's host-cleanup half remains the operator's tool).
- [ ] 7.4 Bench validation (P6 reshaped; no repo commits beyond checkbox flips):
      virgin-box install with **no ethernet cable attached at all** (micro-B only):
      stack healthy, box-Loki queryable on-box, phone AOA link + log drain functional
      on Type-A while the gadget idles, warmup/offline open passed, `ip route` shows
      no default, unplug/replug micro-B → idempotent re-run; then `--build` over
      micro-B; then a single-layer app-update round-trip (the update flow the public
      actually rides). Note USB2 throughput for the record.

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

### Sandbox→box plumbing (operator, once per host, only if agent-driven deploys are wanted)

```bash
sudo iptables -I FORWARD 1 -s 10.250.250.0/24 -d 169.254.0.1 -j ACCEPT
sudo iptables -I FORWARD 2 -d 10.250.250.0/24 -s 169.254.0.1 -m conntrack \
  --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -t nat -I POSTROUTING 1 -s 10.250.250.0/24 -d 169.254.0.1 -j MASQUERADE
```

Masquerade is mandatory — the box has no route back to the sandbox subnet, so replies
must return to the host's cable-NIC APIPA address. Head insertion keeps the rules above
coi's per-session range rejects; coi regenerates only its own per-sandbox rules, but
probe from a sandbox after the next session starts to confirm nothing reordered them.
Optionally try the ssh_targets route first (set `zed-box.host` to `169.254.0.1`, start a
new sandbox session, `uv run sandbox authorize zed-box`): if the installed coi version
generates ordered per-target rules, the manual pair is unnecessary — the shadowed
`10.0.0.1:22` pair in the 2026-09-23 dump suggests it does not (or mis-orders them;
worth a coi bug report either way — see §8).

## 8. Follow-ups deliberately not built

- `--host <target>` shared-LAN override (doc ghost removed in P5; build only if needed).
- Option-2 manual NM profile fallback: moot — item 1 resolved without it (host deploys
  need no profile; the sandbox path uses the §7 rule pair).
- Report the shadowed per-target rules to coi: the `10.0.0.1:22` accept+masq pair sits
  after the per-sandbox range rejects and can never match. If coi generates these from
  `ssh_targets`, target allows must be inserted above the rejects.
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
- **`plan.md` tracked on the branch** (operator ruling; differs from the extraction repo's
  untracked convention). Delete when the last checkbox lands.
- **Deploy origin = host shell by default** (resolved 2026-09-23 by the laptop ruleset
  read): coi restricted mode rejects sandbox→link-local per session, and the old 100.64
  path never carried sandbox deploys anyway (nm-shared FORWARD blocks new forwarded
  connections). Sandbox→box stays available via the documented §7 rule pair — never
  built into the installer.
- **P4 redesigned from firmware to seeding** (operator-approved 2026-09-23, after
  research): no ZED X firmware exists (Stereolabs-confirmed — no fw updates for ZED X /
  X Mini / X One). Offline camera open is enabled by baking the two ZEDX `.isp` profiles
  into the service image (devel build stage) and seeding the per-SN factory calibration
  conf fetched once on the host. SDK stays 5.2: the 5.3 EEPROM path needs post-May-2026
  cameras or a one-time online `--dc` session on the box, and a bump drags base-image,
  pyzed, and actor-drift cost — a separate decision with its own bench validation.
- **Camera serial source = operator prompt off the physical label** (P4.2
  implementation ruling): every on-box serial read path goes through `Camera.open()`,
  which is exactly the call that fails offline before the calibration is seeded — a
  diagnostic open cannot bootstrap itself. The prompt runs once per box; the seeded
  file makes later installs skip it (idempotency check on `SN*.conf`).
- **Transport pivot: micro-B only, permanently** (operator ruling 2026-09-23, after the
  host-APIPA bench failure §4 and the public-kit requirement): install/deploy/debug rides
  the micro-B OTG port in CDC-ethernet gadget mode; the box configures the host, so no
  host-side networking can block an install, and the needed cable ships with every unit
  (USB2 speeds: minutes for a one-time install, seconds-to-a-minute for layer updates —
  acceptable; `--build` iteration still functions over it). Ethernet support is deleted,
  not dual-run: the APIPA discovery stack is one family of failure modes with no
  population that needs it once micro-B exists, and the box's ethernet keeps factory
  state. Type-A stays the AOA phone port. Supersedes the §1 link-local spine ruling;
  P6 folds into P7. A dual-transport option was considered and rejected on
  carrying-cost grounds (~120 lines plus the NM/APIPA failure family forever).
