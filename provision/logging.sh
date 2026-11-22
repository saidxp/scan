#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# usage: logging.sh <server|client> <loghost-ip>
ROLE="${1:?usage: logging.sh <server|client> <loghost-ip>}"
LOGHOST="${2:?need loghost-ip}"

apt-get update -y
apt-get install -y rsyslog

if [ "$ROLE" = "server" ]; then
    # This host IS the loghost: set its static LAN IP and receive logs over UDP 514.
    cat > /etc/network/interfaces <<'IF'
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback
allow-hotplug enp0s3
iface enp0s3 inet dhcp
    post-up ip route del default via 10.0.2.2 dev enp0s3 || true
auto enp0s8
iface enp0s8 inet static
    address 192.168.50.20
    netmask 255.255.255.0
    gateway 192.168.50.1
IF
    ifdown enp0s8 2>/dev/null || true
    ip addr flush dev enp0s8 2>/dev/null || true
    ifup enp0s8 || true

    mkdir -p /var/log/remote
    cat > /etc/rsyslog.d/50-remote-server.conf <<'SRV'
module(load="imudp")
input(type="imudp" port="514")
$template RemoteHost,"/var/log/remote/%FROMHOST-IP%.log"
*.* ?RemoteHost
SRV
    systemctl restart rsyslog

else
    # Forward this host's logs to the loghost (UDP).
    cat > /etc/rsyslog.d/90-remote-client.conf <<CLI
*.* @${LOGHOST}:514
CLI
    systemctl restart rsyslog
fi
