#!/usr/bin/env bash
# Edit only the native user routing fragment. Fixed project policy is composed
# and validated by config-parts.sh; no operation here silently restarts service.
set -euo pipefail
umask 077
RM_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
for RM_HELPER in runtime-paths.sh config-parts-lib.sh; do
    [ -r "$RM_SCRIPT_DIR/$RM_HELPER" ] || { printf 'route-manager: missing %s; deploy the complete scripts directory.\n' "$RM_HELPER" >&2; exit 1; }
    . "$RM_SCRIPT_DIR/$RM_HELPER"
done
sb_load_paths
SB_CONFIG_PARTS_TOOL=${SB_CONFIG_PARTS_TOOL:-$RM_SCRIPT_DIR/config-parts.sh}
RM_PARTS=$(sb_parts_dir)

fail() { printf 'route-manager: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
require_parts() {
    sb_parts_active || fail '当前为完整 JSON 模式。请先在配置菜单使用「拆分配置」或运行 sbctl split-config；不会自动迁移或修改原配置。'
    [ -d "$RM_PARTS" ] || fail '分片目录不可读；请先在配置菜单修复配置路径。'
}
check_routing() {
    jq -se 'length==1 and (.[0]|type=="object" and keys==["route"])
      and (.[0].route|type=="object" and keys==["rules"])
      and (.[0].route.rules|type=="array" and all(.[];type=="object"))' "$1" >/dev/null 2>&1 ||
        fail 'routing.json 必须只包含原生 {"route":{"rules":[]}}；请在配置菜单修复 JSON 结构。'
}
check_outbounds() {
    jq -se 'length==1 and (.[0]|type=="object" and keys==["outbounds"])
      and (.[0].outbounds|type=="array")' "$1" >/dev/null 2>&1 || fail 'outbounds.json 结构不可读；请在配置菜单修复。'
}
print_rules() {
    check_routing "$1"
    jq -r '
      def show: if .==null then "不限" else tojson end;
      if (.route.rules|length)==0 then "（尚无自定义规则）" else
        .route.rules | to_entries[] | (.key+1) as $n | .value as $r |
        "\($n). 源=\($r.source_ip_cidr|show) 目标=\($r.ip_cidr|show) → \($r.outbound|show)",
        "   端口=\($r.port|show) 传输=\($r.network|show) 应用协议=\($r.protocol|show)",
        ([$r|keys[]|select(.!="source_ip_cidr" and .!="ip_cidr" and .!="outbound" and .!="port" and .!="network" and .!="protocol" and .!="action" and .!="type")]
          | if length>0 then "   保留的其他条件键：\(tojson)" else empty end)
      end' "$1" || fail '无法显示规则摘要。'
}
group_array() {
    jq -c '[.outbounds[] | select(type=="object" and (.tag|type=="string" and length>0)
      and (.type=="selector" or .type=="urltest" or .type=="loadbalance")) | {tag,type}]' "$1" || fail '无法读取出站组。'
}
print_groups() {
    check_outbounds "$1"
    group_array "$1" | jq -r 'if length==0 then "（没有带 tag 的 selector/urltest/loadbalance 出站组）"
      else to_entries[] | "\(.key+1). \(.value.tag|tojson) [\(.value.type)]" end' || fail '无法显示出站组。'
}

usage() {
    cat <<'HELP'
用法：sbctl routes COMMAND（或 bash scripts/route-manager.sh COMMAND）
  list / groups                 只读规则 / 实际出站组，不生成配置或重启
  add --group TAG [条件...]      新增规则；至少指定 source 或 destination
  edit N [条件...]               修改第 N 条，仅更新显式指定字段
  remove N                      删除第 N 条
  move FROM TO                  将规则移至最终位置 TO（编号从 1 开始）
  menu                          交互管理；保存与「校验并重启应用」分开
条件：
  --source IP[/PREFIX][,...]     源 IP 范围；IPv4 单地址自动补 /32
  --destination IP[/PREFIX][,...]  目标 IP 范围；IPv6 单地址补 /128
  --group TAG                   实际 selector/urltest/loadbalance 的 tag
  --port PORT[,PORT...]          目标端口 1..65535
  --network tcp|udp|tcp,udp      传输协议
  --protocol http,tls,...        嗅探得到的应用协议（核心作最终校验）
  --position N                  仅 add：插入位置，默认末尾
edit 可用 --clear-source / --clear-destination / --clear-port /
  --clear-network / --clear-protocol 删除对应条件；其他原生限定保持原样。
完整 JSON 模式不会自动迁移。修改通过中央校验后保存，不隐式重启。
从先前列表编写脚本时可传 SB_CONFIG_PARTS_EXPECTED=<fingerprint> 防止陈旧编号覆盖。
HELP
}

