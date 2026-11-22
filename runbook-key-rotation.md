# Runbook: SSH Key Rotation

## 1. Overview & Objective

This runbook documents the standard operating procedure for rotating an SSH keypair for an administrative or service account (e.g., `admin1`) across the fleet.

Key rotation ensures:
- Compromised or outdated keys are revoked.
- Zero downtime during transition.
- Explicit verification and proof that old keys are rejected.

---

## 2. Prerequisites

- Admin access to the bastion host (`bastion` on `127.0.0.1:2022`).
- Access to `fleet/run.sh` from the management laptop.
- Local OpenSSH client tools (`ssh-keygen`, `ssh`).

---

## 3. Step-by-Step Rotation Procedure

In this example, we rotate the key for user `admin1`.

### Step 1: Generate a New Keypair
On your local workstation, generate a new Ed25519 keypair:

```bash
# Generate the new key
ssh-keygen -t ed25519 -C "admin1-rotated-$(date +%Y%m%d)" -f ~/.ssh/admin1_new -N ""
```

You now have:
- Private key: `~/.ssh/admin1_new`
- Public key: `~/.ssh/admin1_new.pub`

---

### Step 2: Verify Access with the Current (Old) Key
Before rotating, confirm access works with the current key:

```bash
ssh -i ~/.ssh/id_ed25519 -p 2022 admin1@127.0.0.1 "whoami; hostname"
```
*Expected Output:*
```text
admin1
remote-gateway
```

---

### Step 3: Distribute the New Public Key Fleet-Wide

Deploy the new public key into `~admin1/.ssh/authorized_keys` across the fleet using `fleet/run.sh`:

```bash
NEW_KEY=$(cat ~/.ssh/admin1_new.pub)

# Replace the authorized_keys with the new key across the fleet
fleet/run.sh "echo '$NEW_KEY' | sudo tee /home/admin1/.ssh/authorized_keys > /dev/null && sudo chmod 600 /home/admin1/.ssh/authorized_keys"
```

*Expected Output:*
```text
==================== SUMMARY =====================
  bastion    OK
  client1    OK
  client2    OK
  loghost    OK
==================================================
```

---

### Step 4: Permanent Update in the Project Repository

To ensure key changes persist across future `vagrant destroy -f && vagrant up` rebuilds, update the stored public key file in the repo:

```bash
cp ~/.ssh/admin1_new.pub ~/remote/keys/admin1.pub
```

---

## 4. Verification & Proof of Rotation

### Test A: Verify the NEW Key Works
Attempt SSH login with the newly created private key:

```bash
ssh -i ~/.ssh/admin1_new -p 2022 admin1@127.0.0.1 "echo 'New key accepted: \$(whoami) on \$(hostname)'"
```

*Proof / Expected Result (SUCCESS):*
```text
New key accepted: admin1 on remote-gateway
```

---

### Test B: Verify the OLD Key is REJECTED
Attempt SSH login using the revoked (old) private key:

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p 2022 admin1@127.0.0.1 "echo 'This should not run'"
```

*Proof / Expected Result (REJECTED):*
```text
admin1@127.0.0.1: Permission denied (publickey).
```

---

## 5. Rollback Procedure

If the new key fails verification before removing old access:
1. Re-add the previous public key (`~/remote/keys/admin1.pub.bak`) to `/home/admin1/.ssh/authorized_keys`.
2. Inspect `/var/log/auth.log` or syslog on `loghost` to identify why the key was rejected (e.g., incorrect permissions on `.ssh` or `authorized_keys`).
