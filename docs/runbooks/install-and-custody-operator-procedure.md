# Reviewed-tool install + custody verification — operator procedure (rev 2)

Pinned revision `d3c98ea8fa821ff1a39a480843a81688d4a727b3`, branch `fix/home-migration-orchestration`.

Rev 1 had four defects that would each have failed at the keyboard. They are corrected here and the
corrections are stated, not silently applied:

1. **The manifest was not a trust root.** Rev 1 staged from `/opt/jol/delivery` and verified with a
   manifest from the *same* uid-1000-writable directory. An attacker who can rewrite the files can rewrite
   the manifest beside them. Now every staged path is verified against **its blob in the pinned commit**,
   read independently from **two** git stores, and the manifest is demoted to corroboration.
2. **Staged scripts were mode 644.** Measured: direct execution of a 644 file → **rc=126**; via
   `bash <path>` → works. Now staged `-m 755 -o root -g root` *and* invoked explicitly with `bash`, so
   neither path depends on the other.
3. **Globs expanded before `sudo`.** Measured: `ls -1d /var/backups/jol-workstation/pre-install-*` as uid
   1000 → `Permission denied`, so `sudo ls … pre-install-*` receives the **literal pattern** and
   `CAP=$(sudo ls …|head -1)` captures junk. Now discovery runs inside `sudo bash -c '…'`.
4. **Failures did not stop the sequence.** Rev 1's digest comparisons could pass on two empty strings —
   which is exactly how my own age round-trip falsely reported `BYTE-EXACT`. Now `set -euo pipefail`
   plus an explicit length check on every digest before any comparison.
   **And a hole found while rehearsing that fix:** `git cat-file blob "$C:$p" | sha256sum` hashes the
   *empty string* when the blob lookup fails, producing `e3b0c442…` — a well-formed 64-character digest.
   A length guard therefore cannot detect the failure, and two failed lookups compare **equal**. Every
   commit-blob digest below is now taken from a **file**, after asserting the blob is non-empty, and the
   `git` exit status is checked before hashing.

**Residual, stated not hidden:** `git branch -r --contains d3c98ea` → **0 remote refs**, and every `.git`
store on this host is uid-1000 writable. So the authenticity of the "reviewed" commit **cannot be
established on this machine alone**. Root-staging closes the agent TOCTOU window (post-stage, uid 1000
cannot modify); it does not defend against a workstation that is itself compromised. Pushing
`fix/home-migration-orchestration` gives the revision an out-of-band anchor and is the one change that
would make this procedure's premise verifiable rather than assumed.

---

## Step 0 — host guard, then the allow-list

```bash
hostname                     # MUST be ubuntu, or stop: these paths do not exist elsewhere
command -v git sha256sum rsync >/dev/null || { echo "missing tooling"; false; }
```

The list is **derived from the reviewed installer and cross-checked**, never typed from memory — a
`cut -d'|' -f1` on the manifest lines keeps the leading `"` and silently produces paths that verify
nothing. That happened while writing this.

```bash
D=/opt/jol/delivery/jol-infrastructure-home-migration
C=d3c98ea8fa821ff1a39a480843a81688d4a727b3
A=$(mktemp)
grep -oE '"[a-z0-9._-]+\.sh\|jol-[a-z-]+\.sh\|[0-9]+"' "$D/scripts/maintenance/install-workstation-scripts.sh" \
  | tr -d '"' | cut -d'|' -f1 | sed 's|^|scripts/maintenance/|' > "$A"
printf 'scripts/maintenance/install-workstation-scripts.sh\nscripts/maintenance/capture-installed-workstation-scripts.sh\n' >> "$A"
sort -u "$A" -o "$A"
cp "$A" /tmp/allowlist          # the fixed path the root contexts below read; root cannot see $A
grep -c '"' "$A"                # MUST print 0
wc -l < "$A"                   # MUST print 8
wc -l < /tmp/allowlist          # MUST also print 8, or the handoff to root lost lines
```

