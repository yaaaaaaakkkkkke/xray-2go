#!/bin/bash

# ============================================================
# 精简版 Xray-2go 一键脚本
# 协议：
#   Argo（可选）：VLESS+WS+TLS（Cloudflare Argo 隧道）
#   Reality（可选）：VLESS+TCP+TLS（VLESS Reality）
#   免流（可选）：VLESS+WS 明文（port 80）| VLESS+HTTPUpgrade（port 80）| 不安装
#   Shadowsocks（可选）：SS+TCP/UDP
# ============================================================

# 颜色输出：printf 替代 echo -e，避免依赖 echo 的 -e 扩展行为
red()    { printf '\033[1;91m%s\033[0m\n' "$1"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$1"; }
purple() { printf '\033[1;35m%s\033[0m\n' "$1"; }
skyblue(){ printf '\033[1;36m%s\033[0m\n' "$1"; }
reading() { printf '\033[1;91m%s\033[0m' "$1"; read -r "$2"; }

# ── 常量 ────────────────────────────────────────────────────
server_name="xray"
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
freeflow_conf="${work_dir}/freeflow.conf"
argo_mode_conf="${work_dir}/argo_mode.conf"
reality_mode_conf="${work_dir}/reality_mode.conf"
reality_conf="${work_dir}/reality.conf"
ss_conf="${work_dir}/ss.conf"
shortcut_path="/usr/local/bin/s"

# ── 环境变量（可外部注入） ───────────────────────────────────
export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
export ARGO_PORT=${ARGO_PORT:-'8080'}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1

# ── 读取持久化 Argo 模式 ──────────────────────────────────────
_raw=$(cat "${argo_mode_conf}" 2>/dev/null)
case "${_raw}" in
    yes|no) ARGO_MODE="${_raw}" ;;
    *)      ARGO_MODE="yes"     ;;
esac
unset _raw

# ── 若已安装，从 config.json 读取实际 ARGO_PORT ──────────────
if [ "${ARGO_MODE}" = "yes" ] && [ -f "${config_dir}" ]; then
    _port=$(jq -r '.inbounds[0].port' "${config_dir}" 2>/dev/null)
    if echo "$_port" | grep -qE '^[0-9]+$'; then
        export ARGO_PORT=$_port
    fi
    unset _port
fi

# ── 读取持久化免流配置（line1=mode, line2=path） ─────────────
# FREEFLOW_MODE: none | ws | httpupgrade   FF_PATH: URL path
FF_PATH="/"
if [ -f "${freeflow_conf}" ]; then
    _l1=$(sed -n '1p' "${freeflow_conf}" 2>/dev/null)
    _l2=$(sed -n '2p' "${freeflow_conf}" 2>/dev/null)
    case "${_l1}" in
        ws|httpupgrade) FREEFLOW_MODE="${_l1}" ;;
        *)              FREEFLOW_MODE="none"   ;;
    esac
    [ -n "${_l2}" ] && FF_PATH="${_l2}"
    unset _l1 _l2
else
    FREEFLOW_MODE="none"
fi

# ── 读取持久化 Reality 模式 ───────────────────────────────────
_raw=$(cat "${reality_mode_conf}" 2>/dev/null)
case "${_raw}" in
    yes|no) REALITY_MODE="${_raw}" ;;
    *)      REALITY_MODE="no"      ;;
esac
unset _raw

# ── 读取持久化 Reality 参数（SNI / PORT） ────────────────────
REALITY_SNI="www.cloudflare.com"
REALITY_PORT="443"
if [ -f "${reality_conf}" ]; then
    _sni=$(sed -n '1p' "${reality_conf}" 2>/dev/null)
    _rp=$(sed -n  '2p' "${reality_conf}" 2>/dev/null)
    [ -n "${_sni}" ] && REALITY_SNI="${_sni}"
    echo "${_rp}" | grep -qE '^[0-9]+$' && REALITY_PORT="${_rp}"
    unset _sni _rp
fi

# ── 读取持久化 Shadowsocks 配置（line1=mode, line2=port, line3=password, line4=method） ──
SS_MODE="no"
SS_PORT="8388"
SS_PASSWORD=""
SS_METHOD="aes-256-gcm"
if [ -f "${ss_conf}" ]; then
    _s1=$(sed -n '1p' "${ss_conf}" 2>/dev/null)
    _s2=$(sed -n '2p' "${ss_conf}" 2>/dev/null)
    _s3=$(sed -n '3p' "${ss_conf}" 2>/dev/null)
    _s4=$(sed -n '4p' "${ss_conf}" 2>/dev/null)
    case "${_s1}" in yes|no) SS_MODE="${_s1}" ;; esac
    echo "${_s2}" | grep -qE '^[0-9]+$' && SS_PORT="${_s2}"
    [ -n "${_s3}" ] && SS_PASSWORD="${_s3}"
    [ -n "${_s4}" ] && SS_METHOD="${_s4}"
    unset _s1 _s2 _s3 _s4
fi

# ============================================================
# check_xray / check_argo
# 输出状态文字到 stdout，返回值：0=运行中 1=未运行 2=未安装
# ============================================================
check_xray() {
    if [ ! -f "${work_dir}/${server_name}" ]; then
        echo "not installed"; return 2
    fi
    if [ -f /etc/alpine-release ]; then
        if rc-service xray status 2>/dev/null | grep -q "started"; then
            echo "running"; return 0
        else
            echo "not running"; return 1
        fi
    else
        if [ "$(systemctl is-active xray 2>/dev/null)" = "active" ]; then
            echo "running"; return 0
        else
            echo "not running"; return 1
        fi
    fi
}

check_argo() {
    if [ "${ARGO_MODE}" = "no" ]; then
        echo "disabled"; return 3
    fi
    if [ ! -f "${work_dir}/argo" ]; then
        echo "not installed"; return 2
    fi
    if [ -f /etc/alpine-release ]; then
        if rc-service tunnel status 2>/dev/null | grep -q "started"; then
            echo "running"; return 0
        else
            echo "not running"; return 1
        fi
    else
        if [ "$(systemctl is-active tunnel 2>/dev/null)" = "active" ]; then
            echo "running"; return 0
        else
            echo "not running"; return 1
        fi
    fi
}

