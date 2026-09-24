import configparser
import json
import platform
import re
import shlex
import socket
import tempfile
import time
from logging import getLogger
from pathlib import Path
from subprocess import CalledProcessError
from typing import NoReturn

import typer
from bashrun.bash import bash, bash_check, bash_output, bash_pipe

from .constants import (
    APPLIANCE_BANNER_PATHS,
    APPLIANCE_BANNER_TEXT,
    APPLIANCE_DEFAULT_TARGET,
    APPLIANCE_SYSTEM_UNITS_TO_MASK,
    APPLIANCE_USER_UNITS_TO_MASK,
    ALLOY_CONFIG_SOURCE,
    BAKE_FILE,
    BOX_IP,
    BOX_REACHABLE_PROBE_SECONDS,
    BOX_SSH_TARGET,
    CALIBRATION_DOWNLOAD_URL,
    CAMERA_OPEN_PROBE,
    COMPOSE_SOURCE,
    DOCKER_DEB_BASE,
    DOCKER_DEBS,
    GHCR_BASE,
    L4T_USB_DEVICE_MODE_CONFIG,
    L4T_USB_DEVICE_MODE_UNIT,
    LOKI_BOX_CONFIG_SOURCE,
    REGISTRY_IMAGE,
    REGISTRY_PORT,
    REMOTE_ALLOY_CONFIG,
    REMOTE_COMPOSE,
    REMOTE_DIR,
    REMOTE_LOKI_CONFIG,
    REMOTE_WAIT_FOR_ZED_CAMERA,
    SSH_KEY,
    SSH_KNOWN_HOSTS,
    SSH_OPTIONS,
    SSH_SOCKET,
    SSH_TRUST,
    STOCK_IMAGE_SHIP_TAG,
    SUDOERS_RULE,
    SYSTEMD_UNIT_SOURCE,
    WAIT_FOR_ZED_CAMERA_SOURCE,
    ZED_SERVICES,
    ZED_SETTINGS_DIR,
    ZED_STOCK_IMAGES,
)
from .messages import (
    ARM64_EMULATION_MISSING,
    BOX_HAS_DEFAULT_ROUTE,
    BOX_HOST_KEY_STUCK,
    BOX_ID_UNRESOLVABLE,
    BOX_LOGIN_PROMPT,
    BOX_UNREACHABLE,
    CALIBRATION_PLACEHOLDER,
    CAMERA_SERIAL_UNREADABLE,
    FACTORY_LOGIN_REJECTED,
    IMAGE_UNRESOLVED_ON_BOX,
)
from .ssh import ssh_check, ssh_output, ssh_quiet, ssh_run

logger = getLogger(__name__)

# The Stereolabs stock image ships `user` with this factory login password; it
# is public documentation across their install docs and restored on reflash.
# Tried silently before falling back to an operator prompt.
FACTORY_LOGIN = "admin"


