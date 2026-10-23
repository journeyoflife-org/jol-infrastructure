# ADR-008: Admin SSH Reachability to the Backup Server (pbs01)

## Status

**Accepted — executed and verified 2026-10-22.**

Applied: `tcp dport 22 ip saddr 192.168.88.249/32 accept` at `/etc/nftables.conf` line 25, behind an
`nft -c -f` syntax gate and a 5-minute `systemd-run` dead-man rollback (disarmed after verification).
`ssh root@10.10.10.30 hostname` from the workstation returns `pbs01` on the first attempt, and pbs01's own
auth log records the connection as coming from `192.168.88.249` — proving the router preserves the source,
which is the premise this decision rests on.

Verified unchanged by the reload: the four original `accept` rules plus ICMP/ICMPv6 (`accept` count 9 → 10,
so `nft -f` discarded nothing), `nftables.service` `enabled` (survives reboot), `sshd -T` key-only posture,
fail2ban `ignoreip` and its 0/0 counters, `hv01 → pbs01:8007`, and the PBS ACL table. The write itself is
in the audit log as `key="firewall"` at `2026-10-22T18:28:48Z`.
Evidence: `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` §1–§11.

**Still open (conditions not met by the change itself):**

1. Condition 1 — **the DHCP reservation is NOT yet created.** `192.168.88.249` is still `proto dhcp`, so
   the `/32` can rot into intermittent access. Until the reservation exists this allowance is provisional.
2. `/ip firewall filter print` on the MikroTik remains uncaptured. It is no longer load-bearing (the path
   is demonstrably forwarded), but the router matrix should be recorded rather than inferred, and
   `vlan-audit-2026-08-29.md` §2 has already misled two sessions by being generalised beyond its source.
3. Option A (VLAN 10 L2 membership) was **not** executed and stays a contingency.
4. Discovered while verifying: pbs01 had **no working time source** (clock +65.657 s fast, sole chrony peer
   was the offline admin01). **CLOSED 2026-10-22** — fixed at 18:54Z (peer retired, upstream drop-in added,
   `chronyc tracking` proved the −65.658732 s step) and re-provisioned at 19:04Z to the fleet form after
   review found the first revision left only **2 sources** (`server <pool-zone>` pins one address per line;
   two cannot reject a falseticker). `ssh pbs01` being available is what made the fix, its verification and
   its re-audit possible in minutes instead of a physical-console trip — that is this ADR's payoff on the
   finding it surfaced. Status and evidence: `docs/servers/pbs01.md` §Security Controls,
   `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` §13–§15.
5. Also enabled by the new path: the PBS access-control state could finally be **read back** instead of
   inferred (`acl list`, `user permissions`, `user list-tokens`). It confirmed the hv01 `401` has two
   independent causes — `pve-backup@pbs!pve-token` exists and is enabled but holds **zero ACL rows**, and
   `pbs01.pw` on hv01 is 1 byte. The grant + token rotation remain operator-only (§0.1: a token secret is
   shown once and must land in the PVE storage form, never in a captured shell).

## Context

`pbs01` (10.10.10.30, Proxmox Backup Server 4.2) is the only off-host backup target for the AI estate
(VMIDs 100/101/102) and the `jol-llm` model store. Its host nftables permits `22/tcp` from
`10.10.10.0/24` only, under `policy drop`:

```nft
type filter hook input priority filter; policy drop;
tcp dport 22   ip saddr 10.10.10.0/24  accept
tcp dport 8007 ip saddr 10.10.10.0/24  accept
tcp dport 8007 ip saddr 10.60.60.0/24  accept
tcp dport 8007 ip saddr 10.30.30.10    accept
```

The designed SSH source was `admin01` (`10.10.10.50`), which no longer answers ICMP or TCP. Every
administration task therefore falls back to the PBS Web UI xterm.js console reached through a
session-limited loopback tunnel, which costs a manual paste per command and prevents scripted evidence
capture.

Measured facts that constrain the design (2026-10-22, read-only probes):

| Fact | Evidence |
|------|----------|
| The operator workstation (`192.168.88.249`, router `defconf` bridge) **already has a routed path into VLAN 10** | `10.10.10.2:80/:23` (N2048) and `10.10.10.11:443` (iDRAC) answer; `10.10.10.30` answers ICMP |
| The MikroTik does **not** masquerade inter-VLAN traffic | hv01 `ss -tn` shows peer `192.168.88.249:43588`, not the router address |
| pbs01's host rules are therefore the **sole** blocker for the workstation | the two rows above, plus no `192.168.88.0/24` accept anywhere in the ruleset |
| `10.60.60.20` is a backup **data-path** source | `tcp dport 8007 ip saddr 10.60.60.0/24 accept` is what makes hv01 backups and restores work |
| fail2ban on pbs01: 3 retries → 24 h ban, `ignoreip 127.0.0.0/8, 10.10.10.0/24`, counters 0 failed / 0 banned | `fail2ban-client get sshd ignoreip` |

## Decision

Grant the operator workstation SSH reachability to pbs01 with **exactly one scoped rule on one device**:

```nft
tcp dport 22 ip saddr 192.168.88.249/32 accept
```

Applied as an edit to the ruleset **file** (not a live `nft add`), behind a syntax gate and a dead-man
rollback, and **never** added to fail2ban `ignoreip`. No router change, no switch change, no change to any
`/24`.