# ============================================================
# manage_packages
# 通用包安装，支持 apt / dnf / yum / apk
# ============================================================
manage_packages() {
    [ "$#" -lt 2 ] && red "未指定包名或操作" && return 1
    local action=$1; shift
    [ "$action" != "install" ] && red "未知操作: $action" && return 1
    for package in "$@"; do
        if command -v "$package" > /dev/null 2>&1; then
            green "${package} already installed"; continue
        fi
        yellow "正在安装 ${package}..."
        if   command -v apt > /dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt install -y "$package"
        elif command -v dnf > /dev/null 2>&1; then dnf install -y "$package"
        elif command -v yum > /dev/null 2>&1; then yum install -y "$package"
        elif command -v apk > /dev/null 2>&1; then apk update && apk add "$package"
        else red "未知系统！"; return 1; fi
    done
}

# ============================================================
# get_realip
# 优先 IPv4；若归属 CF/特定 CDN 则切换 IPv6
# ============================================================
get_realip() {
    local ip ipv6
    ip=$(curl -s --max-time 2 ipv4.ip.sb)
    if [ -z "$ip" ]; then
        ipv6=$(curl -s --max-time 2 ipv6.ip.sb)
        if [ -n "$ipv6" ]; then echo "[$ipv6]"; else echo ""; fi
        return
    fi
    if curl -s --max-time 3 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        ipv6=$(curl -s --max-time 2 ipv6.ip.sb)
        if [ -n "$ipv6" ]; then echo "[$ipv6]"; else echo "$ip"; fi
    else
        echo "$ip"
    fi
}

# ============================================================
# get_current_uuid
# 从 config.json 搜索第一个 VLESS inbound 的 UUID；
# 找不到时（如 SS-only 场景）回退到全局 UUID 变量
# ============================================================
get_current_uuid() {
    local id
    id=$(jq -r '
        (first(.inbounds[] | select(.protocol=="vless") | .settings.clients[0].id) // empty)
    ' "${config_dir}" 2>/dev/null)
    echo "${id:-${UUID}}"
}

# ============================================================
# install_shortcut
# 将脚本本体复制到 /usr/local/bin/xray2go（固定路径），
# 再创建 /usr/local/bin/s 指向它。
# 兼容 bash <(curl ...) / pipe 执行场景：此时 $0 为临时 fd 路径，
# 通过 /proc/self/fd/255 读取当前 bash 进程加载的脚本内容。
# ============================================================
install_shortcut() {
    local script_main="/usr/local/bin/xray2go"

    # 优先：$0 是真实文件（直接执行 bash argo.sh）
    if [ -f "$0" ]; then
        cp -f "$0" "${script_main}"
    # 次选：bash <(curl ...) 场景，fd/255 指向脚本内容
    elif [ -r /proc/self/fd/255 ]; then
        cat /proc/self/fd/255 > "${script_main}"
    else
        yellow "无法确定脚本路径，快捷方式安装跳过"; return 1
    fi

    chmod +x "${script_main}"

    # s → xray2go
    printf '#!/bin/bash\nexec /usr/local/bin/xray2go "$@"\n' > "${shortcut_path}"
    chmod +x "${shortcut_path}"
    green "快捷方式已安装：输入 s 可直接启动本脚本"
}

# ============================================================
# _save_freeflow_conf
# 将 FREEFLOW_MODE 和 FF_PATH 持久化（两行格式）
# ============================================================
_save_freeflow_conf() {
    mkdir -p "${work_dir}"
    printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"
}

# ============================================================
# _save_ss_conf
# 将 SS 参数持久化（四行格式）
# ============================================================
_save_ss_conf() {
    mkdir -p "${work_dir}"
    printf '%s\n%s\n%s\n%s\n' "${SS_MODE}" "${SS_PORT}" "${SS_PASSWORD}" "${SS_METHOD}" > "${ss_conf}"
}

# ============================================================
# ask_argo_mode
# ============================================================
ask_argo_mode() {
    echo ""
    green  "是否安装 Cloudflare Argo 隧道？"
    skyblue "------------------------------------"
    green  "1. 安装 Argo（VLESS+WS+TLS，默认）"
    green  "2. 不安装 Argo（仅免流/Reality/SS 节点）"
    skyblue "------------------------------------"
    reading "请输入选择(1-2，回车默认1): " argo_choice

    case "${argo_choice}" in
        2) ARGO_MODE="no"  ;;
        *) ARGO_MODE="yes" ;;
    esac
    mkdir -p "${work_dir}"
    echo "${ARGO_MODE}" > "${argo_mode_conf}"

    case "${ARGO_MODE}" in
        yes) green  "已选择：安装 Argo" ;;
        no)  yellow "已选择：不安装 Argo" ;;
    esac
    echo ""
}

# ============================================================
# ask_reality_mode
# ============================================================
ask_reality_mode() {
    echo ""
    green  "是否安装 VLESS Reality 节点？"
    skyblue "----------------------------------------"
    green  "1. 安装 Reality（VLESS+TCP+TLS）"
    green  "2. 不安装 Reality（默认）"
    skyblue "----------------------------------------"
    reading "请输入选择(1-2，回车默认2): " reality_choice

    case "${reality_choice}" in
        1) REALITY_MODE="yes" ;;
        *) REALITY_MODE="no"  ;;
    esac
    mkdir -p "${work_dir}"
    echo "${REALITY_MODE}" > "${reality_mode_conf}"

    if [ "${REALITY_MODE}" = "yes" ]; then
        reading "请输入 Reality SNI（回车默认 www.cloudflare.com）: " r_sni
        reading "请输入 Reality 监听端口（回车默认 443）: " r_port
        [ -z "${r_sni}" ] && r_sni="www.cloudflare.com"
        if ! echo "${r_port}" | grep -qE '^[0-9]+$' || \
           [ "${r_port}" -lt 1 ] 2>/dev/null || [ "${r_port}" -gt 65535 ] 2>/dev/null; then
            r_port="443"
        fi
        REALITY_SNI="${r_sni}"
        REALITY_PORT="${r_port}"
        printf '%s\n%s\n' "${REALITY_SNI}" "${REALITY_PORT}" > "${reality_conf}"
        green "已选择：安装 Reality（SNI=${REALITY_SNI}，Port=${REALITY_PORT}）"
    else
        yellow "已选择：不安装 Reality"
    fi
    echo ""
}