Verify each allowed path against the pinned commit in **both** stores before staging anything:

```bash
while read -r p; do
  a=$(git -C "$D" rev-parse -q --verify "$C:$p") || { echo "NO-BLOB-IN-DELIVERY $p"; exit 1; }
  b=$(git -C /opt/jol/repos/jol-infrastructure rev-parse -q --verify "$C:$p") || { echo "NO-BLOB-IN-SHARED $p"; exit 1; }
  w=$(git -C "$D" hash-object "$p")
  [ ${#a} -eq 40 ] && [ "$a" = "$b" ] && [ "$a" = "$w" ] || { echo "MISMATCH $p ${a:0:12} ${b:0:12} ${w:0:12}"; exit 1; }
  echo "MATCH(3-way) $p"
done < /tmp/allowlist
```

Measured on this host: **8/8 MATCH(3-way)**. Any `MISMATCH`, `NO-BLOB`, or a count other than 8 → **STOP.**

## Step 1 — stage into a root-only directory, executable, and re-verify *there*

Verifying the source and then copying is not enough: verify what will actually run.

```bash
S=/usr/local/src/jol-home-migration-d3c98ea
sudo install -d -m 700 -o root -g root "$S"
while read -r p; do sudo install -D -m 755 -o root -g root "$D/$p" "$S/$p"; done < "$A"
sudo cp -p /opt/jol/delivery/MANIFEST-d3c98ea.sha256 "$S/"
sudo chown root:root "$S/MANIFEST-d3c98ea.sha256"; sudo chmod 644 "$S/MANIFEST-d3c98ea.sha256"
```

Re-derive the blob check from inside the root copy — `sha256sum -c` alone would pass on a manifest and
files that were both staged from the writable tree:

```bash
sudo bash -c 'C=d3c98ea8fa821ff1a39a480843a81688d4a727b3; D=/opt/jol/delivery/jol-infrastructure-home-migration
 rc=0
while read -r p; do
  if ! git -C "$D" cat-file -e "$C:$p" 2>/dev/null; then echo "NO-BLOB $p"; rc=1; continue; fi
  git -C "$D" cat-file blob "$C:$p" > /tmp/blobcheck || { echo "EXTRACT-FAIL $p"; rc=1; continue; }
  if [ ! -s /tmp/blobcheck ]; then echo "EMPTY-BLOB $p"; rc=1; continue; fi
  want=$(sha256sum /tmp/blobcheck | cut -d" " -f1)
  got=$(sha256sum "$S/$p" | cut -d" " -f1)
  if [ ${#want} -ne 64 ] || [ ${#got} -ne 64 ]; then echo "EMPTY-DIGEST-ABORT $p"; rc=1
  elif [ "$want" = "$got" ]; then echo "STAGED-MATCH $p"
  else echo "STAGED-MISMATCH $p"; rc=1; fi
done < /tmp/allowlist
 rm -f /tmp/blobcheck
 exit $rc'
```

Then, as corroboration only: `cd "$S" && sudo sha256sum -c MANIFEST-d3c98ea.sha256`.
Note `install -D -m 755` stages 8 files; the manifest lists 19 digest lines over 18 distinct paths because
`install-workstation-scripts.sh` appears twice with the same digest. Expect 19 `OK`, not 18.

## Step 2 — capture: discover, verify the real timestamped directory, decide reuse

All discovery inside the privileged shell; the glob cannot be expanded as uid 1000.

```bash
sudo bash -c 'ls -la /var/backups/jol-workstation/ 2>&1; echo "--- candidates:";
for d in /var/backups/jol-workstation/pre-install-*; do [ -d "$d" ] || continue; echo "$d"; done'
```

Verify **each actual timestamped directory**, never the parent:

