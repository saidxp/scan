#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

MODE="${1:?usage: dvwa.sh <network|application>}"

configure_network() {
    cat > /etc/network/interfaces <<'EOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# Vagrant management NIC: keep the address, but do not use its direct NAT route.
allow-hotplug enp0s3
iface enp0s3 inet dhcp
    post-up ip route del default via 10.0.2.2 dev enp0s3 || true

# Isolated lab subnet B.
auto enp0s8
iface enp0s8 inet static
    address 192.168.60.20
    netmask 255.255.255.0
    gateway 192.168.60.1
EOF

    ifdown enp0s8 2>/dev/null || true
    ip addr flush dev enp0s8 2>/dev/null || true
    ifup enp0s8
    ip route del default via 10.0.2.2 dev enp0s3 2>/dev/null || true
    ip route replace default via 192.168.60.1 dev enp0s8

    rm -f /etc/resolv.conf
    echo "nameserver 192.168.60.1" > /etc/resolv.conf

    ip -4 -br address show enp0s8
    ip route
}

install_application() {
    # Fail unless downloads will cross the lab gateway rather than direct Vagrant NAT.
    ip route get 1.1.1.1 | grep -q 'via 192.168.60.1 dev enp0s8'

    apt-get update
    apt-get install -y ca-certificates curl docker.io
    systemctl enable --now docker

    docker pull docker.io/library/mariadb:10
    docker pull ghcr.io/digininja/dvwa:latest

    docker network inspect dvwa-lab >/dev/null 2>&1 || docker network create dvwa-lab
    docker volume create dvwa-db-data >/dev/null
    docker rm -f dvwa dvwa-db >/dev/null 2>&1 || true

    docker run -d \
        --name dvwa-db \
        --network dvwa-lab \
        --restart unless-stopped \
        --env MYSQL_ROOT_PASSWORD=dvwa \
        --env MYSQL_DATABASE=dvwa \
        --env MYSQL_USER=dvwa \
        --env 'MYSQL_PASSWORD=p@ssw0rd' \
        --mount source=dvwa-db-data,target=/var/lib/mysql \
        docker.io/library/mariadb:10 >/dev/null

    docker run -d \
        --name dvwa \
        --network dvwa-lab \
        --restart unless-stopped \
        --env DB_SERVER=dvwa-db \
        --env DEFAULT_SECURITY_LEVEL=low \
        --publish 192.168.60.20:80:80 \
        ghcr.io/digininja/dvwa:latest >/dev/null

    for _ in $(seq 1 60); do
        if docker exec dvwa-db mariadb-admin ping -h 127.0.0.1 -udvwa -p'p@ssw0rd' --silent >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    docker exec dvwa-db mariadb-admin ping -h 127.0.0.1 -udvwa -p'p@ssw0rd' --silent >/dev/null

    for _ in $(seq 1 60); do
        if curl --fail --silent http://192.168.60.20/setup.php >/dev/null; then
            break
        fi
        sleep 2
    done
    curl --fail --silent http://192.168.60.20/setup.php >/dev/null

    if ! docker exec dvwa-db mariadb -udvwa -p'p@ssw0rd' -D dvwa -Nse \
        "SELECT 1 FROM information_schema.tables WHERE table_schema='dvwa' AND table_name='users'" 2>/dev/null | grep -qx 1; then
        cookie_jar="$(mktemp)"
        setup_page="$(mktemp)"
        trap 'rm -f "$cookie_jar" "$setup_page"' EXIT

        curl --fail --silent --show-error \
            --cookie-jar "$cookie_jar" \
            http://192.168.60.20/setup.php \
            --output "$setup_page"

        token="$(sed -nE "s/.*name=['\"]user_token['\"][^>]*value=['\"]([^'\"]+)['\"].*/\1/p" "$setup_page" | head -n 1)"
        test -n "$token"

        curl --fail --silent --show-error --location \
            --cookie "$cookie_jar" \
            --cookie-jar "$cookie_jar" \
            --data-urlencode 'create_db=Create / Reset Database' \
            --data-urlencode "user_token=${token}" \
            http://192.168.60.20/setup.php \
            >/dev/null
    fi

    docker exec dvwa-db mariadb -udvwa -p'p@ssw0rd' -D dvwa -Nse \
        "SELECT COUNT(*) FROM users" | grep -Eq '^[1-9][0-9]*$'
    curl --fail --silent http://192.168.60.20/login.php >/dev/null
}

case "$MODE" in
    network)
        configure_network
        ;;
    application)
        install_application
        ;;
    *)
        echo "usage: dvwa.sh <network|application>" >&2
        exit 2
        ;;
esac