# ============================================================
# ask_freeflow_mode
# 交互选择免流协议和 path，持久化 FREEFLOW_MODE + FF_PATH
# ============================================================
ask_freeflow_mode() {
    echo ""
    green  "请选择免流方式："
    skyblue "-----------------------------"
    green  "1. VLESS + WS  （明文 WebSocket，port 80）"
    green  "2. VLESS + HTTPUpgrade （HTTP 升级，port 80）"
    green  "3. 不安装免流节点（默认）"
    skyblue "-----------------------------"
    reading "请输入选择(1-3，回车默认3): " ff_choice

    case "${ff_choice}" in
        1) FREEFLOW_MODE="ws"          ;;
        2) FREEFLOW_MODE="httpupgrade" ;;
        *) FREEFLOW_MODE="none"        ;;
    esac

    if [ "${FREEFLOW_MODE}" != "none" ]; then
        reading "请输入免流 path（回车默认 /）: " ff_path_input
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
        ws)          green  "已选择：VLESS+WS 免流（path=${FF_PATH}）"          ;;
        httpupgrade) green  "已选择：VLESS+HTTPUpgrade 免流（path=${FF_PATH}）" ;;
        none)        yellow "不安装免流节点"                                     ;;
    esac
    echo ""
}

# ============================================================
# ask_ss_mode
# 交互选择是否安装 Shadowsocks 及参数，持久化到 ss.conf
# ============================================================
ask_ss_mode() {
    echo ""
    green  "是否安装 Shadowsocks 节点？"
    skyblue "--------------------------------------------"
    green  "1. 安装 Shadowsocks（SS+TCP/UDP）"
    green  "2. 不安装（默认）"
    skyblue "--------------------------------------------"
    reading "请输入选择(1-2，回车默认2): " ss_choice

    case "${ss_choice}" in
        1) SS_MODE="yes" ;;
        *) SS_MODE="no"  ;;
    esac

    if [ "${SS_MODE}" = "yes" ]; then
        reading "请输入 SS 监听端口（回车默认 8388）: " ss_p
        if ! echo "${ss_p}" | grep -qE '^[0-9]+$' || \
           [ "${ss_p}" -lt 1 ] 2>/dev/null || [ "${ss_p}" -gt 65535 ] 2>/dev/null; then
            ss_p="8388"
        fi
        reading "请输入 SS 密码（回车自动生成）: " ss_pw
        [ -z "${ss_pw}" ] && ss_pw=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-16)

        echo ""
        green  "请选择加密方式："
        skyblue "-----------------------------"
        green  "1. aes-256-gcm（默认，推荐）"
        green  "2. aes-128-gcm"
        green  "3. chacha20-poly1305"
        green  "4. xchacha20-poly1305"
        skyblue "-----------------------------"
        reading "请输入选择(1-4，回车默认1): " ss_m
        case "${ss_m}" in
            2) SS_METHOD="aes-128-gcm"       ;;
            3) SS_METHOD="chacha20-poly1305"  ;;
            4) SS_METHOD="xchacha20-poly1305" ;;
            *) SS_METHOD="aes-256-gcm"        ;;
        esac

        SS_PORT="${ss_p}"
        SS_PASSWORD="${ss_pw}"
        _save_ss_conf
        green "已选择：安装 Shadowsocks（Port=${SS_PORT}，Method=${SS_METHOD}）"
    else
        _save_ss_conf
        yellow "已选择：不安装 Shadowsocks"
    fi
    echo ""
}

# ============================================================
# get_freeflow_inbound_json <uuid>
# 根据 FREEFLOW_MODE / FF_PATH 输出免流 inbound JSON 字符串
# ============================================================
get_freeflow_inbound_json() {
    local uuid="$1"
    case "${FREEFLOW_MODE}" in
        ws)
            cat << EOF
{
  "port": 80, "listen": "::", "protocol": "vless",
  "settings": { "clients": [{ "id": "${uuid}" }], "decryption": "none" },
  "streamSettings": {
    "network": "ws", "security": "none",
    "wsSettings": { "path": "${FF_PATH}" }
  },
  "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }
}
EOF
            ;;
        httpupgrade)
            cat << EOF
{
  "port": 80, "listen": "::", "protocol": "vless",
  "settings": { "clients": [{ "id": "${uuid}" }], "decryption": "none" },
  "streamSettings": {
    "network": "httpupgrade", "security": "none",
    "httpupgradeSettings": { "path": "${FF_PATH}" }
  },
  "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }
}
EOF
            ;;
    esac
}

# ============================================================
# get_reality_inbound_json <uuid> <private_key> <short_id>
# 输出 Reality inbound JSON 字符串
# ============================================================
get_reality_inbound_json() {
    local uuid="$1" privkey="$2" shortid="$3"
    cat << EOF
{
  "port": ${REALITY_PORT}, "listen": "::", "protocol": "vless",
  "settings": {
    "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "${REALITY_SNI}:${REALITY_PORT}",
      "serverNames": ["${REALITY_SNI}"],
      "privateKey": "${privkey}",
      "shortIds": ["${shortid}"]
    }
  },
  "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }
}
EOF
}

# ============================================================
# get_ss_inbound_json
# 输出 Shadowsocks inbound JSON 字符串
# ============================================================
get_ss_inbound_json() {
    cat << EOF
{
  "port": ${SS_PORT}, "listen": "::", "protocol": "shadowsocks",
  "settings": {
    "method": "${SS_METHOD}",
    "password": "${SS_PASSWORD}",
    "network": "tcp,udp"
  },
  "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }
}
EOF
}

# ============================================================
# inbounds 下标计算
# 布局：[Argo?][Reality?][FreeFlow?][SS?]
# ============================================================
calc_reality_index() {
    if [ "${ARGO_MODE}" = "yes" ]; then echo 1; else echo 0; fi
}

