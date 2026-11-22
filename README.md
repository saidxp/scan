# Scan — Security Assessment of an Isolated DVWA Target

A security assessment layered on the routed lab. The lab provides the network (two
subnets, a bastion, centralized logging); this project adds a **deliberately vulnerable
target** — DVWA — and a full assessment of it: reconnaissance, findings, exploitation,
OWASP risk rating, remediation in code, and before/after verification.

The whole environment builds from code. `vagrant destroy -f && vagrant up` reproduces both
the lab and the fixes.

---

## 1. Topology

```
                    [ Management Workstation ]
                                │  SSH 127.0.0.1:2022 (bastion only)
                                ▼
                 ┌───────────────────────────────┐
                 │  gateway  (BASTION / JUMP)    │
                 │  WAN   10.0.2.15  (enp0s3)    │
                 │  LAN-A 192.168.50.1 (enp0s8)  │
                 │  LAN-B 192.168.60.1 (enp0s9)  │
                 └───────┬───────────────┬───────┘
                         │               │
        Subnet A "gateway-lan"     Subnet B "gateway-lan-b"
                         │               │
      ┌──────────────────┴───┐   ┌───────┴──────────────────────────┐
      │ client1  192.168.50.50│   │ client2  192.168.60.10           │
      │ loghost  192.168.50.20│   │ dvwa     192.168.60.20  ← TARGET │
      └───────────────────────┘   └──────────────────────────────────┘
```

- The **gateway** is the only host with an external NIC, so it is the bastion and the single
  entry point.
- The **DVWA target** lives in subnet B, has **no host port forward** (the web app is never
  exposed to the host or the internet), and is reached only through the bastion.
- `client2` is the **oversight host**: the one address allowed to talk to the web app.

---

## 2. Deliverables

| Path | What it is |
|---|---|
| [Vagrantfile](file:///home/saidxp/scan/Vagrantfile) | The whole environment as code (5 VMs, NICs, provisioning order). |
| [provision/](file:///home/saidxp/scan/provision) | Provisioners, including the F1 fix and the DVWA containment. |
| [report/assessment.md](file:///home/saidxp/scan/report/assessment.md) | The assessment: recon → findings → rating → remediation → verification. |
| [report/walkthrough.md](file:///home/saidxp/scan/report/walkthrough.md) | End-to-end story: deploy → network → target → isolate → attack → defense. |
| [remediation/notes.md](file:///home/saidxp/scan/remediation/notes.md) | Why each fix is what it is (contain, don't patch) and the ordering trap. |
| [scans/before/](file:///home/saidxp/scan/scans/before) | Evidence: recon dumps and the "before" impact of each finding. |
| [scans/after/](file:///home/saidxp/scan/scans/after) | Evidence: the same checks after a clean rebuild. |

---

## 3. Quick Start

```bash
vagrant destroy -f
vagrant up
```

Optional: install the client SSH config so `ssh client1` / `ssh client2` hop through the
bastion automatically.

```bash
cp ssh/ssh_config ~/.ssh/config
chmod 600 ~/.ssh/config
```

---

## 4. Findings at a Glance

| ID | Finding | Severity | Fixed by |
|---|---|:---:|---|
| F1 | Internal hosts reachable directly over SSH (bastion bypassed) | High | `provision/bastion.sh` (`internal`) |
| F2 | Un-patchable DVWA reachable by the whole subnet | High | `provision/dvwa.sh` (`contain`) |
| F3 | DVWA host has unrestricted internet egress | Medium | `provision/dvwa.sh` (`contain`) |

Full detail, impact, and OWASP ratings: [report/assessment.md](file:///home/saidxp/scan/report/assessment.md).

---

## 5. Reproducing the Evidence

Everything in `scans/` is captured output, not prose. To re-run the checks yourself, reach
the hosts through the bastion and look at the same things:

```bash
# F1: direct SSH must fail, ProxyJump must work
ssh -o ConnectTimeout=5 -p 2200 vagrant@127.0.0.1        # -> timed out
ssh client1 "uid; hostname"                              # -> works (through bastion)

# F2: only the oversight host (192.168.60.10) may reach the web app
ssh client2 "curl -s -o /dev/null -w '%{http_code}\n' http://192.168.60.20/"   # -> 302
ssh bastion "curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://192.168.60.20/"  # -> 000 (blocked)

# F3: egress from the target must be blocked
ssh ... dvwa "curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://1.1.1.1"    # -> 000

# state check
ssh ... dvwa "sudo nft list tables; sudo docker ps"
```

The DVWA target has no `Host` entry in `ssh/ssh_config`; reach it explicitly:

```bash
ssh -i .vagrant/machines/dvwa/virtualbox/private_key -J bastion vagrant@192.168.60.20
```

---

## 6. Base Lab (not in scope here)

Routing, DHCP/DNS, the bastion service, fail2ban, centralized logging, and key rotation come
from the **remote** project, which this one builds on. They are used here as the perimeter
the assessment assumes — not re-tested.
