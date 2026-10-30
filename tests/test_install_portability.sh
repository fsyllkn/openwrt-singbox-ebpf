#!/usr/bin/env bash
# Fresh installation paths and existing per-device settings, without host writes.
set -euo pipefail
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d /tmp/sb-install-portability.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
awk '
  /^(record_source_directory|validate_provider_samples|copy_missing_file|deploy_provider_samples|create_default_config|check_service_conflicts)\(\) \{/ { emit = 1 }
  emit { print }
  emit && /^}$/ { emit = 0 }
' "$BASE/install.sh" > "$TEST_DIR/install-functions.sh"
. "$TEST_DIR/install-functions.sh"

INSTALL_DIR=$TEST_DIR/custom\ installation
CONFIG=$TEST_DIR/external\ config/router.json
REPO_ROOT=$TEST_DIR/custom\ source
mkdir -p "$INSTALL_DIR/config" "$REPO_ROOT/examples"
cp "$BASE/config/config.template.json" "$INSTALL_DIR/config/"
for name in xboard local; do cp "$BASE/examples/$name.sample.json" "$REPO_ROOT/examples/"; done
deploy_provider_samples
create_default_config > "$TEST_DIR/fresh-config.log"
[ "$(jq -r '.experimental.clash_api.external_ui' "$CONFIG")" = "$INSTALL_DIR/board/dist" ] || fail 'fresh template retained old HOME'
[ "$(stat -c '%a' "$CONFIG")" = 600 ] || fail 'fresh config mode is not private'
jq 'del(.experimental.clash_api.external_ui)' "$CONFIG" > "$TEST_DIR/actual.json"
jq 'del(.experimental.clash_api.external_ui)' "$BASE/config/config.template.json" > "$TEST_DIR/expected.json"
cmp "$TEST_DIR/actual.json" "$TEST_DIR/expected.json" || fail 'fresh rendering changed unrelated policy'
for name in xboard local; do
    cmp "$REPO_ROOT/examples/$name.sample.json" "$INSTALL_DIR/providers/$name.sample.json" || fail 'public provider sample not deployed'
    cmp "$INSTALL_DIR/providers/$name.sample.json" "$INSTALL_DIR/providers/$name.json" || fail 'fresh runtime provider not initialized from sample'
    [ "$(stat -c '%a' "$INSTALL_DIR/providers/$name.json")" = 600 ] || fail 'fresh provider mode is not private'
done
jq -e '[.providers[]|select(.type=="local")|.path]|sort==["providers/local.json","providers/xboard.json"]' "$CONFIG" >/dev/null || fail 'fresh provider paths are not relative to HOME'
grep -Fq 'Example nodes do not provide a working proxy' "$TEST_DIR/fresh-config.log" || fail 'fresh install did not distinguish sample nodes from working proxy service'
cat > "$CONFIG" <<'JSON'
{"inbounds":[{"type":"mixed","tag":"custom-lan","listen":"10.77.9.5","listen_port":17890,"users":[{"username":"test-user","password":"test-only"}]}],"route":{"rules":[{"ip_cidr":["10.8.0.104/32","172.20.0.0/16"],"outbound":"office-node"}]},"providers":[{"type":"local","path":"/mnt/proxy nodes/custom.json"}]}
JSON
cp "$CONFIG" "$TEST_DIR/existing.json"
rm "$INSTALL_DIR/providers/xboard.json" "$INSTALL_DIR/providers/local.json"
deploy_provider_samples
create_default_config > "$TEST_DIR/existing-config.log"
cmp "$TEST_DIR/existing.json" "$CONFIG" || fail 'existing custom inbounds/routes/providers were overwritten'
[ ! -e "$INSTALL_DIR/providers/xboard.json" ] && [ ! -e "$INSTALL_DIR/providers/local.json" ] || fail 'missing real provider was replaced with dummy data for an existing config'
[ ! -s "$TEST_DIR/existing-config.log" ] || fail 'existing configuration received a fresh-install sample message'
record_source_directory
[ "$(cat "$INSTALL_DIR/runtime/source-dir")" = "$REPO_ROOT" ] || fail 'custom source location lost'
[ "$(stat -c '%a' "$INSTALL_DIR/runtime/source-dir")" = 600 ] || fail 'source record not private'

