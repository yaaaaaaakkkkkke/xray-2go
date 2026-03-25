#!/bin/bash

# ============================================================
# 精简版 Xray-2go 一键脚本
# 协议：
#   Argo（可选）：VLESS+WS+TLS（Cloudflare Argo 隧道）
#   Reality（可选）：VLESS+TCP+TLS（VLESS Reality）
#   免流（可选）：VLESS+WS 明文（port 80）| VLESS+HTTPUpgrade（port 80）
#   Shadowsocks（可选）：SS+TCP/UDP
# ============================================================

# ── 颜色输出 ─────────────────────────────────────────────────
red()    { printf '\033[1;91m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
purple() { printf '\033[1;35m%s\033[0m\n' "$*"; }
skyblue(){ printf '\033[1;36m%s\033[0m\n' "$*"; }
gray()   { printf '\033[0;90m%s\033[0m\n' "$*"; }
reading(){ printf '\033[1;91m%s\033[0m' "$1"; read -r "$2"; }

# ── 常量 ─────────────────────────────────────────────────────
server_name="xray"
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
freeflow_conf="${work_dir}/freeflow.conf"
argo_mode_conf="${work_dir}/argo_mode.conf"
reality_mode_conf="${work_dir}/reality_mode.conf"
reality_conf="${work_dir}/reality.conf"
reality_keys_conf="${work_dir}/reality_keys.conf"
ss_conf="${work_dir}/ss.conf"
shortcut_path="/usr/local/bin/s"
shortcut_path_upper="/usr/local/bin/S"

# ── 环境变量（可外部注入） ────────────────────────────────────
export UUID=${UUID:-$(gen_uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)}
export ARGO_PORT=${ARGO_PORT:-'8080'}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1

# ============================================================
# 基础工具函数
# ============================================================

# gen_uuid - 生成随机 UUID
gen_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# is_alpine - 判断是否为 Alpine 系统
is_alpine() {
    [ -f /etc/alpine-release ]
}

# valid_port <port> - 校验端口合法性，合法返回 0
valid_port() {
    local p="$1"
    echo "${p}" | grep -qE '^[0-9]+$' || return 1
    [ "${p}" -ge 1 ] && [ "${p}" -le 65535 ]
}

# load_conf <file> <line_number> - 读取配置文件指定行
load_conf() {
    sed -n "${2}p" "$1" 2>/dev/null
}

# service_cmd <action> <service> - 统一 service 操作
# action: start | stop | restart | status | enable | disable
service_cmd() {
    local action="$1" svc="$2"
    if is_alpine; then
        case "${action}" in
            enable)  rc-update add "${svc}" default ;;
            disable) rc-update del "${svc}" default ;;
            *)       rc-service "${svc}" "${action}" ;;
        esac
    else
        case "${action}" in
            enable|disable) systemctl "${action}" "${svc}" ;;
            *)               systemctl "${action}" "${svc}" ;;
        esac
    fi
}

# service_is_active <service> - 检查服务是否运行中，是返回 0
service_is_active() {
    local svc="$1"
    if is_alpine; then
        rc-service "${svc}" status 2>/dev/null | grep -q "started"
    else
        [ "$(systemctl is-active "${svc}" 2>/dev/null)" = "active" ]
    fi
}

# ── 读取持久化配置 ────────────────────────────────────────────

_load_argo_mode() {
    local v
    v=$(cat "${argo_mode_conf}" 2>/dev/null)
    case "${v}" in yes|no) echo "${v}" ;; *) echo "yes" ;; esac
}

_load_reality_mode() {
    local v
    v=$(cat "${reality_mode_conf}" 2>/dev/null)
    case "${v}" in yes|no) echo "${v}" ;; *) echo "no" ;; esac
}

_load_freeflow_conf() {
    local mode path
    mode=$(load_conf "${freeflow_conf}" 1)
    path=$(load_conf "${freeflow_conf}" 2)
    case "${mode}" in ws|httpupgrade) ;; *) mode="none" ;; esac
    [ -z "${path}" ] && path="/"
    echo "${mode}"
    echo "${path}"
}

_load_reality_conf() {
    local sni port
    sni=$(load_conf "${reality_conf}" 1)
    port=$(load_conf "${reality_conf}" 2)
    [ -z "${sni}" ] && sni="www.cloudflare.com"
    valid_port "${port}" || port="443"
    echo "${sni}"
    echo "${port}"
}

_load_ss_conf() {
    local mode port password method
    mode=$(load_conf "${ss_conf}" 1)
    port=$(load_conf "${ss_conf}" 2)
    password=$(load_conf "${ss_conf}" 3)
    method=$(load_conf "${ss_conf}" 4)
    case "${mode}" in yes|no) ;; *) mode="no" ;; esac
    valid_port "${port}" || port="8388"
    [ -z "${password}" ] && password=""
    [ -z "${method}" ] && method="aes-256-gcm"
    echo "${mode}"; echo "${port}"; echo "${password}"; echo "${method}"
}

# ── 初始化全局状态变量 ────────────────────────────────────────
ARGO_MODE=$(_load_argo_mode)

# 若已安装，从 config.json 同步实际 ARGO_PORT
if [ "${ARGO_MODE}" = "yes" ] && [ -f "${config_dir}" ]; then
    _port=$(jq -r '.inbounds[0].port' "${config_dir}" 2>/dev/null)
    valid_port "${_port}" && export ARGO_PORT="${_port}"
    unset _port
fi

REALITY_MODE=$(_load_reality_mode)

{ read -r REALITY_SNI; read -r REALITY_PORT; } <<EOF
$(_load_reality_conf)
EOF

{ read -r _ff_mode; read -r FF_PATH; } <<EOF
$(_load_freeflow_conf)
EOF
FREEFLOW_MODE="${_ff_mode}"; unset _ff_mode

{ read -r SS_MODE; read -r SS_PORT; read -r SS_PASSWORD; read -r SS_METHOD; } <<EOF
$(_load_ss_conf)
EOF

# ============================================================
# check_xray / check_argo
# 输出状态文字到 stdout，返回值：0=运行中 1=未运行 2=未安装 3=禁用
# ============================================================
check_xray() {
    [ ! -f "${work_dir}/${server_name}" ] && echo "not installed" && return 2
    if service_is_active xray; then
        echo "running"; return 0
    else
        echo "not running"; return 1
    fi
}

check_argo() {
    if [ "${ARGO_MODE}" = "no" ]; then
        echo "disabled"; return 3
    fi
    [ ! -f "${work_dir}/argo" ] && echo "not installed" && return 2
    if service_is_active tunnel; then
        echo "running"; return 0
    else
        echo "not running"; return 1
    fi
}

