# Security Assessment — Isolated DVWA Target

Assessment of the deliberately vulnerable **DVWA** target that sits in subnet B of the
lab, reached only through the bastion. Findings are proven with captured evidence in
`scans/before/` and re-checked after remediation in `scans/after/`.

---

## 1. Scope

| Item | Value |
|---|---|
| Target | DVWA web application |
| Address | `192.168.60.20` (subnet B) |
| Stack | Docker image `ghcr.io/digininja/dvwa:latest` + `mariadb:10`, Apache 2.4.69 |
| Security level | `DEFAULT_SECURITY_LEVEL=low` (image default) |
| Oversight host | `client2` (`192.168.60.10`, subnet B) |
| Access path | management host → bastion (`127.0.0.1:2022`) → ProxyJump → target |

Out of scope: the rest of the lab (routing, DHCP/DNS, logging), which is covered by the
`remote` project.

### Why this path

The gateway is the only host with an external NIC, so it is the bastion. Internal hosts —
including the DVWA target — are on isolated `intnet` segments. The intent is that the
**bastion is the only way in** and that the vulnerable target stays boxed in. The
assessment checks whether those two intents actually hold.

### Environment check (done before choosing the image)

The host is **amd64 (x86_64), 64-bit** (`uname -m` → `x86_64`), and VirtualBox is
`7.1.18`. The guest box was therefore chosen as the amd64 build of `debian13-local`
(Debian 13 "trixie"), so host and guest architectures match. The running guests also
report `x86_64-pc-linux-gnu` in their nmap OS fingerprints.
Evidence: [host-architecture.txt](file:///home/saidxp/scan/scans/before/host-architecture.txt).

---

## 2. Step 1 — Reconnaissance

Full-TCP nmap of subnet B (`192.168.60.1` gateway + `192.168.60.20` target):

- `192.168.60.20` → `80/tcp open` Apache httpd 2.4.69; `22/tcp filtered` (no-response).
- `192.168.60.1` → `22/tcp open` OpenSSH 10.0p2; `53/tcp open` dnsmasq 2.91.

Evidence: [nmap-subnet-b-full.nmap](file:///home/saidxp/scan/scans/before/nmap-subnet-b-full.nmap),
[arp-subnet-b.txt](file:///home/saidxp/scan/scans/before/arp-subnet-b.txt).

Two things from recon drove the findings:

1. The target's **`80/tcp` is open to whatever can route to it** — so the question is
   *who* can route to it, not whether the port is open.
2. `vagrant status` / `vagrant port` shows each VM has an **auto-created host port
   forward** for SSH (`2200`, `2201`, `2202`, …) bound to `127.0.0.1`. That is a second
   way into the internal hosts, independent of the bastion.
   Evidence: [vagrant-forwarded-ports.txt](file:///home/saidxp/scan/scans/before/vagrant-forwarded-ports.txt),
   [host-ssh-forward-bind.txt](file:///home/saidxp/scan/scans/before/host-ssh-forward-bind.txt).

---

## 3. Step 2 — Assessment (weaknesses)

| ID | Weakness | Severity |
|---|---|---|
| **F1** | Internal hosts are directly reachable over SSH from the host via Vagrant's auto port-forwards — the bastion is bypassable. | High |
| **F2** | The un-patchable DVWA target accepts `tcp/80` from its **whole subnet** and from the gateway, not just the oversight host. | High |
| **F3** | The DVWA host has **unrestricted internet egress** — a compromised app can call out. | Medium |

---

## 4. Step 3 — Exploitation (concrete impact)

### F1 — Bastion bypass

From the management host, connecting straight to the VM's forwarded port logged in as the
`vagrant` user without ever touching the bastion:

```
$ ssh -p 2200 vagrant@127.0.0.1    # client1's auto-forward
saidxp
uid=1001(vagrant) gid=1001(vagrant) ...
```

Impact: a full interactive shell on an internal host, **outside** the bastion and therefore
outside fail2ban and the centralized audit trail. The single-entry-point design is defeated.

Evidence: [client1-direct-ssh-impact.txt](file:///home/saidxp/scan/scans/before/client1-direct-ssh-impact.txt),
[client1-direct-ssh.conf](file:///home/saidxp/scan/scans/before/client1-direct-ssh.conf).

### F2 — Over-exposed vulnerable target

The target answered on `tcp/80` to more than the oversight host:

```
gateway (192.168.60.1) -> dvwa:80  : GATEWAY_CAN_REACH_DVWA80
client2 (192.168.60.10) -> dvwa:80 : CLIENT2_CAN_REACH_DVWA80
```

Anyone who reaches the segment can reach the app. Once there, the app is the classic DVWA
exposure: default credentials and a command-injection page that yields RCE. Captured pages:

- [dvwa-default-login-impact.html](file:///home/saidxp/scan/scans/before/dvwa-default-login-impact.html) — authenticated DVWA page reached with default credentials.
- [dvwa-rce-impact.html](file:///home/saidxp/scan/scans/before/dvwa-rce-impact.html) — the Command Injection module (RCE).

Impact: remote code execution as the web user inside the container, plus database access —
from any host on the segment, and (as F1 shows) from the host itself.

Evidence: [dvwa-http-reachability.txt](file:///home/saidxp/scan/scans/before/dvwa-http-reachability.txt),
[dvwa-exposure-from-subnetA.txt](file:///home/saidxp/scan/scans/before/dvwa-exposure-from-subnetA.txt).

### F3 — Unrestricted egress

The target host could reach the internet:

```
dvwa HOST      -> internet      : HOST_INTERNET_OK
dvwa CONTAINER -> tcp 1.1.1.1:80: CONTAINER_TCP_INTERNET_FAIL
```

Impact: if the app is exploited (F2), the attacker can exfiltrate data or pull further
payloads. (The container itself already failed to reach out; the host did not.)

Evidence: [dvwa-egress.txt](file:///home/saidxp/scan/scans/before/dvwa-egress.txt),
[gateway-rules-and-dvwa-egress.txt](file:///home/saidxp/scan/scans/before/gateway-rules-and-dvwa-egress.txt).

---

## 5. Step 4 — Risk rating (OWASP)

### F1 — Bastion bypass / direct SSH to internal hosts

| Factor | Assessment |
|---|---|
| OWASP Top 10 | **A05:2021 – Security Misconfiguration** (also A01 Broken Access Control) |
| Skill required | Low — `vagrant port` tells you the port; no exploitation needed |
| Likelihood | High — the forward is created automatically on every build |
| Technical impact | High — full shell on an internal host |
| Business impact | High — perimeter controls (bastion, fail2ban, audit log) fully bypassed |
| **Overall** | **High** |

### F2 — Vulnerable target exposed beyond the oversight host

| Factor | Assessment |
|---|---|
| OWASP Top 10 | **A05:2021 – Security Misconfiguration** (app itself: A03 Injection, A07 Auth failures) |
| Skill required | Low — default creds + built-in command injection |
| Likelihood | High — reachable from the segment and from the host |
| Technical impact | High — RCE in the container + DB access |
| Business impact | High — any host on the segment is a launch point |
| **Overall** | **High** |

### F3 — Unrestricted egress from the target

| Factor | Assessment |
|---|---|
| OWASP Top 10 | **A05:2021 – Security Misconfiguration** (weak egress control) |
| Skill required | Low (post-exploitation) |
| Likelihood | Medium — needs F2 first |
| Technical impact | High — data exfiltration / payload download |
| Business impact | Medium — bounded by the lab, but it breaks containment |
| **Overall** | **Medium** |

---

## 6. Step 5 — Remediation (done in code, not on a running box)

All fixes live in `Vagrantfile` + `provision/` so they survive `vagrant destroy -f && vagrant up`.

| Finding | Fix | Where |
|---|---|---|
| F1 | Internal hosts drop `tcp/22` unless the source is the bastion (`192.168.50.1` / `192.168.60.1`). | [provision/bastion.sh](file:///home/saidxp/scan/provision/bastion.sh) (role `internal`) |
| F2 | DVWA input chain: allow `tcp/80` **only** from `192.168.60.10`, then drop. | [provision/dvwa.sh](file:///home/saidxp/scan/provision/dvwa.sh) (`contain`) |
| F3 | DVWA output/forward chains: allow loopback + internal ranges only, then drop. | [provision/dvwa.sh](file:///home/saidxp/scan/provision/dvwa.sh) (`contain`) |

DVWA is a third-party image we cannot patch, so F2/F3 are fixed by **containment at the
firewall** rather than by changing the app. Details and the ordering gotcha are in
[remediation/notes.md](file:///home/saidxp/scan/remediation/notes.md).

---

## 7. Step 6 — Verification (destroy / rebuild / re-scan)

The lab was torn down and rebuilt from code, then every finding was re-checked with one
short targeted test. Before/after pairs:

| Finding | Before (broken) | After (fixed) | After evidence |
|---|---|---|---|
| F1 | Direct SSH on `2200` logged in as `vagrant` | ports `2200`–`2203` → connection **timed out**; ProxyJump still works | [f1-direct-ssh-blocked.txt](file:///home/saidxp/scan/scans/after/f1-direct-ssh-blocked.txt) |
| F2 | gateway + any subnet-B host reached `tcp/80` | client2 → `302` (allowed), gateway → **BLOCKED** | [f2f3-containment-after.txt](file:///home/saidxp/scan/scans/after/f2f3-containment-after.txt) |
| F3 | DVWA host reached the internet | host → `1.1.1.1` **BLOCKED**, container → **BLOCKED** | [f2f3-containment-after.txt](file:///home/saidxp/scan/scans/after/f2f3-containment-after.txt) |

Reproducible state after the clean rebuild:

```
$ sudo nft list tables
table inet filter
table inet dvwa-contain

$ sudo docker ps
dvwa    Up
dvwa-db Up
```

---

## 8. Step 7 — Result & residual risk

All three findings are closed and the fixes rebuild from code. Residual risk:

- DVWA stays deliberately vulnerable **by design**; its safety now depends entirely on the
  containment rules. If the `dvwa-contain` table is removed (e.g. a provisioner that
  rewrites `/etc/nftables.conf`), F2/F3 return — which is exactly why `contain` must run
  **last** in the Vagrantfile.
- F1's fix relies on the bastion source IPs staying `192.168.50.1` / `192.168.60.1`.

No open High or Medium findings remain in scope.
