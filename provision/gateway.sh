#!/bin/bash 

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Make sure ifupdown exists (not guaranteed on newer Debian boxes)
apt-get update
apt-get install -y ifupdown

# =========================
# 1. Network cards
# =========================
cat > /etc/network/interfaces <<'EOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# WAN (NAT)
allow-hotplug enp0s3
iface enp0s3 inet dhcp

# LAN A
auto enp0s8
iface enp0s8 inet static
    address 192.168.50.1
    netmask 255.255.255.0

# LAN B
auto enp0s9
iface enp0s9 inet static
    address 192.168.60.1
    netmask 255.255.255.0
EOF

# Apply LAN A and LAN B now (never touch enp0s3: Vagrant SSH uses it)
for nic in enp0s8 enp0s9; do
    ifdown "$nic" 2>/dev/null || true
    ip addr flush dev "$nic"
    ifup "$nic"
done

ip -br a

# =========================
# 2. Routing: IP forwarding
# =========================
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf
sysctl -w net.ipv4.ip_forward=1

# =========================
# 3. NAT: masquerade on the WAN card
# =========================
apt-get update
apt-get install -y nftables

cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "enp0s3" masquerade
  }
}

table inet filter {

  chain forward {
    type filter hook forward priority 0; policy drop;

    # replies to connections already allowed
    ct state established,related accept

    # both subnets may go out to the internet
    iifname { "enp0s8", "enp0s9" } oifname "enp0s3" accept

    # between the subnets: ICMP only
    iifname "enp0s8" oifname "enp0s9" icmp type { echo-request, echo-reply } accept
    iifname "enp0s9" oifname "enp0s8" icmp type { echo-request, echo-reply } accept
    
    # allow syslog (udp 514) from subnet B to the loghost on subnet A
    iifname "enp0s9" oifname "enp0s8" udp dport 514 accept
  }

}
EOF

systemctl enable nftables
systemctl restart nftables
