# Workstation owner window — install, custody, sustained-write measurement

**Scope boundary.** This document covers the three owner actions that do **not** touch `/home`,
`/etc/fstab` or `/etc/crypttab`. It stops deliberately before the Phase 2 cutover. Nothing here
needs `rescue.target`, nothing here can log anyone out, and every step is reversible on its own.

Transcripts captured 2026-11-05T19:10Z from `HEAD` = `5770277`; this document revised
2026-11-05T19:39Z after three of its own expected-output blocks were checked against the source
line numbers and corrected. Every "expected" block below is either a **real captured transcript**
from this host (marked *captured*) or the **exact `printf` format taken from the code** that will
emit it (marked *from code*). Where a number cannot be known in advance it is shown as a
placeholder and the reason is stated. No expected output in this file was written from imagination.

---

## 0. Preconditions — run these first, without sudo

They cost nothing and each one is a way for the window to fail later.

```bash
cd /opt/jol/repos/jol-infrastructure
git rev-parse HEAD                       # expect 5770277 or newer
git status --porcelain                   # expect the concurrent session's files only
```

Then confirm every installer source is committed, because step 1 **refuses** otherwise:

```bash
awk -F'|' '/^    "[a-z0-9-]+\.sh\|/{print $1}' scripts/maintenance/install-workstation-scripts.sh \
  | tr -d ' "' | while read -r s; do
    h="$(git rev-parse -q --verify "HEAD:scripts/maintenance/$s" || true)"
    w="$(git hash-object "scripts/maintenance/$s" || true)"
    printf '%-32s %s\n' "$s" "$([[ -n "$h" && "$h" == "$w" ]] && echo CLEAN || echo DIRTY)"
  done
```

*Captured on this host at 19:10Z — all six must read `CLEAN`:*

```
fix-jol-backup-mount.sh            CLEAN
backup-workstation-home.sh         CLEAN
provision-jolhome-disk.sh          CLEAN
migrate-home-to-jolhome.sh         CLEAN
record-jolhome-custody.sh          CLEAN
benchmark-jolhome-writes.sh        CLEAN
```

Also confirm the volume is mounted off-disk and the target is still empty, and that the
privileged directory has **not** been handed to anyone:

```bash
findmnt -no SOURCE,TARGET /mnt/jolhome-staging   # expect: /dev/mapper/jolhome_crypt /mnt/jolhome-staging
stat -c '%a %U:%G %n' /var/lib/jol-workstation    # expect: 700 root:root /var/lib/jol-workstation
```

> If `/var/lib/jol-workstation` is anything other than `700 root:root`, **stop**. Two gates
> (custody attestation, Phase 0 backup proof) derive their honesty from uid 1000 being unable to
> look inside it. A mode change there is not a precondition failure, it is an incident.

---

## 1. Install the six scripts to `/usr/local/bin`

### The command

```bash
sudo DRY_RUN=0 /opt/jol/repos/jol-infrastructure/scripts/maintenance/install-workstation-scripts.sh
```

### Expected output — *from code; identical to the captured DRY_RUN plan except `DRY  :` → `APPLY:`*

```
=== install-workstation-scripts.sh (DRY_RUN=0, host=ubuntu, target=/usr/local/bin) ===
APPLY: install -m 755 -o root -g root /opt/jol/repos/jol-infrastructure/scripts/maintenance/fix-jol-backup-mount.sh /usr/local/bin/jol-fix-backup-mount.sh
APPLY: install -m 755 -o root -g root /opt/jol/repos/jol-infrastructure/scripts/maintenance/backup-workstation-home.sh /usr/local/bin/jol-backup-home.sh
APPLY: install -m 755 -o root -g root /opt/jol/repos/jol-infrastructure/scripts/maintenance/provision-jolhome-disk.sh /usr/local/bin/jol-provision-home-disk.sh
APPLY: install -m 755 -o root -g root /opt/jol/repos/jol-infrastructure/scripts/maintenance/migrate-home-to-jolhome.sh /usr/local/bin/jol-migrate-home.sh
APPLY: install -m 755 -o root -g root /opt/jol/repos/jol-infrastructure/scripts/maintenance/record-jolhome-custody.sh /usr/local/bin/jol-record-custody.sh
APPLY: install -m 755 -o root -g root /opt/jol/repos/jol-infrastructure/scripts/maintenance/benchmark-jolhome-writes.sh /usr/local/bin/jol-write-bench.sh

=== verify ===
OK   : jol-fix-backup-mount.sh sha256 8278a0c31bc14ecf… identical to repo copy, mode 755 root:root
OK   : jol-backup-home.sh sha256 96039c4df64227ac… identical to repo copy, mode 755 root:root
OK   : jol-provision-home-disk.sh sha256 b58c737f8ff8032e… identical to repo copy, mode 755 root:root
OK   : jol-migrate-home.sh sha256 b7f7e8a01093c376… identical to repo copy, mode 755 root:root
OK   : jol-record-custody.sh sha256 c93140fd5e75660c… identical to repo copy, mode 755 root:root
OK   : jol-write-bench.sh sha256 20baa4dd19ef2a19… identical to repo copy, mode 755 root:root

=== done ===
```

