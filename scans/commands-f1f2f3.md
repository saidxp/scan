# Commands used to analyze & verify F1 / F2 / F3

All remote checks go **through the bastion** — there is no direct path from the
host into subnet B.

**Common access pattern** (used by every remote command below):

```bash
cd /home/saidxp/scan
K=.vagrant/machines            # private keys live here

# into a subnet-B host (dvwa / client2) via bastion:
ssh -i $K/gateway/virtualbox/private_key \
    -i $K/dvwa/virtualbox/private_key \
    -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    -J vagrant@127.0.0.1:2022 vagrant@192.168.60.20 '<remote command>'
```

Add `| tee scans/before/<name>.txt` (or `scans/after/`) to save evidence.

---

## F1 — direct SSH exposure / bastion bypass

**Analyze (before):**

```bash
# 1. which host ports Vagrant auto-forwards (this IS the exposure)
for m in gateway client1 client2 loghost dvwa; do echo "=== $m ==="; vagrant port $m; done
# -> 22=>2022/2222, client1 2200, client2 2201, dvwa 2202   [vagrant-forwarded-ports.txt]

# 2. confirm they are listening and bound to 127.0.0.1 only
ss -ltnp | grep -E '2022|2200|2201|2202|2203'                # [host-ssh-forward-bind.txt]

# 3. PROVE the bypass: log in directly, skipping the bastion
ssh -p 2200 -i $K/client1/virtualbox/private_key \
    -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    vagrant@127.0.0.1 id
# -> uid=1001(vagrant)   [client1-direct-ssh-impact.txt]
```

**Verify (after):**

```bash
# direct ports must now TIME OUT
for p in 2200 2201 2202 2203; do
  ssh -p $p -i $K/client1/virtualbox/private_key -o ConnectTimeout=5 \
      -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      vagrant@127.0.0.1 true
done
# -> Connection to 127.0.0.1 port 22xx timed out   [f1-direct-ssh-blocked.txt]

# through the bastion must still work
ssh -i $K/gateway/virtualbox/private_key -i $K/client1/virtualbox/private_key \
    -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    -J vagrant@127.0.0.1:2022 vagrant@192.168.50.50 id   # -> PROXY_OK

# the live rule doing the blocking (on any client)
ssh -J vagrant@127.0.0.1:2022 vagrant@192.168.50.50 'sudo nft list ruleset'
```

---

## F2 — who can reach DVWA tcp/80

**Analyze (before):**

```bash
# untrusted subnet A (client1) -> dvwa:80  (raw TCP, no curl)
ssh -J vagrant@127.0.0.1:2022 vagrant@192.168.50.50 \
  'timeout 3 bash -c "echo > /dev/tcp/192.168.60.20/80" && echo DVWA_TCP_BLOCKED_from_subnetA'
# [dvwa-exposure-from-subnetA.txt]

# approved host client2 -> dvwa:80
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.60.20/          # -> CLIENT2_CAN_REACH_DVWA80

# gateway (192.168.60.1) -> dvwa:80
ssh -J vagrant@127.0.0.1:2022 vagrant@192.168.60.1 \
  'timeout 3 bash -c "echo > /dev/tcp/192.168.60.20/80" && echo GATEWAY_CAN_REACH_DVWA80'
# [dvwa-http-reachability.txt  — both reached it BEFORE]

# fingerprint the app (service/version/title/methods/enum)
nmap -Pn -p80 -sV --script http-title,http-headers,http-methods,http-enum \
     -oA /vagrant/scans/before/nmap-dvwa-http 192.168.60.20
# [nmap-dvwa-http.nmap]

# default-credential impact page
curl -s -c jar.txt -d 'username=admin&password=password&Login=Login' http://192.168.60.20/login.php
# [dvwa-default-login-impact.html]
```

**Verify (after):**

```bash
# approved host -> 302 (still allowed)
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.60.20/     # -> 302

# gateway -> BLOCKED
ssh -J vagrant@127.0.0.1:2022 vagrant@192.168.60.1 \
  'timeout 3 bash -c "echo > /dev/tcp/192.168.60.20/80" || echo BLOCKED'
# [f2f3-containment-after.txt]
```

---

## F3 — DVWA egress to the internet

**Analyze (before):**

```bash
# from the dvwa HOST
ssh ... vagrant@192.168.60.20 \
  'curl -s -o /dev/null -w "%{http_code}\n" http://1.1.1.1; ping -c1 1.1.1.1'
# -> HOST_INTERNET_OK   [gateway-rules-and-dvwa-egress.txt / dvwa-egress.txt]

# from the dvwa CONTAINER
ssh ... vagrant@192.168.60.20 \
  'sudo docker exec dvwa timeout 3 bash -c "echo > /dev/tcp/1.1.1.1/80"'
# -> CONTAINER_TCP_INTERNET_FAIL

# what the gateway was letting through
ssh -J vagrant@127.0.0.1:2022 vagrant@192.168.60.1 'sudo nft list ruleset'
# [gateway-firewall.txt]
```

**Verify (after):**

```bash
# dvwa host -> internet
ssh ... vagrant@192.168.60.20 'curl -s -o /dev/null -w "%{http_code}\n" http://1.1.1.1'  # -> 000 / BLOCKED
# container -> internet
ssh ... vagrant@192.168.60.20 'sudo docker exec dvwa timeout 3 bash -c "echo > /dev/tcp/1.1.1.1/80"'  # -> BLOCKED
# [f2f3-containment-after.txt]
```

---

## Supporting recon / context commands

```bash
nmap -sn -PE --reason -oA /vagrant/scans/before/nmap-subnet-a-discovery 192.168.50.0/24
nmap -Pn -p- -sS -sV -O --reason -T4 -oA /vagrant/scans/before/nmap-subnet-b-full 192.168.60.1 192.168.60.20
nmap -Pn -sU --top-ports 100 -sV --reason -T4 -oA /vagrant/scans/before/nmap-gateway-udp 192.168.60.1
arp-scan -I enp0s8 192.168.60.0/24          # [arp-subnet-b.txt]
uname -m; uname -srm; VBoxManage --version  # [host-architecture.txt]
```

The `-oA` and `| tee` are what produced every file in `scans/before/` and `scans/after/`.