calc_freeflow_index() {
    local idx=0
    [ "${ARGO_MODE}"    = "yes" ] && idx=$(( idx + 1 ))
    [ "${REALITY_MODE}" = "yes" ] && idx=$(( idx + 1 ))
    echo $idx
}

calc_ss_index() {
    local idx=0
    [ "${ARGO_MODE}"         = "yes"  ] && idx=$(( idx + 1 ))
    [ "${REALITY_MODE}"      = "yes"  ] && idx=$(( idx + 1 ))
    [ "${FREEFLOW_MODE}"    != "none" ] && idx=$(( idx + 1 ))
    echo $idx
}

# ============================================================
# _jq_set_inbound <idx> <json_str>
# 在 inbounds[$idx] 写入或替换 inbound；数组不足则用空对象填充
# ============================================================
_jq_set_inbound() {
    local idx="$1" ib_json="$2"
    jq --argjson ib "${ib_json}" --argjson idx "${idx}" '
        (.inbounds | length) as $len |
        if $len > $idx then .inbounds[$idx] = $ib
        else .inbounds = (.inbounds + [range($idx - $len + 1) | {}]) | .inbounds[$idx] = $ib
        end
    ' "${config_dir}" > "${config_dir}.tmp" \
        && mv "${config_dir}.tmp" "${config_dir}"
}

# ============================================================
# _jq_del_inbound <idx> <match>
# 安全删除 inbounds[$idx]：仅当协议/security/network 匹配 match 时才删除
# ============================================================
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
    ' "${config_dir}" > "${config_dir}.tmp" \
        && mv "${config_dir}.tmp" "${config_dir}"
}

# ============================================================
# apply_reality_config
# ============================================================
apply_reality_config() {
    local cur_uuid privkey shortid ri_json
    cur_uuid=$(get_current_uuid)
    [ -z "$cur_uuid" ] || [ "$cur_uuid" = "null" ] && cur_uuid="${UUID}"

    case "${REALITY_MODE}" in
        yes)
            local keys_file="${work_dir}/reality_keys.conf"
            if [ ! -f "${keys_file}" ]; then
                local key_out pubkey_gen
                key_out=$("${work_dir}/${server_name}" x25519 2>/dev/null)
                privkey=$(echo "${key_out}"    | grep -i 'Private key' | awk '{print $NF}')
                pubkey_gen=$(echo "${key_out}" | grep -i 'Public key'  | awk '{print $NF}')
                shortid=$(openssl rand -hex 8 2>/dev/null || \
                    cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-16)
                printf '%s\n%s\n%s\n' "${privkey}" "${pubkey_gen}" "${shortid}" > "${keys_file}"
            else
                privkey=$(sed -n '1p' "${keys_file}")
                shortid=$(sed -n '3p' "${keys_file}")
            fi
            ri_json=$(get_reality_inbound_json "${cur_uuid}" "${privkey}" "${shortid}")
            _jq_set_inbound "$(calc_reality_index)" "${ri_json}"
            ;;
        no)
            _jq_del_inbound "$(calc_reality_index)" "reality"
            ;;
    esac
}

# ============================================================
# apply_freeflow_config
# ============================================================
apply_freeflow_config() {
    local cur_uuid ff_json
    cur_uuid=$(get_current_uuid)
    [ -z "$cur_uuid" ] || [ "$cur_uuid" = "null" ] && cur_uuid="${UUID}"

    case "${FREEFLOW_MODE}" in
        ws|httpupgrade)
            ff_json=$(get_freeflow_inbound_json "${cur_uuid}")
            _jq_set_inbound "$(calc_freeflow_index)" "${ff_json}"
            ;;
        none)
            # 删除时需区分当前实际 network（ws 或 httpupgrade）
            local cur_net
            cur_net=$(jq -r --argjson idx "$(calc_freeflow_index)" \
                '.inbounds[$idx].streamSettings.network // ""' "${config_dir}" 2>/dev/null)
            _jq_del_inbound "$(calc_freeflow_index)" "${cur_net:-ws}"
            ;;
    esac
}

# ============================================================
# apply_ss_config
# ============================================================
apply_ss_config() {
    case "${SS_MODE}" in
        yes) _jq_set_inbound "$(calc_ss_index)" "$(get_ss_inbound_json)" ;;
        no)  _jq_del_inbound "$(calc_ss_index)" "shadowsocks"            ;;
    esac
}

# ============================================================
# install_xray
# 下载 xray（+ cloudflared 当 ARGO_MODE=yes），写入 config.json
# ============================================================
install_xray() {
    clear
    purple "正在安装 Xray-2go（精简版），请稍等..."

    local ARCH_RAW ARCH ARCH_ARG
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64')            ARCH='amd64'; ARCH_ARG='64'        ;;
        'x86'|'i686'|'i386') ARCH='386';  ARCH_ARG='32'        ;;
        'aarch64'|'arm64')   ARCH='arm64'; ARCH_ARG='arm64-v8a' ;;
        'armv7l')            ARCH='armv7'; ARCH_ARG='arm32-v7a' ;;
        's390x')             ARCH='s390x'; ARCH_ARG='s390x'     ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    mkdir -p "${work_dir}" && chmod 755 "${work_dir}"

    # 检测并跳过已存在的二进制文件
    if [ ! -f "${work_dir}/${server_name}" ]; then
        curl -sLo "${work_dir}/${server_name}.zip" \
            "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_ARG}.zip" \
            || { red "xray 下载失败，请检查网络"; exit 1; }
        unzip "${work_dir}/${server_name}.zip" -d "${work_dir}/" > /dev/null 2>&1 \
            || { red "xray 解压失败"; exit 1; }
        chmod +x "${work_dir}/${server_name}"
        rm -rf "${work_dir}/${server_name}.zip" \
               "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" \
               "${work_dir}/README.md"   "${work_dir}/LICENSE"
    else
        green "xray 二进制已存在，跳过下载"
    fi

    if [ "${ARGO_MODE}" = "yes" ] && [ ! -f "${work_dir}/argo" ]; then
        curl -sLo "${work_dir}/argo" \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" \
            || { red "cloudflared 下载失败，请检查网络"; exit 1; }
        chmod +x "${work_dir}/argo"
    elif [ "${ARGO_MODE}" = "yes" ]; then
        green "cloudflared 二进制已存在，跳过下载"
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
        cat > "${config_dir}" << EOF
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

    # 按布局顺序依次写入各 inbound
    [ "${REALITY_MODE}"  = "yes"  ] && apply_reality_config
    [ "${FREEFLOW_MODE}" != "none" ] && apply_freeflow_config
    [ "${SS_MODE}"       = "yes"  ] && apply_ss_config
}