cleanup_edit() {
    local code=$?
    trap - EXIT
    if [ -n "${RM_WORK:-}" ]; then
        if [ "$code" -ne 0 ] && [ "${RM_KEEP:-0}" -eq 1 ]; then
            printf '未应用的输入/草稿保留于：%s（目录 0700，文件 0600）。\n' "$RM_WORK" >&2
        else
            rm -rf -- "$RM_WORK"
        fi
    fi
    exit "$code"
}
snapshot() {
    require_parts
    RM_EXPECTED=$(sb_parts_fingerprint) || fail '无法读取分片状态；请先修复布局或 generated 手工改动。'
    if [ "${SB_CONFIG_PARTS_EXPECTED+x}" = x ]; then
        [[ "$SB_CONFIG_PARTS_EXPECTED" =~ ^[a-f0-9]{64}$ ]] || fail '期望指纹必须是 64 位小写十六进制。'
        [ "$RM_EXPECTED" = "$SB_CONFIG_PARTS_EXPECTED" ] || fail '配置已在显示列表后改变；请重新读取规则编号。'
    fi
    RM_WORK=$(mktemp -d "$RM_PARTS.route-edit.XXXXXX") || fail '无法创建私有草稿目录。'
    chmod 700 "$RM_WORK" || fail '无法保护草稿目录权限。'
    cp -- "$RM_PARTS/routing.json" "$RM_WORK/routing-before.json" || fail '无法读取路由源文件。'
    cp -- "$RM_PARTS/outbounds.json" "$RM_WORK/outbounds.json" || fail '无法读取出站源文件。'
    chmod 600 "$RM_WORK/"*.json || fail '无法保护草稿文件权限。'
    check_routing "$RM_WORK/routing-before.json"
    check_outbounds "$RM_WORK/outbounds.json"
    RM_COUNT=$(jq '.route.rules|length' "$RM_WORK/routing-before.json") || fail '无法读取规则数。'
    printf '{}\n' > "$RM_WORK/patch.json" || fail '无法创建字段草稿。'
    printf '[]\n' > "$RM_WORK/clear.json" || fail '无法创建字段草稿。'
    RM_DRAFT=$RM_WORK/routing.json
}
remember_request() {
    jq -n --args '$ARGS.positional' -- "$@" > "$RM_WORK/request.json" || fail '无法保存私有输入草稿。'
    RM_KEEP=1
}
trim() {
    RM_VALUE=${1#"${1%%[![:space:]]*}"}
    RM_VALUE=${RM_VALUE%"${RM_VALUE##*[![:space:]]}"}
}
ipv4() {
    local address=$1 item normalized= separator= octets
    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$address" || return 1
    for item in "${octets[@]}"; do
        [ "${#item}" -le 3 ] && ((10#$item<=255)) || return 1
        normalized+="$separator$((10#$item))"; separator=.
    done
    printf '%s\n' "$normalized"
}
cidr() {
    local address=${1%/*} prefix= max=32 check group normalized count=0 compressed=0 tail head
    if [[ "$1" = */* ]]; then prefix=${1##*/}; else address=$1; fi
    if [[ "$address" = *:* ]]; then
        max=128
        [[ "$address" =~ ^[0-9a-fA-F:.]+$ ]] || fail 'IPv6 地址含无效字符。'
        check=$address
        if [[ "$check" = *.* ]]; then
            tail=${check##*:}
            normalized=$(ipv4 "$tail") || fail 'IPv6 内嵌 IPv4 无效。'
            address=${check%:*}:$normalized
            check=${check%:*}:0:0
        fi
        [[ "$check" != *:::* ]] || fail 'IPv6 压缩格式无效。'
        if [[ "$check" = *::* ]]; then
            compressed=1
            tail=${check#*::}
            head=${check%%::*}
            [[ "$tail" != *::* ]] || fail 'IPv6 只能使用一次 ::。'
            [[ "$head" != :* && "$head" != *: && "$tail" != :* && "$tail" != *: ]] || fail 'IPv6 压缩格式无效。'
            check=${check/::/:}
            check=${check#:}; check=${check%:}
        else
            [[ "$check" != :* && "$check" != *: ]] || fail 'IPv6 格式无效。'
        fi
        local groups=()
        IFS=: read -r -a groups <<< "$check" || fail 'IPv6 分组不可读。'
        for group in "${groups[@]}"; do
            [[ "$group" =~ ^[0-9a-fA-F]{1,4}$ ]] || fail 'IPv6 分组无效。'
            count=$((count+1))
        done
        if [ "$compressed" -eq 1 ]; then ((count<8)) || fail 'IPv6 分组过多。'; else ((count==8)) || fail 'IPv6 必须有 8 组或使用 ::。'; fi
        address=${address,,}
    else
        address=$(ipv4 "$address") || fail 'IPv4 必须是有效的四段十进制地址。'
    fi
    if [[ "$1" != */* ]]; then prefix=$max; fi
    [[ "$prefix" =~ ^[0-9]{1,3}$ ]] && ((10#$prefix<=max)) || fail 'IP 前缀长度无效。'
    printf '%s/%s\n' "$address" "$((10#$prefix))"
}
list_value() {
    local kind=$1 text=$2 item value result='[]' values=()
    [[ "$text" != *$'\n'* && "$text" != *$'\r'* ]] || fail '条件列表必须是单行，不能包含 CR/LF。'
    IFS=, read -r -a values <<< "$text" || fail '条件列表不可读。'
    [[ -n "$text" && "$text" != *, ]] || fail '条件列表不能为空或以逗号结尾。'
    for item in "${values[@]}"; do
        trim "$item"; item=$RM_VALUE
        [ -n "$item" ] || fail '条件列表包含空项。'
        case "$kind" in
            cidr) value=$(cidr "$item") || exit 1; result=$(jq -cn --argjson values "$result" --arg value "$value" '$values+[$value]') || fail '无法构建 IP 条件。' ;;
            port)
                [[ "$item" =~ ^[0-9]{1,5}$ ]] && ((10#$item>=1 && 10#$item<=65535)) || fail '端口必须是 1..65535 的整数。'
                result=$(jq -cn --argjson values "$result" --argjson value "$((10#$item))" '$values+[$value]') || fail '无法构建端口条件。' ;;
            network)
                [[ "$item" = tcp || "$item" = udp ]] || fail '传输协议仅支持 tcp、udp 或 tcp,udp。'
                result=$(jq -cn --argjson values "$result" --arg value "$item" '$values+[$value]') || fail '无法构建传输协议条件。' ;;
            protocol)
                [[ "$item" =~ ^[a-z][a-z0-9_-]*$ ]] || fail '应用协议名称格式无效。'
                result=$(jq -cn --argjson values "$result" --arg value "$item" '$values+[$value]') || fail '无法构建应用协议条件。' ;;
        esac
    done
    printf '%s\n' "$result"
}
index_value() {
    [[ "$1" =~ ^[0-9]{1,9}$ ]] && ((10#$1>=1 && 10#$1<=$2)) || fail "规则编号必须在 1..$2 之间。"
    printf '%s\n' "$((10#$1))"
}
parse_options() {
    local action=$1 option key kind value
    shift
    RM_POSITION=$((RM_COUNT+1))
    RM_GROUP_SET=0 RM_OPTIONS=0
    while [ "$#" -gt 0 ]; do
        option=$1; shift
        case "$option" in
            --source) key=source_ip_cidr; kind=cidr ;;
            --destination) key=ip_cidr; kind=cidr ;;
            --port) key=port; kind=port ;;
            --network) key=network; kind=network ;;
            --protocol) key=protocol; kind=protocol ;;
            --group) key=outbound; kind=group ;;
            --position) key=position; kind=position ;;
            --clear-source|--clear-destination|--clear-port|--clear-network|--clear-protocol)
                [ "$action" = edit ] || fail '--clear-* 仅适用于 edit。'
                case "$option" in --clear-source) key=source_ip_cidr ;; --clear-destination) key=ip_cidr ;; *) key=${option#--clear-} ;; esac
                jq --arg key "$key" '.+[$key]' "$RM_WORK/clear.json" > "$RM_WORK/next.json" || fail '无法构建清除字段草稿。'
                mv "$RM_WORK/next.json" "$RM_WORK/clear.json" || fail '无法保存清除字段草稿。'
                RM_OPTIONS=$((RM_OPTIONS+1)); continue ;;
            *) fail '未知选项；运行 sbctl routes help 查看用法。' ;;
        esac
        [ "$#" -gt 0 ] || fail '选项缺少参数。'
        value=$1; shift
        case "$kind" in
            position) [ "$action" = add ] || fail '--position 仅适用于 add。'; RM_POSITION=$(index_value "$value" "$((RM_COUNT+1))") || exit 1; continue ;;
            group)
                group_array "$RM_WORK/outbounds.json" | jq -e --arg tag "$value" '[.[]|select(.tag==$tag)]|length==1' >/dev/null || fail '目标必须是 outbounds.json 中唯一的带 tag 的 selector/urltest/loadbalance 出站组。'
                value=$(jq -cn --arg value "$value" '$value') || fail '无法构建目标出站组。'; RM_GROUP_SET=1 ;;
            *) value=$(list_value "$kind" "$value") || exit 1 ;;
        esac
        jq --arg key "$key" --argjson value "$value" '.[$key]=$value' "$RM_WORK/patch.json" > "$RM_WORK/next.json" || fail '无法构建字段草稿。'
        mv "$RM_WORK/next.json" "$RM_WORK/patch.json" || fail '无法保存字段草稿。'
        RM_OPTIONS=$((RM_OPTIONS+1))
    done
    [ "$action" != add ] || [ "$RM_GROUP_SET" -eq 1 ] || fail '新增规则需要 --group。'
    [ "$RM_OPTIONS" -gt 0 ] || fail '没有指定要修改的字段。'
    jq -e --slurpfile patch "$RM_WORK/patch.json" 'all(.[]; . as $key | $patch[0]|has($key)|not)' "$RM_WORK/clear.json" >/dev/null || fail '同一条件不能同时设置和清除。'
}
build_update() {
    local action=$1 number=${2:-1}
    jq --arg action "$action" --argjson number "$number" --argjson position "$RM_POSITION" \
       --slurpfile patch "$RM_WORK/patch.json" --slurpfile clear "$RM_WORK/clear.json" '
      (if $action=="add" then {action:"route"} else .route.rules[$number-1] end) as $original
      | (($original + $patch[0]) | delpaths($clear[0]|map([.]))) as $edited
      | if $action=="add" then .route.rules=(.route.rules[:($position-1)]+[$edited]+.route.rules[($position-1):])
        else .route.rules[$number-1]=$edited end
    ' "$RM_WORK/routing-before.json" > "$RM_DRAFT" || fail '无法构建路由草稿。'
    if [ "$action" = add ]; then
        jq -e --argjson position "$RM_POSITION" '.route.rules[$position-1] | [.source_ip_cidr,.ip_cidr] | any(.[];type=="array" and length>0)' "$RM_DRAFT" >/dev/null || fail '新增规则至少需要一个明确的源 IP 或目标 IP 范围。'
    fi
}
save_draft() {
    chmod 600 "$RM_DRAFT" || fail '无法保护路由草稿权限。'
    if ! SB_CONFIG_PARTS_EXPECTED="$RM_EXPECTED" sb_parts_set routing "$RM_DRAFT" > "$RM_WORK/validation.log" 2>&1; then
        cat "$RM_WORK/validation.log" >&2
        fail '校验或并发检查失败；本次没有覆盖原 sources/generated。修正草稿后可用 sbctl config-part routing FILE 提交。'
    fi
    RM_KEEP=0
    info '特色路由已保存，未重启服务。需要应用时请选择「校验并重启应用」或运行 sbctl restart。'
}
mutate() (
    local action=$1 number= destination=
    shift
    RM_WORK= RM_KEEP=0
    trap cleanup_edit EXIT
    snapshot
    remember_request "$action" "$@"
    case "$action" in
        add) parse_options add "$@"; build_update add ;;
        edit)
            [ "$#" -ge 1 ] || fail '用法：edit N [条件...]'
            number=$(index_value "$1" "$RM_COUNT") || exit 1; shift
            parse_options edit "$@"; build_update edit "$number" ;;
        remove)
            [ "$#" -eq 1 ] || fail '用法：remove N'
            number=$(index_value "$1" "$RM_COUNT") || exit 1
            jq --argjson number "$number" 'del(.route.rules[$number-1])' "$RM_WORK/routing-before.json" > "$RM_DRAFT" || fail '无法构建删除草稿。' ;;
        move)
            [ "$#" -eq 2 ] || fail '用法：move FROM TO'
            number=$(index_value "$1" "$RM_COUNT") || exit 1
            destination=$(index_value "$2" "$RM_COUNT") || exit 1
            jq --argjson from "$number" --argjson to "$destination" '.route.rules as $rules | $rules[$from-1] as $item
              | ($rules[:($from-1)]+$rules[$from:]) as $remaining
              | .route.rules=($remaining[:($to-1)]+[$item]+$remaining[($to-1):])' "$RM_WORK/routing-before.json" > "$RM_DRAFT" || fail '无法构建移动草稿。' ;;
    esac
    save_draft
)

prompt() {
    printf '%s' "$1"
    if ! IFS= read -r RM_REPLY; then info ''; info '输入结束，已取消。'; return 2; fi
}
confirm() {
    prompt "$1 [Y/n]: " || return 2
    case "$RM_REPLY" in ''|y|Y|yes|YES) return 0 ;; *) info '已取消。'; return 1 ;; esac
}
menu_edit() (
    local action=$1 number=1 destination= key flag current group_count choice answer args=() field empty_hint
    RM_WORK= RM_KEEP=0
    trap cleanup_edit EXIT
    # Take the snapshot before displaying either rule or group numbers. The
    # exact fingerprint remains attached to the whole interactive operation.
    snapshot
    if [ "$action" != add ]; then
        print_rules "$RM_WORK/routing-before.json"
        prompt '规则编号: ' || exit 2
        number=$(index_value "$RM_REPLY" "$RM_COUNT") || exit 1
    fi
    case "$action" in
        remove)
            remember_request remove "$number"
            jq --argjson number "$number" 'del(.route.rules[$number-1])' "$RM_WORK/routing-before.json" > "$RM_DRAFT" || fail '无法构建删除草稿。' ;;
        move)
            prompt "移动到最终位置 (1..$RM_COUNT): " || exit 2
            destination=$(index_value "$RM_REPLY" "$RM_COUNT") || exit 1
            remember_request move "$number" "$destination"
            jq --argjson from "$number" --argjson to "$destination" '.route.rules as $rules | $rules[$from-1] as $item
              | ($rules[:($from-1)]+$rules[$from:]) as $remaining
              | .route.rules=($remaining[:($to-1)]+[$item]+$remaining[($to-1):])' "$RM_WORK/routing-before.json" > "$RM_DRAFT" || fail '无法构建移动草稿。' ;;
        add|edit)
            if [ "$action" = edit ]; then
                info '留空保留原条件；输入 - 清除该条件。其他高级条件原样保留。'
                empty_hint='留空保留，- 清除'
            else
                info '客户端源 IP 和目标 IP 至少填写一个；未填写的条件不限。'
                empty_hint='留空不限'
            fi
            for field in source destination port network protocol; do
                case "$field" in
                    source) key=source_ip_cidr; flag="客户端源 IP/CIDR（逗号分隔，$empty_hint）" ;;
                    destination) key=ip_cidr; flag="目标 IP/CIDR（逗号分隔，$empty_hint）" ;;
                    port) key=port; flag="目标端口（逗号分隔，$empty_hint）" ;;
                    network) key=network; flag="传输协议（tcp/udp/tcp,udp，$empty_hint）" ;;
                    protocol) key=protocol; flag="应用协议（http/tls/...，$empty_hint）" ;;
                esac
                current=
                if [ "$action" = edit ]; then current=$(jq -c --argjson number "$number" --arg key "$key" '.route.rules[$number-1][$key] // null' "$RM_WORK/routing-before.json") || fail '无法读取现有条件。'; fi
                prompt "$flag${current:+ [当前 $current]}: " || exit 2
                if [ "$action" = edit ] && [ "$RM_REPLY" = - ]; then args+=("--clear-$field")
                elif [ -n "$RM_REPLY" ]; then args+=("--$field" "$RM_REPLY"); fi
            done
            print_groups "$RM_WORK/outbounds.json"
            group_count=$(group_array "$RM_WORK/outbounds.json" | jq length) || fail '无法读取出站组数量。'
            [ "$group_count" -gt 0 ] || fail '没有可选出站组；请先编辑 outbounds.json。'
            prompt '出站组编号（编辑时留空保留）: ' || exit 2
            if [ -n "$RM_REPLY" ]; then
                choice=$(index_value "$RM_REPLY" "$group_count") || exit 1
                answer=$(group_array "$RM_WORK/outbounds.json" | jq -r --argjson choice "$choice" '.[$choice-1].tag') || fail '无法读取所选出站组。'
                args+=(--group "$answer")
            elif [ "$action" = add ]; then fail '新增规则必须选择出站组。'; fi
            if [ "$action" = add ]; then
                prompt "插入位置（留空末尾 $((RM_COUNT+1))）: " || exit 2
                [ -z "$RM_REPLY" ] || args+=(--position "$RM_REPLY")
            fi
            [ "${#args[@]}" -gt 0 ] || { info '没有修改。'; exit 0; }
            remember_request "$action" "$number" "${args[@]}"
            parse_options "$action" "${args[@]}"
            build_update "$action" "$number" ;;
    esac
    info '待保存的自定义规则顺序：'
    print_rules "$RM_DRAFT"
    if confirm '确认保存（不重启）'; then :; else answer=$?; RM_KEEP=0; [ "$answer" -ne 2 ] || exit 2; exit 0; fi
    save_draft
)
apply_routes() {
    local result checker=$SH_SINGBOX_HOME/scripts/sbctl
    if confirm '校验当前所有分片并重启应用'; then :; else result=$?; [ "$result" -ne 2 ] || return 2; return 0; fi
    [ -r "$checker" ] || { info '缺少已安装的 sbctl；请完整部署脚本。'; return 1; }
    bash "$checker" preflight || { info '校验失败，未调用重启。'; return 1; }
    bash "$checker" restart
}
menu() {
    local result
    require_parts
    while :; do
        printf '\n特色路由（源文件：%s/routing.json）\n' "$RM_PARTS"
        printf '%s\n' '1. 查看规则' '2. 新增规则' '3. 编辑规则' '4. 删除规则' '5. 调整顺序' '6. 查看出站组' '7. 校验并重启应用' '0. 返回' 'q. 退出菜单'
        prompt '选择: ' || return 2
        case "$RM_REPLY" in
            0) return 0 ;;
            q|Q) return 2 ;;
            1) if (print_rules "$RM_PARTS/routing.json"); then :; fi ;;
            6) if (print_groups "$RM_PARTS/outbounds.json"); then :; fi ;;
            2|3|4|5)
                case "$RM_REPLY" in 2) RM_MENU_ACTION=add ;; 3) RM_MENU_ACTION=edit ;; 4) RM_MENU_ACTION=remove ;; 5) RM_MENU_ACTION=move ;; esac
                if menu_edit "$RM_MENU_ACTION"; then :; else result=$?; [ "$result" -ne 2 ] || return 2; fi ;;
            7) if apply_routes; then :; else result=$?; [ "$result" -ne 2 ] || return 2; fi ;;
            *) info '请选择 0..7 或 q。' ;;
        esac
    done
}

command -v jq >/dev/null 2>&1 || fail 'jq is required.'
RM_ACTION=${1:-help}
shift $(( $# > 0 ? 1 : 0 ))
case "$RM_ACTION" in
    help|--help|-h) usage ;;
    list) [ "$#" -eq 0 ] || fail '用法：list'; require_parts; print_rules "$RM_PARTS/routing.json" ;;
    groups) [ "$#" -eq 0 ] || fail '用法：groups'; require_parts; print_groups "$RM_PARTS/outbounds.json" ;;
    add|edit|remove|move) mutate "$RM_ACTION" "$@" ;;
    menu) [ "$#" -eq 0 ] || fail '用法：menu'; menu ;;
    *) usage >&2; exit 1 ;;
esac
