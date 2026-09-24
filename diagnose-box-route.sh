#!/usr/bin/env bash
# Read-only box-side diagnostics for the gadget-bridge default route: the
# route table, the dnsmasq config serving the gadget link, the L4T
# usb-device-mode scripts, netplan/networkd config, and any DHCP client
# processes. Runs from the operator laptop over the installer's own ssh
# state (.placeframe/ssh/) and changes nothing on either side.

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh -F /dev/null \
    -i "$repo_root/.placeframe/ssh/id_ed25519" \
    -o UserKnownHostsFile="$repo_root/.placeframe/ssh/known_hosts" \
    -o StrictHostKeyChecking=accept-new \
    -o LogLevel=ERROR \
    user@192.168.55.1 '
echo "=== routes (ip route show) ==="
ip route show
echo
echo "=== dnsmasq config (/etc/dnsmasq.d/) ==="
grep -rn "option\|dhcp\|interface" /etc/dnsmasq.d/ 2>/dev/null || echo "no /etc/dnsmasq.d matches"
echo
echo "=== dnsmasq process ==="
ps -ef | grep [d]nsmasq || echo "no dnsmasq process"
echo
echo "=== L4T usb-device-mode files ==="
ls /opt/nvidia/l4t-usb-device-mode/ 2>/dev/null || echo "dir missing"
echo
echo "=== route/dhcp references in L4T usb-device-mode ==="
grep -rn "route add\|default via\|dhcpcd\|dhclient\|udhcpc" /opt/nvidia/l4t-usb-device-mode/ 2>/dev/null || echo "no matches"
echo
echo "=== netplan config ==="
cat /etc/netplan/*.yaml 2>/dev/null || echo "no netplan files"
echo
echo "=== networkd config ==="
ls /etc/systemd/network/ 2>/dev/null || echo "no networkd dir"
cat /etc/systemd/network/*.network 2>/dev/null
echo
echo "=== DHCP client processes ==="
ps -ef | grep -Ei "[d]hcpcd|[d]hclient|[u]dhcpc" || echo "no dhcp client running"
'