# New configuration generation must preserve real files already present in
# providers, including readable links, and never replace dangling links.
(
    INSTALL_DIR=$TEST_DIR/existing-provider-home
    CONFIG=$TEST_DIR/existing-provider-config.json
    mkdir -p "$INSTALL_DIR/config" "$INSTALL_DIR/providers"
    cp "$BASE/config/config.template.json" "$INSTALL_DIR/config/"
    deploy_provider_samples
    printf '{"outbounds":[{"type":"socks","tag":"keep-device-node","server":"192.0.2.88","server_port":1080}]}\n' > "$INSTALL_DIR/providers/xboard.json"
    printf '{"outbounds":[{"type":"socks","tag":"keep-linked-node","server":"192.0.2.89","server_port":1080}]}\n' > "$TEST_DIR/linked-provider.json"
    ln -s "$TEST_DIR/linked-provider.json" "$INSTALL_DIR/providers/local.json"
    cp "$INSTALL_DIR/providers/xboard.json" "$TEST_DIR/provider-before.json"
    cp "$TEST_DIR/linked-provider.json" "$TEST_DIR/linked-before.json"
    create_default_config > "$TEST_DIR/existing-provider.log"
    cmp "$TEST_DIR/provider-before.json" "$INSTALL_DIR/providers/xboard.json" || fail 'new config overwrote existing device provider'
    cmp "$TEST_DIR/linked-before.json" "$TEST_DIR/linked-provider.json" || fail 'new config changed linked provider contents'
    [ -L "$INSTALL_DIR/providers/local.json" ] || fail 'new config replaced provider symlink'
)
for scenario in missing malformed empty missing_tag dangling_sample dangling_provider dangling_config; do
    (
        INSTALL_DIR="$TEST_DIR/$scenario/home"
        CONFIG="$TEST_DIR/$scenario/config.json"
        mkdir -p "$INSTALL_DIR/config"
        cp "$BASE/config/config.template.json" "$INSTALL_DIR/config/"
        deploy_provider_samples
        case "$scenario" in
            missing) rm "$INSTALL_DIR/providers/local.sample.json" ;;
            malformed) printf '{invalid\n' > "$INSTALL_DIR/providers/local.sample.json" ;;
            empty) printf '{"outbounds":[]}\n' > "$INSTALL_DIR/providers/local.sample.json" ;;
            missing_tag) printf '{"outbounds":[{"type":"socks"}]}\n' > "$INSTALL_DIR/providers/local.sample.json" ;;
            dangling_sample)
                rm "$INSTALL_DIR/providers/local.sample.json"
                ln -s "$TEST_DIR/$scenario/missing-target" "$INSTALL_DIR/providers/local.sample.json"
                deploy_provider_samples
                [ -L "$INSTALL_DIR/providers/local.sample.json" ] || fail 'sample deployment replaced dangling sample symlink' ;;
            dangling_provider) ln -s "$TEST_DIR/$scenario/missing-target" "$INSTALL_DIR/providers/local.json" ;;
            dangling_config) ln -s "$TEST_DIR/$scenario/missing-target" "$CONFIG" ;;
        esac
        if (create_default_config) > "$TEST_DIR/$scenario/output" 2>&1; then fail "$scenario accepted while creating new config"; fi
        [ ! -e "$CONFIG" ] || fail "$scenario created a configuration despite invalid prerequisites"
        [ ! -e "$INSTALL_DIR/providers/xboard.json" ] || fail "$scenario initialized runtime providers before validation completed"
        case "$scenario" in
            dangling_sample) [ -L "$INSTALL_DIR/providers/local.sample.json" ] || fail 'dangling sample was overwritten' ;;
            dangling_provider) [ -L "$INSTALL_DIR/providers/local.json" ] || fail 'dangling runtime provider was overwritten' ;;
            dangling_config) [ -L "$CONFIG" ] || fail 'dangling configuration was overwritten' ;;
        esac
        grep -Eq 'provider sample|Existing provider|Existing configuration' "$TEST_DIR/$scenario/output" || fail 'provider/config prerequisite error was unclear'
    )
