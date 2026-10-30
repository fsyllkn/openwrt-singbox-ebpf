#!/bin/sh
# Shared runtime selectors for OpenWrt init, sbctl and configuration helpers.
# Source this file, then call sb_load_paths. Resolving paths does not read a
# sing-box JSON file, create directories, or require an installed service.

sb_load_paths() {
    sb_paths_home=${SH_SINGBOX_HOME:-}
    sb_paths_config=${SH_SINGBOX_CONFIG:-}

    # An explicit home is a complete installation override. Do not combine it
    # with another installation's UCI config_file unless CONFIG is explicit too.
    if [ -z "$sb_paths_home" ] && command -v uci >/dev/null 2>&1; then
        sb_paths_home=$(uci -q get sing-box.main.service_dir 2>/dev/null) || sb_paths_home=
        if [ -z "$sb_paths_config" ]; then
            sb_paths_config=$(uci -q get sing-box.main.config_file 2>/dev/null) || sb_paths_config=
        fi
    fi
    sb_paths_home=${sb_paths_home:-/opt/sing-box}
    sb_paths_config=${sb_paths_config:-$sb_paths_home/config/config.json}

    case "$sb_paths_home" in
        /*) ;;
        *) printf '%s\n' 'sing-box: service directory must be an absolute path (SH_SINGBOX_HOME / sing-box.main.service_dir).' >&2
           unset sb_paths_home sb_paths_config
           return 1 ;;
    esac
    case "$sb_paths_config" in
        /*) ;;
        *) printf '%s\n' 'sing-box: configuration file must be an absolute path (SH_SINGBOX_CONFIG / sing-box.main.config_file).' >&2
           unset sb_paths_home sb_paths_config
           return 1 ;;
    esac

    SH_SINGBOX_HOME=$sb_paths_home
    SH_SINGBOX_CONFIG=$sb_paths_config
    export SH_SINGBOX_HOME SH_SINGBOX_CONFIG
    unset sb_paths_home sb_paths_config
}