The six `sha256` prefixes above are the real repo digests captured at 19:10Z, so the `OK` lines
are checkable against this document, not just against the installer's own opinion:

| source | full repo sha256 |
|---|---|
| `fix-jol-backup-mount.sh` | `8278a0c31bc14ecfb120a1dd87f0586176f3570d19113474def3b9f141dfeb7e` |
| `backup-workstation-home.sh` | `96039c4df64227acef72a394b63f526af3777ac360266155aeb0a519da08942f` |
| `provision-jolhome-disk.sh` | `b58c737f8ff8032ee81c64035aad00391faf36c047ac4b0dce4c7040bc0136bf` |
| `migrate-home-to-jolhome.sh` | `b7f7e8a01093c37635d4b7b8c678b78ca8354e7f909f3c512256e6813a91aca6` |
| `record-jolhome-custody.sh` | `c93140fd5e75660c28cb67c60bf2b73b8f5c3b132ced9aa8e3b60188352b1e0d` |
| `benchmark-jolhome-writes.sh` | `20baa4dd19ef2a1941abae1939021905ed1540557c1889290b7a4ee51582d4f6` |

### If it refuses instead

The dirty-source guard added in `e00c2d2` fires per target and **skips that one**, continuing the
others, then exits 1. *Captured real shape:*

```
FAIL: /opt/jol/repos/jol-infrastructure/scripts/maintenance/<file>.sh differs from HEAD — refusing to install uncommitted content
      head=<40-hex>  worktree=<40-hex>
      commit it, or set ALLOW_DIRTY=1 if you are installing a draft deliberately
```

Both hashes are printed so the difference is checkable. `ALLOW_DIRTY=1` installs the draft and
prints `WARN: … installing UNCOMMITTED worktree content` instead. Prefer committing.

### Verify afterwards — independently, not via the installer's own summary

```bash
for t in jol-fix-backup-mount.sh jol-backup-home.sh jol-provision-home-disk.sh \
         jol-migrate-home.sh jol-record-custody.sh jol-write-bench.sh; do
  printf '%s  %s\n' "$(stat -c '%a %U:%G' /usr/local/bin/$t)" "$t"
done
```

Expect **six lines of `755 root:root`**. Then prove content identity against the repo rather than
against the installer:

```bash
cd /opt/jol/repos/jol-infrastructure/scripts/maintenance
for p in "fix-jol-backup-mount.sh|jol-fix-backup-mount.sh" "backup-workstation-home.sh|jol-backup-home.sh" \
         "provision-jolhome-disk.sh|jol-provision-home-disk.sh" "migrate-home-to-jolhome.sh|jol-migrate-home.sh" \
         "record-jolhome-custody.sh|jol-record-custody.sh" "benchmark-jolhome-writes.sh|jol-write-bench.sh"; do
  s="${p%%|*}"; d="${p##*|}"
  a="$(sha256sum "$s" | cut -d' ' -f1)"; b="$(sha256sum "/usr/local/bin/$d" | cut -d' ' -f1)"
  printf '%-28s %s\n' "$d" "$([[ "$a" == "$b" ]] && echo MATCH || echo "MISMATCH repo=$a host=$b")"
done
```

Expect **six `MATCH`**. Then confirm the payoff — three read-only invocations now work **without a
password**:

```bash
/usr/local/bin/jol-fix-backup-mount.sh --verify-only | tail -2
/usr/local/bin/jol-migrate-home.sh --preflight | tail -2
/usr/local/bin/jol-write-bench.sh --report; echo "rc=$?"   # expect rc=1, "no benchmark has been run yet"
```

The first two must exit 0. The third **must** say no benchmark has run yet — at this point none
has. If it instead prints a table, step 3 was already done.

