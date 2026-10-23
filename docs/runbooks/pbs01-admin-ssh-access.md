# pbs01 admin SSH access — design and change package

**Host affected**: pbs01 (10.10.10.30, Proxmox Backup Server 4.2) · **Requesting host**: operator workstation `ubuntu` (192.168.88.249)
**Motive**: eliminate the browser-shell copy-paste tax on every pbs01 administration task.
**Compliance**: ISO 27001 A.8.2 / A.8.5 / A.8.20 / A.8.13 · SOC 2 CC6.1 / CC6.6 · GDPR Art. 5(1)(f), Art. 32
**⚠ NO CREDENTIALS in this document.** Secrets are typed by the operator only (§0.1).

---

## 0. Verdict (professional opinion) — REVISED 2026-10-22 after measurement

**Do Option B — one `/32` accept line on pbs01. Do not do Option A, and do not touch the router.**

The original verdict in this file (Option A: L2 membership in VLAN 10 on the workstation's second NIC)
rested on a premise that measurement has now **falsified**: it claimed the workstation "has no VLAN 10 path
at all". It does have one. Probed from `192.168.88.249` on 2026-10-22:

| Target | Result | What it proves |
|--------|--------|----------------|
| `10.10.10.2` (N2048 mgmt — a VLAN-10 host) | `:80` OPEN, `:23` OPEN, ICMP OK | the MikroTik **does** forward `defconf → vlan10` |
| `10.10.10.11` (iDRAC prox01 — VLAN 10) | `:443` OPEN | not a one-host accident |
| `10.10.10.30` (pbs01) | **ICMP OK**, `:22` and `:8007` closed | pbs01 is reachable; only its own input rules refuse the source |
| hv01's `ss -tn` view of this operator's live session | peer = `192.168.88.249:43588` | the router **does not masquerade** inter-VLAN traffic, so a `/32` source rule on pbs01 can actually match |

The earlier `:8007` timeout had been read as a router block. It is not: pbs01 has no `8007` accept for
`192.168.88.0/24` either, so that packet was always going to be refused at the host — the observation was
consistent with a host-only block and was over-interpreted. Same for `:22`.

Consequence: **Option B is a one-device change, not the two-device change this file assumed.** Option A
buys nothing Option B does not, while costing a physical cable trace, a switch-port change, a static
address, and a permanently dual-homed workstation. Option A is retained below but **downgraded** — it is
the right answer only if the operator later wants standing L2 adjacency to the whole management VLAN
(switch, iDRACs), which is a larger blast radius than the single peer actually needed.

Option C (widen to a `/24`) stays rejected — see §4.

---

## 1. What is actually blocking (measured 2026-10-22, not inferred)

Captured from a root shell obtained through the PBS Web UI xterm.js console (the UI is reachable over the
permitted 8007 path via a loopback tunnel — that is how this evidence was gathered without SSH, which is
the blocked resource):

```nft
type filter hook input priority filter; policy drop;
tcp dport 22   ip saddr 10.10.10.0/24  accept      # ← the only SSH allowance
tcp dport 8007 ip saddr 10.10.10.0/24  accept
tcp dport 8007 ip saddr 10.60.60.0/24  accept      # ← backup data path from hv01
tcp dport 8007 ip saddr 10.30.30.10    accept      # ← backup data path from llm-prod-lt01
```
Backed up to `/root/prechange-20261022/pbs01-nft.txt` (+ `etc-pbs.tar.gz`, mode 600) on pbs01.

| Layer | State | Consequence |
|-------|-------|-------------|
| pbs01 nftables | `policy drop`, SSH from `10.10.10.0/24` only | **independently sufficient to block** every non-VLAN-10 source — confirmed, not inferred |
| MikroTik forward matrix | **MEASURED 2026-10-22 — does not block this path.** `10.10.10.2:80/:23` and `10.10.10.11:443` answer from `192.168.88.249`; pbs01 answers ICMP; hv01 sees the true peer `192.168.88.249` (no masquerade) | **not a blocker for `defconf → vlan10`.** The 2026-08-29 audit summary `vlan60 → vlan10:8007` describes the **VLAN-60** source and does not generalise to the defconf bridge. `/ip firewall filter print` still owed for the record |
| Source host | admin01 (10.10.10.50) answers no ICMP, no TCP | the designed SSH source no longer exists on the network |
| fail2ban | `ignoreip 127.0.0.0/8, 10.10.10.0/24`; 3 retries → 24 h; counters 0 failed / 0 banned | any new SSH source becomes bannable |

**The distinction that makes Option A/B acceptable and Option C not:** the workstation is **not** a backup
data-path source. The addresses that must reach `8007` are `10.60.60.20` (hv01) and `10.30.30.10` (llm).
Exposing SSH to the workstation therefore cannot ban a backup path. Exposing SSH to `10.60.60.0/24` can —
that is the specific reason the hypervisor segment stays out, and it is already forbidden by
`docs/runbooks/hv01-storage-backup-reconfiguration.md` §6 ("fail2ban must never be able to ban a
backup-path source").

Measured enabler on the workstation (2026-10-22):

```text
enp8s0  04:d9:f5:c8:ba:36  UP  1000  192.168.88.249/24  DHCP  → office/defconf bridge, internet, work
enp9s0  04:d9:f5:c8:ba:35  UP  1000  (no address)       ← cabled, linked, unused
```

---

## 2. Option A — VLAN 10 L2 membership on `enp9s0` (recommended)

### 2.1 Preconditions (check before configuring anything)

a. **Find which switch port `enp9s0` lands on.** From the workstation, flap the link and watch for the port
   LED, or trace the cable physically:
   ```bash
   sudo ip link set enp9s0 down; sleep 3; sudo ip link set enp9s0 up
   ```
b. **Preferred route: re-home that cable into admin01's port `Gi1/0/47`** — documented as
   `access vlan 10`, `Active`, and its device is dead. That requires **no switch configuration at all**.
   ⚠ Verify `Gi1/0/47` has no `port-security` pinned to admin01's MAC (`maximum 1 / violation shutdown`
   was armed elsewhere in this fleet, see vlan-audit §3): a violation err-disables the port. Clearing it
   needs N2048 admin access, which is a **known-open credential gap** (vlan-audit F2: supplied password
   rejected 2/2 after the 2026-08-08 rotation). If the port is already sticky-locked to admin01, either
   clear it on the switch or use any other free VLAN 10 access port.
c. **Pick a collision-free address.** `10.10.10.50` is admin01's documented address; reuse it only once
   admin01 is formally retired (it is also pbs01's documented chrony Stratum-3 peer — retiring the host
   breaks NTP on pbs01, so **prefer a new address such as `10.10.10.51`** and fix chrony separately).
   Probe from pbs01 before claiming it:
   ```bash
   # [PBS01 shell]
   ping -c 2 -W 1 10.10.10.51; ip neigh | grep 10.10.10.51
   ```
   Then reserve it on the router's DHCP scope so nothing else is handed it.

### 2.2 Workstation configuration (⚠ netplan is NOT the right tool on this host)

Measured 2026-10-22: `/etc/netplan/01-network-manager-all.yaml` + six auto-generated
`90-NM-*.yaml` files ⇒ **NetworkManager is the renderer**, and `enp9s0` is NM-managed
(`nmcli device` → `disconnected`). Hand-authoring a netplan file here fights NM's own
connection store, so the earlier `90-pbs-mgmt.yaml` recipe is withdrawn. Use NM, and pin the
interface to exactly one peer with a `/32` — L2 adjacency to the whole management VLAN is not
needed to reach pbs01:

```bash
# [WORKSTATION] — one peer only, never-default, no DNS on this NIC
sudo nmcli connection add type ethernet ifname enp9s0 con-name pbs-mgmt \
  ipv4.method manual ipv4.addresses 10.10.10.51/32 \
  ipv4.never-default yes ipv4.ignore-auto-dns yes ipv6.method disabled \
  connection.autoconnect yes
sudo nmcli connection up pbs-mgmt
nmcli -f IPV4.ADDRESS,IP4.ROUTES connection show pbs-mgmt
ip route add 10.10.10.30/32 dev enp9s0 scope link   # or as a persistent ipv4.routes entry
ip route get 10.10.10.30                            # must be: 10.10.10.30 dev enp9s0 scope link
ip route | grep -c '^default'                       # must still be exactly 1 (enp8s0)
```

Rollback: `sudo nmcli connection delete pbs-mgmt`.

**Why the N2048 VLAN 10 ARP bug does not bite here:** the documented firmware defect breaks
broadcast/ARP flooding across **trunk `Gi1/0/48`**, which is why pbs01 carries a permanent ARP entry for
the *gateway* `10.10.10.1`. Workstation ↔ pbs01 are both access ports in the same VLAN on the same switch,
so their ARP never traverses that trunk. Do not add a gateway to `enp9s0`; if you do, you re-enter the bug.

### 2.3 Security constraints that come with Option A (⚠ the first was unsatisfiable as written)

- ~~`net.ipv4.ip_forward = 0` on the workstation, permanently.~~ **Impossible on this host.** Measured
  2026-10-22: `ip_forward = 1` while the sysctl line in `/etc/sysctl.d/99-sysctl.conf` is **commented
  out** ⇒ the value is set at runtime by `dockerd`, which requires it. Zeroing it breaks every container
  and is re-set on the next daemon start — a green gate that proves nothing. The enforceable equivalent
  is to deny forwarding *through the management interface* at Docker's own documented, restart-surviving
  hook, and to prove it empirically:
  ```bash
  # [WORKSTATION] DOCKER-USER survives daemon restarts; raw iptables -I FORWARD does not
  sudo iptables -I DOCKER-USER -o enp9s0 -j DROP
  sudo iptables -I DOCKER-USER -i enp9s0 -j DROP
  docker run --rm alpine sh -c 'nc -kvz -w3 10.10.10.30 22' \
    && echo "LEAK — a container can reach the backup server; fix before proceeding"
  ```
  A dual-homed host with unrestricted forwarding is a bridge from the office/IoT-adjacent segment into
  the management VLAN, which is the risk this bullet was written to close.
- No default route, no DNS server on `enp9s0` (`ipv4.never-default yes` in §2.2 is what enforces it).
- The workstation runs Docker bridges (`br-…*`, `docker0`) and a browser with agent tooling. It is now
  L2-adjacent to the backup server. This is the **residual risk accepted** by this design — it is the same
  posture admin01 was built for, and it is why the pbs01 side stays key-only with fail2ban intact.

### 2.4 Payoff

```sshconfig
# ~/.ssh/config   [WORKSTATION]
Host pbs01
    HostName 10.10.10.30
    User root
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 30
    ServerAliveCountMax 5
```
Then `ssh pbs01`, `scp`, `rsync`, and `ssh pbs01 'nft list ruleset' | tee evidence/…` replace every
browser-shell paste. Keep using the UI shell only as the out-of-band fallback if SSH regresses.

---

## 3. Option B — single `/32` accept on pbs01 (**now the recommended path — see §0**)

**One device, one line.** §0's measurement removed the two-device assumption: the router already
forwards `defconf → vlan10` and preserves source addresses, so no MikroTik change is required and
**step 2 below is cancelled** (kept only as a contingency if a future router rebuild drops the path).

1. `[WORKSTATION]` Make the source stable first — it is DHCP today (`192.168.88.249` via `proto dhcp`).
   Create a DHCP reservation on the router and confirm the lease before writing any rule; a `/32`
   allowlist against a rotating address silently rots into "sometimes SSH works". Until the reservation
   exists, treat the rule as provisional.
2. `[MIKROTIK]` — **NOT REQUIRED** (measured). Retained as contingency only: if a future RouterOS
   rebuild removes the `defconf → vlan10` forward, add it with **no source-NAT**, so pbs01 logs and
   fail2ban keep seeing the true operator address:
   ```
   /ip firewall filter add chain=forward action=accept src-address=192.168.88.249/32 \
     dst-address=10.10.10.30/32 dst-port=22 protocol=tcp place-before=<the vlan10 drop line> \
     comment="JOL: workstation -> pbs01 SSH (change <ticket>)"
   ```
3. `[PBS01]` Host rule — the only mutation needed. Added as a **file edit, not a live `nft add`**,
   so it survives a reboot and stays reviewable:
   ```bash
   ls -l /etc/nftables.conf /etc/nftables.d/ 2>/dev/null; grep -n "dport 22" /etc/nftables.conf
   cp -a /etc/nftables.conf /root/prechange-20261022/nftables.conf.bak
   ```
   Then add, immediately after the existing `tcp dport 22 ip saddr 10.10.10.0/24 accept` line:
   `tcp dport 22 ip saddr 192.168.88.249/32 accept`
   **Apply with a dead-man switch** — never lock yourself out of a box with no IPMI:
   ```bash
   nft -c -f /tmp/nft.new                            # syntax gate, MUST pass first
   systemd-run --on-active=5min --unit=nft-rollback /usr/sbin/nft -f /root/prechange-20261022/nftables.conf.bak
   nft -f /etc/nftables.conf
   ```
   ⚠ The gate is `nft -c -f FILE`, **not** `nft check ruleset -f FILE`. The latter is rejected by nft
   itself (`Error: syntax error, options must be specified before commands`) because `-f` is an nft
   *option* and must precede the command — a mistake that cost a round-trip on 2026-10-22. Note the
   distinction when it fails: a broken gate is not a broken change. Verified preconditions for this
   host, captured 2026-10-22: ruleset source is `/etc/nftables.conf` (exactly one file), `accept`-rule
   count running == file == **9** (so `nft -f` cannot silently drop out-of-band rules), and
   `systemctl is-enabled nftables` → `enabled` (so the file edit survives a reboot).
4. Do **not** add the workstation to fail2ban `ignoreip`. It is not a data-path source, so a 24 h ban after
   three typos is the correct cost; exempting it would strip brute-force protection from an internet-facing
   desktop.
5. File **ADR-008 "Admin SSH reachability to the backup server"** (AGENTS.md §1 Dependency Rules 3:
   cross-VLAN requires an ADR) — authored at `docs/adr/ADR-008-pbs01-admin-ssh.md`.

---

## 4. Option C — rejected

| Proposal | Why rejected |
|----------|--------------|
| `22` from `10.60.60.0/24` | routes every VM on the hypervisor (rag/mcp/her, one with internet egress) to root SSH on the box holding their own backups — "delete the backups, then encrypt". Also makes `10.60.60.20` bannable, i.e. a typo becomes a backup+restore outage; forbidden by hv01 runbook §6. |
| `22` from `192.168.88.0/24` | that /24 is the router's `defconf` bridge, shared with home/IoT (WR841N, vlan80 per vlan-audit §2). A /24 allowlist on a backup server for an IoT-bearing LAN is not defensible under A.8.20/CC6.6. |
| Move SSH to another port | irrelevant: the filter is source-subnet based. Proven by the 2026-10-22 probes — `2222/8422/22222` all time out while `8007` answers instantly on the same host. |
| Disable fail2ban to reduce friction | removes the only control protecting a key-only root login on an Art. 9 data custodian. |

---

## 5. Both options — sshd-side checks before declaring success

pbs01 is already key-only with `AllowUsers root` (§SSH Policy). Confirm rather than assume, and confirm
the operator's public key is actually authorised — the "SSH keys deployed" claim of 2026-08-01 has never
been functionally verified because no SSH session has ever succeeded from here:

```bash
# [PBS01]
sshd -T | grep -Ei "passwordauthentication|pubkeyauthentication|allowusers|maxauthtries|permitrootlogin"
loginctl --no-pager 2>/dev/null; wc -l /root/.ssh/authorized_keys; ssh-keygen -lf /root/.ssh/authorized_keys
```
If the workstation key is absent, append the **public** key (never a private key), then `chmod 700 /root/.ssh`
`chmod 600 /root/.ssh/authorized_keys`. The key to expect or add is the workstation's
`~/.ssh/id_ed25519.pub` = `256 SHA256:5wSsJlMIANmTTvucmimQqYlVGsyVmq8daj7nOZkWlws
ubuntu24-jol-server-auth (ED25519)` — the fleet server-auth key, measured on the workstation
2026-10-22. Public-key material is not a secret; the matching private key must never leave the
workstation.

---

## 6. Rollback

| Option | Rollback |
|--------|----------|
| A | `sudo nmcli connection delete pbs-mgmt` and remove the two `DOCKER-USER` rules — workstation leaves VLAN 10; no server-side artefact exists to unwind. |
| B (host) | `cp -a /root/prechange-20261022/nftables.conf.bak /etc/nftables.conf && nft -f /etc/nftables.conf` (or let the 5-min dead-man unit do it), then remove the router rule. |
| B (router) | `/ip firewall filter remove <id>`; verify with `/ip firewall filter print` that the line count returns to the captured baseline. |
| Key | remove the appended line from `/root/.ssh/authorized_keys` from the UI shell. |

---

## 7. Acceptance gates (§0.4 — every box needs command output)

```text
✔ Path exists            [WORKSTATION] ssh -o BatchMode=yes -o ConnectTimeout=5 root@10.10.10.30 hostname
                         → "pbs01" on the FIRST attempt, 2026-10-22 (key-only, no password path)
✔ Single default route   [WORKSTATION] ip route | grep -c '^default' → 1 (via 192.168.88.1, enp8s0)
✔ Not dual-homed         [WORKSTATION] ip route | grep -c '10\.10\.10\.' → 0 — Option A was never applied,
                         so enp9s0 carries no address and the whole container-leak / ip_forward risk class
                         that §2.3 was written to close never came into existence. That section is now
                         contingency-only guidance for Option A.
✔ Rule is on disk        [PBS01] /etc/nftables.conf line 25 AND `nft list ruleset` line 10 both show it;
                         `nftables.service` enabled ⇒ survives reboot
✔ True source logged     [PBS01] journalctl -u ssh → "from 192.168.88.249" — the operator address, NOT
                         10.10.10.1 ⇒ no masquerade on this path (the §0 premise, confirmed server-side)
✔ fail2ban intact        [PBS01] ignoreip still `127.0.0.0/8, 10.10.10.0/24` — no exemption added;
                         0 failed / 0 banned, i.e. the first SSH attempt succeeded without an auth failure
✔ Nothing else lost      [PBS01] `accept` count 9 → 10 (exactly +1); all four original accepts plus
                         `ip protocol icmp` / `ip6 nexthdr ipv6-icmp` still present after `nft -f`
✔ Audit trail            [PBS01] 1 event `key="firewall"` for /etc/nftables.conf at 2026-10-22T18:28:48Z
                         (⚠ query gotchas that nearly produced a false "no audit" finding: the log is
                         log_format=ENRICHED ⇒ partly binary, needs `grep -a`; keys are QUOTED
                         (`key="firewall"`); raw records use lowercase `type=`. See evidence §11)
✔ Backup path unaffected [HV01] hv01 → pbs01:8007 still OPEN; [PBS01] `acl list` table byte-identical
                         Note: the `pbs01` storage on hv01 is still `inactive` — that is the separate
                         1-byte `pbs01.pw` credential defect, untouched by this change
◻ Change record          CHANGELOG.md row + this file's Change History + ADR-008 → all written;
                         ⚠ the CC8.1 GitHub ISSUE is still to be raised by the operator
⚠ STILL OPEN             DHCP reservation for 192.168.88.249 — the address is still `proto dhcp`, so the
                         /32 can rot; until reserved, this allowance is provisional
⚠ STILL OPEN             /ip firewall filter print on the MikroTik (no longer load-bearing, owed for record)
```

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-10-22 | Package authored. Recommendation: Option A (VLAN 10 L2 membership on the workstation's unused, already-linked `enp9s0`), because the gap is a missing host in the designed admin VLAN rather than a misconfigured rule — it needs no firewall change and no ADR. Option B documented as fallback with dead-man rollback; Option C rejected. Grounded in the captured pbs01 ruleset, the fail2ban `ignoreip` capture, and the measured workstation NIC state | `/root/prechange-20261022/pbs01-nft.txt` on pbs01; `docs/servers/pbs01.md` §Admin SSH Path |
| 2026-10-22 (executed) | **Option B applied and verified — pbs01 SSH-reachable from the workstation.** `/etc/nftables.conf` line 25 `tcp dport 22 ip saddr 192.168.88.249/32 accept`, gated by `nft -c -f`, rolled back by a 5-min `systemd-run` dead-man that was disarmed after verification; pre-change file at `pbs01:/root/prechange-20261022/nftables.conf.bak`. All §7 gates show output except the CC8.1 issue and the DHCP reservation (both open). Two things the execution proved about the design: (a) `accept` count went 9 → 10 with every original rule intact, so the §3 pre-flight count comparison is the right guard for `nft -f` on this host; (b) pbs01 logged the session as `from 192.168.88.249`, confirming server-side that no masquerade sits on this path — the fact that made a `/32` viable at all. Option A was **not** executed, so §2.2/§2.3 (nmcli profile, `DOCKER-USER` drops, container-leak probe) are demoted to contingency guidance: `enp9s0` still carries no address and the workstation has no route into `10.10.10.0/24` except via its default gateway, so the dual-homing risk class never materialised. New finding raised during verification: pbs01's clock is **+65.657 s fast** with a dead chrony peer (`10.10.10.50` = offline admin01), `Reach 0`, never synced since boot — SOC 2 CC7.2 / ISO A.8.16 impact on every audit and snapshot timestamp this host produces; deliberately left as a separate change because stepping a backup server's clock backwards needs its own record and an idle window | `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` §1–§11; ADR-008 status Accepted |
| 2026-10-22 (same day, **recommendation reversed**) | Option A's premise falsified by direct measurement, so **Option B is now the recommendation**: from `192.168.88.249` the workstation reaches `10.10.10.2:80/:23`, `10.10.10.11:443` and answers ICMP on `10.10.10.30` ⇒ the MikroTik **does** forward `defconf → vlan10`, and pbs01's own input rules are the sole blocker. hv01's `ss -tn` shows peer `192.168.88.249` ⇒ no inter-VLAN masquerade, so a `/32` source rule can match. Option B is therefore **one line on one device**, not two. The earlier `:8007` timeout was over-interpreted: pbs01 refuses that source for `8007` too, so the observation never discriminated between the layers. Also corrected: (a) the `ip_forward = 0` gate is **unsatisfiable** on this host — `dockerd` sets it and the sysctl line is commented out — replaced by a `DOCKER-USER` drop plus an empirical container probe; (b) netplan authoring withdrawn, this desktop renders through **NetworkManager** (`01-network-manager-all.yaml` + `90-NM-*.yaml`), so an `nmcli` profile with `ipv4.never-default yes` and a `/32` is the correct, least-privilege form; (c) Option A downgraded to contingency, its blast radius (whole mgmt VLAN) larger than the need (one peer) | this file §0 probe table; `nft list ruleset` captured to `/root/prechange-20261022/pbs01-nft-full.txt`; `nmcli`/`sysctl`/`/etc/netplan` inspection 2026-10-22 |
