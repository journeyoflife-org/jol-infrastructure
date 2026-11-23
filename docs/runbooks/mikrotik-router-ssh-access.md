# MikroTik RB5009 admin SSH access — key install, host-key pinning and service hardening

**Host affected**: MikroTik RB5009UG+S+ management router (RouterOS 7.19.6) · admin plane `192.168.88.1` (defconf bridge)
**Requesting host**: operator workstation `ubuntu` (`192.168.88.249` via `enp4s0`)
**Motive**: retire the password-exposed management path (vlan-audit **F2/F3**) — give the operator key-only SSH and lock the router's service plane to the management subnets.
**Compliance**: ISO 27001 A.8.2 / A.9.4 / A.8.20 · SOC 2 CC6.1 / CC6.6 · GDPR Art. 32
**⚠ NO CREDENTIALS in this document.** The admin password is typed by the operator only (§0.1); it must never enter chat, argv, or history.
**Executed & verified 2026-11-23.** Change tracked in the linked GitHub issue.

---

## 0. Verdict (professional opinion)

Key-only SSH on RouterOS is achieved by **importing a key for the user** — there is **no `use-public-key-only` toggle** to set (§2.3). Once a key is present, the router **refuses that user's password over SSH** (verified §4.2). The durable hardening therefore has three parts: (a) install the key, (b) pin the host key on the client so it is enforced automatically, (c) restrict `/ip service` to the management subnets and disable the cleartext services.

Do this **over the defconf bridge only while the `Gi1/0/48 ↔ ether2` trunk fault stands**: the documented VLAN 10 SVI `10.10.10.1` is unreachable (§1). Any service source-restriction **must** include `192.168.88.0/24` or it locks out the only working path.

---

## 1. Reachability precondition (measure before configuring)

| Target | Meaning | Expected while trunk fault stands |
|--------|---------|-----------------------------------|
| `192.168.88.1:22` | defconf bridge SSH | OPEN — this is the admin path |
| `192.168.88.1:8291` | Winbox | OPEN — mandatory escape hatch (no serial port on RB5009) |
| `10.10.10.1` | VLAN 10 SVI | unreachable until the trunk is repaired |

```bash
# [WORKSTATION]
ping -c1 -W1 192.168.88.1 && echo "defconf up"
ip route get 192.168.88.1 | head -1     # must select src 192.168.88.249
```

**Keep a Winbox session open for the whole window** — a self-inflicted lockout on a device with no
serial console is otherwise recoverable only by Netinstall-grade reflash.

---

## 2. RouterOS SSH key installation (the two traps)

### 2.1 Rights gate (do first)
The `>` prompt is ambiguous on RouterOS. Confirm the account is writable before any `set`:
```routeros
/user print where name=admin          # expect group=full
```

### 2.2 Pre-change capture (§0.3)
```routeros
/export file=pre-ssh-hardening-20261123
/system backup save name=pre-ssh-hardening-20261123
```
Pull both files off the router flash afterwards (they are the rollback unit).

### 2.3 Import — **file-based only, no inline key**
RouterOS `/user ssh-keys import` has **no `public-key=` parameter** — only `public-key-file=`. Typing an
inline key resolves by abbreviation to `public-key-file` and fails `input does not match any value of
public-key-file` (really "no such file"), silently leaving the key uninstalled.

Put the pubkey on the router as a file first (Winbox **Files** drag of `~/mikrotik-admin.pub`, or
`scp`), then:
```routeros
/file print where name=mikrotik-admin.pub
/user ssh-keys import public-key-file=mikrotik-admin.pub user=admin
/user ssh-keys print detail         # expect: user=admin key-type=ed25519 bits=256 key-owner="<comment>"
/file remove mikrotik-admin.pub     # never leave the plaintext key file on the device
```

There is **no** `/user set admin use-public-key-only=yes` — that parameter does not exist. Importing the
key is itself what disables password fallback for that user on SSH.

---

## 3. Workstation side — present the right key, enforce the pinned fingerprint

### 3.1 Pin the host key (TOFU over the trusted defconf L2)
```bash
# [WORKSTATION] — capture, read the fingerprint, record it
ssh-keyscan -t rsa 192.168.88.1 > /tmp/mt.hostkey
ssh-keygen -lf /tmp/mt.hostkey
# RouterOS 7.19 default SSH offers ONLY an ssh-rsa host key (no ed25519 host key).
# Pinned 2026-11-23 value:
#   2048 SHA256:/3aeBoFR4MhiCBiOHb+z08yKPgy2azh0ENX9Q76hhm8 (RSA)
```
Because the first capture happens on the trusted defconf segment, accept it as TOFU, then enforce it
forever with `StrictHostKeyChecking yes`. A future re-key (or any host-key change) then **hard-fails**
instead of silently re-prompting — which is the point.