### Rollback of step 1

```bash
sudo rm -f /usr/local/bin/jol-{migrate-home,record-custody,write-bench}.sh
sudo install -m 750 -o root -g root <previous copies> …    # only if you want the old 750 trio back
```
Nothing outside `/usr/local/bin` is touched; no service is involved. Leaving the files in place is
also safe — they are inert until invoked.

---

## 2. Place the custody attestation

**This step requires you to type the recovery passphrase.** The script never sees it: `cryptsetup`
reads it from `/dev/tty` directly. If anyone (including an agent) has ever pasted that passphrase
into a command line, a file, or a chat, this step is the one that proves it — and the volume should
then be re-keyed.

### 2a. Plan first, without sudo

```bash
/usr/local/bin/jol-record-custody.sh
```

*Captured real output on this host:*

```
=== record-jolhome-custody.sh (DRY_RUN=1, host=ubuntu) ===
volume: jolhome_crypt -> UUID=4fc2ae29-3dd3-43c7-b43b-325ba9ed2690 -> /dev/nvme2n1p1
keyslots occupied: NOT MEASURED — cryptsetup luksDump needs root. Plan only; nothing is asserted about the slot count.
PLAN : prompt for the recovery slot index, then run
       cryptsetup luksOpen --test-passphrase --key-slot <N> /dev/nvme2n1p1
       (cryptsetup reads the passphrase from YOUR terminal; this script never does)
PLAN : write /var/lib/jol-workstation/jolhome-custody (mode 600, root:root) with the public metadata only
PLAN : re-read it through custody_verdict from /opt/jol/repos/jol-infrastructure/scripts/maintenance/migrate-home-to-jolhome.sh and delete it if not PASS

Nothing was verified and nothing was written. Re-run with DRY_RUN=0.
```

Note the deliberate honesty: unprivileged it reports `NOT MEASURED`, **not** `0 keyslots`. A zero
here would be the "absent measurement rendered as healthy zero" failure.

### 2b. Execute

```bash
sudo DRY_RUN=0 /usr/local/bin/jol-record-custody.sh
```

*From code — the interactive lines you will see, in this order:*

```
=== record-jolhome-custody.sh (DRY_RUN=0, host=ubuntu) ===
keyslots occupied: 2 (0 1 )
Which keyslot holds the RECOVERY secret? [0 1 ] _        ← you type the slot index, Enter
Verifying keyslot <N> opens /dev/nvme2n1p1.
cryptsetup will prompt. This script does not see, capture or store what you type.
```

`cryptsetup` then prints its own passphrase prompt on the same terminal. Type the recovery
passphrase there. After a successful verification the recorder asks one more question — an
allowlist, not free text:

```
Where is the recovery passphrase held? (one class per line)
  1) vaultwarden:sops-custody
  2) usb-safe:DR-JOL
  3) offsite-sealed-envelope
Choose [1-3]: _                                            ← you type 1, 2 or 3
```

An answer outside that list is refused with `'<x>' is not one of the listed classes — nothing was
written`, and so is a keyslot index that is not occupied. Both abort **before** any artifact is
written.

**Success line:**

```
keyslot <N> verified — the secret recorded in custody does open this volume
```

**Failure line** (wrong slot or wrong secret — nothing is written either way):

```
keyslot <N> did NOT open the volume.
```

On failure the script writes **no artifact**, so the Phase 2 gate keeps refusing. That is the
designed outcome, not a partial success: an unopenable secret recorded as custody is worse than no
record. Retry with the other index, or stop and treat the recovery secret as suspect.

### 2c. Verify

The artifact is root-owned and inside a `700` directory, so verification needs sudo — by design:

```bash
sudo stat -c '%a %U:%G %n' /var/lib/jol-workstation/jolhome-custody     # expect: 600 root:root …
sudo cat /var/lib/jol-workstation/jolhome-custody
```

Expected fields — *from code*, and **no secret material in any of them**:

```
schema=1
utc=<YYYY-MM-DDTHH:MM:SSZ>
host=ubuntu
mapper=jolhome_crypt
luks_uuid=4fc2ae29-3dd3-43c7-b43b-325ba9ed2690
keyslot=<N>
slots_total=2
verify=PASS
verify_cmd=cryptsetup luksOpen --test-passphrase --key-slot <N>
custody_location=<where you said the passphrase lives>
attested_by=jol
secret_recorded=no
```