def install_box(build: bool, service_shas: dict[str, str], env_lock: dict[str, str]) -> None:
    # Fail before touching the box if the host can't actually cross-build the
    # arm64 images — otherwise the missing prerequisite only surfaces as an
    # opaque `exec format error` mid-build, after the box has been reconfigured.
    if build:
        _ensure_arm64_emulation()

    # The gadget address is deterministic, so reachability needs no discovery:
    # wait out gadget link bring-up (driver bind, NM activation, DHCP served by
    # the box), then bootstrap key access if this is a virgin box.
    logger.info("probing_box_reachability", extra={"box_ip": BOX_IP, "timeout_seconds": BOX_REACHABLE_PROBE_SECONDS})
    deadline = time.monotonic() + BOX_REACHABLE_PROBE_SECONDS
    while not _ssh_port_open(BOX_IP):
        if time.monotonic() >= deadline:
            _abort(BOX_UNREACHABLE.format(box_ip=BOX_IP, timeout_seconds=BOX_REACHABLE_PROBE_SECONDS))
        time.sleep(1)
    _ensure_key_access()

    # Open one SSH connection and reuse it for every command below.
    logger.info("connecting_to_box", extra={"target": BOX_SSH_TARGET})
    bash(f"ssh {SSH_OPTIONS} -fN {BOX_SSH_TARGET}")
    try:
        # Refresh the passwordless-sudo rule. `sudo -n install` overwrites the
        # file with identical content on subsequent runs, so this is naturally
        # idempotent; no content-comparison check is needed. The `-n` flag
        # fails loudly instead of prompting if NOPASSWD isn't in effect,
        # which surfaces a stale or missing rule as a script-fatal error
        # rather than silently degrading to interactive. On an already-
        # bootstrapped box this step's real job is propagating SUDOERS_RULE
        # evolution across installer versions.
        logger.info("refreshing_sudoers_rule")
        ssh_quiet("cat > /tmp/install-zed.sudoers", stdin_text=SUDOERS_RULE + "\n")
        ssh_quiet("sudo -n install -m 0440 -o root -g root /tmp/install-zed.sudoers /etc/sudoers.d/install-zed")
        ssh_quiet("rm /tmp/install-zed.sudoers")

        # Install Docker from pinned .deb URLs (Ubuntu's repo is a moving target).
        if ssh_check("which docker"):
            logger.info("docker_already_installed")
        else:
            logger.info("installing_docker")
            with tempfile.TemporaryDirectory() as temp_directory:
                logger.info("downloading_docker_packages", extra={"count": len(DOCKER_DEBS)})
                for deb_file in DOCKER_DEBS:
                    bash(f"curl -fsSL -o {temp_directory}/{deb_file} {DOCKER_DEB_BASE}/{deb_file}")
                logger.info("transferring_docker_packages", extra={"target": BOX_SSH_TARGET})
                bash(f"scp {SSH_OPTIONS} {temp_directory}/*.deb {BOX_SSH_TARGET}:/tmp/")
            deb_paths = " ".join(f"/tmp/{deb_file}" for deb_file in DOCKER_DEBS)
            box_user = BOX_SSH_TARGET.split("@")[0]
            ssh_quiet(f"sudo dpkg -i {deb_paths}")
            ssh_quiet(f"sudo usermod -aG docker {box_user}")
            ssh_quiet(f"rm {deb_paths}")
            logger.info("docker_installed", extra={"user": box_user})

        # Wire NVIDIA Container Toolkit into dockerd so compose's `runtime: nvidia` works.
        if ssh_check("grep -q nvidia /etc/docker/daemon.json"):
            logger.info("nvidia_runtime_already_configured")
        else:
            logger.info("configuring_nvidia_runtime")
            ssh_quiet("sudo nvidia-ctk runtime configure --runtime=docker")
            ssh_quiet("sudo systemctl restart docker")

        # The gadget service is the transport this install rides. Idempotent:
        # `enable` only symlinks, `--now` only starts an inactive unit, so a
        # live link is never bounced. Reverts the pre-pivot installer's own
        # disable step on boxes that ran it.
        logger.info("ensuring_usb_device_mode_service", extra={"unit": L4T_USB_DEVICE_MODE_UNIT})
        ssh_quiet(f"sudo systemctl enable --now {L4T_USB_DEVICE_MODE_UNIT}")
        _defuse_gadget_default_route()

        # Strip the JetPack desktop to a headless appliance; see _strip_to_appliance.
        _strip_to_appliance()

        # Add the box's hostname to /etc/hosts so sudo doesn't reverse-DNS each call.
        box_hostname = ssh_output("hostname").strip()
        if ssh_check(f"grep -q {box_hostname} /etc/hosts"):
            logger.info("etc_hosts_entry_present", extra={"hostname": box_hostname})
        else:
            logger.info("adding_etc_hosts_entry", extra={"hostname": box_hostname})
            ssh_quiet("sudo tee -a /etc/hosts > /dev/null", stdin_text=f"127.0.0.1 {box_hostname}\n")

        # The host's gadget-side address as the box reaches it ($SSH_CLIENT) —
        # keys the --build registry reference.
        host_ip = ssh_output("echo $SSH_CLIENT").split()[0]

        # Acquire container images: host pulls + save|load across the cable
        # (default), or cross-compile via the local registry (--build). The
        # stock observability images are never built locally — digest-pinned
        # mirror pulls shipped from the host in both modes.
        images = _acquire_images(host_ip, build, service_shas, env_lock)

        # Ship the compose file and supporting scripts. The aoa-alloy /
        # aoa-loki configs ship as files beside the compose file and mount
        # via compose configs: — the stock images carry no baked config.
        logger.info("transferring_compose_file", extra={"source": str(COMPOSE_SOURCE)})
        ssh_quiet(f"mkdir -p {REMOTE_DIR}")
        bash(f"scp {SSH_OPTIONS} {COMPOSE_SOURCE!s} {BOX_SSH_TARGET}:{REMOTE_COMPOSE}")
        bash(f"scp {SSH_OPTIONS} {WAIT_FOR_ZED_CAMERA_SOURCE!s} {BOX_SSH_TARGET}:{REMOTE_WAIT_FOR_ZED_CAMERA}")
        bash(f"scp {SSH_OPTIONS} {LOKI_BOX_CONFIG_SOURCE!s} {BOX_SSH_TARGET}:{REMOTE_LOKI_CONFIG}")
        bash(f"scp {SSH_OPTIONS} {ALLOY_CONFIG_SOURCE!s} {BOX_SSH_TARGET}:{REMOTE_ALLOY_CONFIG}")

        # Jetson hardware-burned serial survives OS reflashes.
        box_id = ssh_output("tr -d '\\0\\n' < /proc/device-tree/serial-number").strip()
        if not box_id:
            _abort(BOX_ID_UNRESOLVABLE)

        # Write the .env that compose reads: built-image refs + every SHA-keyed
        # variable compose.rig.yml references (one per box image; ZED_CAPTURE_SHA
        # also feeds SERVICE_VERSION) + the stock-image ship tags + box
        # hardware id for log tagging. The stock pair is referenced by its
        # transport tag, not the digest pin: docker load synthesizes its own
        # RepoDigest instead of restoring the registry one, so a digest ref
        # cannot resolve on the box — the pin governs the host pull.
        box_shas = {service.sha_key: service_shas[service.sha_key] for service in ZED_SERVICES}
        stock_images = {image.image_env: env_lock[image.image_env] for image in ZED_STOCK_IMAGES}
        stock_ship_tags = {key: _ship_tag(value) for key, value in stock_images.items()}
        env_lines = "".join(f"{key}={value}\n" for key, value in {**images, **box_shas, **stock_ship_tags}.items())
        ssh_quiet(f"tee {REMOTE_DIR}/.env", stdin_text=env_lines + f"ZED_BOX_ID={box_id}\n")

        # Install the systemd unit so the stack auto-starts on boot.
        logger.info("installing_systemd_unit", extra={"unit": "placeframe-zed.service"})
        remote_home = ssh_output("echo $HOME").strip()
        remote_compose_abs = REMOTE_COMPOSE.replace("~", remote_home)
        remote_wait_for_zed_camera_abs = REMOTE_WAIT_FOR_ZED_CAMERA.replace("~", remote_home)
        unit_content = (
            SYSTEMD_UNIT_SOURCE
            .read_text()
            .replace("COMPOSE_PATH", remote_compose_abs)
            .replace("WAIT_FOR_ZED_CAMERA_PATH", remote_wait_for_zed_camera_abs)
        )
        ssh_quiet("sudo tee /etc/systemd/system/placeframe-zed.service > /dev/null", stdin_text=unit_content)
        ssh_quiet("sudo systemctl daemon-reload")
        ssh_quiet("sudo systemctl enable placeframe-zed.service")

        # Start the host-side camera daemons; the container bind-mounts their IPC sockets.
        logger.info("enabling_camera_daemons")
        ssh_quiet("sudo systemctl enable --now nvargus-daemon zed_x_daemon")

        # Direct compose (not `systemctl restart placeframe-zed.service`): the
        # unit's wait_for_zed_camera ExecStartPre would gate the deploy on the
        # daemons' boot timing, which the install's own ordering already
        # handles.
        logger.info("redeploying_compose_stack", extra={"compose": REMOTE_COMPOSE})
        ssh_quiet(f"sudo docker compose -f {REMOTE_COMPOSE} down --remove-orphans")
        ssh_quiet(f"sudo docker compose -f {REMOTE_COMPOSE} up -d")

        # Seed the per-camera factory calibration after the stack is up: the
        # serial probe execs into the running container, and the settings
        # bind is a directory mount — a conf seeded now is visible to the
        # running container without a recreate.
        _seed_camera_calibration()

        # Tripwire: nothing in install-zed adds a default route, and the
        # camera-open assertion below only proves the offline posture if the
        # box actually is offline.
        if ssh_output("ip route show default").strip():
            _abort(BOX_HAS_DEFAULT_ROUTE)

        # Offline camera-open assertion. With the seeded calibration, the
        # baked .isp profiles, and ZED_SDK_DISABLE_DOWNLOAD there is no
        # download path left, so a successful open proves the offline posture
        # end-to-end. Failure is fatal — the propagated SDK error is the
        # diagnostic — rather than deferring a broken rig to first capture.
        logger.info("verifying_offline_camera_open")
        ssh_run(CAMERA_OPEN_PROBE)

        logger.info("install_done")
    finally:
        # Close the SSH multiplexer (otherwise it lingers until ControlPersist expires).
        bash_check(f"ssh -o ControlPath={SSH_SOCKET} -O exit {BOX_SSH_TARGET}")


