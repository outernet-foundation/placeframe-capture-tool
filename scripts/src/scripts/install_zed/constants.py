from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ZedService:
    # Image base name and compose.bake.yml target — the same string by
    # construction.
    name: str
    # Env var compose.rig.yml uses to override the image (`${X:-default}`). Asymmetric
    # with name (`zed-capture` → `ZED_IMAGE`, not `ZED_CAPTURE_IMAGE`), so listed explicitly.
    image_env: str
    # Key into the dict returned by `compute_service_shas`.
    sha_key: str


@dataclass(frozen=True)
class StockImage:
    # Mirror reference without the digest suffix; the digest env value from
    # .env.lock (`@sha256:...`) appends to form the full pullable reference.
    reference: str
    # Key into .env.lock carrying that digest suffix.
    digest_env: str


# Every first-party image the box runs is cross-built (arm64) by
# `install-zed --build` and pushed to the host's local registry, or pulled
# from ghcr.io otherwise.
ZED_SERVICES: tuple[ZedService, ...] = (
    ZedService("zed-capture", "ZED_IMAGE", "ZED_CAPTURE_SHA"),
    ZedService("aoa-bridge", "AOA_BRIDGE_IMAGE", "AOA_BRIDGE_SHA"),
    ZedService("aoa-gateway", "AOA_GATEWAY_IMAGE", "AOA_GATEWAY_SHA"),
)

# Observability stock images consumed straight from the org mirror,
# per-arch arm64 manifest digests from .env.lock — never built locally,
# pulled on the host and shipped to the box in both install modes.
ZED_STOCK_IMAGES: tuple[StockImage, ...] = (
    StockImage("ghcr.io/outernet-foundation/mirror/docker.io/grafana/loki", "LOKI_DIGEST"),
    StockImage("ghcr.io/outernet-foundation/mirror/docker.io/grafana/alloy", "ALLOY_DIGEST"),
)

# Transport tag pinned onto digest-pulled stock images before `docker save`:
# a tagless image loses RepoDigests through save/load, and compose resolves
# the stock refs by digest on the box.
STOCK_IMAGE_SHIP_TAG = "placeframe-ship"

REPO_ROOT = Path(__file__).resolve().parents[4]
BAKE_FILE = REPO_ROOT / "compose.bake.yml"
COMPOSE_SOURCE = REPO_ROOT / "compose.rig.yml"
SYSTEMD_UNIT_SOURCE = REPO_ROOT / "docker" / "zed-capture" / "placeframe-zed.service"
WAIT_FOR_ZED_CAMERA_SOURCE = REPO_ROOT / "docker" / "zed-capture" / "wait_for_zed_camera.py"
LOKI_BOX_CONFIG_SOURCE = REPO_ROOT / "docker" / "zed-capture" / "box.yaml"
ALLOY_CONFIG_SOURCE = REPO_ROOT / "docker" / "zed-capture" / "config.alloy"
ENV_LOCK_FILE = REPO_ROOT / ".env.lock"
REMOTE_DIR = "~/.placeframe"
REMOTE_COMPOSE = f"{REMOTE_DIR}/compose.rig.yml"
REMOTE_WAIT_FOR_ZED_CAMERA = f"{REMOTE_DIR}/wait_for_zed_camera.py"
REMOTE_LOKI_CONFIG = f"{REMOTE_DIR}/box.yaml"
REMOTE_ALLOY_CONFIG = f"{REMOTE_DIR}/config.alloy"
# Box-side source of the compose bind mount into the container's
# /usr/local/zed/settings — where the seeded per-camera calibration lives.
ZED_SETTINGS_DIR = "/usr/local/zed/settings"
# Stereolabs' factory-calibration service; the only artifact install-zed
# ever fetches from stereolabs.com, fetched once on the host at seed time.
CALIBRATION_DOWNLOAD_URL = "https://calib.stereolabs.com/?SN={serial}"
SSH_SOCKET = "/tmp/install-zed-ssh-%C"
SSH_MUX = f"-o ControlMaster=auto -o ControlPath={SSH_SOCKET} -o ControlPersist=120"
SSH_KEY = Path.home() / ".ssh" / "id_ed25519"
GHCR_BASE = "ghcr.io/outernet-foundation/placeframe-capture-tool"

