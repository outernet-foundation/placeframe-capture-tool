ARM64_EMULATION_MISSING = """\
Cross-building arm64 images on this x86 host needs QEMU:
docker run --privileged --rm tonistiigi/binfmt --install arm64
(persists until reboot) — or pull prebuilt images with plain
`uv run install-zed`."""

BOX_HOST_KEY_STUCK = """\
Host-key verification still fails after the installer's known_hosts reset —
not a state the point-to-point cable can produce. Something on this host is
diverting ssh to the gadget address; see .placeframe/logs/install-zed.jsonl."""

BOX_ID_UNRESOLVABLE = "Could not resolve box id: /proc/device-tree/serial-number is empty or missing"

IMAGE_UNRESOLVED_ON_BOX = "Image {image} is missing on the box after the save|load transfer — re-run install-zed."

BOX_HAS_DEFAULT_ROUTE = """\
The box has a default route. Its ethernet port (factory state, no placeframe
role) picking up a gateway is the expected cause — unplug the cable and re-run.
A route via l4tbr0 means the gadget defroute defusal failed — see
.placeframe/logs/install-zed.jsonl."""

CAMERA_SERIAL_UNREADABLE = """\
The camera probe returned no serial line — the install is headless and the
camera is its own serial source, so the camera must be attached and reachable
for install-zed to complete. Attach the camera (FAKRA to port 0) and re-run.
Probe output tail:

{probe_tail}"""

CALIBRATION_PLACEHOLDER = """\
calib.stereolabs.com returned a placeholder (all-zero) calibration for SN
{serial}: the serial does not match a manufactured camera. Check it against
the camera's label and re-run install-zed."""

BOX_LOGIN_PROMPT = "box login password (installs the install-zed SSH key and the passwordless sudo rule)"

FACTORY_LOGIN_REJECTED = "Factory password rejected — the next prompt takes this box's current `user` password."

BOX_UNREACHABLE = """\
No answer at {box_ip} within {timeout_seconds}s. Check the micro-B cable, the
box's power, and that nv-l4t-usb-device-mode.service is active on the box —
a pre-pivot box needs it enabled once over ethernet."""
