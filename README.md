# Remote — Bastion Architecture & Hardened Fleet Administration

Secure remote administration of a multi-subnet virtualized fleet. Built on top of the **connect** dual-subnet routing network, this project introduces a single hardened entry point (bastion), network-level isolation of internal hosts, aggressive brute-force protection, centralized audit logging, one-command fleet automation, and verified cryptographic key rotation.

---

## 1. Network & Security Architecture

```
                          [ Management Workstation / Laptop ]
                                          │
                  ┌───────────────────────┴───────────────────────┐
                  │ External SSH Entry: 127.0.0.1:2022 (WAN NAT)  │
                  ▼                                               ▼
      ┌───────────────────────┐                    ┌─────────────────────────┐
      │   remote-gateway      │                    │  Direct Internal SSH:   │
      │   (BASTION / JUMP)    │                    │  192.168.50.50 (c1)     │
      │   WAN: 10.0.2.15      │                    │  192.168.60.10 (c2)     │
      │   LAN-A: 192.168.50.1 │                    │  ──▶ UNREACHABLE / DROP │
      │   LAN-B: 192.168.60.1 │                    └─────────────────────────┘
      └───────────┬───────────┘
                  │
        ┌─────────┴────────────────────────────────────────┐
        │                                                  │
        ▼ (Subnet A: "gateway-lan")                        ▼ (Subnet B: "gateway-lan-b")
 ┌──────────────────────────────┐                   ┌──────────────────────────────┐
 │ remote-client1 (DHCP)        │                   │ remote-client2 (Static)      │
 │ IP: 192.168.50.50            │                   │ IP: 192.168.60.10            │
 │ SSH: Bastion-only (nftables) │                   │ SSH: Bastion-only (nftables) │
 └──────────────┬───────────────┘                   └──────────────┬───────────────┘
                │                                                  │
                │              rsyslog (UDP 514)                   │
                ├──────────────────────────────────────────────────┤
                ▼
 ┌──────────────────────────────┐
 │ remote-loghost (Static)      │
 │ IP: 192.168.50.20            │
 │ Central syslog repository    │
 └──────────────────────────────┘
```

### Why the Gateway is the Bastion
The **gateway** VM is the network edge: it is the only machine equipped with an external WAN-facing adapter (`enp0s3`, VirtualBox NAT). Internal hosts (`client1`, `client2`, `loghost`) reside exclusively on isolated internal virtual network segments (`intnet`). Because no external traffic can reach internal machines without crossing the gateway, establishing the bastion service on the gateway provides a natural, auditable perimeter.

---

## 2. Subject Requirements & Compliance Matrix

| Subject Requirement | Implementation Mechanism | Associated File(s) | Verified Status |
|---|---|---|:---:|
| **Bastion Host (Only external entry point)** | Port 2022 forwarded to gateway; internal hosts block direct non-bastion SSH via `nftables` | `Vagrantfile`, `provision/bastion.sh` | **PASS** |
| **SSH Hardening (Fleet-wide)** | Keys-only authentication, `PermitRootLogin no`, `LogLevel VERBOSE` | `ssh/sshd_config`, `provision/bastion.sh` | **PASS** |
| **ProxyJump Configuration** | Single-command access (`ssh client1`) transparently hopping through bastion | `ssh/ssh_config` | **PASS** |
| **Brute-Force Protection (fail2ban)** | Systemd backend, `mode=aggressive` matching failed public keys, ignore list configured | `provision/bastion.sh` | **PASS** |
| **Fleet Automation Script** | Single command runs tasks on all hosts, per-host summary, resilient to individual node failure | `fleet/run.sh` | **PASS** |
| **Centralized Logging** | Real-time rsyslog forwarding (UDP 514) from all hosts to dedicated collector | `provision/logging.sh`, `Vagrantfile` | **PASS** |
| **Key Rotation & Incident Runbook** | Documented standard operating procedure for compromised keys with rejection proof | `runbook-key-rotation.md` | **PASS** |

---

## 3. Quick Start & Deployment

### Step 1: Fully Automated Build from Code
The entire multi-VM environment deploys from scratch with zero manual intervention:

```bash
vagrant destroy -f
time vagrant up
```

### Step 2: Configure Workstation SSH Client
Install the project client configuration into your local environment:

```bash
cp ssh/ssh_config ~/.ssh/config
chmod 600 ~/.ssh/config
```