def _defuse_gadget_default_route() -> None:
    # Stock L4T behavior: runtime-start.sh runs on every gadget link-up (a
    # udev rule fires it) and adds `default gw ${net_ipv4_defroute_router}`
    # pointing at the host. Blanking the config variable is the scripts' own
    # documented way to suppress that, and the runtime guard then never
    # fires — durable across replugs, unlike deleting the route alone. The
    # route already installed by this boot's link-up still gets dropped;
    # never restart the gadget service to achieve that, it would bounce the
    # link the install itself rides.
    config = ssh_output(f"cat {L4T_USB_DEVICE_MODE_CONFIG}")
    if re.search(r"^net_ipv4_defroute_router=$", config, re.MULTILINE):
        logger.info("gadget_default_route_already_defused")
    else:
        logger.info("defusing_gadget_default_route")
        defused = re.sub(r"^net_ipv4_defroute_router=.*$", "net_ipv4_defroute_router=", config, flags=re.MULTILINE)
        ssh_quiet(f"sudo tee {L4T_USB_DEVICE_MODE_CONFIG}", stdin_text=defused)
    if ssh_output("ip route show default dev l4tbr0").strip():
        ssh_quiet("sudo ip route del default dev l4tbr0")


def _strip_to_appliance() -> None:
    # The stock JetPack image boots to a GNOME desktop, but the product flow is
    # cable-to-laptop then install-zed; nobody sits at the box with HDMI and a
    # keyboard. The desktop session is not just dead weight: its volume-monitor
    # probers (gvfs-mtp / gvfs-afc / gvfs-gphoto2 / gvfs-udisks2) call
    # libusb_open and read descriptors against every newly-enumerated USB
    # device. Against an AOA-mode phone those reads stall the kernel's 5s
    # USB_CTRL_GET_TIMEOUT and trip usb_reset_and_verify_device(), which
    # invalidates the accessory FD the user already granted and forces Android
    # to fire a second UsbConfirmActivity dialog inside the app.
    #
    # Four actions strip the premise: (a) set the default target to
    # multi-user.target, dropping gdm and the entire graphical session; (b) mask
    # the consumer-USB / desktop / auto-update system units
    # (APPLIANCE_SYSTEM_UNITS_TO_MASK); (c) --global mask the gvfs + evolution
    # user units (APPLIANCE_USER_UNITS_TO_MASK) so they stay off even if a
    # maintenance user shells in interactively; (d) overwrite the login banners
    # so plugging in HDMI shows a signal, not a black screen. nvargus-daemon and
    # zed_x_daemon are left running — the compose stack binds their IPC sockets.
    #
    # Strip-the-premise was chosen over symptomatic udev VID filtering. A VID
    # filter would silence this one dialog-respawn but leave the whole
    # consumer-USB-monitoring stack running on hardware that has no business
    # running it; the next latent conflict (fwupd auto-upgrading, snapd
    # refreshing, PackageKit holding the apt lock) would land in the same place.
    current_target = ssh_output("systemctl get-default").strip()
    if current_target == APPLIANCE_DEFAULT_TARGET:
        logger.info("appliance_default_target_already_set", extra={"target": current_target})
    else:
        logger.info(
            "setting_appliance_default_target",
            extra={"from": current_target, "to": APPLIANCE_DEFAULT_TARGET},
        )
        ssh_quiet(f"sudo systemctl set-default {APPLIANCE_DEFAULT_TARGET}")

    logger.info("masking_appliance_system_units", extra={"count": len(APPLIANCE_SYSTEM_UNITS_TO_MASK)})
    ssh_quiet(f"sudo systemctl mask --now {' '.join(APPLIANCE_SYSTEM_UNITS_TO_MASK)}")

    logger.info("masking_appliance_user_units", extra={"count": len(APPLIANCE_USER_UNITS_TO_MASK)})
    ssh_quiet(f"sudo systemctl --global mask {' '.join(APPLIANCE_USER_UNITS_TO_MASK)}")

    for banner_path in APPLIANCE_BANNER_PATHS:
        current = ssh_output(f"cat {banner_path}") if ssh_check(f"test -f {banner_path}") else ""
        if current == APPLIANCE_BANNER_TEXT:
            logger.info("appliance_banner_present", extra={"path": banner_path})
        else:
            logger.info("installing_appliance_banner", extra={"path": banner_path})
            ssh_quiet(f"sudo tee {banner_path} > /dev/null", stdin_text=APPLIANCE_BANNER_TEXT)


