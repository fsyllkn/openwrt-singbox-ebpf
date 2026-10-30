#!/usr/bin/env bash
# Explicit section composition; never use sing-box merge (it embeds secrets).
set -euo pipefail
umask 077
CP_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
for CP_HELPER in runtime-paths.sh config-parts-lib.sh; do
    [ -r "$CP_SCRIPT_DIR/$CP_HELPER" ] || { printf 'config-parts: missing %s; deploy the complete scripts directory.\n' "$CP_HELPER" >&2; exit 1; }
    . "$CP_SCRIPT_DIR/$CP_HELPER"
done
sb_load_paths
CP_CONFIG=$SH_SINGBOX_CONFIG
CP_PARTS=$(sb_parts_dir)
CP_POLICY=$SH_SINGBOX_HOME/config/config.template.json
CP_LOCK=$CP_PARTS.lock
CP_WORK= CP_BACKUP= CP_LOCKED=0 CP_TRANSACTION=0 CP_NEW_PARTS=0
CP_CHANGED=() CP_HAD_FILE=()
CP_NAMES=(providers inbounds outbounds routing settings)

die() { printf 'config-parts: %s\n' "$*" >&2; exit 1; }
note() { printf 'config-parts: %s\n' "$*"; }
is_active() { [ -e "$CP_PARTS" ] || [ -L "$CP_PARTS" ]; }

resolved_target() {
    readlink -f -- "$1" || return 1
}

atomic_write() {
    local source=$1 destination target temp
    destination=$2
    target=$(resolved_target "$destination") || return 1
    [ -n "$target" ] && [ -d "$(dirname -- "$target")" ] && [ ! -d "$target" ] || return 1
    temp=$(mktemp "$(dirname -- "$target")/.config-parts-write.XXXXXX") || return 1
    if ! cp -- "$source" "$temp" || ! chmod 600 "$temp" || ! mv -f -- "$temp" "$target"; then
        rm -f -- "$temp"
        return 1
    fi
}

