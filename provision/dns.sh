#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get install -y dnsmasq

cat > /etc/dnsmasq.d/lab.conf <<'EOF'
# DNS only, no DHCP
port=53
no-dhcp-interface=enp0s8,enp0s9
listen-address=192.168.50.1,192.168.60.1
bind-interfaces

# Do not read /etc/hosts, the records are below
no-hosts

# Internal records
address=/gateway/192.168.50.1
address=/client-a/192.168.50.50
address=/client-b/192.168.60.10

# Everything else goes to the internet
server=8.8.8.8
server=1.1.1.1
EOF

dnsmasq --test
systemctl enable dnsmasq
systemctl restart dnsmasq