done
(
    INSTALL_DIR=$TEST_DIR/edited-samples
    mkdir -p "$INSTALL_DIR/providers"
    printf 'locally edited sample must stay untouched\n' > "$INSTALL_DIR/providers/xboard.sample.json"
    chmod 0400 "$INSTALL_DIR/providers/xboard.sample.json"
    deploy_provider_samples
    [ "$(cat "$INSTALL_DIR/providers/xboard.sample.json")" = 'locally edited sample must stay untouched' ] || fail 'deployment overwrote an edited sample'
    [ "$(stat -c '%a' "$INSTALL_DIR/providers/xboard.sample.json")" = 400 ] || fail 'deployment changed edited sample permissions'
    [ -f "$INSTALL_DIR/providers/local.sample.json" ] || fail 'deployment did not fill missing sample beside edited file'
)

# The generic names must not silently replace a firmware package or other tool.
mkdir -p "$TEST_DIR/aliases"
printf '#!/bin/sh\n# distribution sing-box\n' > "$TEST_DIR/init"
if (check_service_conflicts "$TEST_DIR/init" "$TEST_DIR/aliases/sbctl" "$TEST_DIR/aliases/local-sbctl") > "$TEST_DIR/conflict.log" 2>&1; then
    fail 'foreign procd service accepted'
fi
cp "$BASE/openwrt/sing-box.init" "$TEST_DIR/init"
printf '#!/bin/sh\n# another tool\n' > "$TEST_DIR/aliases/sbctl"
if (check_service_conflicts "$TEST_DIR/init" "$TEST_DIR/aliases/sbctl" "$TEST_DIR/aliases/local-sbctl") > "$TEST_DIR/conflict.log" 2>&1; then
    fail 'foreign controller accepted'
fi
rm "$TEST_DIR/aliases/sbctl"
ln -s "$BASE/scripts/sbctl" "$TEST_DIR/aliases/sbctl"
check_service_conflicts "$TEST_DIR/init" "$TEST_DIR/aliases/sbctl" "$TEST_DIR/aliases/local-sbctl"

# Execute the real installer only up to its early unsupported-architecture gate.
# No package, network or filesystem deployment may happen first.
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/id" <<'SH'
#!/bin/sh
[ "$*" = -u ] || exit 66
echo 0
SH
chmod 0755 "$TEST_DIR/bin/id"
cat > "$TEST_DIR/bin/uname" <<'SH'
#!/bin/sh
case "$1" in
    -m) echo mips ;;
    -r) echo 6.6.0 ;;
    *) exit 66 ;;
esac
SH
chmod 0755 "$TEST_DIR/bin/uname"
if PATH="$TEST_DIR/bin:$PATH" SH_SINGBOX_HOME="$TEST_DIR/unsupported" SH_SINGBOX_CONFIG="$TEST_DIR/unsupported/config.json" \
    bash "$BASE/install.sh" > "$TEST_DIR/unsupported.log" 2>&1; then
    fail 'unsupported Linux architecture accepted'
fi
grep -Fq 'Unsupported architecture: mips' "$TEST_DIR/unsupported.log" || fail 'unsupported platform error unclear'
[ ! -e "$TEST_DIR/unsupported" ] || fail 'unsupported architecture mutated installation'

# Exercise the real offline bootstrap with only its OS marker and launcher
# paths redirected to the fixture. No network, /etc or /usr writes occur.
BOOT_SOURCE=$TEST_DIR/bootstrap\ source
BOOT_TARGET=$TEST_DIR/bootstrap\ target
mkdir -p "$BOOT_SOURCE/scripts" "$BOOT_SOURCE/openwrt" "$BOOT_SOURCE/config" "$BOOT_SOURCE/examples" \
    "$BOOT_SOURCE/providers" "$BOOT_TARGET/config" "$BOOT_TARGET/providers"
