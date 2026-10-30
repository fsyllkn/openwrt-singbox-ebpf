#!/usr/bin/env bash
# Offline deployment behavior without touching /etc, services or networking.
set -euo pipefail
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d /tmp/sb-scripts-update.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
mkdir -p "$TEST_DIR/bin"

# Extract only the production deployment functions. The private init-path
# argument points to the fixture; the public CLI still requires OpenWrt.
awk '
  /^(deploy_scripts_only|record_source_directory|check_service_conflicts|validate_provider_samples|copy_missing_file|deploy_provider_samples)\(\) \{/ { emit = 1 }
  emit { print }
  emit && /^}$/ { emit = 0 }
' "$BASE/install.sh" > "$TEST_DIR/deploy-function.sh"
test -s "$TEST_DIR/deploy-function.sh"
cat > "$TEST_DIR/runner.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
info() { printf '%s\n' "$*"; }
ok() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
REPO_ROOT=$CASE_SOURCE
. "$REPO_ROOT/scripts/runtime-paths.sh"
sb_load_paths
. "$DOWNLOAD_LIBRARY"
. "$PARTS_LIBRARY"
INSTALL_DIR=$SH_SINGBOX_HOME
CONFIG=$SH_SINGBOX_CONFIG
. "$DEPLOY_FUNCTION"
deploy_scripts_only "$CASE_INIT"
SH
cat > "$TEST_DIR/bin/uci" <<'SH'
#!/bin/sh
case "$*" in
    '-q get sing-box.main.service_dir') printf '%s\n' "$CASE_HOME" ;;
    '-q get sing-box.main.config_file') printf '%s\n' "$CASE_CONFIG" ;;
    *) printf 'uci %s\n' "$*" >> "$MUTATION_LOG"; exit 98 ;;
esac
SH
cat > "$TEST_DIR/forbidden-command" <<'SH'
#!/bin/sh
printf '%s %s\n' "$0" "$*" >> "$MUTATION_LOG"
exit 98
SH
for command in curl wget opkg apk apt-get systemctl service nft ip sysctl mount \
    reboot killall pkill logread; do
    cp "$TEST_DIR/forbidden-command" "$TEST_DIR/bin/$command"
done
chmod 0755 "$TEST_DIR/bin/"*
PATH=$TEST_DIR/bin:$PATH
DEPLOY_FUNCTION=$TEST_DIR/deploy-function.sh
DOWNLOAD_LIBRARY=$BASE/scripts/download.sh
PARTS_LIBRARY=$BASE/scripts/config-parts-lib.sh
export PATH DEPLOY_FUNCTION DOWNLOAD_LIBRARY PARTS_LIBRARY
unset SH_SINGBOX_HOME SH_SINGBOX_CONFIG

fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
prepare_case() {
    CASE_DIR=$TEST_DIR/$1
    CASE_HOME=$CASE_DIR/installed
    CASE_SOURCE=$CASE_DIR/source
    CASE_INIT=$CASE_DIR/init/sing-box
    CASE_CONFIG=$CASE_DIR/custom\ config/live.json
    MUTATION_LOG=$CASE_DIR/forbidden.log
    export CASE_HOME CASE_SOURCE CASE_INIT CASE_CONFIG MUTATION_LOG
    mkdir -p "$CASE_SOURCE/openwrt" "$CASE_SOURCE/config" "$CASE_SOURCE/providers" "$CASE_SOURCE/examples" \
        "$CASE_HOME/scripts" "$CASE_HOME/bin" "$CASE_HOME/runtime" \
        "$CASE_HOME/config" "$CASE_HOME/providers" "$CASE_DIR/init" \
        "$(dirname "$CASE_CONFIG")" "$CASE_DIR/before"
    cp -a "$BASE/scripts" "$CASE_SOURCE/scripts"
    cp "$BASE/menu.sh" "$BASE/uninstall.sh" "$CASE_SOURCE/"
    cp "$BASE/openwrt/sing-box.init" "$CASE_SOURCE/openwrt/"
    cp "$BASE/config/config.template.json" "$CASE_SOURCE/config/config.template.json"
    for name in xboard local; do cp "$BASE/examples/$name.sample.json" "$CASE_SOURCE/examples/"; done
    printf '{"test":"source production config must never be imported"}\n' > "$CASE_SOURCE/config/config.json"
    printf '{"test":"source provider must never be imported"}\n' > "$CASE_SOURCE/providers/private.json"
    printf '{"test":"source runtime xboard must never be imported"}\n' > "$CASE_SOURCE/providers/xboard.json"
    printf '{"test":"source runtime local must never be imported"}\n' > "$CASE_SOURCE/providers/local.json"
    for file in "$CASE_SOURCE"/scripts/*; do
        [ -f "$file" ] || continue
        # Upgrade a version that did not yet ship these interactive helpers.
        case "$(basename "$file")" in route-manager.sh|terminal-input.sh) continue ;; esac
        printf '#!/bin/sh\n# old installed %s\n' "$(basename "$file")" > "$CASE_HOME/scripts/$(basename "$file")"
    done
    printf '#!/bin/sh\n# existing menu\n' > "$CASE_HOME/scripts/menu.sh"
    printf '#!/bin/sh\n# custom local helper\n' > "$CASE_HOME/scripts/local-helper.sh"
    cp "$TEST_DIR/forbidden-command" "$CASE_HOME/bin/sing-box"
    cp "$TEST_DIR/forbidden-command" "$CASE_INIT"
    printf '\n# OpenWrt procd service init script for sing-box eBPF (reF1nd)\n' >> "$CASE_INIT"
    printf '#!/bin/sh\n# old uninstall\n' > "$CASE_HOME/uninstall.sh"
    chmod 0700 "$CASE_HOME/scripts/"* "$CASE_HOME/uninstall.sh"
    chmod 0755 "$CASE_HOME/bin/sing-box" "$CASE_INIT"
    printf '{"test":"installed default config stays untouched"}\n' > "$CASE_HOME/config/config.json"
    printf '{"test":"previous bundled template"}\n' > "$CASE_HOME/config/config.template.json"
    chmod 0644 "$CASE_HOME/config/config.template.json"
    printf '{"test":"UCI selected external config stays untouched"}\n' > "$CASE_CONFIG"
    printf '{"test":"installed private provider"}\n' > "$CASE_HOME/providers/private.json"
    printf '{"test":"installed xboard provider stays untouched"}\n' > "$CASE_HOME/providers/xboard.json"
    printf '{"interface":"br-lan","source_cidr":"10.23.40.0/23"}\n' > "$CASE_HOME/runtime/gateway.json"
    printf 'active gateway marker\n' > "$CASE_HOME/runtime/gateway-active"
    printf 'owned forwarding marker\n' > "$CASE_HOME/runtime/gateway-forward-owned"
    printf 'existing validation cache\n' > "$CASE_HOME/runtime/config.valid"
    chmod 0600 "$CASE_HOME/config/config.json" "$CASE_CONFIG" "$CASE_HOME/providers/private.json"
    cp -a "$CASE_HOME" "$CASE_DIR/before/installed"
    cp -p "$CASE_INIT" "$CASE_DIR/before/sing-box.init"
    cp -p "$CASE_CONFIG" "$CASE_DIR/before/external-config.json"
}

prepare_case success
# Broken download settings must not block this fully offline repair path.
SB_DOWNLOAD_MODE=invalid-offline-setting bash "$TEST_DIR/runner.sh" > "$CASE_DIR/output.log" 2>&1 || {
    cat "$CASE_DIR/output.log" >&2
    fail 'scripts-only deployment failed'
}
[ ! -e "$MUTATION_LOG" ] || fail 'deployment invoked network/core/service command'
for file in "$CASE_SOURCE"/scripts/*; do
    [ -f "$file" ] || continue
    deployed=$CASE_HOME/scripts/$(basename "$file")
    cmp "$file" "$deployed" || fail "script was not delivered: $(basename "$file")"
    [ "$(stat -c '%a' "$deployed")" = 755 ] || fail "wrong script mode: $(basename "$file")"
done
cmp "$CASE_SOURCE/menu.sh" "$CASE_HOME/scripts/menu.sh" || fail 'menu not delivered'
cmp "$CASE_SOURCE/uninstall.sh" "$CASE_HOME/uninstall.sh" || fail 'uninstaller not delivered'
cmp "$CASE_SOURCE/openwrt/sing-box.init" "$CASE_HOME/openwrt/sing-box.init" || fail 'init template not delivered'
cmp "$CASE_SOURCE/openwrt/sing-box.init" "$CASE_INIT" || fail 'service init not delivered'
cmp "$CASE_SOURCE/config/config.template.json" "$CASE_HOME/config/config.template.json" || fail 'bundled template not updated'
[ "$(stat -c '%a' "$CASE_HOME/config/config.template.json")" = 644 ] || fail 'template should not be executable'
for file in "$CASE_HOME/scripts/menu.sh" "$CASE_HOME/uninstall.sh" \
    "$CASE_HOME/openwrt/sing-box.init" "$CASE_INIT"; do
    [ "$(stat -c '%a' "$file")" = 755 ] || fail "wrong executable mode: $file"
done
for file in bin/sing-box config/config.json providers/private.json providers/xboard.json runtime/gateway.json \
    runtime/gateway-active runtime/gateway-forward-owned scripts/local-helper.sh; do
    cmp "$CASE_DIR/before/installed/$file" "$CASE_HOME/$file" || fail "preserved file changed: $file"
done
for name in xboard local; do
    cmp "$CASE_SOURCE/examples/$name.sample.json" "$CASE_HOME/providers/$name.sample.json" || fail 'scripts-only did not deploy public sample'
    [ "$(stat -c '%a' "$CASE_HOME/providers/$name.sample.json")" = 600 ] || fail 'sample permissions are not private'
done
[ ! -e "$CASE_HOME/providers/local.json" ] || fail 'scripts-only created a dummy runtime provider for an existing configuration'
cmp "$CASE_DIR/before/external-config.json" "$CASE_CONFIG" || fail 'UCI external config changed'
[ "$(stat -c '%a' "$CASE_CONFIG")" = 600 ] || fail 'external config permissions changed'
[ ! -f "$CASE_HOME/runtime/config.valid" ] || fail 'old validation cache not invalidated'
[ "$(cat "$CASE_HOME/runtime/source-dir")" = "$CASE_SOURCE" ] || fail 'source checkout location not recorded'
[ "$(stat -c '%a' "$CASE_HOME/runtime/source-dir")" = 600 ] || fail 'source record permissions changed'
backups=("$CASE_HOME"/runtime/scripts-backup.*)
[ "${#backups[@]}" -eq 1 ] && [ -d "${backups[0]}" ] || fail 'missing deployment backup'
backup=${backups[0]}
[ "$(stat -c '%a' "$backup")" = 700 ] || fail 'backup directory permissions are too open'
diff -r "$CASE_DIR/before/installed/scripts" "$backup/scripts" || fail 'old scripts backup differs'
cmp "$CASE_DIR/before/sing-box.init" "$backup/sing-box.init" || fail 'old init backup differs'
cmp "$CASE_DIR/before/installed/uninstall.sh" "$backup/uninstall.sh" || fail 'old uninstaller backup differs'
cmp "$CASE_DIR/before/installed/config/config.template.json" "$backup/config.template.json" || fail 'old template backup differs'

prepare_case preserved_samples
printf 'edited local sample\n' > "$CASE_HOME/providers/xboard.sample.json"
ln -s "$CASE_DIR/missing-sample-target" "$CASE_HOME/providers/local.sample.json"
bash "$TEST_DIR/runner.sh" > "$CASE_DIR/output.log" 2>&1 || fail 'scripts-only rejected existing edited samples'
[ "$(cat "$CASE_HOME/providers/xboard.sample.json")" = 'edited local sample' ] || fail 'scripts-only overwrote an edited sample'
[ -L "$CASE_HOME/providers/local.sample.json" ] && [ ! -e "$CASE_HOME/providers/local.sample.json" ] || fail 'scripts-only replaced a dangling sample link'
[ ! -e "$CASE_HOME/providers/local.json" ] || fail 'scripts-only initialized dummy runtime cache'
cmp "$CASE_DIR/before/installed/providers/xboard.json" "$CASE_HOME/providers/xboard.json" || fail 'scripts-only changed existing runtime provider'
[ ! -e "$MUTATION_LOG" ] || fail 'sample deployment invoked network/core/service command'

for scenario in missing_sample invalid_sample; do
    prepare_case "$scenario"
    if [ "$scenario" = missing_sample ]; then
        rm "$CASE_SOURCE/examples/local.sample.json"
    else
        printf '{"outbounds":[]}\n' > "$CASE_SOURCE/examples/local.sample.json"
    fi
    if bash "$TEST_DIR/runner.sh" > "$CASE_DIR/output.log" 2>&1; then fail "$scenario was deployed"; fi
    grep -Fq 'local.sample.json' "$CASE_DIR/output.log" || fail 'missing/invalid provider sample not identified'
    diff -r "$CASE_DIR/before/installed" "$CASE_HOME" || fail 'bad source sample changed installation before validation'
    cmp "$CASE_DIR/before/sing-box.init" "$CASE_INIT" || fail 'bad source sample changed init'
    cmp "$CASE_DIR/before/external-config.json" "$CASE_CONFIG" || fail 'bad source sample changed active config'
    [ ! -e "$MUTATION_LOG" ] || fail 'bad sample invoked network/core/service command'
done

prepare_case invalid_syntax
printf '\nif then\n' >> "$CASE_SOURCE/scripts/gateway.sh"
if bash "$TEST_DIR/runner.sh" > "$CASE_DIR/output.log" 2>&1; then
    fail 'invalid source syntax was deployed'
fi
grep -Fq 'Shell syntax failed' "$CASE_DIR/output.log" || fail 'syntax failure not reported'
diff -r "$CASE_DIR/before/installed" "$CASE_HOME" || fail 'installation changed before all syntax checks passed'
cmp "$CASE_DIR/before/sing-box.init" "$CASE_INIT" || fail 'init changed on syntax failure'
cmp "$CASE_DIR/before/external-config.json" "$CASE_CONFIG" || fail 'external config changed on syntax failure'
[ ! -e "$MUTATION_LOG" ] || fail 'failure path invoked network/core/service command'

prepare_case incomplete_source
rm "$CASE_SOURCE/scripts/sbctl"
if bash "$TEST_DIR/runner.sh" > "$CASE_DIR/output.log" 2>&1; then
    fail 'source missing sbctl was deployed'
fi
grep -Fq 'Incomplete source' "$CASE_DIR/output.log" || fail 'missing required source not reported'
grep -Fq 'scripts/sbctl' "$CASE_DIR/output.log" || fail 'missing sbctl not identified'
diff -r "$CASE_DIR/before/installed" "$CASE_HOME" || fail 'incomplete source modified installation'
cmp "$CASE_DIR/before/sing-box.init" "$CASE_INIT" || fail 'incomplete source modified init'
cmp "$CASE_DIR/before/external-config.json" "$CASE_CONFIG" || fail 'incomplete source modified external config'
[ ! -e "$MUTATION_LOG" ] || fail 'incomplete source invoked network/core/service command'

for missing_helper in download.sh configure-download.sh config-parts-lib.sh config-parts.sh route-manager.sh terminal-input.sh; do
    prepare_case "missing-$missing_helper"
    rm "$CASE_SOURCE/scripts/$missing_helper"
    if bash "$TEST_DIR/runner.sh" > "$CASE_DIR/output.log" 2>&1; then
        fail "source missing $missing_helper was deployed"
    fi
    grep -Fq "Incomplete source: missing scripts/$missing_helper" "$CASE_DIR/output.log" || fail 'missing required helper not identified'
    diff -r "$CASE_DIR/before/installed" "$CASE_HOME" || fail 'missing required helper modified installation'
    cmp "$CASE_DIR/before/sing-box.init" "$CASE_INIT" || fail 'missing required helper modified init'
    cmp "$CASE_DIR/before/external-config.json" "$CASE_CONFIG" || fail 'missing required helper modified external config'
    [ ! -e "$MUTATION_LOG" ] || fail 'missing required helper invoked network/core/service command'
done

# Offline repair accepts missing generated JSON when a reserved parts path
# exists. Do not validate/apply even broken sources; do not seed runtime caches.
for shape in pending broken missing_output dangling_parts; do
    prepare_case "parts-$shape"
    parts_dir=${CASE_CONFIG%.json}.d
    if [ "$shape" = dangling_parts ]; then
        ln -s "$CASE_DIR/missing-parts" "$parts_dir"
    else
        mkdir "$parts_dir"
        printf '{"source":"keep pending user edit"}\n' > "$parts_dir/inbounds.json"
        printf '{"route":{"rules":[{"ip_cidr":["10.77.90.0/24"],"action":"route","outbound":"custom-node"}]}}\n' > "$parts_dir/routing.json"
        printf 'invalid layout is repairable offline\n' > "$parts_dir/layout.json"
        cp -a "$parts_dir" "$CASE_DIR/before-parts"
    fi
    mkdir "$parts_dir.backup.previous"
    printf '{"route":{"rules":[]}}\n' > "$parts_dir.backup.previous/routing.json"
    cp -a "$parts_dir.backup.previous" "$CASE_DIR/before-parts-backup"
    if [ "$shape" = missing_output ] || [ "$shape" = dangling_parts ]; then rm "$CASE_CONFIG"; fi
    SB_DOWNLOAD_MODE=invalid bash "$TEST_DIR/runner.sh" > "$CASE_DIR/output.log" 2>&1 || {
        cat "$CASE_DIR/output.log" >&2; fail 'offline repair rejected reserved parts with missing/broken generated output'
    }
    if [ "$shape" = missing_output ] || [ "$shape" = dangling_parts ]; then
        [ ! -e "$CASE_CONFIG" ] || fail 'offline repair rendered a missing generated output'
    else
        cmp "$CASE_DIR/before/external-config.json" "$CASE_CONFIG" || fail 'offline repair changed generated output'
    fi
    if [ "$shape" = dangling_parts ]; then
        [ -L "$parts_dir" ] && [ ! -e "$parts_dir" ] || fail 'offline repair changed dangling parts link'
    else
        diff -r "$CASE_DIR/before-parts" "$parts_dir" || fail 'offline repair changed a user fragment or layout marker'
    fi
    diff -r "$CASE_DIR/before-parts-backup" "$parts_dir.backup.previous" || fail 'offline repair changed a previous user routing backup'
    cmp "$CASE_SOURCE/scripts/route-manager.sh" "$CASE_HOME/scripts/route-manager.sh" || fail 'offline repair omitted route manager'
    cmp "$CASE_SOURCE/scripts/terminal-input.sh" "$CASE_HOME/scripts/terminal-input.sh" || fail 'offline repair omitted terminal input helper'
    cmp "$CASE_DIR/before/installed/providers/xboard.json" "$CASE_HOME/providers/xboard.json" || fail 'offline repair changed existing runtime provider'
    [ ! -e "$CASE_HOME/providers/local.json" ] || fail 'offline repair initialized a dummy provider cache'
    [ ! -e "$MUTATION_LOG" ] || fail 'offline parts repair invoked network/core/service'
done

prepare_case invalid_template
printf '{invalid json\n' > "$CASE_SOURCE/config/config.template.json"
if bash "$TEST_DIR/runner.sh" > "$CASE_DIR/output.log" 2>&1; then fail 'invalid template was deployed'; fi
diff -r "$CASE_DIR/before/installed" "$CASE_HOME" || fail 'invalid template changed installation'
cmp "$CASE_DIR/before/sing-box.init" "$CASE_INIT" || fail 'invalid template changed init'
cmp "$CASE_DIR/before/external-config.json" "$CASE_CONFIG" || fail 'invalid template changed external config'
[ ! -e "$MUTATION_LOG" ] || fail 'invalid template invoked network/core/service command'
echo 'Offline scripts-only deployment and preservation tests passed.'
