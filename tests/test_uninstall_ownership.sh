#!/usr/bin/env bash
# Ownership/cleanup checks use only fixture paths; no real service is stopped.
set -euo pipefail
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d /tmp/sb-uninstall.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
awk '
  /^(validate_purge_target|remove_owned_sbctl_link|quote_shell_path|remove_owned_sb_launcher|restore_managed_network)\(\) \{/ { emit = 1 }
  emit { print }
  emit && /^}$/ { emit = 0 }
' "$BASE/uninstall.sh" > "$TEST_DIR/functions.sh"
. "$TEST_DIR/functions.sh"
INSTALL_DIR=$TEST_DIR/installation
mkdir -p "$INSTALL_DIR/scripts" "$TEST_DIR/links"
cp "$BASE/scripts/sbctl" "$INSTALL_DIR/scripts/sbctl"
validate_purge_target
for unsafe in / /opt /etc /usr /overlay; do
    if (INSTALL_DIR=$unsafe; validate_purge_target) > "$TEST_DIR/purge.log" 2>&1; then
        fail "unsafe purge target $unsafe accepted"
    fi
done
ln -s / "$TEST_DIR/root-link"
if (INSTALL_DIR=$TEST_DIR/root-link; validate_purge_target) > "$TEST_DIR/purge.log" 2>&1; then
    fail 'symlink to root passed purge guard'
fi
mkdir "$TEST_DIR/foreign"
if (INSTALL_DIR=$TEST_DIR/foreign; validate_purge_target) > "$TEST_DIR/purge.log" 2>&1; then
    fail 'unrecognized directory passed purge guard'
fi

ln -s "$INSTALL_DIR/scripts/sbctl" "$TEST_DIR/links/owned"
ln -s "$BASE/install.sh" "$TEST_DIR/links/foreign"
printf '#!/bin/sh\n# other controller\n' > "$TEST_DIR/links/regular"
remove_owned_sbctl_link "$TEST_DIR/links/owned"
remove_owned_sbctl_link "$TEST_DIR/links/foreign"
remove_owned_sbctl_link "$TEST_DIR/links/regular"
[ ! -L "$TEST_DIR/links/owned" ] || fail 'owned CLI symlink retained'
[ -L "$TEST_DIR/links/foreign" ] || fail 'foreign CLI symlink removed'
[ -f "$TEST_DIR/links/regular" ] || fail 'foreign regular CLI removed'

# Recognize only complete generated launchers, with source and service paths
# treated as literal data. This includes old double-quoted launchers while
# supporting the POSIX quoting used by bootstrap for arbitrary clone paths.
(
    # Default OpenWrt builds disable BusyBox tr character classes. Model the
    # resulting literal deletion set, or use the minimal real BusyBox supplied
    # by CI, before checking cleanup against the exact generated launcher.
    tr() {
        if [ -n "${SB_TEST_BOOTSTRAP_BUSYBOX:-}" ]; then
            "$SB_TEST_BOOTSTRAP_BUSYBOX" tr "$@"
        elif [ "$#" -eq 2 ] && [ "$1" = -d ] && [ "$2" = '[:cntrl:]' ]; then
            command tr -d 'clnrt:[]'
        else
            command tr "$@"
        fi
    }
    [ "$(printf '%s' './quick-install.sh' | tr -d '[:cntrl:]')" = './quik-isa.sh' ] ||
        fail 'class-disabled tr fixture does not match OpenWrt behavior'
    source_dir=$TEST_DIR/source
    fixture_launcher=$TEST_DIR/links/sb
    side_effect=$TEST_DIR/launcher-was-executed
    for path_shape in ordinary spaces unicode punctuation; do
        case "$path_shape" in
            ordinary) path_suffix=checkout ;;
            spaces) path_suffix='clone folder with spaces' ;;
            unicode) path_suffix='中文 源码目录' ;;
            punctuation) path_suffix='quoted'\'' $(touch "$SIDE_EFFECT") `touch "$SIDE_EFFECT"` $HOME "literal" \ path' ;;
        esac
        INSTALL_DIR=$TEST_DIR/runtime/$path_suffix
        source_dir=$TEST_DIR/source/$path_suffix
        SIDE_EFFECT=$side_effect
        export SIDE_EFFECT
        for kind in source installed; do
            case "$kind" in
                source) menu_path=$source_dir/menu.sh ;;
                installed) menu_path=$INSTALL_DIR/scripts/menu.sh ;;
            esac
            for style in legacy literal; do
                # Build fixtures independently of the production quote helper.
                python3 - "$fixture_launcher" "$menu_path" "$style" <<'PY'