for file in README.md quick-install.sh install.sh uninstall.sh; do cp "$BASE/$file" "$BOOT_SOURCE/$file"; done
for file in sbctl runtime-paths.sh download.sh configure-download.sh gateway.sh dns-guard.sh update-core.sh; do
    cp "$BASE/scripts/$file" "$BOOT_SOURCE/scripts/$file"
done
cp "$BASE/openwrt/sing-box.init" "$BOOT_SOURCE/openwrt/"
cp "$BASE/config/config.template.json" "$BOOT_SOURCE/config/"
for name in xboard local; do cp "$BASE/examples/$name.sample.json" "$BOOT_SOURCE/examples/"; done
cat > "$BOOT_SOURCE/menu.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$0" > "$TEST_MENU_LOG"
SH
cp "$BOOT_SOURCE/menu.sh" "$BOOT_TARGET/menu.sh"
printf '{"source":"must not replace device configuration"}\n' > "$BOOT_SOURCE/config/config.json"
printf '{"device":"keep custom settings"}\n' > "$BOOT_TARGET/config/config.json"
printf '{"device":"keep private provider"}\n' > "$BOOT_TARGET/providers/private.json"
cp "$BOOT_TARGET/config/config.json" "$TEST_DIR/bootstrap-config-before"
cp "$BOOT_TARGET/providers/private.json" "$TEST_DIR/bootstrap-provider-before"
: > "$TEST_DIR/openwrt_release"
sed -e "s@/etc/openwrt_release@$TEST_DIR/openwrt_release@g" \
    -e "s@/usr/bin/sb@$TEST_DIR/sb-launcher@g" "$BASE/quick-install.sh" > "$TEST_DIR/bootstrap.sh"
TEST_MENU_LOG=$TEST_DIR/menu-launch.log; export TEST_MENU_LOG
PATH="$TEST_DIR/bin:$PATH" SB_INSTALL_SOURCE_DIR="$BOOT_TARGET" \
    sh "$TEST_DIR/bootstrap.sh" --source "$BOOT_SOURCE" --no-menu > "$TEST_DIR/bootstrap.log" 2>&1 || {
    cat "$TEST_DIR/bootstrap.log" >&2; fail 'offline bootstrap rejected custom paths with spaces'
}
cmp "$TEST_DIR/bootstrap-config-before" "$BOOT_TARGET/config/config.json" || fail 'bootstrap overwrote device config'
cmp "$TEST_DIR/bootstrap-provider-before" "$BOOT_TARGET/providers/private.json" || fail 'bootstrap overwrote device provider'
sh "$TEST_DIR/sb-launcher"
[ "$(cat "$TEST_MENU_LOG")" = "$BOOT_TARGET/menu.sh" ] || fail 'launcher failed to quote spaced source path'
# A symlink spelling of the same checkout must not trigger self-copy errors.
ln -s "$BOOT_TARGET" "$TEST_DIR/target-alias"
PATH="$TEST_DIR/bin:$PATH" SB_INSTALL_SOURCE_DIR="$TEST_DIR/target-alias" \
    sh "$TEST_DIR/bootstrap.sh" --source "$BOOT_TARGET" --no-menu > "$TEST_DIR/same-source.log" 2>&1 ||
    fail 'canonical source/target identity was not recognized'
cp "$TEST_DIR/sb-launcher" "$TEST_DIR/launcher-before"
mkdir "$TEST_DIR/unsafe;target"
ln -s "$TEST_DIR/unsafe;target" "$TEST_DIR/unsafe-alias"
for unsafe_target in "$TEST_DIR/unsafe;target" "$TEST_DIR/unsafe-alias"; do
    if PATH="$TEST_DIR/bin:$PATH" SB_INSTALL_SOURCE_DIR="$unsafe_target" \
        sh "$TEST_DIR/bootstrap.sh" --source "$BOOT_SOURCE" --no-menu > "$TEST_DIR/unsafe-target.log" 2>&1; then
        fail 'shell metacharacters in canonical launcher target accepted'
    fi
    cmp "$TEST_DIR/launcher-before" "$TEST_DIR/sb-launcher" || fail 'rejected target modified launcher'
done
echo 'Installation portability, source discovery and user configuration preservation tests passed.'
