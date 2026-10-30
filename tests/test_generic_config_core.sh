#!/usr/bin/env bash
# Optional real-core check of the three unchanged public configurations.
# The caller supplies an already downloaded/verified executable; this script
# never downloads anything, installs files, or invokes `sing-box run`.
set -euo pipefail
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if [ -z "${SB_TEST_CORE:-}" ]; then
    echo 'SKIP: set SB_TEST_CORE to a verified reF1nd executable to check the public configurations with the real core.'
    exit 0
fi
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
CORE=$SB_TEST_CORE
case "$CORE" in
    /*) ;;
    *) CORE="$PWD/$CORE" ;;
esac
[ -f "$CORE" ] && [ -x "$CORE" ] || fail 'SB_TEST_CORE must point to an executable file'
CHECK_TIMEOUT=${SB_TEST_CORE_CHECK_TIMEOUT:-60}
[[ "$CHECK_TIMEOUT" =~ ^[0-9]+$ ]] && [ "$CHECK_TIMEOUT" -gt 0 ] || fail 'SB_TEST_CORE_CHECK_TIMEOUT must be a positive integer'
command -v timeout >/dev/null 2>&1 || fail 'timeout is required for the real-core check'
TEST_DIR=$(mktemp -d /tmp/sb-generic-core.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
timeout "$CHECK_TIMEOUT" "$CORE" version > "$TEST_DIR/version" 2>&1 || fail 'supplied core cannot report its version'
sed -n '1p' "$TEST_DIR/version"

# Pinned source 78ea0ce9257bd3bedd4d1185d6cc4723f04096b4:
# cmd/sing-box/cmd_check.go calls box.New and Close, without Start.
# common/dialer/ebpf_self_bypass_linux.go prepares a kernel BPF map even
# during check when local eBPF is enabled. Capability errors must fail this
# requested check explicitly; disabling the inbound would test another config.
# Remote rule-set and dashboard downloads occur in the Start stages, so these
# original remote URLs remain unchanged and no local mock rules are inserted.
for config in config/config.json config/config.template.json examples/lan-private-routing.json; do
    [ -f "$BASE/$config" ] || fail "missing public configuration: $config"
    mkdir -p "$TEST_DIR/work"
    printf 'Checking unchanged configuration: %s\n' "$config"
    if (cd "$TEST_DIR/work" && timeout "$CHECK_TIMEOUT" "$CORE" check -c "$BASE/$config") > "$TEST_DIR/check.log" 2>&1; then
        printf 'PASS: %s\n' "$config"
    else
        status=$?
        cat "$TEST_DIR/check.log" >&2
        if grep -Fq 'prepare eBPF self-bypass' "$TEST_DIR/check.log" &&
            grep -Eiq 'operation not permitted|permission denied|not supported|memlock' "$TEST_DIR/check.log"; then
            printf '%s\n' 'BLOCKED: this core allocates a temporary eBPF map during check. The environment lacks the required BPF capability or kernel support; no configuration check was declared successful for this file.' >&2
        fi
        fail "real-core check failed for $config (exit $status); no runtime service was started"
    fi
done
echo 'Real-core configuration checks passed. This does not test device startup, listener binding, BPF attachment, DNS or routing.'
