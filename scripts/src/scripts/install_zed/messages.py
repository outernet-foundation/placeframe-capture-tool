ARM64_EMULATION_MISSING = """\
Cross-building the box's linux/arm64 images on this x86 host needs QEMU
binfmt_misc emulation, but no enabled qemu-aarch64 handler is registered.
Without it the build dies on the first arm64 RUN step with `exec format error`.

Register the emulators on the host (persists until reboot), then retry:
  docker run --privileged --rm tonistiigi/binfmt --install arm64

Or skip local cross-compilation and pull prebuilt images from ghcr.io instead:
  uv run install-zed"""

BOX_ID_UNRESOLVABLE = "Could not resolve box id: /proc/device-tree/serial-number is empty or missing"

IMAGE_PULL_FAILED = """\
Host pull failed for {image}. Either the tag has not been pushed to ghcr.io
yet, or this host has no internet. Push via CI (merge/push to trigger the
build workflow) or build locally with: uv run install-zed --build"""

IMAGE_UNRESOLVED_ON_BOX = """\
Image {image} did not resolve on the box after the save|load transfer — the
tarball lost the reference metadata. Re-run install-zed; if it persists,
keep the install log and report it."""

REGISTRY_PULL_FAILED = """\
Box pull from the host-local registry failed for {image}. Check that the
registry container is running on the host and that the box's
insecure-registries entry matches the host's current link-local address."""

BOX_HAS_DEFAULT_ROUTE = """\
The box has a default route — the offline install posture is broken, and
nothing in install-zed adds one. Remove it on the box
(`nmcli con mod <connection> ipv4.gateway ''`) and re-run."""

CAMERA_SERIAL_PROMPT = "ZED camera serial number (numeric, printed on the camera's label)"

CAMERA_SERIAL_INVALID = """\
The camera serial is the numeric string printed on the camera's label;
got {serial!r}."""

CALIBRATION_DOWNLOAD_FAILED = """\
Fetching the factory calibration from calib.stereolabs.com failed for SN
{serial}. Check this host's internet, then re-run install-zed."""

CALIBRATION_PLACEHOLDER = """\
calib.stereolabs.com returned a placeholder (all-zero) calibration for SN
{serial}: the serial does not match a manufactured camera. Check it against
the camera's label and re-run install-zed."""

CAMERA_OPEN_FAILED = """\
Camera.open() failed with the box offline. The seeded calibration is the
usual missing artifact: check that the serial entered at the prompt matches
the camera's label and that /usr/local/zed/settings/SN*.conf exists on the
box. The install stops here on purpose — a rig that cannot open its camera
offline is not installed."""

BOX_LOGIN_PROMPT = "box login password (installs the install-zed SSH key and the passwordless sudo rule)"

FACTORY_LOGIN_REJECTED = """\
Factory password rejected for {target}: this box's `user` password is not the
Stereolabs factory default. The next prompt takes the box login password to
retry the first-contact bootstrap."""

BOX_STATIC_FLIP_TIMEOUT = """\
The box never answered at {box_ip} after the scheduled renumber. The factory
address it was discovered at is in the box_discovered log line — ssh there and
check `nmcli device status`, then re-run install-zed."""

NO_BOX_DISCOVERED = """\
No ZED Box found on the link-local segment within {timeout_seconds}s
(ARP-scanned: {interfaces}). Check the cable and the box's power. A factory
box self-assigns a 169.254.x.y address ~45s after boot; a box installed by
install-zed already sits at {box_ip} and is found by the static probe."""

NO_HOST_LINK_LOCAL_ADDRESS = """\
No carrier-up ethernet interface holds a self-assigned link-local (169.254.x.y)
address on this host. The host side is zero-config: plug the cable to the box
and wait out NetworkManager's ~45s DHCP timeout — the port then falls back to
a link-local address on its own. install-zed never configures host networking."""

NO_BOX_WIRED_CONNECTION = """\
Could not find a wired (802-3-ethernet) NetworkManager device on the box
during bootstrap. nmcli device list:
{raw}"""
