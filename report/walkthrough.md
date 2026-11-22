# Walkthrough — From `vagrant up` to Attack and Defense

The whole project in order: deploy the machines, build the network, drop in a realistic
vulnerable app, isolate it, then show **how it would be attacked** and **how the network
now stops that**. Every step below is what the code actually does; links point at the
captured evidence.

```
deploy ─▶ network ─▶ target ─▶ isolate ─▶ attack (simulated) ─▶ defense (enforced)
```

---

## Phase 1 — Deploy from code

```bash
vagrant destroy -f
vagrant up
```

Five VMs come up from the `Vagrantfile`, no manual steps:

| VM | Role | Subnet |
|---|---|---|
| `gateway` | bastion / router | WAN + A + B |
| `client1` | workstation | A (DHCP) |
| `loghost` | syslog collector | A (static) |
| `client2` | oversight host | B (static) |
| `dvwa` | **target** | B (static) |

Architecture was checked before choosing the image: host is amd64/x86_64, so the amd64
`debian13-local` (Debian 13) box is used — host and guest match.
Evidence: [host-architecture.txt](file:///home/saidxp/scan/scans/before/host-architecture.txt).

---

## Phase 2 — Build the network environment

The gateway is the hub. It gets three cards (`enp0s3` WAN NAT, `enp0s8` → subnet A
`192.168.50.1`, `enp0s9` → subnet B `192.168.60.1`) and is turned into a router by
[provision/gateway.sh](file:///home/saidxp/scan/provision/gateway.sh):

- **Forwarding on:** `net.ipv4.ip_forward=1`.
- **NAT out to the internet:** `oifname "enp0s3" masquerade`.
- **Filter policy `drop`** on forward, then allow only:
  - replies to established connections,
  - both subnets → WAN,
  - subnet A ↔ subnet B **ICMP only**,
  - subnet B → loghost **udp/514** (syslog).

Addressing is delivered by [provision/dhcp.sh](file:///home/saidxp/scan/provision/dhcp.sh)
(DHCP, with a MAC reservation pinning `client1` to `192.168.50.50`) and DNS via `dnsmasq`
on the gateway. `client2` and `dvwa` are static
([client-b.sh](file:///home/saidxp/scan/provision/client-b.sh) and the DVWA `network` stage).
Captured firewall:
[gateway-firewall.txt](file:///home/saidxp/scan/scans/before/gateway-firewall.txt).

Key point: **subnet A and subnet B cannot route to each other except ICMP.** They are
separate `intnet` segments (cables `gateway-lan` and `gateway-lan-b`).

---

## Phase 3 — Place the target (a realistic isolated web app)

DVWA is deployed by [provision/dvwa.sh](file:///home/saidxp/scan/provision/dvwa.sh) (`application`),
exactly like a small real deployment — two containers on their own network:

```bash
docker network create dvwa-lab
docker run -d --name dvwa-db  --network dvwa-lab  mariadb:10 ...        # database
docker run -d --name dvwa      --network dvwa-lab \
    --publish 192.168.60.20:80:80  ghcr.io/digininja/dvwa:latest        # web app
```

Two deliberate isolation choices:

1. **The app's port is published only on the guest's LAN-B address** (`192.168.60.20:80`),
   never on the host and never on the WAN card — there is **no `forwarded_port` for DVWA**
   in the `Vagrantfile`. So the web app is unreachable from your laptop or the internet.
2. The target is on **subnet B**, a segment that can only be reached by crossing the bastion.

The host's default route is also removed on the target and pointed at the gateway, so the
app's own traffic goes through the lab, not straight out. The app is fully set up
automatically (database created, login page reachable) so it is genuinely usable.

---

## Phase 4 — Isolate the target

This is where the design is enforced. Three things keep the target boxed in, all in code so
they survive a rebuild.

### The only way in is the bastion

[provision/bastion.sh](file:///home/saidxp/scan/provision/bastion.sh) (`internal` role) makes
each internal host drop `tcp/22` unless the source is the bastion:

```
tcp dport 22 ip saddr 192.168.50.1 accept   # (192.168.60.1 on subnet B)
tcp dport 22 drop
```

### The un-patchable app is contained, not patched

DVWA is *meant* to be exploitable, so it is boxed in at the firewall. The `contain` stage of
[provision/dvwa.sh](file:///home/saidxp/scan/provision/dvwa.sh) writes table `inet dvwa-contain`:

- **input:** `tcp/80` allowed **only** from `192.168.60.10` (the oversight host), then drop.
- **output:** allow loopback + internal ranges only, then drop.
- **forward:** allow container bridges to internal ranges only, then drop (needed because
  `br_netfilter` sends container traffic through the forward hook).

**Ordering matters.** `bastion.sh` runs `flush ruleset` and rewrites `/etc/nftables.conf`, so
`contain` must run **last** — otherwise the containment table is erased on rebuild.

State after a clean rebuild:

```
$ sudo nft list tables
table inet filter
table inet dvwa-contain
```

---

## Phase 5 — Attack (simulated)

This is how a real assessment attacks the target. Every step is a captured command.

### 5.1 Reconnaissance

From the oversight host, scan the segment
([nmap-subnet-b-full.nmap](file:///home/saidxp/scan/scans/before/nmap-subnet-b-full.nmap)):
the target shows `80/tcp open` Apache httpd 2.4.69, `22/tcp filtered`.

### 5.2 Reach the app

From the allowed host, the web app answers:

```
client2 (192.168.60.10) -> dvwa:80 : CLIENT2_CAN_REACH_DVWA80
```

### 5.3 Exploit the app

DVWA ships exploitable — log in with default credentials, then use the **Command Injection**
module for RCE inside the container. Captured pages:
[dvwa-default-login-impact.html](file:///home/saidxp/scan/scans/before/dvwa-default-login-impact.html),
[dvwa-rce-impact.html](file:///home/saidxp/scan/scans/before/dvwa-rce-impact.html).

### 5.4 The attack that mattered most — bypassing the bastion

The dangerous case: an attacker on the *host* skipping the bastion entirely through Vagrant's
auto SSH port-forwards.

```
$ ssh -p 2200 vagrant@127.0.0.1     # client1's auto-forward
saidxp
uid=1001(vagrant) ...
```

A full shell on an internal host, **outside** the bastion, fail2ban, and the audit trail.
Evidence: [client1-direct-ssh-impact.txt](file:///home/saidxp/scan/scans/before/client1-direct-ssh-impact.txt).

---

## Phase 6 — Defense (enforced)

Each attack above, and what now stops it:

| Attack | Defense | Where | Proof |
|---|---|---|---|
| Direct SSH to internal host (port-forward) | drop `tcp/22` unless from bastion | [bastion.sh](file:///home/saidxp/scan/provision/bastion.sh) | ports `2200`–`2203` **time out** → [f1-direct-ssh-blocked.txt](file:///home/saidxp/scan/scans/after/f1-direct-ssh-blocked.txt) |
| Reach DVWA from the gateway / any host | allow `tcp/80` only from `192.168.60.10` | [dvwa.sh](file:///home/saidxp/scan/provision/dvwa.sh) `contain` | client2 → `302`, gateway → **BLOCKED** |
| Exfiltrate / call out from the target | egress allow-loopback+internal, then drop | [dvwa.sh](file:///home/saidxp/scan/provision/dvwa.sh) `contain` | host → `1.1.1.1` **BLOCKED** → [f2f3-containment-after.txt](file:///home/saidxp/scan/scans/after/f2f3-containment-after.txt) |

Legitimate access still works: `ssh client2` hops through the bastion (ProxyJump) and the app
returns `302` to the oversight host. That is the whole point — **the target stays attackable
for the assessment, but only from the one host and the one direction we allow.**

---

## Recap

1. **Deploy** — five machines from code, architecture checked.
2. **Network** — gateway routes A↔B↔WAN, DHCP/DNS, subnets isolated except ICMP + syslog.
3. **Target** — a realistic containerised DVWA, on subnet B, with no host exposure.
4. **Isolate** — bastion-only SSH + firewall containment (input/output/forward).
5. **Attack** — recon, reach the app, exploit it (default creds + RCE), and the bastion bypass.
6. **Defense** — every attack mapped to a rule in code, with before/after proof.

Full detail: [report/assessment.md](file:///home/saidxp/scan/report/assessment.md) ·
why these fixes: [remediation/notes.md](file:///home/saidxp/scan/remediation/notes.md).
