#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Block auto-start during install (config does not exist yet)
echo -e '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
apt-get install -y isc-dhcp-server
rm -f /usr/sbin/policy-rc.d

cat > /etc/default/isc-dhcp-server <<'EOF'
INTERFACESv4="enp0s8"
EOF

cat > /etc/dhcp/dhcpd.conf <<'EOF'
default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet 192.168.50.0 netmask 255.255.255.0 {
    range 192.168.50.100 192.168.50.200;
    option subnet-mask 255.255.255.0;
    option routers 192.168.50.1;
    option domain-name-servers 192.168.50.1;
}

# Static reservation by MAC
host client-a {
    hardware ethernet 08:00:27:aa:00:01;
    fixed-address 192.168.50.50;
}
EOF

dhcpd -t -cf /etc/dhcp/dhcpd.conf
systemctl enable isc-dhcp-server
systemctl restart isc-dhcp-server