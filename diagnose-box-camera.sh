#!/usr/bin/env bash
# Read-only box-side diagnostics for the camera-open failure: daemon unit
# states, the IPC socket directories on the host and inside the container,
# the zed_x_daemon journal, and a fresh run of the offline camera-open
# check (its exit status is the timing experiment). Runs from the operator
# laptop over the installer's own ssh state (.placeframe/ssh/). Restarts
# zed_x_daemon (stateless stock unit) once at the end to observe which
# socket it creates.

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
echo "=== full host unix socket table ==="
cat /proc/net/unix
echo
echo "=== /tmp on the host ==="
ls -la /tmp
echo
echo "=== restarting zed_x_daemon and watching for its socket ==="
sudo systemctl restart zed_x_daemon.service
sleep 3
grep -iE "zed|cam|sock" /proc/net/unix || echo "no matching unix socket paths after restart"
ls -la /tmp | grep -iE "zed|sock" || echo "no zed/sock files in /tmp after restart"
journalctl -u zed_x_daemon -n 10 --no-pager
systemctl is-active zed_x_daemon
'