Two fields are load-bearing. `luks_uuid` must equal the crypttab UUID above — that binding is what
makes a stale artifact from a re-formatted volume fail instead of passing. `secret_recorded=no`
must be `no`: if custody copy and backup copy were ever the same file on the same disk, the control
is decorative.

Then confirm the gate that consumes it now agrees, from root (unprivileged it can only report
`UNVERIFIED`, which is correct and not a failure):

```bash
sudo /usr/local/bin/jol-migrate-home.sh --preflight 2>&1 | grep -iE 'custody|attest'
```

Expect the custody alert to be **gone**, replaced by silence or a PASS-derived line. The remaining
`BUSY` alert is expected from a desktop session and clears itself in `rescue.target`.

### Rollback of step 2

```bash
sudo /usr/local/bin/jol-record-custody.sh --clear
```

```
Cleared /var/lib/jol-workstation/jolhome-custody — migrate-home-to-jolhome.sh will now refuse the cutover.
Re-run this recorder to restore it. The keyslot itself is untouched.
```

No keyslot is added, removed or re-keyed by any path in this document.

---

## 3. §3.6 sustained-write characterisation

Writes 32 GiB to the **empty** encrypted volume and removes it again. This is the measurement that
sizes the Phase 2 copy window; until it exists, the window is a guess.

### 3a. Plan first

```bash
/usr/local/bin/jol-write-bench.sh
```

*Captured real output:*

```
=== jolhome sustained-write benchmark (DRY_RUN=1, target /mnt/jolhome-staging) ===
  target: mount=yes off-disk=yes source='/dev/mapper/jolhome_crypt' extra_entries=0
  guards: PASS
DRY  : would write 32 GiB as 32 sequential 1 GiB direct steps to /mnt/jolhome-staging/.wtest
DRY  : per-interval samples to /home/jol/.local/share/jol-fleet-health/write-bench-<utc>.tsv
DRY  : ownership handover: NO_HANDOVER (WIN_DIR=/home/jol/.local/share/jol-fleet-health, operator home=/home/jol)
DRY  : running as uid 1000 (jol)
DRY  : 32 sequential dd steps of 1 GiB, each at its own seek offset, oflag=direct conv=fdatasync
DRY  : first step would be: dd if=/dev/zero of=/mnt/jolhome-staging/.wtest bs=1M count=1024 seek=0 oflag=direct conv=fdatasync
  fio available on this host: yes — this script uses dd either way,
         so the result depends on nothing that might be absent on the rescue shell.
=== PLAN OK — re-run with DRY_RUN=0 under sudo to execute ===
```

**Read the `ownership handover:` line before you continue.** Under sudo it must read
`FILE_AND_DIR`, and the `operator home=` value must be `/home/jol`. If it ever prints
`FILE_ONLY_WARN`, your `WIN_DIR` points outside your home — the script will then **decline** to
change that directory's ownership, which is the fix that landed in `d383634` after review found a
`WIN_DIR=/var/lib/jol-workstation` run would otherwise have handed the privileged artifact
directory to uid 1000.

One drift worth knowing before you read the projection: the script's default `PAYLOAD_GIB=76` is a
static figure, while `--preflight` **measures** the payload — currently `77 GiB`. Pass the measured
number so the projection is not optimistic by ~1 %:

```bash
sudo PAYLOAD_GIB=77 DRY_RUN=0 /usr/local/bin/jol-write-bench.sh
```

### 3b. Expected live output — *from code; only the numbers are unknown until it runs*

```
=== jolhome sustained-write benchmark (DRY_RUN=0, target /mnt/jolhome-staging) ===
  target: mount=yes off-disk=yes source='/dev/mapper/jolhome_crypt' extra_entries=0
evidence handed to jol: jol:jol 644 (dir too: /home/jol/.local/share/jol-fleet-health)
writing 32 GiB as 32 sequential 1 GiB direct steps
  step  1/32 GiB (offset     0 MiB):   <rate> MiB/s in <n>s
  step  2/32 GiB (offset  1024 MiB):   <rate> MiB/s in <n>s
  …
  step 32/32 GiB (offset 31744 MiB):   <rate> MiB/s in <n>s
RESULT  peak <P> MiB/s | sustained <S> MiB/s | collapse at <C>s
        77 GiB at the SUSTAINED rate = <W> min of copy time
        the SLC cache held for <C>s then fell over: plan the Phase 2 window
        from the sustained figure, never the peak.
cleanup verified: /mnt/jolhome-staging/.wtest absent, target holds only 1 entries
evidence: /home/jol/.local/share/jol-fleet-health/write-bench-<utc>.tsv
=== BENCHMARK COMPLETE ===
```