def _ensure_key_access() -> None:
    # First-contact bootstrap. A virgin box has neither our SSH key nor
    # passwordless sudo, and the steps that would install them (the `sudo -S`
    # bootstrap below, the `sudo -n` rule refresh in install_box) both run
    # over ssh with no TTY — stock sudo refuses to prompt there, so a
    # fresh box dies mid-flight. One password-authenticated session installs
    # both halves: the pubkey into authorized_keys and the SUDOERS_RULE
    # constant into /etc/sudoers.d/install-zed. On every bootstrapped box only
    # the guard runs — no password tried, nothing prompted. The guard probes
    # with a command from SUDOERS_RULE's own list: `sudo -n true` would be
    # denied even on a bootstrapped box (`true` is not in the rule), so a
    # listed no-op is the honest dormancy probe.
    _ensure_box_host_key()
    if bash_check(f"ssh {SSH_TRUST} -o BatchMode=yes -o ConnectTimeout=5 {BOX_SSH_TARGET} sudo -n systemctl --version"):
        return

    if not _bootstrap_box_access(FACTORY_LOGIN):
        typer.echo(FACTORY_LOGIN_REJECTED, err=True)
        password: str = typer.prompt(BOX_LOGIN_PROMPT, hide_input=True)
        _bootstrap_box_access(password)


