#!/bin/sh
# Model firmware capabilities and UCI flags without real mounts or services.
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d /tmp/sb-procd-capabilities.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
. "$BASE/openwrt/sing-box.init"
CONFIG=$TEST_DIR/config.json
MOUNTS=$TEST_DIR/mounts
FILESYSTEMS=$TEST_DIR/filesystems
TARGET=$TEST_DIR/cgroup
EVENTS=$TEST_DIR/events
export EVENTS
mount() {
    printf 'mount:%s\n' "$*" >> "$EVENTS"
    [ "${MOCK_MOUNT:-ok}" != denied ] || return 1
    [ "${MOCK_MOUNT:-ok}" != unverified ] || return 0
    printf 'none %s cgroup2 rw 0 0\n' "$TARGET" > "$MOUNTS"
}
printf '{}\n' > "$CONFIG"
: > "$MOUNTS"; : > "$FILESYSTEMS"
check_cgroup2 "$MOUNTS" "$FILESYSTEMS" "$TARGET"
[ ! -e "$EVENTS" ] || fail 'non-eBPF configuration attempted a mount'
printf '{"inbounds":[{"type":"ebpf","local":{"enabled":true,"data_plane":"cgroup"}}]}\n' > "$CONFIG"
if check_cgroup2 "$MOUNTS" "$FILESYSTEMS" "$TARGET" > "$TEST_DIR/no-kernel.log" 2>&1; then
    fail 'firmware without cgroup2 accepted'
fi
[ ! -e "$EVENTS" ] || fail 'unsupported firmware attempted a mount'
# The pinned core enables local when neither enabled flag is explicit, and an
# empty data_plane has the same cgroup default as an omitted data_plane.
for json in '{"inbounds":[{"type":"ebpf"}]}' \
    '{"inbounds":[{"type":"ebpf","local":{"enabled":true,"data_plane":""}}]}'; do
    printf '%s\n' "$json" > "$CONFIG"
    if check_cgroup2 "$MOUNTS" "$FILESYSTEMS" "$TARGET" > "$TEST_DIR/default-plane.log" 2>&1; then
        fail 'default-enabled local cgroup path skipped capability validation'
    fi
done
printf '{"inbounds":[{"type":"ebpf","shared":{"enabled":true}}]}\n' > "$CONFIG"
check_cgroup2 "$MOUNTS" "$FILESYSTEMS" "$TARGET"
[ ! -e "$EVENTS" ] || fail 'shared-only configuration attempted a cgroup mount'
printf '{"inbounds":[{"type":"ebpf","local":{"enabled":true,"data_plane":"tc"}}]}\n' > "$CONFIG"
check_cgroup2 "$MOUNTS" "$FILESYSTEMS" "$TARGET"
[ ! -e "$EVENTS" ] || fail 'local TC configuration attempted a cgroup mount'
printf '{"inbounds":[{"type":"ebpf","local":{"enabled":true,"data_plane":"cgroup"}}]}\n' > "$CONFIG"
printf 'nodev\tcgroup2\n' > "$FILESYSTEMS"
printf 'none %s tmpfs rw 0 0\n' "$TARGET" > "$MOUNTS"
if check_cgroup2 "$MOUNTS" "$FILESYSTEMS" "$TARGET" > "$TEST_DIR/other-mount.log" 2>&1; then
    fail 'existing unrelated mount accepted'
fi
[ ! -e "$EVENTS" ] || fail 'existing unrelated mount was replaced'
printf 'none %s cgroup2 rw 0 0\n' "$TARGET" > "$MOUNTS"
check_cgroup2 "$MOUNTS" "$FILESYSTEMS" "$TARGET"
[ ! -e "$EVENTS" ] || fail 'existing cgroup2 mounted twice'
: > "$MOUNTS"
check_cgroup2 "$MOUNTS" "$FILESYSTEMS" "$TARGET"
grep -Fq "mount:-t cgroup2 none $TARGET" "$EVENTS" || fail 'supported cgroup2 was not mounted'
for scenario in denied unverified; do
    : > "$MOUNTS"
    if MOCK_MOUNT=$scenario check_cgroup2 "$MOUNTS" "$FILESYSTEMS" "$TARGET" > "$TEST_DIR/$scenario.log" 2>&1; then
        fail "cgroup mount $scenario was accepted"
    fi
done

# Custom subtree selection must inspect its actual containing filesystem, not
# assume every cgroup2 hierarchy lives at /sys/fs/cgroup.
CUSTOM_ROOT=$TEST_DIR/custom\ cgroup
mkdir -p "$CUSTOM_ROOT/subtree" "$CUSTOM_ROOT/overmounted/subtree"
CUSTOM_ESCAPED=$(printf '%s' "$CUSTOM_ROOT" | sed 's/ /\\040/g')
printf 'none %s cgroup2 rw 0 0\n' "$CUSTOM_ESCAPED" > "$MOUNTS"
: > "$EVENTS"
check_cgroup2 "$MOUNTS" "$FILESYSTEMS" "$TARGET"
[ ! -s "$EVENTS" ] || fail 'default path ignored existing nonstandard cgroup2 mount'
jq -n --arg path "$CUSTOM_ROOT/subtree" \
    '{inbounds:[{type:"ebpf",local:{enabled:true,data_plane:"cgroup",cgroup_path:$path}}]}' > "$CONFIG"
