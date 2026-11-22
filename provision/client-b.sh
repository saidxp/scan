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

# LAN B: static address, default route = the gateway
auto enp0s8
iface enp0s8 inet static 
    address 192.168.60.10
    netmask 255.255.255.0
    gateway 192.168.60.1
EOF

ifdown enp0s8 2>/dev/null || true
ifup enp0s8 || true
ip route del default via 10.0.2.2 dev enp0s3 2>/dev/null || true
ip route replace default via 192.168.60.1 dev enp0s8
ip route

apt-get install -y dnsutils arp-scan nmap curl

rm -f /etc/resolv.conf
echo "nameserver 192.168.60.1" > /etc/resolv.conf