def _ensure_box_host_key() -> None:
    # TOFU with reset. Host-key pinning defends against network MITM, which
    # the point-to-point micro-B cable cannot carry, and every L4T gadget
    # device answers at this same address — so a mismatch against the
    # installer-owned known_hosts can only mean a different or reflashed
    # box since the last install from this checkout. Resetting the file is
    # zero-collateral (nothing outside the installer reads it); a mismatch
    # surviving the reset is a state the cable topology cannot produce.
    logger.info("recording_box_host_key")
    if _box_host_key_matches():
        return
    logger.info("resetting_box_host_key", extra={"path": str(SSH_KNOWN_HOSTS)})
    SSH_KNOWN_HOSTS.unlink(missing_ok=True)
    if not _box_host_key_matches():
        _abort(BOX_HOST_KEY_STUCK)


def _box_host_key_matches() -> bool:
    # The probe records the host key (accept-new) and needs no privileges;
    # on a virgin box the same connection fails pubkey auth after the key
    # is recorded, which still counts as recorded.
    try:
        bash_output(f"ssh {SSH_TRUST} -o BatchMode=yes -o ConnectTimeout=5 {BOX_SSH_TARGET} true")
    except CalledProcessError as error:
        stderr = error.stderr or ""
        if "Host key verification failed" in stderr:
            return False
        if "Permission denied" not in stderr:
            raise
    return True