# ============================================================
# main_systemd_services
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

# ============================================================
# alpine_openrc_services
# ============================================================
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

# change_hosts（Alpine 专用）
change_hosts() {
    echo "0 0" > /proc/sys/net/ipv4/ping_group_range
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

# ============================================================
# reset_tunnel_to_temp
# ============================================================
reset_tunnel_to_temp() {
    if [ -f /etc/alpine-release ]; then
        sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> /etc/xray/argo.log 2>&1'\"" \
            /etc/init.d/tunnel
    else
        sed -i "/^ExecStart=/c\\ExecStart=${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2" \
            /etc/systemd/system/tunnel.service
    fi
}

# ============================================================
# restart_xray / restart_argo
# ============================================================
restart_xray() {
    if [ -f /etc/alpine-release ]; then rc-service xray restart
    else systemctl daemon-reload && systemctl restart xray; fi
}

restart_argo() {
    rm -f "${work_dir}/argo.log"
    if [ -f /etc/alpine-release ]; then rc-service tunnel restart
    else systemctl daemon-reload && systemctl restart tunnel; fi
}

# ============================================================
# get_argodomain
# 从 argo.log 提取 trycloudflare.com 子域
# ============================================================
get_argodomain() {
    sleep 3
    local domain i=1
    while [ "$i" -le 5 ]; do
        domain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' \
            "${work_dir}/argo.log" 2>/dev/null | head -1)
        [ -n "$domain" ] && echo "$domain" && return 0
        sleep 2
        i=$(( i + 1 ))
    done
    echo ""; return 1
}

# ============================================================
# print_nodes
# ============================================================
print_nodes() {
    echo ""
    if [ ! -f "${client_dir}" ]; then
        yellow "节点文件不存在，请先安装或重新获取节点信息"
        return 1
    fi
    while IFS= read -r line; do
        [ -n "$line" ] && printf '\033[1;35m%s\033[0m\n' "$line"
    done < "${client_dir}"
    echo ""
}

# ============================================================
# build_freeflow_link <ip>
# 根据 FREEFLOW_MODE / FF_PATH 输出免流节点链接
# ============================================================
build_freeflow_link() {
    local ip="$1" uuid path_enc
    uuid=$(get_current_uuid)
    # 对 path 中的空格和 % 做基础编码（/ 保留）
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

# ============================================================
# build_reality_link <ip>
# ============================================================
build_reality_link() {
    local ip="$1" uuid pubkey shortid
    local keys_file="${work_dir}/reality_keys.conf"
    uuid=$(get_current_uuid)
    pubkey=$(sed -n '2p' "${keys_file}" 2>/dev/null)
    shortid=$(sed -n '3p' "${keys_file}" 2>/dev/null)
    echo "vless://${uuid}@${ip}:${REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${pubkey}&sid=${shortid}&type=tcp&flow=xtls-rprx-vision#Reality"
}

# ============================================================
# build_ss_link <ip>
# SIP002 格式：ss://base64(method:password)@host:port
# ============================================================
build_ss_link() {
    local ip="$1" userinfo
    userinfo=$(printf '%s:%s' "${SS_METHOD}" "${SS_PASSWORD}" | base64 | tr -d '\n')
    echo "ss://${userinfo}@${ip}:${SS_PORT}#SS-${SS_METHOD}"
}

# ============================================================
# get_info
# 生成 url.txt 并打印；行顺序：Argo | Reality | FreeFlow | SS
# ============================================================
get_info() {
    clear
    local IP
    IP=$(get_realip)
    [ -z "$IP" ] && yellow "警告：无法获取服务器 IP，依赖 IP 的节点链接将缺失"

    # 颜色提示输出到 stderr，节点链接输出到 stdout，再重定向 stdout 到 url.txt
    {
        if [ "${ARGO_MODE}" = "yes" ]; then
            local cur_uuid argodomain
            cur_uuid=$(get_current_uuid)
            purple "正在获取 ArgoDomain，请稍等..." >&2
            restart_argo
            argodomain=$(get_argodomain)
            if [ -z "$argodomain" ]; then
                yellow "未能获取 ArgoDomain，可稍后通过 Argo 管理菜单重新获取" >&2
                argodomain="<未获取到域名>"
            else
                green "ArgoDomain：${argodomain}" >&2
            fi
            echo "vless://${cur_uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#Argo"
        fi
        [ "${REALITY_MODE}"  = "yes"  ] && [ -n "$IP" ] && build_reality_link  "${IP}"
        [ "${FREEFLOW_MODE}" != "none" ] && [ -n "$IP" ] && build_freeflow_link "${IP}"
        [ "${SS_MODE}"       = "yes"  ] && [ -n "$IP" ] && build_ss_link        "${IP}"
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
    if [ -z "$argodomain" ]; then
        yellow "未能获取临时域名，请检查网络或稍后重试"; return 1
    fi
    green "ArgoDomain：${argodomain}"
    sed -i "1s/sni=[^&]*/sni=${argodomain}/; 1s/host=[^&]*/host=${argodomain}/" "${client_dir}"
    print_nodes
    green "节点已更新，请手动复制以上链接"
}

# ============================================================
# _update_reality_url <ip>  原地替换 url.txt 中的 Reality 行
# ============================================================
_update_reality_url() {
    local ip="$1" new_link escaped
    new_link=$(build_reality_link "${ip}")
    if grep -q 'security=reality' "${client_dir}" 2>/dev/null; then
        escaped=$(printf '%s\n' "${new_link}" | sed 's/[\/&]/\\&/g')
        sed -i "/security=reality/c\\${escaped}" "${client_dir}"
    fi
}

# ============================================================
# _update_ss_url <ip>  原地替换 url.txt 中的 SS 行
# ============================================================
_update_ss_url() {
    local ip="$1" new_link escaped
    new_link=$(build_ss_link "${ip}")
    if grep -q '^ss://' "${client_dir}" 2>/dev/null; then
        escaped=$(printf '%s\n' "${new_link}" | sed 's/[\/&]/\\&/g')
        sed -i "/^ss:\/\//c\\${escaped}" "${client_dir}"
    fi
}

# ============================================================
# _update_freeflow_url <ip>  原地替换 url.txt 中的免流行
# ============================================================
_update_freeflow_url() {
    local ip="$1" new_link escaped
    new_link=$(build_freeflow_link "${ip}")
    if grep -q '#FreeFlow' "${client_dir}" 2>/dev/null; then
        escaped=$(printf '%s\n' "${new_link}" | sed 's/[\/&]/\\&/g')
        sed -i "/#FreeFlow/c\\${escaped}" "${client_dir}"
    fi
}

# ============================================================
# manage_argo - Argo 隧道管理
# ============================================================
manage_argo() {
    if [ "${ARGO_MODE}" != "yes" ]; then
        yellow "未安装 Argo，Argo 管理不可用"; sleep 1; menu; return
    fi
    local cx
    check_argo > /dev/null 2>&1; cx=$?
    if [ "$cx" -eq 2 ]; then
        yellow "Argo 尚未安装！"; sleep 1; menu; return
    fi
    clear; echo ""
    green  "1. 启动 Argo 服务";            skyblue "----------------"
    green  "2. 停止 Argo 服务";            skyblue "----------------"
    green  "3. 添加固定隧道（token/json）"; skyblue "----------------------------------"
    green  "4. 切换回临时隧道";             skyblue "-----------------------"
    green  "5. 重新获取临时域名";           skyblue "------------------------"
    purple "6. 返回主菜单";                skyblue "------------"
    reading "请输入选择: " choice

    case "${choice}" in
        1)
            if [ -f /etc/alpine-release ]; then rc-service tunnel start
            else systemctl start tunnel; fi
            green "Argo 已启动"
            ;;
        2)
            if [ -f /etc/alpine-release ]; then rc-service tunnel stop
            else systemctl stop tunnel; fi
            green "Argo 已停止"
            ;;
        3)
            yellow "固定隧道回源端口为 ${ARGO_PORT}，请在 CF 后台配置对应 ingress"
            echo ""
            reading "请输入你的 Argo 域名: " argo_domain
            [ -z "$argo_domain" ] && red "Argo 域名不能为空" && return
            reading "请输入 Argo 密钥（token 或 json）: " argo_auth

            if echo "$argo_auth" | grep -q "TunnelSecret"; then
                local tunnel_id
                tunnel_id=$(echo "$argo_auth" | cut -d'"' -f12)
                echo "$argo_auth" > "${work_dir}/tunnel.json"
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
                if [ -f /etc/alpine-release ]; then
                    sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --edge-ip-version auto --config /etc/xray/tunnel.yml run >> /etc/xray/argo.log 2>&1'\"" \
                        /etc/init.d/tunnel
                else
                    sed -i "/^ExecStart=/c\\ExecStart=/bin/sh -c '/etc/xray/argo tunnel --edge-ip-version auto --config /etc/xray/tunnel.yml run >> /etc/xray/argo.log 2>&1'" \
                        /etc/systemd/system/tunnel.service
                fi
            elif echo "$argo_auth" | grep -qE '^[A-Z0-9a-z=]{120,250}$'; then
                if [ -f /etc/alpine-release ]; then
                    sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_auth} >> /etc/xray/argo.log 2>&1'\"" \
                        /etc/init.d/tunnel
                else
                    sed -i "/^ExecStart=/c\\ExecStart=/bin/sh -c '/etc/xray/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_auth} >> /etc/xray/argo.log 2>&1'" \
                        /etc/systemd/system/tunnel.service
                fi
            else
                yellow "token 或 json 格式不匹配，请重新输入"
                manage_argo; return
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
            if [ -f /etc/alpine-release ]; then
                grep -Fq -- "--url http://localhost:${ARGO_PORT}" /etc/init.d/tunnel \
                    && using_temp="true"
            else
                grep -Fq -- "--url http://localhost:${ARGO_PORT}" \
                    /etc/systemd/system/tunnel.service && using_temp="true"
            fi
            if [ "$using_temp" = "true" ]; then
                get_quick_tunnel
            else
                yellow "当前使用固定隧道，无法获取临时域名"
                sleep 2; menu
            fi
            ;;
        6) menu ;;
        *) red "无效的选项！" ;;
    esac
}