check_cgroup2 "$MOUNTS" "$FILESYSTEMS" "$TARGET"
[ ! -s "$EVENTS" ] || fail 'valid custom subtree caused a new mount'
printf 'none %s tmpfs rw 0 0\n' "$CUSTOM_ESCAPED" > "$MOUNTS"
if check_cgroup2 "$MOUNTS" "$FILESYSTEMS" "$TARGET" > "$TEST_DIR/custom-wrong-fs.log" 2>&1; then
    fail 'custom subtree on a non-cgroup2 filesystem accepted'
fi
[ ! -s "$EVENTS" ] || fail 'custom non-cgroup filesystem was overwritten'
printf 'none %s cgroup2 rw 0 0\nnone %s/overmounted tmpfs rw 0 0\n' "$CUSTOM_ESCAPED" "$CUSTOM_ESCAPED" > "$MOUNTS"
jq -n --arg path "$CUSTOM_ROOT/overmounted/subtree" \
    '{inbounds:[{type:"ebpf",local:{cgroup_path:$path}}]}' > "$CONFIG"
if check_cgroup2 "$MOUNTS" "$FILESYSTEMS" "$TARGET" > "$TEST_DIR/custom-overmount.log" 2>&1; then
    fail 'nested foreign mount inside cgroup2 was ignored'
fi
jq -n --arg path "$CUSTOM_ROOT/missing" \
    '{inbounds:[{type:"ebpf",local:{cgroup_path:$path}}]}' > "$CONFIG"
if check_cgroup2 "$MOUNTS" "$FILESYSTEMS" "$TARGET" > "$TEST_DIR/custom-missing.log" 2>&1; then
    fail 'missing custom cgroup subtree accepted'
fi
[ ! -s "$EVENTS" ] || fail 'invalid custom subtree attempted an arbitrary mount'

# UCI enabled=0 must stop before any controller, mount, DNS or gateway call.
uci() {
    case "$*" in
        '-q get sing-box.main.enabled') printf '%s\n' "${MOCK_ENABLED:-1}" ;;
        '-q get sing-box.main.auto_dns') printf '%s\n' "${MOCK_AUTO_DNS:-1}" ;;
        *) return 1 ;;
    esac
}
load_service_paths() { printf 'load-paths\n' >> "$EVENTS"; }
: > "$EVENTS"
MOCK_ENABLED=0 start_service > "$TEST_DIR/disabled.log"
[ ! -s "$EVENTS" ] || fail 'disabled service changed runtime state'
if MOCK_ENABLED=invalid start_service > "$TEST_DIR/invalid-option.log" 2>&1; then
    fail 'invalid enabled flag accepted'
fi
[ ! -s "$EVENTS" ] || fail 'invalid flag changed runtime state'

# With the service enabled, a failed cgroup check precedes every DNS/gateway call.
mkdir -p "$TEST_DIR/home"
for helper in core sbctl dns gateway; do
    cat > "$TEST_DIR/home/$helper" <<'SH'
#!/bin/sh
printf '%s:%s\n' "${0##*/}" "$*" >> "$EVENTS"
SH
    chmod 0755 "$TEST_DIR/home/$helper"
done
load_service_paths() {
    SERVICE_DIR=$TEST_DIR/home
    BIN=$SERVICE_DIR/core
    SBCTL=$SERVICE_DIR/sbctl
    DNS_GUARD=$SERVICE_DIR/dns
    GATEWAY=$SERVICE_DIR/gateway
}
check_cgroup2() { printf 'cgroup\n' >> "$EVENTS"; return "${MOCK_CGROUP_STATUS:-0}"; }
procd_open_instance() { printf 'procd-open\n' >> "$EVENTS"; }
procd_set_param() { :; }
procd_close_instance() { :; }
: > "$EVENTS"
if MOCK_CGROUP_STATUS=1 start_service > "$TEST_DIR/cgroup-failure.log" 2>&1; then
    fail 'failed cgroup preflight accepted'
fi
printf 'sbctl:preflight\ncgroup\n' > "$TEST_DIR/expected"
cmp "$TEST_DIR/expected" "$EVENTS" || fail 'network setup or core launch occurred before capability check'
: > "$EVENTS"
MOCK_AUTO_DNS=0 start_service > "$TEST_DIR/no-dns.log"
printf 'sbctl:preflight\ncgroup\ngateway:apply\nprocd-open\n' > "$TEST_DIR/expected"
cmp "$TEST_DIR/expected" "$EVENTS" || fail 'auto_dns=0 did not skip DNS setup'
echo 'Procd firmware capability and UCI flag tests passed.'