def _bootstrap_box_access(password: str) -> bool:
    # The password rides env -> SSH_ASKPASS helper -> ssh's password prompt,
    # never a command line (bashrun logs commands, not stdin/env) and only over
    # the encrypted channel. SSH_ASKPASS_REQUIRE=force (OpenSSH >= 8.4) makes
    # ssh use the helper even with a terminal attached,
    # StrictHostKeyChecking=accept-new auto-accepts the first connection's host
    # key, and PubkeyAuthentication=no forces the password path so a pass
    # actually proves the password. A `Permission denied` on the first call is
    # the one failure that returns False — the caller retries with an
    # operator-entered password; every other failure (transport drop, askpass
    # trouble) raises loudly instead of masquerading as a wrong password.
    public_key = SSH_KEY.with_suffix(".pub").read_text()
    with tempfile.TemporaryDirectory() as temp_directory:
        askpass_helper = Path(temp_directory) / "install-zed-askpass"
        askpass_helper.write_text('#!/bin/sh\necho "$INSTALL_ZED_ASKPASS"\n')
        askpass_helper.chmod(0o700)
        askpass_env = {
            "SSH_ASKPASS": str(askpass_helper),
            "SSH_ASKPASS_REQUIRE": "force",
            "INSTALL_ZED_ASKPASS": password,
        }
        auth_options = f"{SSH_TRUST} -o PubkeyAuthentication=no -o ConnectTimeout=5"
        key_command = (
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        )
        sudoers_stage = "cat > /tmp/install-zed.sudoers"
        sudoers_install = "sudo -S install -m 0440 -o root -g root /tmp/install-zed.sudoers /etc/sudoers.d/install-zed"
        sudoers_cleanup = "rm /tmp/install-zed.sudoers"
        try:
            bash_output(
                f"ssh {auth_options} {BOX_SSH_TARGET} {shlex.quote(key_command)}",
                stdin_text=public_key,
                env=askpass_env,
            )
        except CalledProcessError as error:
            if "Permission denied" not in (error.stderr or ""):
                raise
            return False

        # The rule rides stdin and the same `sudo install` mechanism the
        # refreshing_sudoers_rule step uses — it never passes through a
        # remote shell parse, so SUDOERS_RULE needs no quoting at all.
        bash_output(
            f"ssh {auth_options} {BOX_SSH_TARGET} {shlex.quote(sudoers_stage)}",
            stdin_text=f"{SUDOERS_RULE}\n",
            env=askpass_env,
        )
        bash_output(
            f"ssh {auth_options} {BOX_SSH_TARGET} {shlex.quote(sudoers_install)}",
            stdin_text=f"{password}\n",
            env=askpass_env,
        )
        bash_output(f"ssh {auth_options} {BOX_SSH_TARGET} {shlex.quote(sudoers_cleanup)}", env=askpass_env)
        return True


def _ssh_port_open(address: str) -> bool:
    try:
        with socket.create_connection((address, 22), timeout=2):
            return True
    except OSError:
        return False


def _ensure_arm64_emulation() -> None:
    if platform.machine() in ("aarch64", "arm64"):
        return

    handler = Path("/proc/sys/fs/binfmt_misc/qemu-aarch64")
    if handler.exists() and handler.read_text().startswith("enabled"):
        return

    _abort(ARM64_EMULATION_MISSING)