### 3.2 Host stanza (`~/.ssh/config`)
Back the file up before editing (out-of-workspace files must be appended via the shell, not the edit tool):
```sshconfig
Host mikrotik rb01-mgmt 192.168.88.1
    HostName 192.168.88.1
    User admin
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    UserKnownHostsFile ~/.ssh/known_hosts
    ServerAliveInterval 30
    ServerAliveCountMax 3
```
Validate without connecting: `ssh -G mikrotik | grep -Ei 'identitiesonly|stricthostkey|identityfile'`.

> Post-quantum warning: OpenSSH ≥ 10 prints `connection is not using a post-quantum key exchange` on
> every connect to RouterOS 7.19. Informational only — RouterOS offers no PQ KEX yet. Not a fault.

---

## 4. Verification gates (§0.4 — every line needs command output)

### 4.1 Key-only login works
```bash
ssh -o BatchMode=yes -o PreferredAuthentications=publickey mikrotik '/system resource print'
```
PASS = `rc=0` and `board-name: RB5009UG+S+`. `ssh -v` must show `Server accepts key` then
`Authenticated to 192.168.88.1 … using "publickey"`.

### 4.2 Password is refused for the keyed user
```bash
ssh -o PubkeyAuthentication=no admin@192.168.88.1
```
PASS = `Permission denied` **when the operator types the current correct password**. (If the operator
is unsure of the value the result is inconclusive — but rotation in §6 makes it moot.)
Note: `Permission denied (publickey,password)` in the client's method list is the **service-global**
capability banner, not proof the admin password still authenticates.

### 4.3 Service plane state
```routeros
/ip service print brief
```
PASS = telnet/ftp/www/www-ssl show `X` (disabled); ssh/winbox/api/api-ssl show
`ADDRESS 10.10.10.0/24, 192.168.88.0/24`; and at least one live `ssh` connection row (proves no lockout).

---

## 5. Service hardening applied (closes vlan-audit F3)

```routeros
/ip service disable telnet,ftp,www
/ip service set ssh         address=10.10.10.0/24,192.168.88.0/24
/ip service set winbox      address=10.10.10.0/24,192.168.88.0/24
/ip service set api,api-ssl address=10.10.10.0/24,192.168.88.0/24
```
The `address=` list **replaces** the existing value, so the operator's live source subnet must appear in
the same command. `192.168.88.0/24` is what keeps the defconf admin path alive.

---

## 6. Remaining — F2 is NOT closed by this change (HIGH)

Key-only SSH does **not** retire the exposed admin password — it is still valid for **Winbox, the API,
and the physical console**. The authoritative F2 remediation is unchanged:

1. **Rotate the admin password** (now safe — SSH no longer depends on it); store the new value in
   **Vaultwarden only**.
2. Re-verify Winbox login with the new value while a key-SSH session stays open.
3. Optional defense-in-depth: a separate read-only RouterOS user (`/user group add name=ro-policy
   policy=read,api`) for any automation, instead of sharing `admin`.

Also owed for closure: update `docs/network/vlan-audit-2026-08-29.md` F2/F3 status; the still-open
`dell-n2048-port-table.md` Gi1/0/47 row (admin01 `.50` → workstation `.51`); pull the §2.2 backup/export
files off-router; and the router UPS finding (three unclean power reboots).

---

## 7. Rollback

| Change | Revert |
|--------|--------|
| `/ip service` disable + address restrict | re-enable and clear via Winbox (Winbox stays reachable — it is on the allowed subnets), or restore the §2.2 backup |
| key import | `/user ssh-keys remove [find where user=admin]` |
| client pin/config | delete the `mikrotik` stanza; remove the `192.168.88.1` line from `~/.ssh/known_hosts` |
| full device | `/system reset-configuration` (nuclear) or restore `pre-ssh-hardening-20261123.backup` via Netinstall/winbox |

**Escape hatch rule:** never run §5 or §6 while it is the only open session — keep Winbox (8291) or a
second key-SSH alive until the change is verified (§4).
