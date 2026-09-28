#!/usr/bin/env bash
# One-time migration of an existing ZED Box install (and its host) from the
# retired 100.64.0.0/24 NAT topology to the offline link-local one: the box
# ends at static 169.254.0.1/16 with no gateway/DNS, the host's NAT state is
# removed, and the host port falls back to zero-config APIPA on the same
# cable. Run on the operator laptop with the box attached by the direct
# ethernet cable: ./migrate-zed-box.sh [--host-only] [<cable-nic>]. The NIC
# argument is only needed if auto-detection fails. --host-only skips the box
# renumber entirely — for a box that never went through the old installer's
# renumber (factory state) and only needs the host's retired state removed.
# Every step checks before changing anything, so a partial run can simply be
# re-run. Delete this script once every box has been migrated.

set -euo pipefail

BOX_OLD_TARGET=user@100.64.0.1
BOX_NEW_IP=169.254.0.1
OLD_SUBNET=100.64.0.0/24

HOST_ONLY=false
if [ "${1:-}" = "--host-only" ]; then
    HOST_ONLY=true
    shift
fi

log() { printf '\n== %s ==\n' "$*"; }
port_open() { timeout 3 bash -c "echo > /dev/tcp/$1/22" >/dev/null 2>&1; }

if $HOST_ONLY; then
    log "skipping the box renumber (--host-only)"
elif port_open "$BOX_NEW_IP"; then
    log "box already reachable at $BOX_NEW_IP - skipping the box renumber"
else
    log "checking the old path (ssh $BOX_OLD_TARGET)"
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$BOX_OLD_TARGET" true; then
        echo "cannot reach the box at 100.64.0.1 - check the cable and retry" >&2
        exit 1
    fi

    NIC="${1:-$(nmcli -t -e no -f NAME,DEVICE con show --active | awk -F: '$1=="zedbox"{print $2; exit}')}"
    if [ -z "$NIC" ]; then
        NIC="$(ip -4 -o addr show | awk '$4=="100.64.0.2/24"{print $2; exit}')"
    fi
    if [ -z "$NIC" ]; then
        echo "could not detect the cable NIC - pass it as the first argument: $0 <nic>" >&2
        exit 1
    fi

    log "detecting the box's NetworkManager connection"
    BOX_DEVICE="$(ssh "$BOX_OLD_TARGET" 'nmcli -t -e no -f DEVICE,TYPE,STATE device' | awk -F: '$2=="ethernet" && $3=="connected"{print $1; exit}')"
    if [ -z "$BOX_DEVICE" ]; then
        echo "no connected ethernet device found on the box" >&2
        exit 1
    fi
    BOX_CONN="$(ssh "$BOX_OLD_TARGET" "nmcli -g GENERAL.CONNECTION device show $BOX_DEVICE" | head -n 1)"
    if [ -z "$BOX_CONN" ]; then
        echo "no NetworkManager connection holds $BOX_DEVICE on the box" >&2
        exit 1
    fi

    log "host: temporary zedbox-migrate profile (100.64.0.2/24) on $NIC"
    if sudo nmcli con show zedbox-migrate >/dev/null 2>&1; then
        sudo nmcli con delete zedbox-migrate
    fi
    sudo nmcli con add type ethernet con-name zedbox-migrate ifname "$NIC" \
        ipv4.method manual ipv4.addresses 100.64.0.2/24
    sudo nmcli con up zedbox-migrate

    log "box: scheduling the renumber to $BOX_NEW_IP/16 (fires 3s after we disconnect)"
    ssh "$BOX_OLD_TARGET" "sudo systemd-run --on-active=3 /bin/sh -c 'nmcli con mod \"$BOX_CONN\" \
ipv4.method manual ipv4.addresses $BOX_NEW_IP/16 ipv4.gateway \"\" ipv4.dns \"\"; \
nmcli con up \"$BOX_CONN\"'"

    log "waiting for the renumber to fire"
    sleep 15
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$BOX_OLD_TARGET" true 2>/dev/null; then
        echo "box still answers at 100.64.0.1 - the renumber did not fire; aborting before host cleanup" >&2
        sudo nmcli con delete zedbox-migrate
        exit 1
    fi
    sudo nmcli con delete zedbox-migrate
fi

log "removing the retired host-side NAT state (no-ops where already gone)"
if sudo nmcli con show zedbox >/dev/null 2>&1; then
    sudo nmcli con delete zedbox
fi
if [ -f /etc/NetworkManager/conf.d/zedbox-no-auto-default.conf ]; then
    sudo rm /etc/NetworkManager/conf.d/zedbox-no-auto-default.conf
    sudo nmcli general reload
fi
if [ -f /etc/sysctl.d/99-zedbox.conf ]; then
    sudo rm /etc/sysctl.d/99-zedbox.conf
    sudo sysctl --system
fi
if command -v firewall-cmd >/dev/null 2>&1; then
    FIREWALL_DIRTY=false
    if sudo firewall-cmd --permanent --zone=trusted --query-source="$OLD_SUBNET" >/dev/null 2>&1; then
        sudo firewall-cmd --permanent --zone=trusted --remove-source="$OLD_SUBNET"
        FIREWALL_DIRTY=true
    fi
    if sudo firewall-cmd --permanent --zone=public --query-masquerade >/dev/null 2>&1; then
        sudo firewall-cmd --permanent --zone=public --remove-masquerade
        FIREWALL_DIRTY=true
    fi
    if [ "$FIREWALL_DIRTY" = true ]; then
        sudo firewall-cmd --reload
    fi
fi
for FLAG in -s -d; do
    if sudo iptables -C DOCKER-USER "$FLAG" "$OLD_SUBNET" -j ACCEPT >/dev/null 2>&1; then
        sudo iptables -D DOCKER-USER "$FLAG" "$OLD_SUBNET" -j ACCEPT
    fi
done

log "waiting for the host port to self-assign a link-local address (~45s DHCP timeout)"
for _ in $(seq 1 90); do
    if port_open "$BOX_NEW_IP"; then
        echo ""
        echo "migration complete: the box answers at $BOX_NEW_IP."
        echo "next: uv run install-zed   (from this repo root)"
        exit 0
    fi
    sleep 1
done

echo "the box did not answer at $BOX_NEW_IP within 90s of host cleanup" >&2
echo "a factory box sits at a random link-local address until claimed - that is expected:" >&2
echo "run: uv run install-zed   (it ARP-discovers and claims the box)" >&2
echo "if that reports no box discovered either, unplug/replug the cable and retry" >&2
exit 1