Two ordering facts, both verified against the source line numbers rather than assumed, because this
section is only useful if it can be diffed against a real terminal:

* There is **no** `guards: PASS` line on the live path. That line exists only inside the
  `DRY_RUN == 1` branch; on the live path the same verdict is enforced silently and the script
  `die`s if it is anything but `OK`. Its absence from a real run is correct, not a skipped check.
* `evidence handed to jol:` appears **before** `writing 32 GiB`, because the file is created and
  handed over before the measurement starts. Seeing it near the end means a different script
  version ran.

Two variants are meaningful rather than cosmetic:

* If no collapse appears in 32 GiB you get `no clear collapse seen inside 32 GiB — either the cache
  is larger than the test or the drive is not caching; consider SIZE_GIB=64.` That is an honest
  negative, not a failure.
* `collapse at 0s` in the `RESULT` line means "none found", because the token is a seconds value.

### 3c. Verify

```bash
findmnt --target /mnt/jolhome-staging >/dev/null && df -h /mnt/jolhome-staging | tail -1
ls -l /mnt/jolhome-staging                       # expect: lost+found only
stat -c '%U:%G %a %n' /home/jol/.local/share/jol-fleet-health/write-bench-*.tsv
/usr/local/bin/jol-write-bench.sh --report | tail -6 ; echo "rc=$?"
```

Expect, in order: `avail` back near `929G`; **only** `lost+found` on the volume — that is the
cleanup proof, and it is verified by post-state rather than by `rm` having been called; the evidence
file owned by **`jol:jol`**, not root; and `--report` exiting **0** without a password. That last
pair is the regression test for the bug found in review: the first version wrote samples under a
`700 /root` while `--report` read `/home/jol` and answered *"no benchmark has been run yet"* for a
measurement that had run.

### How to read the result

Plan the Phase 2 window from **sustained**, never peak. The drive is DRAM-less with a dynamic SLC
cache: the short-burst rate is the rated ~4.7 GB/s and says nothing about a 77 GiB copy. `sustained`
here is the mean of the **last third** of intervals — a whole-run mean averages the fast phase into
the slow one and describes neither — and the window is rounded **up**, because a truncated window is
a window that runs out mid-migration with `/home` unmounted.

### Rollback of step 3

There is nothing to roll back: the probe file is removed on every exit path including Ctrl-C, and the
evidence file is a plain text artifact you may delete. If a crash ever leaves `.wtest` behind:

```bash
sudo rm -f /mnt/jolhome-staging/.wtest && df -h /mnt/jolhome-staging | tail -1
```

---

## 4. State at the end of this window, and what is still gated

After steps 1–3 the following should be true, all checkable without sudo:

| property | expected | why it matters |
|---|---|---|
| six `/usr/local/bin/jol-*.sh` | `755 root:root`, sha256 MATCH repo | the install blocker is closed |
| `jol-write-bench.sh --report` | rc=0, prints the plateau | §3.6 evidence is readable by its owner |
| `jol-migrate-home.sh --preflight` | rc=0, no custody alert | Phase 2's fatal gate is satisfied |
| `/var/lib/jol-workstation` | still `700 root:root` | the UNVERIFIED-not-absent discipline still holds |
| `/mnt/jolhome-staging` | `lost+found` only, ~`929G` avail | nothing was left on the volume |
| `/home` | **still `nvme1n1p7`, unencrypted** | unchanged, on purpose |
| `/etc/crypttab`, `/etc/fstab` | **unchanged** | unchanged, on purpose |

**Deliberately not done here.** The Phase 2 cutover — `systemctl isolate rescue.target`, then
`jol-migrate-home.sh` with `DRY_RUN=0`, then `reboot` — is the only remaining storage work and the
only step that can leave the machine unable to log anyone in. It needs its own booked window and is
out of scope above. `tune2fs -m 1` on `/home` is open, root-only, and recorded as headroom rather
than urgency: the rate recipe still refuses to extrapolate on the sample history, so no fill rate is
derivable yet and none should be quoted.

**D-2 stays open until the cutover completes.** Phase 1 produced an empty encrypted container; the
SSH private key and the Tier-1 secret material remain unencrypted at rest until `/home` moves.