# ============================================================
# manage_reality - Reality 节点管理
# ============================================================
manage_reality() {
    if [ "${REALITY_MODE}" != "yes" ]; then
        yellow "未安装 Reality，此管理不可用"; sleep 1; menu; return
    fi
    clear; echo ""
    green  "Reality 当前配置："
    skyblue "  SNI  : ${REALITY_SNI}"
    skyblue "  Port : ${REALITY_PORT}"
    echo   "=========================="
    green  "1. 修改 SNI"
    green  "2. 修改监听端口"
    purple "3. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice

    case "${choice}" in
        1)
            reading "请输入新的 SNI（回车保持当前 ${REALITY_SNI}）: " new_sni
            [ -z "${new_sni}" ] && new_sni="${REALITY_SNI}"
            REALITY_SNI="${new_sni}"
            printf '%s\n%s\n' "${REALITY_SNI}" "${REALITY_PORT}" > "${reality_conf}"
            apply_reality_config
            restart_xray
            local IP; IP=$(get_realip)
            [ -n "$IP" ] && _update_reality_url "${IP}"
            green "SNI 已修改为：${REALITY_SNI}"
            print_nodes
            ;;
        2)
            reading "请输入新的监听端口（回车保持当前 ${REALITY_PORT}）: " new_rp
            if [ -z "${new_rp}" ]; then
                new_rp="${REALITY_PORT}"
            elif ! echo "${new_rp}" | grep -qE '^[0-9]+$' || \
                 [ "${new_rp}" -lt 1 ] || [ "${new_rp}" -gt 65535 ]; then
                red "端口无效，请输入 1-65535 的整数"; return
            fi
            REALITY_PORT="${new_rp}"
            printf '%s\n%s\n' "${REALITY_SNI}" "${REALITY_PORT}" > "${reality_conf}"
            apply_reality_config
            restart_xray
            local IP; IP=$(get_realip)
            [ -n "$IP" ] && _update_reality_url "${IP}"
            green "Reality 端口已修改为：${REALITY_PORT}"
            print_nodes
            ;;
        3) menu ;;
        *) red "无效的选项！" ;;
    esac
}