```bash
sudo bash -c 'for d in /var/backups/jol-workstation/pre-install-*; do
  [ -d "$d" ] || continue
  echo "== $d"
  bash /usr/local/src/jol-home-migration-d3c98ea/scripts/maintenance/capture-installed-workstation-scripts.sh --verify "$d"
  echo "   rc=$?"
done'
```

A capture is reusable **only** if it `--verify`s rc=0 **and** its recorded digests still equal the six live
destinations. Measured current state: `/var/backups/jol-workstation` is `700 root:root`, `--verify` on it
returned **rc=2 `no manifest.txt`**, so there is no completed capture and a fresh one is required.

Create it and capture the exact path **that run** printed — not a glob, not `ls -1dt`:

```bash
sudo bash -c 'CAP=$(env DRY_RUN=0 /usr/local/src/jol-home-migration-d3c98ea/scripts/maintenance/capture-installed-workstation-scripts.sh | tee /dev/stderr | sed -n "s|^.*capture directory \(/\S*\).*$|\1|p" | tail -1)
test -n "$CAP" || { echo "ABORT: capture printed no directory"; exit 1; }
echo "CAPTURE=$CAP"
env DRY_RUN=1 /usr/local/src/jol-home-migration-d3c98ea/scripts/maintenance/capture-installed-workstation-scripts.sh --verify "$CAP" || { echo "ABORT: capture did not verify"; exit 1; }
echo "$CAP" > /root/jol-capture-path'
```

Expect three files recorded with digests at mode 750 and three `ABSENT-PRE-INSTALL`, and `_CAPTURE_COMPLETE`
written last. Anything else → **STOP; do not install.**

**Rollback point (recorded now, before anything changes) — explicit `DRY_RUN=0`:**

```bash
sudo env DRY_RUN=0 /usr/local/src/jol-home-migration-d3c98ea/scripts/maintenance/capture-installed-workstation-scripts.sh --rollback "$(cat /root/jol-capture-path)"
```

## Step 3 — dry survey of the real destinations

```bash
sudo env DRY_RUN=1 bash /usr/local/src/jol-home-migration-d3c98ea/scripts/maintenance/install-workstation-scripts.sh
```

Read all six `target :` lines and the survey count. Expect three `exists … mode 750` and three `does not
exist — install creates it (mode 755)`. A fourth mode, an unexpected content change, or any refusal naming a
dirty source → **STOP and explain it.**

## Step 4 — install, then verify each destination independently

```bash
sudo env DRY_RUN=0 bash /usr/local/src/jol-home-migration-d3c98ea/scripts/maintenance/install-workstation-scripts.sh
sudo bash -c 'C=d3c98ea8fa821ff1a39a480843a81688d4a727b3
 D=/opt/jol/delivery/jol-infrastructure-home-migration
 rc=0
while read -r pair; do
  src=${pair%%|*}; dst=${pair##*|}
  if ! git -C "$D" cat-file -e "$C:scripts/maintenance/$src" 2>/dev/null; then echo "ABORT NO-BLOB $src"; rc=1; continue; fi
  git -C "$D" cat-file blob "$C:scripts/maintenance/$src" > /tmp/bc || { echo "ABORT EXTRACT $src"; rc=1; continue; }
  [ -s /tmp/bc ] || { echo "ABORT EMPTY-BLOB $src"; rc=1; continue; }
  want=$(sha256sum /tmp/bc | cut -d" " -f1)
  got=$(sha256sum "/usr/local/bin/$dst" 2>/dev/null | cut -d" " -f1)
  meta=$(stat -c "%a %U:%G" "/usr/local/bin/$dst" 2>/dev/null)
  if [ ${#want} -ne 64 ] || [ ${#got} -ne 64 ]; then echo "ABORT EMPTY-DIGEST $dst"; rc=1
  elif [ "$want" != "$got" ]; then echo "DIGEST-FAIL $dst"; rc=1
  elif [ "$meta" != "755 root:root" ]; then echo "META-FAIL $dst ($meta)"; rc=1
  else echo "OK $dst ${got:0:16} $meta"; fi
 done <<EOF
fix-jol-backup-mount.sh|jol-fix-backup-mount.sh
backup-workstation-home.sh|jol-backup-home.sh
provision-jolhome-disk.sh|jol-provision-home-disk.sh
migrate-home-to-jolhome.sh|jol-migrate-home.sh
record-jolhome-custody.sh|jol-record-custody.sh
benchmark-jolhome-writes.sh|jol-write-bench.sh
EOF
exit $rc'
```

