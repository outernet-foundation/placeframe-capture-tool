# scripts/

Thin workspace member carrying `install-zed`, the end-to-end SSH deploy of the ZED-box appliance stack. Entry point: `scripts.install_zed.orchestrator:app`, invoked as `uv run install-zed` from the repo root.

## Image acquisition

Three first-party images (`zed-capture`, `aoa-bridge`, `aoa-gateway`) are cross-built arm64 from `compose.bake.yml` — pushed to ghcr by CI (default install mode pulls them) or baked into a transient host-local registry (`--build`, layer-aware pulls across the cable). The two observability images are **stock** mirror pulls (`ZED_STOCK_IMAGES`), digest-pinned from `.env.lock` in both modes — never built locally. `ZED_SERVICES` lists only the three built services; `compute_service_shas` (docker-devkit) keys their tree-SHA tags.

## Constraints

- **First-contact bootstrap + `SUDOERS_RULE` dormancy coupling.** A virgin Stereolabs box has neither the deploy key nor passwordless sudo, and sudo over ssh has no TTY to prompt on. `_ensure_key_access` in `install_zed/box_install.py` is the bootstrap; its dormancy guard probes `sudo -n systemctl --version` **because that command is in `SUDOERS_RULE`'s list** — `sudo -n true` would be denied even on a bootstrapped box, making the guard never sleep. Corollary: removing a command from `SUDOERS_RULE` (`install_zed/constants.py`) silently breaks the guard's dormancy — keep the guard's probe inside the rule's list. The askpass mechanics and the stdin-tmpfile sudoers dance are documented on `_bootstrap_box_access` — that block comment is the source of truth.
- **USB device-mode.** `install-zed` disables L4T's `nv-l4t-usb-device-mode.service` (pins the USB-C port as a peripheral) so the port is free for AOA host duty. Idempotent on every run.
- **The box subnet sits in RFC 6598, not RFC1918.** `100.64.0.0/24` (Shared Address Space, the Tailscale range) — COI-sandboxed agent containers enforce default-deny on RFC1918 destinations; a box outside RFC1918 is reachable from a sandbox via its `0.0.0.0/0` allow rule without weakening LAN isolation.
- **`install-zed` owns the host-side networking the box depends on**: the `zedbox` NetworkManager connection at `100.64.0.2/24`, persistent `ip_forward` sysctl, firewalld trusted-zone source + masquerade. A fresh-Ubuntu host gets a working box→internet path from one invocation.
- **SSH control-master multiplexer** throughout (single TCP connection reused; socket torn down in a `finally`).
- The appliance strip (masked units, the AOA dialog-respawn rationale), the DHCP first-contact claim, and the systemd/camera-daemon ordering are documented in block comments inside `box_install.py` — those comments are the source of truth; this file does not duplicate them.

## Debugging: zed-box SSH access

`ssh zed-box` from a sandbox slot uses the keypair at `/home/code/.ssh-targets/zed-box/id_ed25519`; if it fails with `Permission denied (publickey)`, the sandbox key was never authorized on the box. Run `uv run sandbox authorize zed-box` from the operator's host (once per box/sandbox pair). `install-zed` only installs the operator's personal key — the two paths are independent.