# ── 状态显示颜色封装 ──────────────────────────────────────────
_status_color() {
    local s="$1"
    case "${s}" in
        running)       green  "● ${s}" ;;
        "not running") red    "● ${s}" ;;
        "not installed") yellow "○ ${s}" ;;
        disabled|未启用) gray   "- ${s}" ;;
        *)             gray   "  ${s}" ;;
    esac
}

# ============================================================
# manage_packages
# 通用包安装，支持 apt / dnf / yum / apk
# ============================================================
manage_packages() {
    [ "$#" -lt 2 ] && red "未指定包名或操作" && return 1
    local action="$1"; shift
    [ "${action}" != "install" ] && red "未知操作: ${action}" && return 1

    # 提前探测包管理器，避免循环内重复检测
    local pm=""
    if   command -v apt > /dev/null 2>&1; then pm="apt"
    elif command -v dnf > /dev/null 2>&1; then pm="dnf"
    elif command -v yum > /dev/null 2>&1; then pm="yum"
    elif command -v apk > /dev/null 2>&1; then pm="apk"
    else red "未知包管理器，无法安装依赖"; return 1; fi

    for package in "$@"; do
        if command -v "${package}" > /dev/null 2>&1; then
            green "${package} 已安装，跳过"; continue
        fi
        yellow "正在安装 ${package}..."
        case "${pm}" in
            apt) DEBIAN_FRONTEND=noninteractive apt install -y "${package}" ;;
            dnf) dnf install -y "${package}" ;;
            yum) yum install -y "${package}" ;;
            apk) apk update && apk add "${package}" ;;
        esac
        if ! command -v "${package}" > /dev/null 2>&1; then
            red "${package} 安装失败，请手动检查"; return 1
        fi
    done
}

# ============================================================
# get_realip
# 优先 IPv4；若归属 CF/特定 CDN 则切换 IPv6
# ============================================================
get_realip() {
    local ip ipv6 org
    # 并行获取 IPv4 和组织信息
    ip=$(curl -s --max-time 3 ipv4.ip.sb & )
    ip=$(curl -s --max-time 3 ipv4.ip.sb)

    if [ -z "${ip}" ]; then
        ipv6=$(curl -s --max-time 3 ipv6.ip.sb)
        [ -n "${ipv6}" ] && echo "[${ipv6}]" || echo ""
        return
    fi

    org=$(curl -s --max-time 3 http://ipinfo.io/org 2>/dev/null)
    if echo "${org}" | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        ipv6=$(curl -s --max-time 3 ipv6.ip.sb)
        [ -n "${ipv6}" ] && echo "[${ipv6}]" || echo "${ip}"
    else
        echo "${ip}"
    fi
}

# ============================================================
# get_current_uuid
# 从 config.json 读取第一个 VLESS inbound UUID，回退到全局 UUID
# ============================================================
get_current_uuid() {
    local id
    id=$(jq -r '(first(.inbounds[] | select(.protocol=="vless") | .settings.clients[0].id) // empty)' \
        "${config_dir}" 2>/dev/null)
    echo "${id:-${UUID}}"
}

# ============================================================
# install_shortcut
# ============================================================
install_shortcut() {
    local script_wrapper="${work_dir}/s.sh"
    cat > "${script_wrapper}" << 'EOF'
#!/usr/bin/env bash
bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh) "$@"
EOF
    chmod +x "${script_wrapper}"
    ln -sf "${script_wrapper}" "${shortcut_path}"
    ln -sf "${script_wrapper}" "${shortcut_path_upper}"

    if [ -s "${shortcut_path}" ] && [ -s "${shortcut_path_upper}" ]; then
        green "快捷指令 s / S 创建成功"
    else
        red "快捷指令创建失败"
    fi
}

# ============================================================
# 持久化写入函数
# ============================================================
_save_freeflow_conf() {
    mkdir -p "${work_dir}"
    printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"
}

_save_ss_conf() {
    mkdir -p "${work_dir}"
    printf '%s\n%s\n%s\n%s\n' "${SS_MODE}" "${SS_PORT}" "${SS_PASSWORD}" "${SS_METHOD}" > "${ss_conf}"
}

_save_reality_conf() {
    mkdir -p "${work_dir}"
    printf '%s\n%s\n' "${REALITY_SNI}" "${REALITY_PORT}" > "${reality_conf}"
}

# ============================================================
# 交互询问函数
# ============================================================
ask_argo_mode() {
    echo ""
    green  "是否安装 Cloudflare Argo 隧道？"
    skyblue "────────────────────────────────────"
    green  " 1) 安装 Argo（VLESS+WS+TLS，推荐）"
    green  " 2) 不安装 Argo"
    skyblue "────────────────────────────────────"
    reading "请输入选择 [1-2，回车默认 1]: " argo_choice
    case "${argo_choice}" in
        2) ARGO_MODE="no"  ;;
        *) ARGO_MODE="yes" ;;
    esac
    mkdir -p "${work_dir}"
    echo "${ARGO_MODE}" > "${argo_mode_conf}"
    case "${ARGO_MODE}" in
        yes) green  "✔ 已选择：安装 Argo" ;;
        no)  yellow "✔ 已选择：不安装 Argo" ;;
    esac
    echo ""
}

ask_reality_mode() {
    echo ""
    green  "是否安装 VLESS Reality 节点？"
    skyblue "────────────────────────────────────"
    green  " 1) 安装 Reality（VLESS+TCP+TLS）"
    green  " 2) 不安装 Reality（默认）"
    skyblue "────────────────────────────────────"
    reading "请输入选择 [1-2，回车默认 2]: " reality_choice
    case "${reality_choice}" in
        1) REALITY_MODE="yes" ;;
        *) REALITY_MODE="no"  ;;
    esac
    mkdir -p "${work_dir}"
    echo "${REALITY_MODE}" > "${reality_mode_conf}"

    if [ "${REALITY_MODE}" = "yes" ]; then
        reading "请输入 Reality SNI [回车默认 www.cloudflare.com]: " r_sni
        reading "请输入 Reality 监听端口 [回车默认 443]: " r_port
        [ -z "${r_sni}" ] && r_sni="www.cloudflare.com"
        valid_port "${r_port}" || r_port="443"
        REALITY_SNI="${r_sni}"
        REALITY_PORT="${r_port}"
        _save_reality_conf
        green "✔ 已选择：安装 Reality（SNI=${REALITY_SNI}，Port=${REALITY_PORT}）"
    else
        yellow "✔ 已选择：不安装 Reality"
    fi
    echo ""
}