# ============================================================
# manage_ss - Shadowsocks 节点管理
# ============================================================
manage_ss() {
    if [ "${SS_MODE}" != "yes" ]; then
        yellow "未安装 Shadowsocks，此管理不可用"; sleep 1; menu; return
    fi
    clear; echo ""
    green  "Shadowsocks 当前配置："
    skyblue "  Port    : ${SS_PORT}"
    skyblue "  Method  : ${SS_METHOD}"
    skyblue "  Password: ${SS_PASSWORD}"
    echo   "=============================="
    green  "1. 修改端口"
    green  "2. 修改密码"
    green  "3. 修改加密方式"
    purple "4. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice

    case "${choice}" in
        1)
            reading "请输入新的端口（回车保持当前 ${SS_PORT}）: " new_sp
            if [ -z "${new_sp}" ]; then
                new_sp="${SS_PORT}"
            elif ! echo "${new_sp}" | grep -qE '^[0-9]+$' || \
                 [ "${new_sp}" -lt 1 ] || [ "${new_sp}" -gt 65535 ]; then
                red "端口无效，请输入 1-65535 的整数"; return
            fi
            SS_PORT="${new_sp}"
            _save_ss_conf
            apply_ss_config
            restart_xray
            local IP; IP=$(get_realip)
            [ -n "$IP" ] && _update_ss_url "${IP}"
            green "SS 端口已修改为：${SS_PORT}"
            print_nodes
            ;;
        2)
            reading "请输入新的密码（回车自动生成）: " new_pw
            [ -z "${new_pw}" ] && new_pw=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-16)
            SS_PASSWORD="${new_pw}"
            _save_ss_conf
            apply_ss_config
            restart_xray
            local IP; IP=$(get_realip)
            [ -n "$IP" ] && _update_ss_url "${IP}"
            green "SS 密码已修改"
            print_nodes
            ;;
        3)
            echo ""
            green  "请选择加密方式："
            skyblue "-----------------------------"
            green  "1. aes-256-gcm（推荐）"
            green  "2. aes-128-gcm"
            green  "3. chacha20-poly1305"
            green  "4. xchacha20-poly1305"
            skyblue "-----------------------------"
            reading "请输入选择(1-4): " m_choice
            case "${m_choice}" in
                2) SS_METHOD="aes-128-gcm"       ;;
                3) SS_METHOD="chacha20-poly1305"  ;;
                4) SS_METHOD="xchacha20-poly1305" ;;
                *) SS_METHOD="aes-256-gcm"        ;;
            esac
            _save_ss_conf
            apply_ss_config
            restart_xray
            local IP; IP=$(get_realip)
            [ -n "$IP" ] && _update_ss_url "${IP}"
            green "SS 加密方式已修改为：${SS_METHOD}"
            print_nodes
            ;;
        4) menu ;;
        *) red "无效的选项！" ;;
    esac
}