The OpenSSH client automatically reads `~/.ssh/config`, enabling transparent ProxyJump routing and fleet automation commands.

---

## 4. Auditor Evaluation & Verification Walkthrough

Follow these commands during audit evaluation to inspect each core capability:

### 1. Bastion & ProxyJump Verification
* **Attempt direct connection to internal host (Must Fail):**
  ```bash
  ssh -o ConnectTimeout=5 vagrant@192.168.50.50
  ```
  *Result:* Unreachable / Timed out.
* **Connect through Bastion via ProxyJump (Single Command):**
  ```bash
  ssh client1 "hostname; ip -br a show enp0s8"
  ```
  *Result:* Seamless login. Inspection confirms connection origin IP is `192.168.50.1` (the bastion).

### 2. SSH Hardening Verification
* **Verify password authentication is rejected:**
  ```bash
  ssh -o PubkeyAuthentication=no client1
  ```
  *Result:* `Permission denied (publickey)`.
* **Verify direct root login is disabled:**
  ```bash
  ssh client1 "sudo grep -E '^(PermitRootLogin|PasswordAuthentication)' /etc/ssh/sshd_config.d/60-remote-hardening.conf"
  ```
  *Result:* `PermitRootLogin no`, `PasswordAuthentication no`.

### 3. Fail2ban Brute-Force Protection
* **Trigger ban via repeated unauthorized key attempts:**
  ```bash
  ssh client1 "for i in {1..4}; do ssh -o IdentitiesOnly=yes -i /dev/null -o StrictHostKeyChecking=no 192.168.50.1 2>/dev/null; done"
  ```
* **Inspect ban status on bastion:**
  ```bash
  ssh bastion "sudo fail2ban-client status sshd"
  ```
  *Result:* `Banned IP list: 192.168.50.50`.

### 4. Fleet Automation (`fleet/run.sh`)
* **Execute default administrative health check:**
  ```bash
  fleet/run.sh
  ```
* **Execute custom arbitrary command across fleet:**
  ```bash
  fleet/run.sh "uptime"
  ```
  *Result:* Formatted per-host execution blocks followed by summary report (`bastion OK`, `client1 OK`, `client2 OK`, `loghost OK`).

### 5. Centralized Logging Demonstration
* **Execute an administrative `sudo` action on an internal host:**
  ```bash
  ssh client1 "sudo id"
  ```
* **Inspect centralized collector without logging into client1:**
  ```bash
  ssh loghost "grep sudo /var/log/remote/192.168.50.50.log | tail -n 2"
  ```
  *Result:* Live log record shows `client1` hostname, timestamp, user, and executed command.

