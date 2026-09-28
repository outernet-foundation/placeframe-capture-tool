#!/usr/bin/env bash
# Read-only diagnostics for the laptop<->ZED-Box cable link: host addresses,
# carrier states, NetworkManager state, retired-installer leftovers, a
# link-local ARP scan, and ssh-port probes against anything the scan finds.
# Run on the operator laptop with the box attached by the direct ethernet
# cable and paste the full output back. Changes nothing on either side.

set -u

section() { printf '\n=== %s ===\n' "$*"; }
port_open() { timeout 2 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }

section "addresses (ip -br addr)"
ip -br addr

section "carrier"
for CARRIER in /sys/class/net/*/carrier; do
    IFACE=${CARRIER#/sys/class/net/}
    IFACE=${IFACE%/carrier}
    VALUE=$(cat "$CARRIER" 2>/dev/null) || VALUE="n/a (interface down)"
    printf '%s: %s\n' "$IFACE" "$VALUE"
done

section "active NetworkManager connections"
nmcli -t -e no -f NAME,DEVICE,STATE con show --active 2>&1

section "retired-installer leftovers"
if nmcli con show 2>/dev/null | grep -i zedbox; then :; else echo "no zedbox NM profile"; fi
for LEFTOVER in /etc/sysctl.d/99-zedbox.conf /etc/NetworkManager/conf.d/zedbox-no-auto-default.conf; do
    if [ -f "$LEFTOVER" ]; then echo "present: $LEFTOVER"; else echo "absent:  $LEFTOVER"; fi
done
sudo firewall-cmd --permanent --zone=trusted --query-source=100.64.0.0/24 2>&1 | sed 's/^/trusted-source 100.64.0.0\/24: /'
sudo firewall-cmd --permanent --zone=public --query-masquerade 2>&1 | sed 's/^/public masquerade: /'
sudo iptables -S DOCKER-USER 2>&1 | grep 100.64 || echo "no 100.64 DOCKER-USER rules"

section "link-local ARP scan"
APIPA_IFACES=$(ip -4 -o addr show | awk '$4 ~ /^169\.254\./ {print $2}' | sort -u)
if [ -z "$APIPA_IFACES" ]; then
    echo "no interface holds a 169.254.x.y address - the cable port never self-configured."
    echo "(an active zedbox profile, a manual address, or a down port would explain that)"
else
    for IFACE in $APIPA_IFACES; do
        echo "scanning $IFACE:"
        sudo ping -I "$IFACE" -b -c 3 -W 1 169.254.255.255 >/dev/null 2>&1
        ip neigh show dev "$IFACE" | grep -v FAILED
    done
fi

section "ssh probes"
for TARGET in 169.254.0.1 100.64.0.1; do
    if port_open "$TARGET"; then echo "$TARGET:22 open"; else echo "$TARGET:22 closed/unreachable"; fi
done
for NEIGHBOR in $(ip neigh show | awk '$1 ~ /^169\.254\./ && $0 !~ /FAILED/ {print $1}' | sort -u); do
    if port_open "$NEIGHBOR"; then echo "$NEIGHBOR:22 open"; else echo "$NEIGHBOR:22 closed"; fi
done