def _acquire_images(
    host_ip: str, build: bool, service_shas: dict[str, str], env_lock: dict[str, str]
) -> dict[str, str]:
    stock_references = [env_lock[image.image_env] for image in ZED_STOCK_IMAGES]

    if not build:
        images = {
            service.image_env: f"{GHCR_BASE}/{service.name}:{service_shas[service.sha_key]}" for service in ZED_SERVICES
        }
        # The tree-SHA tags are single-platform arm64 manifests, so a plain
        # pull on the amd64 host errors with no matching manifest.
        for image in images.values():
            _pull_image_on_host(image, "linux/arm64")
        first_party_to_ship = list(images.values())
    else:
        # The local registry keeps first-party iteration cheap: pulls are
        # layer-aware, so only changed layers cross the cable.
        if not bash_check("docker container inspect registry"):
            logger.info("starting_local_registry", extra={"port": REGISTRY_PORT})
            bash_output(
                f"docker run -d -p {REGISTRY_PORT}:{REGISTRY_PORT} --name registry --restart unless-stopped"
                f" {REGISTRY_IMAGE}"
            )
        elif bash_output('docker inspect -f "{{.State.Running}}" registry').strip() != "true":
            logger.info("restarting_local_registry")
            bash_output("docker start registry")

        local_images = {
            service.name: f"localhost:{REGISTRY_PORT}/{service.name}:{service_shas[service.sha_key]}"
            for service in ZED_SERVICES
        }
        remote_images = {
            service.image_env: f"{host_ip}:{REGISTRY_PORT}/{service.name}:{service_shas[service.sha_key]}"
            for service in ZED_SERVICES
        }

        logger.info("cross_compiling_images", extra={"bake_file": str(BAKE_FILE)})
        # Mirrors docker-devkit's build verb: the bake env carries the service
        # SHAs plus the full .env.lock — the Dockerfiles' base-image ARGs have
        # no defaults, so a missing key is a hard bake error, not a fallback.
        env_prefix = " ".join(f"{k}={v}" for k, v in {**service_shas, **env_lock}.items())
        set_flags = " ".join(f"--set {service.name}.tags={local_images[service.name]}" for service in ZED_SERVICES)
        bake_targets = " ".join(service.name for service in ZED_SERVICES)
        bash(
            f"env {env_prefix} docker buildx bake -f {BAKE_FILE} {set_flags}"
            f" --push --provenance=false --sbom=false {bake_targets}",
        )

        # Docker treats `localhost` as insecure-by-default for push; the box's
        # daemon needs the box-facing host IP in its insecure-registries. The
        # host's gadget-side DHCP address churns across plugs; the presence check
        # re-runs on every install and appends the current one.
        if ssh_check(f"grep -q {host_ip}:{REGISTRY_PORT} /etc/docker/daemon.json"):
            logger.info("box_insecure_registry_present", extra={"registry": f"{host_ip}:{REGISTRY_PORT}"})
        else:
            logger.info("configuring_box_insecure_registry", extra={"registry": f"{host_ip}:{REGISTRY_PORT}"})
            daemon_config = json.loads(ssh_output("cat /etc/docker/daemon.json").strip())
            registries: list[str] = daemon_config.get("insecure-registries", [])
            registries.append(f"{host_ip}:{REGISTRY_PORT}")
            daemon_config["insecure-registries"] = registries
            ssh_quiet("sudo tee /etc/docker/daemon.json", stdin_text=json.dumps(daemon_config, indent=2))
            ssh_quiet("sudo systemctl restart docker")

        for image in remote_images.values():
            _pull_image_from_registry(image)

        images = remote_images
        first_party_to_ship = []

    # The stock observability images are never built locally; their per-arch
    # digest refs are platform-unambiguous without a flag, and they ship by
    # tarball in both modes.
    for image in stock_references:
        _pull_image_on_host(image)
    _ship_images_to_box(first_party_to_ship, stock_references)
    return images


def _pull_image_on_host(reference: str, platform: str | None = None) -> None:
    logger.info("pulling_image_on_host", extra={"image": reference, "platform": platform})
    platform_option = f"--platform {platform} " if platform else ""
    bash(f"docker pull {platform_option}{reference}")