ask_freeflow_mode() {
    echo ""
    green  "请选择免流方式："
    skyblue "────────────────────────────────────"
    green  " 1) VLESS + WS（明文 WebSocket，port 80）"
    green  " 2) VLESS + HTTPUpgrade（HTTP 升级，port 80）"
    green  " 3) 不安装免流节点（默认）"
    skyblue "────────────────────────────────────"
    reading "请输入选择 [1-3，回车默认 3]: " ff_choice
    case "${ff_choice}" in
        1) FREEFLOW_MODE="ws"          ;;
        2) FREEFLOW_MODE="httpupgrade" ;;
        *) FREEFLOW_MODE="none"        ;;
    esac

    if [ "${FREEFLOW_MODE}" != "none" ]; then
        reading "请输入免流 path [回车默认 /]: " ff_path_input
        if [ -z "${ff_path_input}" ]; then
            FF_PATH="/"
        else
            case "${ff_path_input}" in
                /*) FF_PATH="${ff_path_input}" ;;
                *)  FF_PATH="/${ff_path_input}" ;;
            esac
        fi
    else
        FF_PATH="/"
    fi

    _save_freeflow_conf
    case "${FREEFLOW_MODE}" in
        ws)          green  "✔ 已选择：VLESS+WS 免流（path=${FF_PATH}）"          ;;
        httpupgrade) green  "✔ 已选择：VLESS+HTTPUpgrade 免流（path=${FF_PATH}）" ;;
        none)        yellow "✔ 不安装免流节点"                                     ;;
    esac
    echo ""
}

ask_ss_mode() {
    echo ""
    green  "是否安装 Shadowsocks 节点？"
    skyblue "────────────────────────────────────"
    green  " 1) 安装 Shadowsocks（SS+TCP/UDP）"
    green  " 2) 不安装（默认）"
    skyblue "────────────────────────────────────"
    reading "请输入选择 [1-2，回车默认 2]: " ss_choice
    case "${ss_choice}" in
        1) SS_MODE="yes" ;;
        *) SS_MODE="no"  ;;
    esac

    if [ "${SS_MODE}" = "yes" ]; then
        reading "请输入 SS 监听端口 [回车默认 8388]: " ss_p
        valid_port "${ss_p}" || ss_p="8388"
        reading "请输入 SS 密码 [回车自动生成]: " ss_pw
        [ -z "${ss_pw}" ] && ss_pw=$(gen_uuid | tr -d '-' | cut -c1-16)
        echo ""
        green  "请选择加密方式："
        skyblue "────────────────────────────────────"
        green  " 1) aes-256-gcm（默认，推荐）"
        green  " 2) aes-128-gcm"
        green  " 3) chacha20-poly1305"
        green  " 4) xchacha20-poly1305"
        skyblue "────────────────────────────────────"
        reading "请输入选择 [1-4，回车默认 1]: " ss_m
        case "${ss_m}" in
            2) SS_METHOD="aes-128-gcm"        ;;
            3) SS_METHOD="chacha20-poly1305"  ;;
            4) SS_METHOD="xchacha20-poly1305" ;;
            *) SS_METHOD="aes-256-gcm"        ;;
        esac
        SS_PORT="${ss_p}"
        SS_PASSWORD="${ss_pw}"
        _save_ss_conf
        green "✔ 已选择：安装 Shadowsocks（Port=${SS_PORT}，Method=${SS_METHOD}）"
    else
        _save_ss_conf
        yellow "✔ 已选择：不安装 Shadowsocks"
    fi
    echo ""
}

# ============================================================
# Inbound JSON 构造函数
# ============================================================
get_freeflow_inbound_json() {
    local uuid="$1"
    case "${FREEFLOW_MODE}" in
        ws)
            cat << EOF
{"port":80,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"${uuid}"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"${FF_PATH}"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}
EOF
            ;;
        httpupgrade)
            cat << EOF
{"port":80,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"${uuid}"}],"decryption":"none"},"streamSettings":{"network":"httpupgrade","security":"none","httpupgradeSettings":{"path":"${FF_PATH}"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}
EOF
            ;;
    esac
}

get_reality_inbound_json() {
    local uuid="$1" privkey="$2" shortid="$3"
    cat << EOF
{"port":${REALITY_PORT},"listen":"::","protocol":"vless","settings":{"clients":[{"id":"${uuid}","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"${REALITY_SNI}:${REALITY_PORT}","serverNames":["${REALITY_SNI}"],"privateKey":"${privkey}","shortIds":["${shortid}"]}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}
EOF
}

get_ss_inbound_json() {
    cat << EOF
{"port":${SS_PORT},"listen":"::","protocol":"shadowsocks","settings":{"method":"${SS_METHOD}","password":"${SS_PASSWORD}","network":"tcp,udp"},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}
EOF
}

# ============================================================
# Inbound 下标计算（布局：Argo? > Reality? > FreeFlow? > SS?）
# ============================================================
calc_reality_index()  {
    [ "${ARGO_MODE}" = "yes" ] && echo 1 || echo 0
}

calc_freeflow_index() {
    local idx=0
    [ "${ARGO_MODE}"    = "yes" ] && idx=$(( idx + 1 ))
    [ "${REALITY_MODE}" = "yes" ] && idx=$(( idx + 1 ))
    echo ${idx}
}

calc_ss_index() {
    local idx=0
    [ "${ARGO_MODE}"         = "yes"  ] && idx=$(( idx + 1 ))
    [ "${REALITY_MODE}"      = "yes"  ] && idx=$(( idx + 1 ))
    [ "${FREEFLOW_MODE}"    != "none" ] && idx=$(( idx + 1 ))
    echo ${idx}
}

# ── jq inbound 操作 ───────────────────────────────────────────
_jq_set_inbound() {
    local idx="$1" ib_json="$2"
    jq --argjson ib "${ib_json}" --argjson idx "${idx}" '
        (.inbounds | length) as $len |
        if $len > $idx then .inbounds[$idx] = $ib
        else .inbounds = (.inbounds + [range($idx - $len + 1) | {}]) | .inbounds[$idx] = $ib
        end
    ' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
}

_jq_del_inbound() {
    local idx="$1" match="$2"
    jq --argjson idx "${idx}" --arg match "${match}" '
        if (.inbounds | length) > $idx and
           ((.inbounds[$idx].streamSettings.security // "") == $match or
            (.inbounds[$idx].streamSettings.network  // "") == $match or
            (.inbounds[$idx].protocol                // "") == $match)
        then .inbounds = (.inbounds[:$idx] + .inbounds[$idx+1:])
        else .
        end
    ' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
}

# ============================================================
# apply_*_config - 将各协议写入 config.json
# ============================================================
apply_reality_config() {
    local cur_uuid privkey shortid ri_json
    cur_uuid=$(get_current_uuid)
    [ -z "${cur_uuid}" ] || [ "${cur_uuid}" = "null" ] && cur_uuid="${UUID}"

    case "${REALITY_MODE}" in
        yes)
            if [ ! -f "${reality_keys_conf}" ]; then
                local key_out
                key_out=$("${work_dir}/${server_name}" x25519 2>/dev/null)
                privkey=$(echo "${key_out}"    | grep -i 'Private key' | awk '{print $NF}')
                local pubkey
                pubkey=$(echo "${key_out}"     | grep -i 'Public key'  | awk '{print $NF}')
                shortid=$(openssl rand -hex 8 2>/dev/null || gen_uuid | tr -d '-' | cut -c1-16)
                printf '%s\n%s\n%s\n' "${privkey}" "${pubkey}" "${shortid}" > "${reality_keys_conf}"
            else
                privkey=$(load_conf "${reality_keys_conf}" 1)
                shortid=$(load_conf "${reality_keys_conf}" 3)
            fi
            ri_json=$(get_reality_inbound_json "${cur_uuid}" "${privkey}" "${shortid}")
            _jq_set_inbound "$(calc_reality_index)" "${ri_json}"
            ;;
        no)
            _jq_del_inbound "$(calc_reality_index)" "reality"
            ;;
    esac
}

apply_freeflow_config() {
    local cur_uuid ff_json
    cur_uuid=$(get_current_uuid)
    [ -z "${cur_uuid}" ] || [ "${cur_uuid}" = "null" ] && cur_uuid="${UUID}"

    case "${FREEFLOW_MODE}" in
        ws|httpupgrade)
            ff_json=$(get_freeflow_inbound_json "${cur_uuid}")
            _jq_set_inbound "$(calc_freeflow_index)" "${ff_json}"
            ;;
        none)
            local cur_net
            cur_net=$(jq -r --argjson idx "$(calc_freeflow_index)" \
                '.inbounds[$idx].streamSettings.network // ""' "${config_dir}" 2>/dev/null)
            _jq_del_inbound "$(calc_freeflow_index)" "${cur_net:-ws}"
            ;;
    esac
}

apply_ss_config() {
    case "${SS_MODE}" in
        yes) _jq_set_inbound "$(calc_ss_index)" "$(get_ss_inbound_json)" ;;
        no)  _jq_del_inbound "$(calc_ss_index)" "shadowsocks"            ;;
    esac
}

# ============================================================
# install_xray - 下载二进制文件，写入基础 config.json
# ============================================================
install_xray() {
    clear
    purple "正在安装 Xray-2go，请稍等..."

    local ARCH_RAW ARCH ARCH_ARG
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        x86_64)            ARCH='amd64'; ARCH_ARG='64'        ;;
        x86|i686|i386)     ARCH='386';  ARCH_ARG='32'         ;;
        aarch64|arm64)     ARCH='arm64'; ARCH_ARG='arm64-v8a' ;;
        armv7l)            ARCH='armv7'; ARCH_ARG='arm32-v7a' ;;
        s390x)             ARCH='s390x'; ARCH_ARG='s390x'     ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    mkdir -p "${work_dir}" && chmod 755 "${work_dir}"

    if [ ! -f "${work_dir}/${server_name}" ]; then
        yellow "正在下载 xray..."
        curl -sLo "${work_dir}/${server_name}.zip" \
            "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_ARG}.zip" \
            || { red "xray 下载失败，请检查网络"; exit 1; }
        unzip "${work_dir}/${server_name}.zip" -d "${work_dir}/" > /dev/null 2>&1 \
            || { red "xray 解压失败"; exit 1; }
        chmod +x "${work_dir}/${server_name}"
        rm -f "${work_dir}/${server_name}.zip" \
              "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" \
              "${work_dir}/README.md"   "${work_dir}/LICENSE"
        green "xray 下载完成"
    else
        green "xray 二进制已存在，跳过下载"
    fi

    if [ "${ARGO_MODE}" = "yes" ]; then
        if [ ! -f "${work_dir}/argo" ]; then
            yellow "正在下载 cloudflared..."
            curl -sLo "${work_dir}/argo" \
                "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" \
                || { red "cloudflared 下载失败，请检查网络"; exit 1; }
            chmod +x "${work_dir}/argo"
            green "cloudflared 下载完成"
        else
            green "cloudflared 二进制已存在，跳过下载"
        fi
    fi

    # 写入基础 config
    if [ "${ARGO_MODE}" = "yes" ]; then
        cat > "${config_dir}" << EOF
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [
    {
      "port": ${ARGO_PORT},
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}" }], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "/vless-argo" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    }
  ],
  "dns": { "servers": ["https+local://8.8.8.8/dns-query"] },
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
    else
        cat > "${config_dir}" << 'EOF'
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [],
  "dns": { "servers": ["https+local://8.8.8.8/dns-query"] },
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
    fi

    [ "${REALITY_MODE}"  = "yes"  ] && apply_reality_config
    [ "${FREEFLOW_MODE}" != "none" ] && apply_freeflow_config
    [ "${SS_MODE}"       = "yes"  ] && apply_ss_config
}

# ============================================================
# 服务注册
# ============================================================
main_systemd_services() {
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=${work_dir}/xray run -c ${config_dir}
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF

    if [ "${ARGO_MODE}" = "yes" ]; then
        cat > /etc/systemd/system/tunnel.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2
StandardOutput=append:${work_dir}/argo.log
StandardError=append:${work_dir}/argo.log
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    fi

    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd && systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
    fi

    systemctl daemon-reload
    systemctl enable xray && systemctl start xray
    [ "${ARGO_MODE}" = "yes" ] && systemctl enable tunnel && systemctl start tunnel
}

alpine_openrc_services() {
    cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run
description="Xray service"
command="/etc/xray/xray"
command_args="run -c /etc/xray/config.json"
command_background=true
pidfile="/var/run/xray.pid"
EOF

    if [ "${ARGO_MODE}" = "yes" ]; then
        cat > /etc/init.d/tunnel << EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '/etc/xray/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> /etc/xray/argo.log 2>&1'"
command_background=true
pidfile="/var/run/tunnel.pid"
EOF
        chmod +x /etc/init.d/tunnel
        rc-update add tunnel default
    fi

    chmod +x /etc/init.d/xray
    rc-update add xray default
}

change_hosts() {
    echo "0 0" > /proc/sys/net/ipv4/ping_group_range
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

# ============================================================
# restart_xray / restart_argo
# ============================================================
restart_xray() {
    if is_alpine; then
        service_cmd restart xray
    else
        systemctl daemon-reload && service_cmd restart xray
    fi
}

restart_argo() {
    rm -f "${work_dir}/argo.log"
    if is_alpine; then
        service_cmd restart tunnel
    else
        systemctl daemon-reload && service_cmd restart tunnel
    fi
}

# ============================================================
# reset_tunnel_to_temp
# ============================================================
reset_tunnel_to_temp() {
    if is_alpine; then
        sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> /etc/xray/argo.log 2>&1'\"" \
            /etc/init.d/tunnel
    else
        sed -i "/^ExecStart=/c\\ExecStart=${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2" \
            /etc/systemd/system/tunnel.service
    fi
}

# ============================================================
# get_argodomain - 从 argo.log 提取 trycloudflare.com 子域
# ============================================================
get_argodomain() {
    local domain i=1
    sleep 3
    while [ "${i}" -le 5 ]; do
        domain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' \
            "${work_dir}/argo.log" 2>/dev/null | head -1)
        [ -n "${domain}" ] && echo "${domain}" && return 0
        sleep 2
        i=$(( i + 1 ))
    done
    echo ""; return 1
}

# ============================================================
# print_nodes - 打印节点信息，并尝试输出二维码
# ============================================================
print_nodes() {
    echo ""
    if [ ! -f "${client_dir}" ]; then
        yellow "节点文件不存在，请先安装或重新获取节点信息"
        return 1
    fi
    skyblue "══════════════════ 节点信息 ══════════════════"
    while IFS= read -r line; do
        [ -n "${line}" ] && printf '\033[1;35m%s\033[0m\n' "${line}"
    done < "${client_dir}"
    skyblue "════════════════════════════════════════════"

    # 尝试输出二维码（需要 qrencode 已安装）
    if command -v qrencode > /dev/null 2>&1; then
        echo ""
        green "节点二维码："
        while IFS= read -r line; do
            [ -n "${line}" ] && {
                # 取 # 后的名字作为标题
                local label
                label=$(echo "${line}" | sed 's/.*#//')
                skyblue "[ ${label} ]"
                qrencode -t ANSIUTF8 "${line}"
                echo ""
            }
        done < "${client_dir}"
    fi
    echo ""
}

# ============================================================
# 节点链接构造函数
# ============================================================
build_freeflow_link() {
    local ip="$1" uuid path_enc
    uuid=$(get_current_uuid)
    path_enc=$(printf '%s' "${FF_PATH}" | sed 's|%|%25|g; s| |%20|g')
    case "${FREEFLOW_MODE}" in
        ws)
            echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=ws&host=${ip}&path=${path_enc}#FreeFlow-WS"
            ;;
        httpupgrade)
            echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=httpupgrade&host=${ip}&path=${path_enc}#FreeFlow-HTTPUpgrade"
            ;;
    esac
}

build_reality_link() {
    local ip="$1" uuid pubkey shortid
    uuid=$(get_current_uuid)
    pubkey=$(load_conf "${reality_keys_conf}" 2)
    shortid=$(load_conf "${reality_keys_conf}" 3)
    echo "vless://${uuid}@${ip}:${REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${pubkey}&sid=${shortid}&type=tcp&flow=xtls-rprx-vision#Reality"
}

build_ss_link() {
    local ip="$1" userinfo
    userinfo=$(printf '%s:%s' "${SS_METHOD}" "${SS_PASSWORD}" | base64 | tr -d '\n')
    echo "ss://${userinfo}@${ip}:${SS_PORT}#SS-${SS_METHOD}"
}

# ============================================================
# get_info - 生成 url.txt 并打印
# ============================================================
get_info() {
    clear
    local IP
    IP=$(get_realip)
    [ -z "${IP}" ] && yellow "警告：无法获取服务器 IP，依赖 IP 的节点链接将缺失"

    {
        if [ "${ARGO_MODE}" = "yes" ]; then
            local cur_uuid argodomain
            cur_uuid=$(get_current_uuid)
            purple "正在获取 ArgoDomain，请稍等..." >&2
            restart_argo
            argodomain=$(get_argodomain)
            if [ -z "${argodomain}" ]; then
                yellow "未能获取 ArgoDomain，可稍后通过 Argo 管理菜单重新获取" >&2
                argodomain="<未获取到域名>"
            else
                green "ArgoDomain：${argodomain}" >&2
            fi
            echo "vless://${cur_uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#Argo"
        fi
        [ "${REALITY_MODE}"  = "yes"  ] && [ -n "${IP}" ] && build_reality_link  "${IP}"
        [ "${FREEFLOW_MODE}" != "none" ] && [ -n "${IP}" ] && build_freeflow_link "${IP}"
        [ "${SS_MODE}"       = "yes"  ] && [ -n "${IP}" ] && build_ss_link        "${IP}"
    } > "${client_dir}"

    print_nodes
}

# ============================================================
# get_quick_tunnel
# ============================================================
get_quick_tunnel() {
    if [ "${ARGO_MODE}" != "yes" ]; then
        yellow "未安装 Argo，此操作不可用"; return 1
    fi
    if [ ! -f "${client_dir}" ]; then
        yellow "节点文件不存在，请先执行安装以初始化节点信息"; return 1
    fi
    yellow "正在重启 Argo 并获取新临时域名..."
    restart_argo
    local argodomain
    argodomain=$(get_argodomain)
    if [ -z "${argodomain}" ]; then
        yellow "未能获取临时域名，请检查网络或稍后重试"; return 1
    fi
    green "ArgoDomain：${argodomain}"
    sed -i "1s/sni=[^&]*/sni=${argodomain}/; 1s/host=[^&]*/host=${argodomain}/" "${client_dir}"
    print_nodes
    green "节点已更新，请手动复制以上链接"
}

