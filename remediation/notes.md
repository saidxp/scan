# Remediation Notes — Isolated DVWA Target

How each finding was fixed, why it was fixed this way, and the one ordering trap that
broke the fix until it was understood.

Everything here is applied by provisioning code, so `vagrant destroy -f && vagrant up`
brings the fixes back. Nothing was patched by hand on a live machine.

---

## F1 — Bastion bypass (direct SSH to internal hosts)

**Cause.** Vagrant automatically publishes a host port forward for SSH on every VM
(`2200`, `2201`, `2202`, `2203`, …), bound to `127.0.0.1`. That is a second door into the
internal hosts that ignores the bastion entirely.

**Fix.** On each internal host, drop `tcp/22` unless the source is the bastion's LAN
address. Implemented by the `internal` role of
[provision/bastion.sh](file:///home/saidxp/scan/provision/bastion.sh):

```
table inet filter {
  chain input {
    type filter hook input priority filter; policy accept;
    iifname "lo" accept
    ct state established,related accept
    tcp dport 22 ip saddr 192.168.50.1 accept    # subnet A copies: bastion
    tcp dport 22 drop
  }
}
```

The source IP differs per subnet — `192.168.50.1` on subnet A, `192.168.60.1` on subnet B —
and is passed as the provisioner argument in the
[Vagrantfile](file:///home/saidxp/scan/Vagrantfile).

**Note.** Vagrant still needs a working management channel to run `vagrant ssh` and the
lifecycle itself, so the design keeps the bastion (the only NAT-facing host) reachable and
closes the direct forwards on the internal hosts, rather than removing the forwards.

**Why not just remove the forwards?** They are recreated by Vagrant's default provider
behaviour on every `up`; filtering them at the guest is what actually survives a rebuild.

---

## F2 + F3 — Contain, don't patch

DVWA is a **deliberately vulnerable third-party image**. There is no supported patch — its
whole purpose is to be exploitable. So the right control is not to fix the app; it is to
**box it in at the network layer** so that its weaknesses cannot be reached by anyone who
should not, and cannot call out if they are.

Implemented by the `contain` mode of [provision/dvwa.sh](file:///home/saidxp/scan/provision/dvwa.sh),
which writes a dedicated nftables table `inet dvwa-contain`:

| Chain | Purpose | Rule of thumb |
|---|---|---|
| `input` | F2 — who may reach the web app | allow `tcp/80` **only** from `192.168.60.10`, then drop |
| `output` | F3 — what the host may reach | allow loopback + internal ranges, then drop |
| `forward` | F3 — what the app's containers may reach | allow `br-*` to internal ranges, then drop |

Three details that matter:

1. **Priority `-10`.** Each chain is hooked at `priority filter - 10`, so containment is
   evaluated *before* the host's normal filter chains. It therefore applies regardless of
   what the rest of the ruleset says.
2. **The `forward` chain is needed because of `br_netfilter`.** Container-to-container
   traffic on the Docker bridge traverses the netfilter **forward** hook, not just
   input/output. Without the forward chain, containers could still talk out.
3. **Re-runs must not stack rules.** `contain` first truncates its own block
   (`sed -i '/# DVWA containment (F2 + F3) - start/,$d'`) before re-appending, and
   `nft -c -f` validates the file before `systemctl restart nftables`.

### The ordering trap (this is what broke the first rebuild)

`bastion.sh` owns `/etc/nftables.conf`: it runs `flush ruleset` and rewrites the whole file
with `cat >`. Anything a different provisioner wrote into that file beforehand is **erased**.

So when `dvwa.sh contain` ran *before* `bastion.sh`, the containment table vanished on the
next boot — the box came up with only `table inet filter`. The fix is purely ordering: in
the
[Vagrantfile](file:///home/saidxp/scan/Vagrantfile), the DVWA block now runs `contain`
**last**, after `bastion.sh`:

```ruby
target.vm.provision "shell", path: "provision/dvwa.sh", args: "network"
target.vm.provision "shell", path: "provision/provision.sh"
target.vm.provision "shell", path: "provision/logging.sh", args: "client 192.168.50.20"
target.vm.provision "shell", path: "provision/dvwa.sh", args: "application"
target.vm.provision "shell", path: "provision/bastion.sh", args: "internal 192.168.60.1"
# Must run LAST: bastion.sh rewrites /etc/nftables.conf with 'flush ruleset'.
target.vm.provision "shell", path: "provision/dvwa.sh", args: "contain"
```

### The bootstrapping catch

Containment blocks egress — but installing Docker and pulling images *needs* egress. So the
earlier provisioning stages (`network`, `application`) call `lift_containment()`, which
deletes `table inet dvwa-contain` while packages and images download. `contain` re-applies
it at the end. Without this, a rebuild on a host that already had containment would fail to
download.

---

## Verification

After `vagrant destroy -f && vagrant up`, both tables are present and every check passes —
see
[scans/after/f2f3-containment-after.txt](file:///home/saidxp/scan/scans/after/f2f3-containment-after.txt)
and
[scans/after/f1-direct-ssh-blocked.txt](file:///home/saidxp/scan/scans/after/f1-direct-ssh-blocked.txt).
Full finding-by-finding results are in
[report/assessment.md](file:///home/saidxp/scan/report/assessment.md#7-step-6--verification-destroy--rebuild--re-scan).
