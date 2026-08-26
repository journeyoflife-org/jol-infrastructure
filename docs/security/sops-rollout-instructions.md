# SOPS Fleet Rollout Instructions (Gate 7 kit)

Per-repo enablement (run ONLY after Gate 8 round-trip passes for the tree):

1. Copy the tree-correct `.sops.yaml` from this repo root (church) or from
   `jol-m-compliance` (marketplace). Recipients: see
   `docs/security/sops-recipients-registry.md`.
2. Create `secrets/encrypted/` with `.gitkeep` for real secrets; use
   `*.enc.yaml` for one-off encrypted configs.
3. Encrypt: `sops --encrypt --in-place path/to/file.enc.yaml`
   (config resolves the recipient automatically).
4. Validate before committing — the checks from the jol-hub validator
   (C5-R2, restore pending): genuine sops metadata present, no
   AGE-SECRET-KEY/PEM/AKIA/token patterns, `.sops.yaml` holds public keys only.
5. Decrypt for use: `SOPS_AGE_KEY_FILE=/opt/jol/.sops/age-<tree>.txt sops -d <file>`
   — never decrypt into a tracked path; never commit plaintext.
6. CI usage: decryption in CI requires the identity in CI secrets
   (GitHub secret holding the Vaultwarden-sourced key at pipeline time) —
   out of scope until a CI need is filed via CC8.1.

Prohibitions (amendment rule 6): private keys in git/CI logs/CLI arguments;
wildcard safe.directory; single shared identity across trees; SOPS for
runtime cluster secrets (ESO owns that surface).