# ── url.txt 原地更新辅助函数 ──────────────────────────────────
_update_url_line() {
    local pattern="$1" new_link="$2" escaped
    if grep -q "${pattern}" "${client_dir}" 2>/dev/null; then
        escaped=$(printf '%s\n' "${new_link}" | sed 's/[\/&]/\\&/g')
        sed -i "/${pattern}/c\\${escaped}" "${client_dir}"
    fi
}

_update_reality_url()  { _update_url_line 'security=reality' "$(build_reality_link "$1")"; }
_update_ss_url()       { _update_url_line '^ss://'           "$(build_ss_link "$1")";      }
_update_freeflow_url() { _update_url_line '#FreeFlow'        "$(build_freeflow_link "$1")"; }

# ============================================================
# manage_argo
# ============================================================
manage_argo() {
    if [ "${ARGO_MODE}" != "yes" ]; then
        yellow "未安装 Argo，Argo 管理不可用"; sleep 1; return
    fi
    check_argo > /dev/null 2>&1
    if [ $? -eq 2 ]; then
        yellow "Argo 尚未安装！"; sleep 1; return
    fi

    while true; do
        clear; echo ""
        green  "── Argo 隧道管理 ──────────────────────"
        green  " 1) 启动 Argo 服务"
        green  " 2) 停止 Argo 服务"
        green  " 3) 添加固定隧道（token/json）"
        green  " 4) 切换回临时隧道"
        green  " 5) 重新获取临时域名"
        purple " 0) 返回主菜单"
        skyblue "────────────────────────────────────"
        reading "请输入选择: " choice

        case "${choice}" in
            1)
                service_cmd start tunnel
                green "Argo 已启动"
                ;;
            2)
                service_cmd stop tunnel
                green "Argo 已停止"
                ;;
            3)
                yellow "固定隧道回源端口为 ${ARGO_PORT}，请在 CF 后台配置对应 ingress"
                echo ""
                reading "请输入你的 Argo 域名: " argo_domain
                [ -z "${argo_domain}" ] && red "Argo 域名不能为空" && continue
                reading "请输入 Argo 密钥（token 或 json）: " argo_auth

                if echo "${argo_auth}" | grep -q "TunnelSecret"; then
                    local tunnel_id
                    tunnel_id=$(echo "${argo_auth}" | cut -d'"' -f12)
                    echo "${argo_auth}" > "${work_dir}/tunnel.json"
                    cat > "${work_dir}/tunnel.yml" << EOF