### 6. Key Rotation & Verification
Follow the full procedure documented in [runbook-key-rotation.md](file:///home/saidxp/remote/runbook-key-rotation.md):
* Generate new keypair: `ssh-keygen -t ed25519 -f ~/.ssh/admin1_new -N ""`
* Deploy across fleet: `fleet/run.sh "echo '$(cat ~/.ssh/admin1_new.pub)' | sudo tee /home/admin1/.ssh/authorized_keys > /dev/null"`
* Prove new key succeeds: `ssh -i ~/.ssh/admin1_new client1 "whoami"`
* Prove revoked key is rejected: `ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes client1 "whoami"` (`Permission denied (publickey)`).

---

## 5. Detailed Engineering Change Log (S0 — S13)

### S0 — Initialize Remote Project
- **WHAT:** Cloned verified `connect` repository structure into `remote/`.
- **WHERE:** `~/remote/` (`Vagrantfile`, `provision/`, `keys/`, `systemd/`).
- **WHY:** Build incrementally upon verified dual-subnet network base.
- **PROVEN:** Directory structure validated.

### S1 — Disambiguate VirtualBox Instance Identifiers
- **WHAT:** Renamed VirtualBox VM names to prevent naming collisions.
- **WHERE:** `Vagrantfile` (`remote-gateway`, `remote-client1`, `remote-client2`).
- **WHY:** Allow concurrent or cleanly separated execution without VirtualBox metadata conflicts.
- **PROVEN:** `grep vb.name Vagrantfile`.

### S2 — Decommission Legacy Connect Environment
- **WHAT:** Executed `vagrant destroy -f` in `connect` directory.
- **WHERE:** `~/connect`.
- **WHY:** Prevent resource exhaustion and port conflicts (`2222`, intnet collision).
- **PROVEN:** `VBoxManage list vms` verified empty.

### S3 — Reproduce Connect Network Baseline
- **WHAT:** Rebuilt multi-VM network from code.
- **WHERE:** `~/remote/build.log`.
- **WHY:** Validate baseline services prior to implementing security layer.
- **PROVEN:** Gateway NAT, DHCP reservation (`192.168.50.50`), static assignment (`192.168.60.10`), DNS resolution (`client-b`), and inter-subnet ICMP routing operational.

### S4 — Bastion Architecture Designation
- **WHAT:** Designated gateway instance as the bastion host.
- **WHERE:** `README.md`, `Vagrantfile`.
- **WHY:** Only instance attached to external WAN interface.
- **PROVEN:** Architecture design confirmed.

### S5 — External Ingress Forwarding
- **WHAT:** Configured dedicated external SSH forward on host loopback.
- **WHERE:** `Vagrantfile` (`guest: 22, host: 2022, host_ip: "127.0.0.1", id: "bastion-ssh"`).
- **WHY:** Establish single controlled perimeter gate.
- **PROVEN:** `nc -zv 127.0.0.1 2022` returned OpenSSH banner.

### S6 — Internal Host Ingress Lockdown
- **WHAT:** Enforced packet filtering restricting port 22 to bastion source IP.
- **WHERE:** `provision/bastion.sh` (`nftables` input chain).
- **WHY:** Internal hosts must refuse external and lateral unauthenticated SSH.
- **PROVEN:** External probes to client IPs drop; inter-client lateral SSH drops; bastion-originated SSH accepts.
- **NOTE:** Preserved `iifname "enp0s3" tcp dport 22 accept` specifically for local Vagrant automation lifecycle.

### S7 — Structure Realignment
- **WHAT:** Consolidated security provisioners into subject-prescribed naming.
- **WHERE:** `provision/bastion.sh`.
- **WHY:** Strict compliance with evaluation structure requirements.
- **PROVEN:** `vagrant validate` clean.

### S8 — Fleet-Wide OpenSSH Hardening
- **WHAT:** Deployed standardized hardened server configuration.
- **WHERE:** `ssh/sshd_config` deployed to `/etc/ssh/sshd_config.d/60-remote-hardening.conf`.
- **WHY:** Eliminate password-based authentication, enforce key security, disable root login, and set `LogLevel VERBOSE` for auditability.
- **PROVEN:** `sshd -T` audit confirmed settings across all hosts.

### S9 — Client ProxyJump Orchestration
- **WHAT:** Authored drop-in OpenSSH client routing configuration.
- **WHERE:** `ssh/ssh_config` (installed to `~/.ssh/config`).
- **WHY:** Single-command transparent administrative jumping (`ssh client1`).
- **PROVEN:** `ssh client1 "echo \$SSH_CLIENT"` validated connection originating from gateway LAN interface.

### S10 — Aggressive Brute-Force Mitigation
- **WHAT:** Implemented `fail2ban` jail on bastion host.
- **WHERE:** `provision/bastion.sh` (`/etc/fail2ban/jail.local`).
- **WHY:** Protect perimeter against public key brute-force attempts.
- **PROVEN:** `mode = aggressive` successfully parsed `VERBOSE` sshd logs; 5 failed key attempts resulted in ban of `192.168.50.50`.

### S11 — Resilient Fleet Automation Engine
- **WHAT:** Created fault-tolerant batch administration script.
- **WHERE:** `fleet/run.sh`.
- **WHY:** Single-command execution across all nodes with per-host exit tracking.
- **PROVEN:** Verified loop execution against all hosts with aggregate summary table.

### S12 — Centralized Audit Logging Infrastructure
- **WHAT:** Deployed dedicated `loghost` VM (`192.168.50.20`) with rsyslog UDP 514 aggregation.
- **WHERE:** `provision/logging.sh`, `Vagrantfile`, `provision/gateway.sh`.
- **WHY:** Immutable, off-host storage of security events and administrative actions.
- **PROVEN:** Verified `/var/log/remote/<IP>.log` files populated from gateway, client1, and client2 across routing boundary.

### S13 — Incident Response & Cryptographic Key Rotation
- **WHAT:** Authored actionable runbook for key rotation and compromise mitigation.
- **WHERE:** `runbook-key-rotation.md`.
- **WHY:** Subject compliance for credential lifecycle management.
- **PROVEN:** Documented end-to-end rollout, verified new key acceptance, and demonstrated rejection of revoked keypair.