cleanup() {
    local code=$? i rollback_failed=0
    trap - EXIT HUP INT TERM
    set +e
    if [ "$CP_TRANSACTION" -eq 1 ]; then
        for ((i=${#CP_CHANGED[@]}-1; i>=0; i--)); do
            if [ "${CP_HAD_FILE[$i]}" = 1 ]; then
                atomic_write "$CP_BACKUP/restore-$i" "${CP_CHANGED[$i]}" || rollback_failed=1
            else
                rm -f -- "${CP_CHANGED[$i]}" || rollback_failed=1
            fi
        done
        if [ "$rollback_failed" -eq 0 ]; then
            if [ "$CP_NEW_PARTS" -eq 1 ]; then rm -rf -- "$CP_PARTS"; else rm -f -- "$CP_PARTS/.transaction"; fi
        else
            printf 'config-parts: rollback incomplete; preparation remains blocked. Private backup: %s\n' "$CP_BACKUP" >&2
        fi
        [ "$code" -ne 0 ] || code=1
    fi
    [ -z "$CP_WORK" ] || rm -rf -- "$CP_WORK"
    if [ "$CP_LOCKED" -eq 1 ]; then rm -f -- "$CP_LOCK/owner"; rmdir -- "$CP_LOCK" 2>/dev/null; fi
    exit "$code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

lock() {
    local attempts=0
    [ -d "$(dirname -- "$CP_PARTS")" ] || die 'Configuration parent directory does not exist.'
    while ! mkdir -m 700 -- "$CP_LOCK" 2>/dev/null; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 15 ] || die "Configuration is locked: $CP_LOCK. Check its owner before removing a stale lock."
        sleep 1
    done
    CP_LOCKED=1
    printf '%s\n' "$$" > "$CP_LOCK/owner"
}

workspace() {
    CP_WORK=$(mktemp -d "$CP_PARTS.work.XXXXXX") || die 'Cannot create a private staging directory.'
    chmod 700 "$CP_WORK"
}

hash_file() { "${CP_SHA256[@]}" -- "$1" | { read -r CP_HASH _; printf '%s\n' "$CP_HASH"; }; }

fingerprint_paths() {
    local path
    for path in "$@"; do
        printf '%s\n' "$path"
        if [ -L "$path" ]; then printf 'symlink:'; readlink -- "$path"; fi
        if [ -f "$path" ]; then
            hash_file "$path" || return 1
        elif [ -e "$path" ]; then
            printf 'not-a-file\n'
        else
            printf 'missing\n'
        fi
    done | "${CP_SHA256[@]}" | { read -r CP_HASH _; printf '%s\n' "$CP_HASH"; }
}

sources_digest() {
    local base=$1
    # Use constant labels so a staged source set has the same digest as its
    # published equivalent; symlink identity is checked by fingerprint below.
    local name
    for name in "${CP_NAMES[@]}"; do
        printf '%s\n' "$name"
        hash_file "$base/$name.json" || return 1
    done | "${CP_SHA256[@]}" | { read -r CP_HASH _; printf '%s\n' "$CP_HASH"; }
}

fingerprint() {
    local paths=("$CP_CONFIG" "$CP_POLICY" "$CP_PARTS/layout.json") name
    for name in "${CP_NAMES[@]}"; do paths+=("$CP_PARTS/$name.json"); done
    { if [ -L "$CP_PARTS" ]; then readlink -- "$CP_PARTS"; fi; fingerprint_paths "${paths[@]}"; } |
        "${CP_SHA256[@]}" | { read -r CP_HASH _; printf '%s\n' "$CP_HASH"; }
}

unchanged() {
    local now
    now=$(fingerprint) || die 'Cannot recheck configuration fingerprints.'
    [ "$now" = "$CP_BEFORE" ] || die 'Configuration or policy changed during validation; nothing was published. Retry after the concurrent edit is complete.'
}

validate_layout() {
    local name
    [ -d "$CP_PARTS" ] || die 'The reserved parts path exists but is not a readable directory; repair it or explicitly disable parts mode.'
    [ ! -e "$CP_PARTS/.transaction" ] && [ ! -L "$CP_PARTS/.transaction" ] || die 'An incomplete parts transaction exists. Restore its private backup before preparing this configuration.'
    [ -f "$CP_PARTS/layout.json" ] || die 'Parts directory has no layout.json marker; refusing to use an old generated configuration.'
    jq -e '
      type == "object" and .format == "sing-box-config-parts" and .version == 1
      and (.generation | type == "number" and . >= 1 and floor == .)
      and ([.generated_sha256,.sources_sha256,.policy_sha256] | all(.[]; type == "string" and test("^[a-f0-9]{64}$")))
    ' "$CP_PARTS/layout.json" >/dev/null 2>&1 || die 'Unsupported or malformed parts layout.json; refusing stale generated output.'
    for name in "${CP_NAMES[@]}"; do
        [ -f "$CP_PARTS/$name.json" ] || die "Missing or unreadable source: $name.json. Refusing stale generated output."
    done
}

guard_generated() {
    local expected actual
    if [ -e "$CP_CONFIG" ] || [ -L "$CP_CONFIG" ]; then
        # A dangling CONFIG symlink is a missing output and may be rebuilt.
        if [ -L "$CP_CONFIG" ] && [ ! -e "$CP_CONFIG" ]; then return 0; fi
        [ -f "$CP_CONFIG" ] || die 'Generated configuration is not a regular file.'
        expected=$(jq -r '.generated_sha256' "$CP_PARTS/layout.json")
        actual=$(hash_file "$CP_CONFIG") || die 'Cannot read generated configuration.'
        [ "$actual" = "$expected" ] || die 'Generated JSON was edited outside the parts workflow. Use import FILE to adopt compatible changes, or disable to keep it as a legacy full configuration.'
    fi
}

semantic_equal() { jq -e -n --slurpfile left "$1" --slurpfile right "$2" '$left | length == 1 and .[0] == $right[0] and ($right | length == 1)' >/dev/null 2>&1; }

validate_policy() {
    [ -f "$CP_POLICY" ] || die 'Project policy template is missing; deploy the complete project template.'
    jq -e '
      type == "object" and (.dns|type=="object") and (.route|type=="object")
      and (.route.rules|type=="array" and length>=3)
      and .route.rules[0].action=="hijack-dns"
      and .route.rules[1].action=="sniff"
      and .route.rules[2].action=="reject"
    ' "$CP_POLICY" >/dev/null 2>&1 || die 'Project DNS/route policy is invalid or its three fixed guards are unsupported.'
}

compose() {
    local directory=$1 output=$2 reason
    validate_policy
    reason=$(jq -nr --slurpfile p "$CP_POLICY" \
        --slurpfile i "$directory/inbounds.json" --slurpfile o "$directory/outbounds.json" \
        --slurpfile v "$directory/providers.json" --slurpfile r "$directory/routing.json" \
        --slurpfile s "$directory/settings.json" '
      def need($ok;$why): if $ok then . else error("CPERR: " + $why) end;
      def wrapped($x;$key): ($x|length)==1 and ($x[0]|type)=="object"
        and ($x[0]|keys)==[$key] and ($x[0][$key]|type)=="array";
      try (
        null
        | need(wrapped($i;"inbounds");"inbounds.json must contain only an inbounds array")
        | need(wrapped($o;"outbounds");"outbounds.json must contain only an outbounds array")
        | need(wrapped($v;"providers");"providers.json must contain only a providers array")
        | need(($r|length)==1 and ($r[0]|type)=="object" and ($r[0]|keys)==["route"]
            and ($r[0].route|type)=="object" and ($r[0].route|keys)==["rules"]
            and ($r[0].route.rules|type)=="array";"routing.json must contain only route.rules")
        | need(($s|length)==1 and ($s[0]|type)=="object"
            and ([$s[0]|keys[]|select(.=="providers" or .=="inbounds" or .=="outbounds" or .=="dns" or .=="route")]|length)==0;
            "settings.json cannot redefine inbounds, outbounds, providers, DNS or route")
        | "ok"
      ) catch (if startswith("CPERR: ") then . else "CPERR: invalid source structure" end)
    ' 2> "$CP_WORK/jq-error.log") || die 'Malformed JSON in configuration sources; no file was published.'
    [ "$reason" = ok ] || die "$reason"
    jq -nS --slurpfile p "$CP_POLICY" \
        --slurpfile i "$directory/inbounds.json" --slurpfile o "$directory/outbounds.json" \
        --slurpfile v "$directory/providers.json" --slurpfile r "$directory/routing.json" \
        --slurpfile s "$directory/settings.json" '
      $s[0] + {inbounds:$i[0].inbounds, outbounds:$o[0].outbounds, providers:$v[0].providers,
        dns:$p[0].dns, route:($p[0].route + {rules:($p[0].route.rules[:3] + $r[0].route.rules + $p[0].route.rules[3:])})}
    ' > "$output" 2> "$CP_WORK/jq-error.log" || die 'Cannot compose configuration sources.'
    chmod 600 "$output"
    validate_graph "$output" "$directory/routing.json"
}

validate_graph() {
    local config=$1 routing=$2 reason
    reason=$(jq -r --slurpfile custom "$routing" '
      def need($ok;$why): if $ok then . else error("CPERR: " + $why) end;
      def strings: type=="array" and all(.[];type=="string" and length>0);
      def items: type=="array" and all(.[];type=="object" and (.type|type=="string" and length>0)
        and ((has("tag")|not) or .tag==null or (.tag|type=="string")));
      def tagged($a): [range(0;$a|length) as $n | $a[$n] + {tag:(if ($a[$n].tag//"")=="" then ($n|tostring) else $a[$n].tag end)}];
      def group: .type=="selector" or .type=="urltest" or .type=="loadbalance";
      def edges($m;$t): (($m[$t].outbounds//[]) + (if ($m[$t].detour//"")=="" then [] else [$m[$t].detour] end));
      def acyclic($m;$t;$stack):
        if ($stack|index($t))!=null then error("CPERR: outbound dependency cycle")
        else all(edges($m;$t)[]; acyclic($m;.;$stack+[$t])) end;
      def safe_choices($m;$t):
        if $t=="Compatible" or $m[$t].type=="direct" or $m[$t].type=="pass" then false
        elif ($m[$t]|group) then (($m[$t].outbounds//[]|length)>0 and all($m[$t].outbounds[];safe_choices($m;.)))
        else true end;
      def scoped_value: if type=="string" then length>0 elif type=="array" then length>0 and all(.[];type=="string" and length>0) else false end;
      try (
        . as $c
        | need((.inbounds|items) and (.outbounds|items) and (.providers|items) and ((.endpoints//[])|items);"inbounds/outbounds/providers/endpoints must be arrays of typed objects")
        | tagged(.inbounds) as $ib | tagged(.outbounds) as $ob | tagged(.endpoints//[]) as $ep | tagged(.providers) as $pv
        | ($ob+$ep) as $nodes | ($nodes|map(.tag)) as $tags | ($pv|map(.tag)) as $providers
        | need(($ib|map(.tag)|length)==($ib|map(.tag)|unique|length);"duplicate inbound tag")
        | need(($tags|length)==($tags|unique|length);"duplicate outbound/endpoint tag")
        | need(($providers|length)==($providers|unique|length);"duplicate Provider tag")
        | need(($tags|index("Compatible"))==null;"Compatible is a reserved core fallback tag")
        | (reduce $nodes[] as $n ({}; .[$n.tag]=$n)) as $m
        | need($m.direct.type=="direct";"the direct role must remain a direct outbound")
        | need(all(["proxy","ai"][]; . as $tag | $m[$tag].type=="selector"
            and ($m[$tag].outbounds|strings) and ($m[$tag].outbounds|length)>0
            and ($m[$tag].default|type)=="string" and ($m[$tag].default|length)>0
            and ($m[$tag].outbounds|index($m[$tag].default))!=null);
            "proxy and ai require nonempty static selectors with a static default")
        | need(all($nodes[]|select(group); (.outbounds//[]|strings) and (.providers//[]|strings)
            and all((.outbounds//[])[]; . as $t | ($tags|index($t))!=null)
            and all((.providers//[])[]; . as $t | ($providers|index($t))!=null));
            "invalid group members or missing outbound/Provider references")
        | need(all($nodes[]|select(group); . as $g | ($g.default//"")=="" or ($g.outbounds//[]|index($g.default))!=null);
            "group default must name one of its static outbounds")
        | need(all($nodes[]; . as $n | ($n.detour//"")=="" or (($n.detour|type)=="string" and ($tags|index($n.detour))!=null));
            "missing outbound detour reference")
        | need(all($tags[];acyclic($m;.;[]));"outbound dependency cycle")
        | need(safe_choices($m;"proxy") and safe_choices($m;"ai");"proxy/ai choices must not reach direct, pass, Compatible or an empty static group")
        | need(all($ib[]; . as $n | ($n.detour//"")=="" or ($ib|map(.tag)|index($n.detour))!=null);"missing inbound detour reference")
        | need(($tags|index($c.route.final))!=null;"route.final references a missing outbound")
        | need(all($c.route.rules[]|..|objects|select(has("outbound")); .outbound as $t | ($t|type)=="string" and ($tags|index($t))!=null);
            "route rule references a missing static outbound")
        | need(all(($c.dns.servers//[])[]|select(has("detour")); .detour as $t | $t=="" or ($tags|index($t))!=null);"DNS policy references a missing outbound")
        | need(all(($c.http_clients//[])[]|select(has("detour")); .detour as $t | $t=="" or ($tags|index($t))!=null);"HTTP client references a missing outbound")
        | need(all($pv[]; . as $v | (($v.download_detour//"")=="" or ($tags|index($v.download_detour))!=null)
            and ((($v.http_client//{}|type)!="object") or (($v.http_client.detour//"")=="" or ($tags|index($v.http_client.detour))!=null)));
            "Provider download references a missing outbound")
        | need(all($custom[0].route.rules[]; . as $r | type=="object" and ((.type//"default")=="default")
            and ((.action//"route")=="route") and (.outbound|type)=="string" and ($tags|index($r.outbound))!=null
            and ([.ip_cidr,.source_ip_cidr,.process_name,.process_path]|any(.[];scoped_value)));
            "custom routing requires a scoped IP/CIDR or process condition and a native route action to a known static outbound")
        | "ok"
      ) catch (if startswith("CPERR: ") then . else "CPERR: invalid configuration graph or field type" end)
    ' "$config" 2> "$CP_WORK/jq-error.log") || die 'Cannot validate the configuration graph.'
    [ "$reason" = ok ] || die "$reason"
}

partition() {
    local input=$1 directory=$2 count
    validate_policy
    [ -f "$input" ] || die 'Full input configuration does not exist.'
    jq -e --slurpfile p "$CP_POLICY" '
      . as $c | $p[0] as $p | (($c.route.rules|length)-($p.route.rules|length)) as $extra
      | type=="object" and (.inbounds|type)=="array" and (.outbounds|type)=="array" and (.providers|type)=="array"
      and .dns==$p.dns and (.route|del(.rules))==($p.route|del(.rules))
      and (.route.rules|type)=="array" and $extra>=0
      and .route.rules[:3]==$p.route.rules[:3] and .route.rules[(3+$extra):]==$p.route.rules[3:]
    ' "$input" >/dev/null 2>&1 || die 'Full configuration cannot be split losslessly: DNS, route policy or rule order differs. Keep legacy mode; no configuration was replaced.'
    mkdir -m 700 -p -- "$directory"
    for CP_NAME in providers inbounds outbounds; do
        jq -S --arg key "$CP_NAME" '{($key): .[$key]}' "$input" > "$directory/$CP_NAME.json"
    done
    count=$(jq --slurpfile p "$CP_POLICY" '(.route.rules|length)-($p[0].route.rules|length)' "$input")
    jq -S --argjson count "$count" '{route:{rules:.route.rules[3:(3+$count)]}}' "$input" > "$directory/routing.json"
    jq -S 'del(.providers,.inbounds,.outbounds,.dns,.route)' "$input" > "$directory/settings.json"
    compose "$directory" "$CP_WORK/partition-check.json"
    semantic_equal "$input" "$CP_WORK/partition-check.json" || die 'Splitting would change the full configuration; legacy input is untouched.'
}

copy_sources() {
    local destination=$1 name
    mkdir -m 700 -- "$destination"
    for name in "${CP_NAMES[@]}"; do cp -- "$CP_PARTS/$name.json" "$destination/$name.json"; chmod 600 "$destination/$name.json"; done
}

preflight() {
    local candidate=$1 checker=$SH_SINGBOX_HOME/scripts/sbctl
    [ -r "$checker" ] || die 'Installed sbctl is required to validate staged configurations; deploy the complete scripts directory.'
    # CP_WORK/candidate.json has no companion candidate.d. The ordinary sbctl
    # path therefore checks this file without recursively composing parts.
    if ! SH_SINGBOX_CONFIG="$candidate" bash "$checker" preflight > "$CP_WORK/preflight.log" 2>&1; then
        if [ -d "$SH_SINGBOX_HOME/runtime" ]; then
            cp -- "$CP_WORK/preflight.log" "$SH_SINGBOX_HOME/runtime/config-parts-last-error.log" 2>/dev/null || :
            chmod 600 "$SH_SINGBOX_HOME/runtime/config-parts-last-error.log" 2>/dev/null || :
        fi
        die 'Staged configuration failed core/device preflight; generated JSON and sources were not replaced. Diagnostics, when available, are in runtime/config-parts-last-error.log (private).'
    fi
}

write_layout() {
    local directory=$1 candidate=$2 generation=$3
    jq -nS --arg generated "$(hash_file "$candidate")" --arg sources "$(sources_digest "$directory")" \
        --arg policy "$(hash_file "$CP_POLICY")" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson generation "$generation" \
        '{format:"sing-box-config-parts",version:1,generation:$generation,generated_sha256:$generated,sources_sha256:$sources,policy_sha256:$policy,updated_at:$time}' \
        > "$directory/layout.json"
}

backup() {
    local name
    CP_BACKUP=$(mktemp -d "$CP_PARTS.backup.XXXXXX") || die 'Cannot create a private transaction backup.'
    chmod 700 "$CP_BACKUP"
    if [ -f "$CP_CONFIG" ]; then cp -- "$CP_CONFIG" "$CP_BACKUP/config.json"; chmod 600 "$CP_BACKUP/config.json"; fi
    if is_active; then
        for name in layout "${CP_NAMES[@]}"; do
            if [ -f "$CP_PARTS/$name.json" ]; then cp -- "$CP_PARTS/$name.json" "$CP_BACKUP/$name.json"; chmod 600 "$CP_BACKUP/$name.json"; fi
        done
    fi
}

transaction_write() {
    local source=$1 destination=$2 target index=${#CP_CHANGED[@]}
    target=$(resolved_target "$destination") || die 'Cannot resolve a configuration write target.'
    if [ -f "$target" ]; then
        cp -- "$target" "$CP_BACKUP/restore-$index" || die 'Cannot back up a configuration write target.'
        chmod 600 "$CP_BACKUP/restore-$index"
        CP_HAD_FILE+=(1)
    else
        CP_HAD_FILE+=(0)
    fi
    CP_CHANGED+=("$target")
    atomic_write "$source" "$target" || die 'Cannot publish configuration; restoring the previous transaction.'
}

publish() {
    local sources=$1 candidate=$2 initializing=$3 generation=1 name changed=1
    shift 3
    local sections=("$@")
    if [ -f "$CP_CONFIG" ] && semantic_equal "$candidate" "$CP_CONFIG"; then changed=0; fi
    # Import is an explicit adoption of a full JSON and can intentionally
    # accept an edited generated file. It must validate even when that file
    # already has exactly the candidate's contents.
    if [ "$initializing" -eq 1 ] || [ "$changed" -eq 1 ] || [ "$CP_ACTION" = import ]; then preflight "$candidate"; fi
    unchanged
    if [ "$initializing" -eq 0 ]; then generation=$(( $(jq -r '.generation' "$CP_PARTS/layout.json") + 1 )); fi
    # Preserve exact generated bytes for semantic no-op renders. This lets UID
    # and listener repair helpers enter the workflow without preflighting the
    # very state they are about to repair.
    if [ "$changed" -eq 0 ]; then cp -- "$CP_CONFIG" "$candidate"; fi
    write_layout "$sources" "$candidate" "$generation"
    if [ "$initializing" -eq 0 ] && [ "${#sections[@]}" -eq 0 ] && [ "$changed" -eq 0 ] &&
       [ "$(jq -r '.sources_sha256' "$CP_PARTS/layout.json")" = "$(sources_digest "$sources")" ] &&
       [ "$(jq -r '.policy_sha256' "$CP_PARTS/layout.json")" = "$(hash_file "$CP_POLICY")" ]; then
        return 0
    fi
    unchanged
    backup
    CP_TRANSACTION=1
    if [ "$initializing" -eq 1 ]; then
        printf '%s\n' "$CP_BACKUP" > "$sources/.transaction"
        mv -- "$sources" "$CP_PARTS" || die 'Cannot install the new parts directory.'
        CP_NEW_PARTS=1
    else
        printf '%s\n' "$CP_BACKUP" > "$CP_PARTS/.transaction"
        for name in "${sections[@]}"; do transaction_write "$sources/$name.json" "$CP_PARTS/$name.json"; done
    fi
    if [ "$changed" -eq 1 ] || [ ! -f "$CP_CONFIG" ]; then transaction_write "$candidate" "$CP_CONFIG"; fi
    if [ "$initializing" -eq 0 ]; then transaction_write "$sources/layout.json" "$CP_PARTS/layout.json"; fi
    rm -f -- "$CP_PARTS/.transaction"
    CP_TRANSACTION=0
    note "Configuration sources and generated JSON are consistent. Private backup: $CP_BACKUP"
}

status() {
    printf 'Configuration: %s\nParts directory: %s\nProject policy: %s\n' "$CP_CONFIG" "$CP_PARTS" "$CP_POLICY"
    if ! is_active; then printf 'Mode: legacy (one editable full JSON)\n'; return 0; fi
    validate_layout
    printf 'Mode: parts (edit source fragments; generated JSON is read-only)\n'
    if [ ! -f "$CP_CONFIG" ]; then
        printf 'State: generated output missing; prepare must rebuild it\n'
    elif [ "$(hash_file "$CP_CONFIG")" != "$(jq -r '.generated_sha256' "$CP_PARTS/layout.json")" ]; then
        printf 'State: manual-output-edit; import or disable is required\n'
        return 1
    elif [ ! -f "$CP_POLICY" ] ||
         [ "$(sources_digest "$CP_PARTS")" != "$(jq -r '.sources_sha256' "$CP_PARTS/layout.json")" ] ||
         [ "$(hash_file "$CP_POLICY")" != "$(jq -r '.policy_sha256' "$CP_PARTS/layout.json")" ]; then
        printf 'State: pending source/policy changes; prepare validates before publishing\n'
    else
        printf 'State: current\n'
    fi
    printf 'Sources: inbounds.json, outbounds.json, providers.json, routing.json, settings.json\n'
}

for CP_COMMAND in jq readlink mktemp; do command -v "$CP_COMMAND" >/dev/null 2>&1 || die "$CP_COMMAND is required."; done
if command -v sha256sum >/dev/null 2>&1; then
    CP_SHA256=(sha256sum)
elif command -v busybox >/dev/null 2>&1 && busybox sha256sum </dev/null >/dev/null 2>&1; then
    CP_SHA256=(busybox sha256sum)
else
    die 'SHA-256 support is required (sha256sum or the BusyBox sha256sum applet).'
fi
CP_ACTION=${1:-status}
shift $(( $# > 0 ? 1 : 0 ))
case "$CP_ACTION" in
    status) [ "$#" -eq 0 ] || die 'Usage: config-parts.sh status'; status; exit 0 ;;
    render) [ "$#" -eq 0 ] || die 'Usage: config-parts.sh render'; is_active || exit 0 ;;
    init) [ "$#" -le 1 ] || die 'Usage: config-parts.sh init [FULL_JSON]'; is_active && die 'Parts already exist; use set/import, or explicitly disable them first.' ;;
    build) [ "$#" -eq 1 ] || die 'Usage: config-parts.sh build OUTPUT' ;;
    fingerprint|disable) [ "$#" -eq 0 ] || die "Usage: config-parts.sh $CP_ACTION" ;;
    commit) [ "$#" -ge 2 ] || die 'Usage: config-parts.sh commit FULL_JSON SECTION...' ;;
    set) [ "$#" -eq 2 ] || die 'Usage: config-parts.sh set SECTION FRAGMENT_JSON' ;;
    import) [ "$#" -eq 1 ] || die 'Usage: config-parts.sh import FULL_JSON' ;;
    *) die 'Usage: config-parts.sh status|init|render|build|commit|set|import|disable|fingerprint' ;;
esac
lock
if [ "$CP_ACTION" = render ] && ! is_active; then exit 0; fi
if [ "$CP_ACTION" = disable ] && ! is_active; then note 'Already using a legacy full configuration.'; exit 0; fi
if [ "$CP_ACTION" != init ] && [ "$CP_ACTION" != disable ]; then
    is_active || die 'This operation requires an active parts directory.'
    validate_layout
    [ "$CP_ACTION" = import ] || guard_generated
fi
if [ "$CP_ACTION" = fingerprint ]; then fingerprint; exit 0; fi
workspace
CP_BEFORE=$(fingerprint) || die 'Cannot fingerprint configuration sources.'
case "$CP_ACTION" in
    commit|set|import)
        if [ "${SB_CONFIG_PARTS_EXPECTED+x}" = x ]; then
            [[ "$SB_CONFIG_PARTS_EXPECTED" =~ ^[a-f0-9]{64}$ ]] || die 'Expected configuration fingerprint must contain exactly 64 lowercase hexadecimal characters.'
            [ "$SB_CONFIG_PARTS_EXPECTED" = "$CP_BEFORE" ] || die 'Configuration or policy changed since editing began; no configuration was published. Read the current sources and retry.'
        fi
        ;;
esac
CP_STAGED=$CP_WORK/sources
CP_CANDIDATE=$CP_WORK/candidate.json

case "$CP_ACTION" in
    init)
        is_active && die 'Parts were created concurrently; nothing was replaced.'
        partition "${1:-$CP_CONFIG}" "$CP_STAGED"
        compose "$CP_STAGED" "$CP_CANDIDATE"
        publish "$CP_STAGED" "$CP_CANDIDATE" 1
        ;;
    render|build)
        copy_sources "$CP_STAGED"
        compose "$CP_STAGED" "$CP_CANDIDATE"
        if [ "$CP_ACTION" = render ]; then
            publish "$CP_STAGED" "$CP_CANDIDATE" 0
        else
            CP_OUTPUT=$(resolved_target "$1") || die 'Cannot resolve build output.'
            CP_RUNTIME_TARGET=$(resolved_target "$CP_CONFIG") || die 'Cannot resolve generated configuration target.'
            CP_POLICY_TARGET=$(resolved_target "$CP_POLICY") || die 'Cannot resolve project policy.'
            CP_PARTS_TARGET=$(resolved_target "$CP_PARTS") || die 'Cannot resolve parts directory.'
            [ "$CP_OUTPUT" != "$CP_RUNTIME_TARGET" ] && [ "$CP_OUTPUT" != "$CP_POLICY_TARGET" ] || die 'build cannot overwrite generated JSON or policy; use render.'
            case "$CP_OUTPUT" in "$CP_PARTS_TARGET"/*) die 'build output must be outside the source parts directory.' ;; esac
            for CP_NAME in layout "${CP_NAMES[@]}"; do
                CP_SOURCE_TARGET=$(resolved_target "$CP_PARTS/$CP_NAME.json") || die 'Cannot resolve a source file target.'
                [ "$CP_OUTPUT" != "$CP_SOURCE_TARGET" ] || die 'build cannot overwrite a source or layout file, including a symlink target.'
            done
            unchanged
            atomic_write "$CP_CANDIDATE" "$CP_OUTPUT" || die 'Cannot write staged build output.'
        fi
        ;;
    commit)
        CP_INPUT=$1; shift
        CP_SECTIONS=("$@")
        for CP_NAME in "${CP_SECTIONS[@]}"; do
            case "$CP_NAME" in providers|inbounds|outbounds|routing|settings) ;; *) die 'Unknown source section.' ;; esac
        done
        partition "$CP_INPUT" "$CP_WORK/candidate-parts"
        copy_sources "$CP_STAGED"
        for CP_NAME in "${CP_SECTIONS[@]}"; do cp -- "$CP_WORK/candidate-parts/$CP_NAME.json" "$CP_STAGED/$CP_NAME.json"; done
        compose "$CP_STAGED" "$CP_CANDIDATE"
        semantic_equal "$CP_INPUT" "$CP_CANDIDATE" || die 'Candidate changes unnamed sections or pending sources; no configuration was published.'
        publish "$CP_STAGED" "$CP_CANDIDATE" 0 "${CP_SECTIONS[@]}"
        ;;
    set)
        CP_NAME=$1
        case "$CP_NAME" in providers|inbounds|outbounds|routing|settings) ;; *) die 'Unknown source section.' ;; esac
        [ -f "$2" ] || die 'Fragment input does not exist.'
        copy_sources "$CP_STAGED"
        cp -- "$2" "$CP_STAGED/$CP_NAME.json"
        compose "$CP_STAGED" "$CP_CANDIDATE"
        publish "$CP_STAGED" "$CP_CANDIDATE" 0 "$CP_NAME"
        ;;
    import)
        partition "$1" "$CP_STAGED"
        compose "$CP_STAGED" "$CP_CANDIDATE"
        publish "$CP_STAGED" "$CP_CANDIDATE" 0 "${CP_NAMES[@]}"
        ;;
    disable)
        [ -f "$CP_CONFIG" ] || die 'A complete runtime JSON is required before disabling parts mode.'
        cp -- "$CP_CONFIG" "$CP_CANDIDATE"
        preflight "$CP_CANDIDATE"
        unchanged
        CP_DISABLED=$(mktemp -d "$CP_PARTS.disabled.XXXXXX") || die 'Cannot reserve a private disabled-directory backup.'
        rmdir -- "$CP_DISABLED"
        mv -- "$CP_PARTS" "$CP_DISABLED" || die 'Cannot move the parts directory out of the reserved location.'
        note "Legacy full-JSON mode enabled. Source directory retained at: $CP_DISABLED"
        ;;
esac