tunnel: ${tunnel_id}
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: ${argo_domain}
    service: http://localhost:${ARGO_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
                    local exec_str="/etc/xray/argo tunnel --edge-ip-version auto --config /etc/xray/tunnel.yml run >> /etc/xray/argo.log 2>&1"
                    if is_alpine; then
                        sed -i "/^command_args=/c\command_args=\"-c '${exec_str}'\"" /etc/init.d/tunnel
                    else
                        sed -i "/^ExecStart=/c\\ExecStart=/bin/sh -c '${exec_str}'" /etc/systemd/system/tunnel.service
                    fi
                elif echo "${argo_auth}" | grep -qE '^[A-Z0-9a-z=]{120,250}$'; then
                    local exec_str="/etc/xray/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_auth} >> /etc/xray/argo.log 2>&1"
                    if is_alpine; then
                        sed -i "/^command_args=/c\command_args=\"-c '${exec_str}'\"" /etc/init.d/tunnel
                    else
                        sed -i "/^ExecStart=/c\\ExecStart=/bin/sh -c '${exec_str}'" /etc/systemd/system/tunnel.service
                    fi
                else
                    yellow "token 或 json 格式不匹配，请重新输入"; continue
                fi

                restart_argo
                if [ -f "${client_dir}" ]; then
                    sed -i "1s/sni=[^&]*/sni=${argo_domain}/; 1s/host=[^&]*/host=${argo_domain}/" "${client_dir}"
                    print_nodes
                else
                    yellow "节点文件不存在，固定隧道已配置，请重新安装后获取节点链接"
                fi
                green "固定隧道已配置"
                ;;
            4)
                reset_tunnel_to_temp
                get_quick_tunnel
                ;;
            5)
                local using_temp="false"
                if is_alpine; then
                    grep -Fq -- "--url http://localhost:${ARGO_PORT}" /etc/init.d/tunnel && using_temp="true"
                else
                    grep -Fq -- "--url http://localhost:${ARGO_PORT}" /etc/systemd/system/tunnel.service && using_temp="true"
                fi
                if [ "${using_temp}" = "true" ]; then
                    get_quick_tunnel
                else
                    yellow "当前使用固定隧道，无法获取临时域名"
                fi
                ;;
            0) return ;;
            *) red "无效的选项" ;;
        esac
        printf '\033[1;91m按回车键继续...\033[0m'; read -r _dummy
    done
}

