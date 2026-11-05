#!/usr/bin/env bash
# =============================================================================
# trufflehog-docker-scan.sh — the LOCAL secret gate for pre-commit.
#
# WHY THIS EXISTS (found 2026-11-01T16:32Z by a failed `git commit`): the hook used
# to build TruffleHog from source through pre-commit's `golang` language. There is no
# Go toolchain on this workstation and Ubuntu 24.04's apt candidate is 1.22, against
# which the hook's dependency `golang.org/x/tools v0.24.0` fails to compile
# (`tokeninternal.go:64:9: invalid array length -delta * delta`). The hook therefore
# could not INSTALL, which aborted every commit — and before that, on any machine
# without Go, the same hook was simply never running. A secret gate that cannot start
# is not a gate; it is decoration.
#
# WHY THE SCAN MODE CHANGED, and it matters: the old entry was
# `trufflehog filesystem --only-verified`. Verification means asking each provider's
# API whether the credential is live, so on an offline host, behind egress controls, or
# for a secret whose provider cannot be reached, `--only-verified` reports NOTHING and
# exits 0. That is the failure class this fleet keeps excavating — an absence of
# measurement rendered as a pass (pbs01 gate 3, hv01 gate 10, the `qm set --help`
# measurement in #128). This wrapper scans by DETECTION (`--no-update`, no
# verification) so a credential-shaped string in a staged file fails the commit here,
# and CI keeps the verified scan (`infra-validate.yml` job `trufflehog-scan`, action
# pinned by SHA) as the second, authoritative layer. More noise is the correct trade:
# a local gate's job is to make you look, not to assure you.
#
# Pinning: the image is referenced by REPOSITORY DIGEST, not a tag. `latest` is what
# the registry offers (tag `v3.82.0` does not exist — measured), so the digest in
# IMAGE below is the pin and must be reviewed whenever it changes.
#
# Exit: 0 no findings, 1 findings OR the scan could not run (never a silent pass),
#       2 usage error.
# =============================================================================
set -uo pipefail

IMAGE='ghcr.io/trufflesecurity/trufflehog@sha256:0d003fc3abc4e1565eca8462b992001314de51451e96e3c44de80d116794d5d1'

if [[ $# -lt 1 ]]; then
    echo "usage: $(basename "$0") <file> [<file> …]" >&2
    exit 2
fi

# Refuse loudly rather than reporting a clean scan when the tool is unavailable.
if ! command -v docker >/dev/null 2>&1; then
    echo "FAIL: docker is not installed — the secret gate DID NOT RUN. Install Docker or" >&2
    echo "      rely on CI's trufflehog-scan, but do not treat this as a pass." >&2
    exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "pulling $IMAGE …" >&2
    docker pull --quiet "$IMAGE" >/dev/null 2>&1 || {
        echo "FAIL: could not pull the pinned image — the secret gate DID NOT RUN." >&2
        exit 1
    }
fi

# The repo is mounted read-only at the same relative paths, so findings point at the
# files pre-commit actually staged. HOME is pointed at the tmpfs because with --user
# mapping the container has no writable home and git inside trufflehog prints
# `could not lock config file //.gitconfig: Permission denied` on every run — noise
# that would train whoever reads it to ignore the line.
docker run --rm --workdir=/src -e HOME=/tmp --user "$(id -u):$(id -g)" \
    -v "$PWD:/src:ro" --tmpfs /tmp:rw,size=64m \
    "$IMAGE" filesystem --no-update --fail "$@"
rc=$?

case $rc in
    0) echo "TruffleHog (local gate): no findings on $#: added file(s)" ;;
    1) echo "TruffleHog (local gate): FINDINGS ABOVE — commit blocked. If any value is real:" >&2
       echo "  it must not reach git at all. Move it to Ansible Vault / SOPS / Vaultwarden," >&2
       echo "  rotate it (it is now disclosed to this shell's history), then re-stage." >&2 ;;
    *) echo "TruffleHog (local gate): scan FAILED to complete (rc=$rc) — not a pass." >&2 ;;
esac
exit $rc