Six `OK` lines → **six installed and verified.** Any `ABORT`/`FAIL` → report that exact line and use the
Step 2 rollback command. A partial install is a real state; name it.

---

## Step 5 — Prompt 2, only after Step 4 is clean

Confirm the installed recorder and helper equal the pinned revision — the digests below are the values
measured from the pinned commit today, so they are a check, not a tautology:
`record-jolhome-custody.sh 1f81e36fde5fdec2…`, `migrate-home-to-jolhome.sh 9684e278969316a1…`.

```bash
sha256sum /usr/local/bin/jol-record-custody.sh /usr/local/bin/jol-migrate-home.sh | cut -c1-16
```

Confirm the two UUIDs are **distinct** — equal values mean a device was resolved to the mapper, which
writes the filesystem UUID into crypttab and fails unlock at boot. Both are readable without root via
structured fields; `cryptsetup luksUUID` itself returns *access denied* unprivileged and is therefore not
the probe to trust:

| Identity | Value |
|---|---|
| LUKS header, `/dev/nvme2n1p1` (ADATA LEGEND 900) | `4fc2ae29-3dd3-43c7-b43b-325ba9ed2690` |
| inner ext4 (destination `/home`) | `15325864-4913-4983-a8cb-d214aa33f516` |
| `/etc/crypttab` | `jolhome_crypt UUID=4fc2ae29-… none luks` — matches the **header** UUID ✓ |

Then, in your terminal. **This is where you type the passphrase, and only cryptsetup sees it:**

```bash
sudo env DRY_RUN=0 /usr/local/bin/jol-record-custody.sh
```

Return only the non-secret result: the keyslot index you entered, whether cryptsetup accepted it, the
artifact path printed, and the rc of
`sudo /usr/local/bin/jol-migrate-home.sh --check-attestation /var/lib/jol-workstation/jolhome-custody; echo rc=$?`
— expect the token `PASS` on stdout and **rc=0**.

> **Corrected 2026-11-07.** This line previously read `--check-attestation; echo rc=$?` with no path and
> said "expect 0". In the reviewed revision the artifact path is **argv[2] with no default**
> (`CA_PATH="${2:-}"` in `migrate-home-to-jolhome.sh`), so the documented form printed `NO_PATH` to stderr
> and exited **2** every time — a calling error that reads as a custody rejection and would have made the
> operator re-run a recorder that had already succeeded. Interface contract, verified against the code:
> stdout is exactly one verdict token; **rc 0 = PASS**, **rc 1 = any other verdict**, **rc 2 = artifact
> could not be read** (`NO_PATH` / `UNREADABLE`). `0` is also what the recorder's own self-check requires
> before it installs its artifact.

Then answer separately: **can you retrieve the recovery credential while `/home` is offline?** The age
identity and recipient are at `/opt/jol/.sops` (device 66315, not `/home`), so they survive an unmounted
`/home` — but that partition is plain `ext4` with no LUKS layer, the identity is mode `600 jol:jol` and
readable by uid 1000, and `shares/` is **absent**, so the Shamir custody path is not on this disk. Vaultwarden
is separately known to have shown an empty vault in a prior session, so no credential there may be assumed
retrievable.

**If the credential test fails: stop. Change no keyslot** — no `luksAddKey`, no `luksKillSlot`, no
reformat. Preserve the current keyslots and report. `systemd-cryptenroll`, not `cryptsetup`, is the tool
for adding a slot later.