# ============================================================
# manage_reality
# ============================================================
manage_reality() {
    if [ "${REALITY_MODE}" != "yes" ]; then
        yellow "未安装 Reality，此管理不可用"; sleep 1; return
    fi

    while true; do
        clear; echo ""
        green  "── Reality 管理 ──────────────────────"
        skyblue "  SNI  : ${REALITY_SNI}"
        skyblue "  Port : ${REALITY_PORT}"
        skyblue "────────────────────────────────────"
        green  " 1) 修改 SNI"
        green  " 2) 修改监听端口"
        purple " 0) 返回主菜单"
        skyblue "────────────────────────────────────"
        reading "请输入选择: " choice

        case "${choice}" in
            1)
                reading "请输入新的 SNI [回车保持 ${REALITY_SNI}]: " new_sni
                [ -z "${new_sni}" ] && new_sni="${REALITY_SNI}"
                REALITY_SNI="${new_sni}"
                _save_reality_conf
                apply_reality_config
                restart_xray
                local IP; IP=$(get_realip)
                [ -n "${IP}" ] && _update_reality_url "${IP}"
                green "SNI 已修改为：${REALITY_SNI}"
                print_nodes
                ;;
            2)
                reading "请输入新的监听端口 [回车保持 ${REALITY_PORT}]: " new_rp
                if [ -z "${new_rp}" ]; then
                    new_rp="${REALITY_PORT}"
                elif ! valid_port "${new_rp}"; then
                    red "端口无效，请输入 1-65535 的整数"; continue
                fi
                REALITY_PORT="${new_rp}"
                _save_reality_conf
                apply_reality_config
                restart_xray
                local IP; IP=$(get_realip)
                [ -n "${IP}" ] && _update_reality_url "${IP}"
                green "Reality 端口已修改为：${REALITY_PORT}"
                print_nodes
                ;;
            0) return ;;
            *) red "无效的选项" ;;
        esac
        printf '\033[1;91m按回车键继续...\033[0m'; read -r _dummy
    done
}