# ============================================================
# change_config - 修改 UUID / Argo 端口 / 免流方式 / 免流 path
# ============================================================
change_config() {
    local ff_label
    case "${FREEFLOW_MODE}" in
        ws)          ff_label="VLESS+WS（当前，path=${FF_PATH}）"          ;;
        httpupgrade) ff_label="VLESS+HTTPUpgrade（当前，path=${FF_PATH}）" ;;
        none)        ff_label="未安装（当前）"                              ;;
        *)           ff_label="未知"                                       ;;
    esac

    clear; echo ""
    green  "1. 修改 UUID"
    skyblue "------------"
    if [ "${ARGO_MODE}" = "yes" ]; then
        green  "2. 修改 Argo 回源端口（当前：${ARGO_PORT}）"
        skyblue "-------------------------------------------"
    fi
    green  "3. 变更免流方式（${ff_label}）"
    skyblue "--------------------------------"
    if [ "${FREEFLOW_MODE}" != "none" ]; then
        green  "4. 修改免流 path（当前：${FF_PATH}）"
        skyblue "------------------------------------"
    fi
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice

    case "${choice}" in
        1)
            reading "请输入新的 UUID（回车自动生成）: " new_uuid
            if [ -z "$new_uuid" ]; then
                new_uuid=$(cat /proc/sys/kernel/random/uuid)
                green "生成的 UUID：$new_uuid"
            fi
            sed -i "s/[a-fA-F0-9]\{8\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{12\}/$new_uuid/g" \
                "$config_dir" "$client_dir"
            export UUID=$new_uuid
            restart_xray
            green "UUID 已修改为：${new_uuid}"
            print_nodes
            ;;
        2)
            if [ "${ARGO_MODE}" != "yes" ]; then
                red "无效的选项！"; return
            fi
            reading "请输入新的 Argo 回源端口（回车随机）: " new_port
            [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
            if ! echo "$new_port" | grep -qE '^[0-9]+$' || \
               [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                red "端口无效，请输入 1-65535 的整数"; return
            fi
            jq --argjson p "$new_port" '.inbounds[0].port = $p' "$config_dir" \
                > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
            if [ -f /etc/alpine-release ]; then
                sed -i "s|http://localhost:[0-9]*|http://localhost:${new_port}|g" /etc/init.d/tunnel
            else
                sed -i "s|http://localhost:[0-9]*|http://localhost:${new_port}|g" \
                    /etc/systemd/system/tunnel.service
            fi
            export ARGO_PORT=$new_port
            restart_xray && restart_argo
            green "Argo 回源端口已修改为：${new_port}"
            ;;
        3)
            if [ ! -f "${client_dir}" ]; then
                yellow "节点文件不存在，请先完成安装后再变更免流方式"; return
            fi
            local old_mode="${FREEFLOW_MODE}"
            ask_freeflow_mode
            # 模式或 path 有任一变更均需重新应用
            apply_freeflow_config
            # 重建 url.txt（保留其他协议行，刷新免流行）
            local ip_now; ip_now=$(get_realip)
            {
                [ "${ARGO_MODE}"    = "yes"  ] && grep '#Argo$'           "${client_dir}" 2>/dev/null
                [ "${REALITY_MODE}" = "yes"  ] && grep 'security=reality' "${client_dir}" 2>/dev/null
                [ "${FREEFLOW_MODE}" != "none" ] && [ -n "$ip_now" ] && build_freeflow_link "${ip_now}"
                [ "${SS_MODE}"      = "yes"  ] && grep '^ss://'           "${client_dir}" 2>/dev/null
            } > "${client_dir}.new" && mv "${client_dir}.new" "${client_dir}"
            restart_xray
            green "免流方式已变更"
            print_nodes
            ;;
        4)
            if [ "${FREEFLOW_MODE}" = "none" ]; then
                red "无效的选项！"; return
            fi
            reading "请输入新的免流 path（回车保持当前 ${FF_PATH}）: " new_path
            if [ -z "${new_path}" ]; then
                new_path="${FF_PATH}"
            else
                case "${new_path}" in
                    /*) : ;;
                    *)  new_path="/${new_path}" ;;
                esac
            fi
            FF_PATH="${new_path}"
            _save_freeflow_conf
            apply_freeflow_config
            local ip_now; ip_now=$(get_realip)
            [ -n "$ip_now" ] && _update_freeflow_url "${ip_now}"
            restart_xray
            green "免流 path 已修改为：${FF_PATH}"
            print_nodes
            ;;
        0) menu ;;
        *) red "无效的选项！" ;;
    esac
}

# ============================================================
# check_nodes - 打印当前节点链接
# ============================================================
check_nodes() {
    local cx
    check_xray > /dev/null 2>&1; cx=$?
    if [ "$cx" -eq 0 ]; then
        print_nodes
    else
        yellow "Xray-2go 尚未安装或未运行"
        sleep 1; menu
    fi
}

# ============================================================
# uninstall_xray - 停止服务，删除服务文件和工作目录
# ============================================================
uninstall_xray() {
    reading "确定要卸载 xray-2go 吗？(y/n): " choice
    case "${choice}" in
        y|Y)
            yellow "正在卸载..."
            if [ -f /etc/alpine-release ]; then
                rc-service xray stop 2>/dev/null
                rc-update del xray default 2>/dev/null
                rm -f /etc/init.d/xray
                if [ "${ARGO_MODE}" = "yes" ]; then
                    rc-service tunnel stop 2>/dev/null
                    rc-update del tunnel default 2>/dev/null
                    rm -f /etc/init.d/tunnel
                fi
            else
                systemctl stop xray 2>/dev/null
                systemctl disable xray 2>/dev/null
                rm -f /etc/systemd/system/xray.service
                if [ "${ARGO_MODE}" = "yes" ]; then
                    systemctl stop tunnel 2>/dev/null
                    systemctl disable tunnel 2>/dev/null
                    rm -f /etc/systemd/system/tunnel.service
                fi
                systemctl daemon-reload
            fi
            rm -rf "${work_dir}"
            rm -f "${shortcut_path}" /usr/local/bin/xray2go
            green "Xray-2go 卸载完成"
            ;;
        *) purple "已取消卸载" ;;
    esac
}

trap 'red "已取消操作"; exit' INT

# ============================================================
# menu - 主菜单
# ============================================================
menu() {
    while true; do
        local xray_status argo_status cx ff_display argo_display reality_display ss_display
        xray_status=$(check_xray); cx=$?
        argo_status=$(check_argo)
        case "${FREEFLOW_MODE}" in
            ws)          ff_display="WS（path=${FF_PATH}）"          ;;
            httpupgrade) ff_display="HTTPUpgrade（path=${FF_PATH}）" ;;
            none)        ff_display="无"                              ;;
            *)           ff_display="未知"                           ;;
        esac
        if [ "${ARGO_MODE}" = "yes" ]; then
            argo_display="${argo_status}"
        else
            argo_display="未启用"
        fi
        if [ "${REALITY_MODE}" = "yes" ]; then
            reality_display="已启用（SNI=${REALITY_SNI} Port=${REALITY_PORT}）"
        else
            reality_display="未启用"
        fi
        if [ "${SS_MODE}" = "yes" ]; then
            ss_display="已启用（Port=${SS_PORT} ${SS_METHOD}）"
        else
            ss_display="未启用"
        fi

        clear; echo ""
        purple "=== Xray-2go 精简版 ==="
        purple " Xray 状态:   ${xray_status}"
        purple " Argo 状态:   ${argo_display}"
        purple " Reality:     ${reality_display}"
        purple " 免流模式:    ${ff_display}"
        purple " Shadowsocks: ${ss_display}"
        echo   "========================"
        green  "1. 安装 Xray-2go"
        red    "2. 卸载 Xray-2go"
        echo   "================="
        green  "3. Argo 隧道管理"
        green  "4. Reality 管理"
        green  "5. Shadowsocks 管理"
        echo   "================="
        green  "6. 查看节点信息"
        green  "7. 修改节点配置"
        echo   "================="
        red    "0. 退出脚本"
        echo   "==========="
        reading "请输入选择(0-7): " choice
        echo ""

        case "${choice}" in
            1)
                if [ "$cx" -eq 0 ]; then
                    yellow "Xray-2go 已安装！"
                else
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
                        rc-service xray restart
                        [ "${ARGO_MODE}" = "yes" ] && rc-service tunnel restart
                    else
                        red "不支持的 init 系统"; exit 1
                    fi
                    install_shortcut
                    get_info
                fi
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

# ── 安装快捷方式（若未存在） ─────────────────────────────────
[ ! -f "${shortcut_path}" ] && install_shortcut 2>/dev/null || true

menu