def _ship_images_to_box(tagged_references: list[str], stock_references: list[str]) -> None:
    # A tarball needs a plain tagged ref per image, and the tag is also the
    # box-side reference for the stock pair: docker load synthesizes its own
    # RepoDigest instead of restoring the registry one, so a digest ref
    # cannot resolve after the cable — the digest pin governs the host pull.
    save_references = list(tagged_references)
    for stock_reference in stock_references:
        tagged_reference = _ship_tag(stock_reference)
        bash(f"docker tag {stock_reference} {tagged_reference}")
        save_references.append(tagged_reference)

    logger.info("shipping_images_to_box", extra={"count": len(save_references)})
    bash_pipe(
        f"docker save {' '.join(save_references)}",
        "gzip",
        f"ssh {SSH_OPTIONS} {BOX_SSH_TARGET} 'gunzip | sudo docker load'",
    )

    # The box is offline: if a reference does not resolve there after the
    # load, compose has no fallback, so the failure must surface now. The
    # checked set is exactly what the box .env hands compose.
    box_references = [*tagged_references, *(_ship_tag(reference) for reference in stock_references)]
    for reference in box_references:
        if not ssh_check(f"sudo docker image inspect {reference}"):
            _abort(IMAGE_UNRESOLVED_ON_BOX.format(image=reference))


def _ship_tag(reference: str) -> str:
    return f"{reference.split('@')[0].rsplit(':', 1)[0]}:{STOCK_IMAGE_SHIP_TAG}"


def _pull_image_from_registry(image: str) -> None:
    logger.info("pulling_image_from_registry", extra={"image": image})
    ssh_run(f"sudo docker pull {image}")


def _seed_camera_calibration() -> None:
    # The box is offline forever, and SDK 5.2 GMSL cameras fail open() with
    # CALIBRATION_FILE_NOT_AVAILABLE unless a local calibration exists — the
    # EEPROM fallback is a 5.3 feature on post-May-2026 cameras. A local
    # settings file is calibration source #1 on every SDK version, so the
    # host (which has internet) fetches the per-SN factory conf once and
    # seeds it into the box path compose bind-mounts at
    # /usr/local/zed/settings. The serial comes from the camera itself: the
    # GMSL init banner prints it even while open() fails on the missing
    # calibration. The install is headless — an unreadable serial is fatal,
    # no label-prompt fallback exists, and the camera is a prerequisite of
    # the closing camera-open assertion anyway. The settings dir accumulates
    # confs from every camera ever attached to the box, so "already seeded"
    # means "the conf for THIS serial exists" — never "any SN*.conf exists".
    # The trailing `2>&1 ; true` merges the banner into the captured stdout
    # and swallows the probe's failure exit (the missing calibration is the
    # expected failure here).
    probe_output = ssh_output(f"{CAMERA_OPEN_PROBE} 2>&1 ; true")
    serial_match = re.search(r"Serial Number: S/N (\d+)", probe_output)
    if serial_match is None:
        _abort(CAMERA_SERIAL_UNREADABLE.format(probe_tail=probe_output.strip()[-400:]))
    serial = serial_match.group(1)

    if ssh_check(f"ls {ZED_SETTINGS_DIR}/SN{serial}.conf"):
        logger.info("camera_calibration_already_seeded", extra={"serial": serial})
        return

    with tempfile.TemporaryDirectory() as temp_directory:
        calibration_path = Path(temp_directory) / f"SN{serial}.conf"
        bash(f"curl -fsSL -o {calibration_path} {CALIBRATION_DOWNLOAD_URL.format(serial=serial)}")

        if not _calibration_is_real(calibration_path):
            _abort(CALIBRATION_PLACEHOLDER.format(serial=serial))

        bash(f"scp {SSH_OPTIONS} {calibration_path} {BOX_SSH_TARGET}:/tmp/")

    ssh_quiet(f"sudo install -D -m 0644 -o root -g root /tmp/SN{serial}.conf {ZED_SETTINGS_DIR}/SN{serial}.conf")
    ssh_quiet(f"rm /tmp/SN{serial}.conf")
    logger.info("camera_calibration_seeded", extra={"serial": serial})


def _calibration_is_real(calibration_path: Path) -> bool:
    # calib.stereolabs.com answers an unknown serial with HTTP 200 and an
    # all-zero placeholder conf, so a non-zero focal length somewhere in the
    # file is the signal that the serial matched a real camera.
    parser = configparser.ConfigParser(interpolation=None)
    parser.read(calibration_path)
    return any(parser.has_option(section, "fx") and parser.getfloat(section, "fx") > 0 for section in parser.sections())


def _abort(message: str) -> NoReturn:
    typer.echo(message, err=True)
    raise SystemExit(1)