# ============================================================
# manage_ss
# ============================================================
manage_ss() {
    if [ "${SS_MODE}" != "yes" ]; then
        yellow "未安装 Shadowsocks，此管理不可用"; sleep 1; return
    fi

    while true; do
        clear; echo ""
        green  "── Shadowsocks 管理 ──────────────────"
        skyblue "  Port    : ${SS_PORT}"
        skyblue "  Method  : ${SS_METHOD}"
        skyblue "  Password: ${SS_PASSWORD}"
        skyblue "────────────────────────────────────"
        green  " 1) 修改端口"
        green  " 2) 修改密码"
        green  " 3) 修改加密方式"
        purple " 0) 返回主菜单"
        skyblue "────────────────────────────────────"
        reading "请输入选择: " choice

        case "${choice}" in
            1)
                reading "请输入新的端口 [回车保持 ${SS_PORT}]: " new_sp
                if [ -z "${new_sp}" ]; then
                    new_sp="${SS_PORT}"
                elif ! valid_port "${new_sp}"; then
                    red "端口无效，请输入 1-65535 的整数"; continue
                fi
                SS_PORT="${new_sp}"
                _save_ss_conf && apply_ss_config && restart_xray
                local IP; IP=$(get_realip)
                [ -n "${IP}" ] && _update_ss_url "${IP}"
                green "SS 端口已修改为：${SS_PORT}"
                print_nodes
                ;;
            2)
                reading "请输入新的密码 [回车自动生成]: " new_pw
                [ -z "${new_pw}" ] && new_pw=$(gen_uuid | tr -d '-' | cut -c1-16)
                SS_PASSWORD="${new_pw}"
                _save_ss_conf && apply_ss_config && restart_xray
                local IP; IP=$(get_realip)
                [ -n "${IP}" ] && _update_ss_url "${IP}"
                green "SS 密码已修改"
                print_nodes
                ;;
            3)
                echo ""
                green  "请选择加密方式："
                skyblue "────────────────────────────────────"
                green  " 1) aes-256-gcm（推荐）"
                green  " 2) aes-128-gcm"
                green  " 3) chacha20-poly1305"
                green  " 4) xchacha20-poly1305"
                skyblue "────────────────────────────────────"
                reading "请输入选择 [1-4]: " m_choice
                case "${m_choice}" in
                    2) SS_METHOD="aes-128-gcm"        ;;
                    3) SS_METHOD="chacha20-poly1305"  ;;
                    4) SS_METHOD="xchacha20-poly1305" ;;
                    *) SS_METHOD="aes-256-gcm"        ;;
                esac
                _save_ss_conf && apply_ss_config && restart_xray
                local IP; IP=$(get_realip)
                [ -n "${IP}" ] && _update_ss_url "${IP}"
                green "SS 加密方式已修改为：${SS_METHOD}"
                print_nodes
                ;;
            0) return ;;
            *) red "无效的选项" ;;
        esac
        printf '\033[1;91m按回车键继续...\033[0m'; read -r _dummy
    done
}

