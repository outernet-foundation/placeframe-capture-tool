#!/usr/bin/env bash
# Read-only box-side diagnostics for the camera-open failure: daemon unit
# states, the IPC socket directories on the host and inside the container,
# the zed_x_daemon journal, a fresh run of the offline camera-open
# check, and the socket path strings compiled into the ZEDX_Daemon binary
# and the container's SDK libraries. Runs from the operator laptop over the
# installer's own ssh state (.placeframe/ssh/) and changes nothing on
# either side.

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh -F /dev/null \
    -i "$repo_root/.placeframe/ssh/id_ed25519" \
    -o UserKnownHostsFile="$repo_root/.placeframe/ssh/known_hosts" \
    -o StrictHostKeyChecking=accept-new \
    -o LogLevel=ERROR \
    user@192.168.55.1 '
echo "=== daemon unit states ==="
systemctl is-active nvargus-daemon zed_x_daemon
systemctl status zed_x_daemon --no-pager -n 0 | head -8
echo
echo "=== socket directories on the host ==="
ls -la /tmp/camsock/ /tmp/argus_socket/ /tmp/nvscsock/ 2>&1
echo
echo "=== socket directories inside the container ==="
sudo docker compose -f ~/.placeframe/compose.rig.yml exec zed-capture ls -la /tmp/camsock/ 2>&1
echo
echo "=== zed_x_daemon journal (this boot) ==="
journalctl -u zed_x_daemon -b --no-pager | tail -15
echo
echo "=== fresh camera-open check ==="
sudo docker compose -f ~/.placeframe/compose.rig.yml exec zed-capture python -c "import pyzed.sl as sl; c = sl.Camera(); p = sl.InitParameters(); e = c.open(p); c.close(); raise SystemExit(0 if e == sl.ERROR_CODE.SUCCESS else 1)" 2>&1
echo "camera-open exit: $?"
echo
echo "=== unix sockets on the host (/proc/net/unix) ==="
grep -iE "zed|cam|argus|nvsc" /proc/net/unix || echo "no matching unix socket paths"
echo
echo "=== unix sockets inside the container (/proc/net/unix) ==="
sudo docker compose -f ~/.placeframe/compose.rig.yml exec zed-capture grep -iE "zed|cam|argus|nvsc" /proc/net/unix 2>&1 || echo "no matching unix socket paths in the container"
echo
echo "=== socket paths the container can see ==="
sudo docker compose -f ~/.placeframe/compose.rig.yml exec zed-capture sh -c "ls -la /tmp/camsock /tmp/argus_socket /tmp/nvscsock; ls /var/run/zed* /run/zed* 2>&1" 2>&1
echo
echo "=== zed_x_daemon unit file ==="
systemctl cat zed_x_daemon.service
echo
echo "=== ZED/imu/argus services and processes on the host ==="
systemctl list-units --type=service --no-pager --no-legend | grep -iE "zed|imu|argus" || echo "no matching units"
ps aux | grep -iE "ZEDX|imu_daemon" | grep -v grep || echo "no matching processes"
echo
echo "=== socket path strings inside ZEDX_Daemon (host binary) ==="
ls -l /usr/sbin/ZEDX_Daemon
grep -aoE "[/A-Za-z0-9_.-]*sock[/A-Za-z0-9_.-]*" /usr/sbin/ZEDX_Daemon | sort -u || echo "unreadable or no matches"
echo
echo "=== socket path strings inside the SDK libraries (container) ==="
sudo docker compose -f ~/.placeframe/compose.rig.yml exec zed-capture find /usr/local/zed/lib -name "*.so*" -exec grep -aoE "[/A-Za-z0-9_.-]*sock[/A-Za-z0-9_.-]*" {} + | sort -u | head -40
echo
echo "=== calibration files on the host ==="
ls -la /usr/local/zed/settings/
echo
echo "=== calibration files inside the container ==="
sudo docker compose -f ~/.placeframe/compose.rig.yml exec zed-capture ls -la /usr/local/zed/settings/
echo
echo "=== settings-path format strings inside the SDK libraries ==="
sudo docker compose -f ~/.placeframe/compose.rig.yml exec zed-capture find /usr/local/zed/lib -name "*.so*" -exec grep -aoE "/usr/local/zed/settings[/A-Za-z0-9_.%-]*" {} + | sort -u | head -20
'