# Micro-B OTG transport. nv-l4t-usb-device-mode brings the port up as a
# CDC-ethernet gadget at the stock L4T address (192.168.55.1) and serves
# DHCP to the host over the cable — the box configures the host, so no
# host-side networking state exists to manage or fail. Stock config is
# kept verbatim: the address is deterministic, and rekeying the subnet
# buys nothing while restricted-mode sandbox filters reject 100.64.0.0/10
# exactly like RFC1918.
BOX_IP = "192.168.55.1"
BOX_SSH_TARGET = f"user@{BOX_IP}"

DOCKER_DEB_BASE = "https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/arm64"
DOCKER_DEBS = [
    "containerd.io_2.2.2-1~ubuntu.22.04~jammy_arm64.deb",
    "docker-ce-cli_29.3.1-1~ubuntu.22.04~jammy_arm64.deb",
    "docker-ce_29.3.1-1~ubuntu.22.04~jammy_arm64.deb",
    "docker-buildx-plugin_0.33.0-1~ubuntu.22.04~jammy_arm64.deb",
    "docker-compose-plugin_5.1.1-1~ubuntu.22.04~jammy_arm64.deb",
]

REGISTRY_IMAGE = "registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"
REGISTRY_PORT = 5000

# The reachability probe polls for this long before concluding the box is
# absent at the gadget address. Gadget link bring-up is seconds-scale —
# driver bind and NetworkManager activation on the host, DHCP served by the
# box — and the window also covers a box that just booted (service start).
BOX_REACHABLE_PROBE_SECONDS = 30

SUDOERS_RULE = (
    "user ALL=(ALL) NOPASSWD: /usr/bin/dpkg, /usr/sbin/usermod, /usr/bin/nvidia-ctk,"
    " /usr/bin/systemctl, /usr/bin/docker, /usr/bin/tee, /usr/bin/install"
)

# Brings the micro-B OTG port up as the CDC-ethernet gadget the install
# itself rides (stock L4T composite: network, serial console, mass-storage).
# install-zed ensures the service is enabled and started; AOA host duty for
# the phone runs on the separate Type-A port, so the two never conflict.
L4T_USB_DEVICE_MODE_UNIT = "nv-l4t-usb-device-mode.service"

APPLIANCE_DEFAULT_TARGET = "multi-user.target"

# System-level units installed by the stock JetPack desktop image that have
# no role on a placeframe appliance. gdm pulls in the entire GNOME session;
# fwupd / packagekit / snapd run unsolicited update + probe traffic;
# geoclue / accounts-daemon / ModemManager / upower are desktop-session
# auxiliaries; cups / bluetooth / whoopsie / apport / unattended-upgrades are
# generic Ubuntu defaults a headless box has no business running.
APPLIANCE_SYSTEM_UNITS_TO_MASK: tuple[str, ...] = (
    "gdm.service",
    "fwupd.service",
    "packagekit.service",
    "snapd.service",
    "geoclue.service",
    "accounts-daemon.service",
    "ModemManager.service",
    "upower.service",
    "cups.service",
    "cups-browsed.service",
    "bluetooth.service",
    "whoopsie.service",
    "apport.service",
    "unattended-upgrades.service",
)

# User-scope units that gnome-session spawns when a desktop user logs in.
# Masking at --global level keeps them off even if a maintenance user shells
# in interactively. The gvfs-*-volume-monitor probers were the proximate
# cause of the AOA dialog-respawn bug — libusb_open + descriptor probes
# against the AOA-mode phone stalled the kernel into a SuperSpeed reset.
APPLIANCE_USER_UNITS_TO_MASK: tuple[str, ...] = (
    "gvfs-udisks2-volume-monitor.service",
    "gvfs-mtp-volume-monitor.service",
    "gvfs-afc-volume-monitor.service",
    "gvfs-gphoto2-volume-monitor.service",
    "evolution-source-registry.service",
    "evolution-calendar-factory.service",
    "evolution-addressbook-factory.service",
    "gnome-software.service",
)

APPLIANCE_BANNER_TEXT = "Placeframe ZED Box - managed remotely, see install-zed.\n"
APPLIANCE_BANNER_PATHS: tuple[str, ...] = ("/etc/issue", "/etc/issue.net", "/etc/motd")