# ============================================================
# change_config - 修改 UUID / Argo 端口 / 免流方式 / 免流 path
# ============================================================
change_config() {
    local ff_label
    case "${FREEFLOW_MODE}" in
        ws)          ff_label="WS（path=${FF_PATH}）"          ;;
        httpupgrade) ff_label="HTTPUpgrade（path=${FF_PATH}）" ;;
        none)        ff_label="未安装"                          ;;
        *)           ff_label="未知"                           ;;
    esac

    while true; do
        clear; echo ""
        green  "── 修改节点配置 ──────────────────────"
        green  " 1) 修改 UUID"
        [ "${ARGO_MODE}" = "yes" ] && \
        green  " 2) 修改 Argo 回源端口（当前：${ARGO_PORT}）"
        green  " 3) 变更免流方式（当前：${ff_label}）"
        [ "${FREEFLOW_MODE}" != "none" ] && \
        green  " 4) 修改免流 path（当前：${FF_PATH}）"
        purple " 0) 返回主菜单"
        skyblue "────────────────────────────────────"
        reading "请输入选择: " choice

        case "${choice}" in
            1)
                reading "请输入新的 UUID [回车自动生成]: " new_uuid
                if [ -z "${new_uuid}" ]; then
                    new_uuid=$(gen_uuid)
                    green "生成的 UUID：${new_uuid}"
                fi
                sed -i "s/[a-fA-F0-9]\{8\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{12\}/${new_uuid}/g" \
                    "${config_dir}" "${client_dir}"
                export UUID="${new_uuid}"
                restart_xray
                green "UUID 已修改为：${new_uuid}"
                print_nodes
                ;;
            2)
                if [ "${ARGO_MODE}" != "yes" ]; then red "无效的选项！"; continue; fi
                reading "请输入新的 Argo 回源端口 [回车随机]: " new_port
                [ -z "${new_port}" ] && new_port=$(shuf -i 2000-65000 -n 1)
                if ! valid_port "${new_port}"; then
                    red "端口无效，请输入 1-65535 的整数"; continue
                fi
                jq --argjson p "${new_port}" '.inbounds[0].port = $p' "${config_dir}" \
                    > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
                if is_alpine; then
                    sed -i "s|http://localhost:[0-9]*|http://localhost:${new_port}|g" /etc/init.d/tunnel
                else
                    sed -i "s|http://localhost:[0-9]*|http://localhost:${new_port}|g" \
                        /etc/systemd/system/tunnel.service
                fi
                export ARGO_PORT="${new_port}"
                restart_xray && restart_argo
                green "Argo 回源端口已修改为：${new_port}"
                ;;
            3)
                if [ ! -f "${client_dir}" ]; then
                    yellow "节点文件不存在，请先完成安装后再变更免流方式"; continue
                fi
                ask_freeflow_mode
                apply_freeflow_config
                local ip_now; ip_now=$(get_realip)
                {
                    [ "${ARGO_MODE}"     = "yes"  ] && grep '#Argo$'           "${client_dir}" 2>/dev/null
                    [ "${REALITY_MODE}"  = "yes"  ] && grep 'security=reality' "${client_dir}" 2>/dev/null
                    [ "${FREEFLOW_MODE}" != "none" ] && [ -n "${ip_now}" ] && build_freeflow_link "${ip_now}"
                    [ "${SS_MODE}"       = "yes"  ] && grep '^ss://'           "${client_dir}" 2>/dev/null
                } > "${client_dir}.new" && mv "${client_dir}.new" "${client_dir}"
                restart_xray
                # 更新显示标签
                case "${FREEFLOW_MODE}" in
                    ws)          ff_label="WS（path=${FF_PATH}）"          ;;
                    httpupgrade) ff_label="HTTPUpgrade（path=${FF_PATH}）" ;;
                    none)        ff_label="未安装"                          ;;
                esac
                green "免流方式已变更"
                print_nodes
                ;;
            4)
                if [ "${FREEFLOW_MODE}" = "none" ]; then red "无效的选项！"; continue; fi
                reading "请输入新的免流 path [回车保持 ${FF_PATH}]: " new_path
                if [ -z "${new_path}" ]; then
                    new_path="${FF_PATH}"
                else
                    case "${new_path}" in /*) : ;; *) new_path="/${new_path}" ;; esac
                fi
                FF_PATH="${new_path}"
                _save_freeflow_conf
                apply_freeflow_config
                local ip_now; ip_now=$(get_realip)
                [ -n "${ip_now}" ] && _update_freeflow_url "${ip_now}"
                restart_xray
                ff_label="${FREEFLOW_MODE}（path=${FF_PATH}）"
                green "免流 path 已修改为：${FF_PATH}"
                print_nodes
                ;;
            0) return ;;
            *) red "无效的选项！" ;;
        esac
        printf '\033[1;91m按回车键继续...\033[0m'; read -r _dummy
    done
}

# ============================================================
# check_nodes
# ============================================================
check_nodes() {
    local cx
    check_xray > /dev/null 2>&1; cx=$?
    if [ "${cx}" -eq 0 ]; then
        print_nodes
    else
        yellow "Xray-2go 尚未安装或未运行"
    fi
}

# ============================================================
# uninstall_xray
# ============================================================
uninstall_xray() {
    reading "确定要卸载 xray-2go 吗？(y/n) [回车取消]: " choice
    case "${choice}" in
        y|Y)
            yellow "正在卸载..."
            if is_alpine; then
                service_cmd stop  xray 2>/dev/null
                service_cmd disable xray 2>/dev/null
                rm -f /etc/init.d/xray
                if [ "${ARGO_MODE}" = "yes" ]; then
                    service_cmd stop  tunnel 2>/dev/null
                    service_cmd disable tunnel 2>/dev/null
                    rm -f /etc/init.d/tunnel
                fi
            else
                service_cmd stop    xray 2>/dev/null
                service_cmd disable xray 2>/dev/null
                rm -f /etc/systemd/system/xray.service
                if [ "${ARGO_MODE}" = "yes" ]; then
                    service_cmd stop    tunnel 2>/dev/null
                    service_cmd disable tunnel 2>/dev/null
                    rm -f /etc/systemd/system/tunnel.service
                fi
                systemctl daemon-reload
            fi
            rm -rf "${work_dir}"
            rm -f "${shortcut_path}" "${shortcut_path_upper}" /usr/local/bin/xray2go
            green "Xray-2go 卸载完成"
            ;;
        *) purple "已取消卸载" ;;
    esac
}

trap 'echo ""; red "已取消操作"; exit 1' INT

# ============================================================
# menu - 主菜单
# ============================================================
menu() {
    while true; do
        local xray_status argo_status cx
        xray_status=$(check_xray); cx=$?
        argo_status=$(check_argo)

        # 状态显示文本
        local ff_display argo_display reality_display ss_display
        case "${FREEFLOW_MODE}" in
            ws)          ff_display="WS（path=${FF_PATH}）"          ;;
            httpupgrade) ff_display="HTTPUpgrade（path=${FF_PATH}）" ;;
            *)           ff_display="未启用"                          ;;
        esac
        [ "${ARGO_MODE}"    = "yes" ] && argo_display="${argo_status}"     || argo_display="未启用"
        [ "${REALITY_MODE}" = "yes" ] && reality_display="SNI=${REALITY_SNI} Port=${REALITY_PORT}" \
                                      || reality_display="未启用"
        [ "${SS_MODE}"      = "yes" ] && ss_display="Port=${SS_PORT} ${SS_METHOD}" \
                                      || ss_display="未启用"

        clear
        printf '\033[1;35m'
        printf '╔══════════════════════════════════╗\n'
        printf '║       Xray-2go  精简版           ║\n'
        printf '╚══════════════════════════════════╝\n'
        printf '\033[0m'

        # 状态栏
        printf ' Xray     : '; _status_color "${xray_status}"
        printf ' Argo     : '; _status_color "${argo_display}"
        printf ' Reality  : '; gray "  ${reality_display}"
        printf ' 免流     : '; gray "  ${ff_display}"
        printf ' SS       : '; gray "  ${ss_display}"
        skyblue "──────────────────────────────────"

        green  " 1) 安装 Xray-2go"
        red    " 2) 卸载 Xray-2go"
        skyblue "──────────────────────────────────"
        green  " 3) Argo 隧道管理"
        green  " 4) Reality 管理"
        green  " 5) Shadowsocks 管理"
        skyblue "──────────────────────────────────"
        green  " 6) 查看节点信息"
        green  " 7) 修改节点配置"
        skyblue "──────────────────────────────────"
        red    " 0) 退出脚本"
        skyblue "──────────────────────────────────"
        reading "请输入选择 [0-7]: " choice
        echo ""

        case "${choice}" in
            1)
                if [ "${cx}" -eq 0 ]; then
                    yellow "Xray-2go 已安装并运行中！"
                    reading "是否重新安装？(y/n) [回车取消]: " reinstall
                    case "${reinstall}" in
                        y|Y) : ;;
                        *)   continue ;;
                    esac
                fi
                ask_argo_mode
                ask_reality_mode
                ask_freeflow_mode
                ask_ss_mode
                manage_packages install jq unzip
                install_xray
                if command -v systemctl > /dev/null 2>&1; then
                    main_systemd_services
                elif command -v rc-update > /dev/null 2>&1; then
                    alpine_openrc_services
                    change_hosts
                    service_cmd restart xray
                    [ "${ARGO_MODE}" = "yes" ] && service_cmd restart tunnel
                else
                    red "不支持的 init 系统"; exit 1
                fi
                get_info
                install_shortcut
                ;;
            2) uninstall_xray ;;
            3) manage_argo ;;
            4) manage_reality ;;
            5) manage_ss ;;
            6) check_nodes ;;
            7) change_config ;;
            0) exit 0 ;;
            *) red "无效的选项，请输入 0 到 7" ;;
        esac
        printf '\033[1;91m按回车键继续...\033[0m'
        read -r _dummy
    done
}

# ── 首次运行安装快捷方式 ──────────────────────────────────────
[ ! -f "${shortcut_path}" ] && install_shortcut 2>/dev/null || true

menu
