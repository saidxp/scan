#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# usage: bastion.sh <bastion|internal> [bastion-ip]
ROLE="${1:?usage: bastion.sh <bastion|internal> [bastion-ip]}"
BASTION="${2:-}"

# ===== 1. SSH hardening on EVERY host (subject: bastion.sh = SSH hardening) =====
SRC=""
if [ -f "/vagrant/ssh/sshd_config" ]; then
    SRC="/vagrant/ssh/sshd_config"
else
    SRC="$(dirname "$(readlink -f "$0")")/../ssh/sshd_config"
fi
mkdir -p /etc/ssh/sshd_config.d
install -m 644 "$SRC" /etc/ssh/sshd_config.d/60-remote-hardening.conf
sshd -t
systemctl reload ssh || systemctl restart ssh

# ===== 2. Internal hosts: accept SSH only from the bastion =====
if [ "$ROLE" = "internal" ]; then
    [ -n "$BASTION" ] || { echo "internal role needs a bastion-ip argument"; exit 1; }
    apt-get update -y
    apt-get install -y nftables
    cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy accept;
    iifname "lo" accept
    ct state established,related accept
    tcp dport 22 ip saddr ${BASTION} accept
    tcp dport 22 drop
  }
}

EOF
    nft -c -f /etc/nftables.conf
    systemctl enable nftables
    systemctl restart nftables
fi

# ===== 3. Bastion: fail2ban (added in the dedicated fail2ban step) =====
if [ "$ROLE" = "bastion" ]; then
    apt-get update -y
    apt-get install -y fail2ban
    cat > /etc/fail2ban/jail.local <<'JAIL'
[DEFAULT]
backend = systemd
# never ban ourselves: laptop/Vagrant path (10.0.2.0/24) and the bastion's own IPs
ignoreip = 127.0.0.1/8 ::1 10.0.2.0/24 192.168.50.1 192.168.60.1
bantime  = 600
findtime = 600
maxretry = 3

[sshd]
enabled = true
port    = 22
# key-only host: match failed publickey / invalid user lines (needs LogLevel VERBOSE)
mode    = aggressive
JAIL
    systemctl enable fail2ban
    systemctl restart fail2ban
    sleep 2
    fail2ban-client status sshd || true
fi