from pathlib import Path
import sys
launcher, path, style = sys.argv[1:]
argument = '"' + path + '"' if style == 'legacy' else "'" + path.replace("'", "'\\''") + "'"
Path(launcher).write_text('#!/bin/sh\nexec /bin/sh ' + argument + ' "$@"\n')
PY
                remove_owned_sb_launcher "$fixture_launcher" "$source_dir"
                [ ! -e "$fixture_launcher" ] || fail "$path_shape $kind $style owned launcher retained"
                [ ! -e "$side_effect" ] || fail 'launcher content or path was executed during ownership check'
            done
        done
    done

    INSTALL_DIR=$TEST_DIR/installation
    source_dir=$TEST_DIR/source
    printf '#!/bin/sh\nexec /bin/sh "%s/scripts/menu.sh" "$@"\n' "$INSTALL_DIR" > "$fixture_launcher"
    cp "$fixture_launcher" "$TEST_DIR/owned-launcher-target"
    ln -s "$TEST_DIR/owned-launcher-target" "$TEST_DIR/links/sb-symlink"
    remove_owned_sb_launcher "$TEST_DIR/links/sb-symlink" "$source_dir"
    [ -L "$TEST_DIR/links/sb-symlink" ] || fail 'symlink launcher removed'
    [ -f "$TEST_DIR/owned-launcher-target" ] || fail 'symlink launcher target changed'

    for kind in mentioned extra_command foreign_path no_shebang; do
        case "$kind" in
            mentioned)
                printf '#!/bin/sh\n# Saved old command: exec /bin/sh "%s/scripts/menu.sh" "$@"\nexec /bin/sh /another/application\n' "$INSTALL_DIR" > "$fixture_launcher" ;;
            extra_command)
                printf '#!/bin/sh\nexec /bin/sh "%s/scripts/menu.sh" "$@"\nprintf extra\\n\n' "$INSTALL_DIR" > "$fixture_launcher" ;;
            foreign_path)
                printf '#!/bin/sh\nexec /bin/sh '\''/another/application/menu.sh'\'' "$@"\n' > "$fixture_launcher" ;;
            no_shebang)
                printf 'exec /bin/sh "%s/scripts/menu.sh" "$@"\n' "$INSTALL_DIR" > "$fixture_launcher" ;;
        esac
        cp "$fixture_launcher" "$TEST_DIR/launcher-before"
        remove_owned_sb_launcher "$fixture_launcher" "$source_dir"
        cmp "$TEST_DIR/launcher-before" "$fixture_launcher" || fail "$kind unrelated launcher changed"
    done
    printf '#!/bin/sh\nexec /bin/sh "/menu.sh" "$@"\n' > "$fixture_launcher"
    remove_owned_sb_launcher "$fixture_launcher" ''
    [ -f "$fixture_launcher" ] || fail 'empty source matched an unrelated root launcher'

    # Control characters cannot appear in the line-based source record. A
    # syntactically matching launcher with such a path is not ours to delete.
    for control in $'\n' $'\r' $'\t' $'\033' $'\177'; do
        for kind in source installed; do
            INSTALL_DIR=$TEST_DIR/installation
            source_dir=$TEST_DIR/source
            case "$kind" in
                source) source_dir=$source_dir$control; menu_path=$source_dir/menu.sh ;;
                installed) INSTALL_DIR=$INSTALL_DIR$control; menu_path=$INSTALL_DIR/scripts/menu.sh ;;
            esac
            printf '#!/bin/sh\nexec /bin/sh "%s" "$@"\n' "$menu_path" > "$fixture_launcher"
            cp "$fixture_launcher" "$TEST_DIR/launcher-before"
            remove_owned_sb_launcher "$fixture_launcher" "$source_dir"
            cmp "$TEST_DIR/launcher-before" "$fixture_launcher" || fail "$kind control-character launcher changed"
        done
    done
    [ ! -e "$side_effect" ] || fail 'ownership check evaluated a path'
)

TEST_EVENTS=$TEST_DIR/events; export TEST_EVENTS
cat > "$INSTALL_DIR/scripts/gateway.sh" <<'SH'
#!/bin/sh
printf 'gateway:%s\n' "$*" >> "$TEST_EVENTS"
exit "${MOCK_GATEWAY_STATUS:-0}"
SH
cat > "$INSTALL_DIR/scripts/dns-guard.sh" <<'SH'
#!/bin/sh
printf 'dns:%s\n' "$*" >> "$TEST_EVENTS"
exit "${MOCK_DNS_STATUS:-0}"
SH
chmod 0755 "$INSTALL_DIR/scripts/gateway.sh" "$INSTALL_DIR/scripts/dns-guard.sh"
restore_managed_network
printf 'gateway:cleanup\ndns:restore\n' > "$TEST_DIR/expected"
cmp "$TEST_DIR/expected" "$TEST_EVENTS" || fail 'managed cleanup invocation differs'
for kind in gateway dns; do
    : > "$TEST_EVENTS"
    if (
        case "$kind" in
            gateway) export MOCK_GATEWAY_STATUS=7 ;;
            dns) export MOCK_DNS_STATUS=9 ;;
        esac
        restore_managed_network
        printf 'unexpected continuation\n' >> "$TEST_EVENTS"
    ) > "$TEST_DIR/cleanup-error.log" 2>&1; then
        fail "$kind cleanup error was hidden"
    fi
    cmp "$TEST_DIR/expected" "$TEST_EVENTS" || fail 'failure prevented DNS cleanup or continued uninstall'
    [ -f "$INSTALL_DIR/scripts/sbctl" ] || fail 'recovery files were lost'
    grep -Fq 'Network cleanup failed' "$TEST_DIR/cleanup-error.log" || fail 'cleanup failure message missing'
done
echo 'Uninstall ownership, purge guards and cleanup error preservation tests passed.'
