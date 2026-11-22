#!/bin/bash
set -euo pipefail

cat > /etc/network/interfaces <<'EOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
# Vagrant management / NAT (no default route on this card)
allow-hotplug enp0s3
iface enp0s3 inet dhcp
    post-up ip route del default via 10.0.2.2 dev enp0s3 || true

# LAN A: IP from the gateway's DHCP, default route = the gateway
auto enp0s8
iface enp0s8 inet dhcp
    up ip route replace default via 192.168.50.1 dev enp0s8 || true
EOF

ifdown enp0s8 2>/dev/null || true
ifup enp0s8 || true
ip -br a 

ip route del default via 10.0.2.2 dev enp0s3 2>/dev/null || true
ip route replace default via 192.168.50.1 dev enp0s8

cat >> /etc/dhcpcd.conf <<'EOF'

interface enp0s3
nohook resolv.conf
EOF

ip route