Supporting conditions, all mandatory:

1. A DHCP reservation pins `192.168.88.249` to the workstation MAC, so the `/32` cannot silently rot.
2. `nft -c -f <candidate-file>` passes before any load (the check flag must precede `-f`;
   `nft check ruleset -f …` is rejected outright by nft). Verified on 2026-10-22 that the candidate
   ruleset adds exactly one line and that the `accept`-rule count in the running ruleset equals the
   count in `/etc/nftables.conf` (9 == 9), so `nft -f` cannot silently discard out-of-band rules.
3. `systemd-run --on-active=5min` restores the pre-change file — pbs01 has **no IPMI**, so a bad rule is
   otherwise a physical visit.
4. Access stays key-only (`AllowUsers root`, password auth disabled); the workstation's *public* key
   `SHA256:5wSsJlMIANmTTvucmimQqYlVGsyVmq8daj7nOZkWlws` is what is authorised.
5. The change is recorded in `CHANGELOG.md` with a CC8.1 issue reference.

## Consequences

- **Positive**: eliminates the browser-shell paste tax; enables scripted evidence capture
  (`ssh pbs01 'nft list ruleset' | tee evidence/…`), which §0.4 requires and the UI console makes onerous.
- **Positive**: attack surface grows by one IP → one port, not by a segment. The hypervisor and IoT-bearing
  broadcast domains stay out.
- **Positive**: fail2ban keeps full effect on the new source. A typo costs the operator 24 h of SSH; it
  cannot cost the fleet a backup path, because the workstation is not a data-path source.
- **Negative**: an internet-facing desktop becomes a network neighbour of the backup server. If that
  workstation is compromised, the attacker can attempt root SSH against pbs01 — mitigated by key-only auth,
  fail2ban, and auditd on pbs01, but it is a real widening of the blast radius and is the accepted residual
  risk of this ADR.
- **Negative**: the `/32` is only as stable as the DHCP reservation. Losing it produces intermittent access
  that looks like a firewall regression.
- **Neutral**: `docs/architecture/trust-boundaries.md` lists VLAN 10 contents as "PBS, admin workstation" —
  this decision makes that statement true again, from a routed rather than an L2 position.

## Alternatives Considered

1. **L2 membership in VLAN 10 on the workstation's unused second NIC (`enp9s0`, linked at 1 Gb/s)** —
   originally recommended in `docs/runbooks/pbs01-admin-ssh-access.md`, **downgraded after measurement**. It
   needs a physical cable trace, a switch-port change (and the N2048 admin credential is a known gap), and
   it grants adjacency to the *whole* management VLAN — switch, iDRACs, router — to reach one host. It also
   creates a permanently dual-homed workstation on a host where `ip_forward` is forced to `1` by Docker, so
   its own stated safety control was unsatisfiable as written. Kept as a contingency.
2. **`22/tcp` from `10.60.60.0/24`** — rejected. Routes every workload on the hypervisor (rag/mcp/her, one
   with internet egress) to root SSH on the box holding their own backups: the "delete the backups, then
   encrypt" sequence. It also makes `10.60.60.20` bannable, converting a password typo into a 24 h
   backup-and-restore outage — explicitly forbidden by `docs/runbooks/hv01-storage-backup-reconfiguration.md`
   §6 ("fail2ban must never be able to ban a backup-path source").
3. **`22/tcp` from `192.168.88.0/24`** — rejected. That `/24` is the router's `defconf` bridge, shared with
   home/IoT equipment (`docs/network/vlan-audit-2026-08-29.md` §2). A segment-wide allowlist on a backup
   server for an IoT-bearing LAN is indefensible under A.8.20 / CC6.6.
4. **Move sshd to a non-standard port** — rejected as futile: the filter is source-subnet based. Proven by
   probes where `2222/8422/22222` all time out while `8007` answers instantly on the same host.
5. **Restore or replace `admin01` as the jump host** — rejected for this need. It reintroduces a
   single-purpose box that is already off the network, and `10.10.10.50` is additionally pbs01's documented
   chrony peer, so retiring it silently degrades NTP and therefore audit-record timestamps.
6. **Continue with the UI console only** — rejected. It does not scale to the remaining work (restore drills,
   log review, prune/verify, evidence capture) and it is the direct cause of the operational error this ADR
   prevents: a local `bind: Address already in use` on a tunnel port was previously misread as "pbs01 is
   unreachable" and used to argue for widening a firewall.

## Compliance

- SOC 2 CC6.1 (logical access), CC6.6 (network segmentation), CC8.1 (change control)
- ISO 27001:2022 A.8.2 (privileged access), A.8.5 (secure authentication), A.8.13 (information backup),
  A.8.20 (network security), A.8.32 (change management)
- GDPR Art. 5(1)(f) / Art. 32 — pbs01 holds special-category (religious affiliation) backup data

## References

- `docs/runbooks/pbs01-admin-ssh-access.md` — full change package, options, rollback, acceptance gates
- `docs/servers/pbs01.md` §Admin SSH Path — measured reachability matrix and ruleset capture
- `docs/network/vlan-audit-2026-08-29.md` §2 — MikroTik forward matrix
- ADR-004 — network segmentation (cloud counterpart)
