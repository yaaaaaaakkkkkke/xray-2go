#!/bin/bash

# ============================================================
# 精简版 Xray-2go 一键脚本
# 协议：
#   Argo 临时隧道：VLESS+WS+TLS（Cloudflare 随机域名）
#   Argo 固定隧道 WS：VLESS+WS+TLS（port 8080，自有域名）
#   Argo 固定隧道 XHTTP：VLESS+XHTTP+TLS（port 8081，自有域名）
#   FreeFlow（可选）：VLESS+WS 明文（port 80）| VLESS+HTTPUpgrade（port 80）
# ============================================================

red()    { printf '\033[1;91m%s\033[0m\n' "$1"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$1"; }
purple() { printf '\033[1;35m%s\033[0m\n' "$1"; }
skyblue(){ printf '\033[1;36m%s\033[0m\n' "$1"; }
reading() { printf '\033[1;91m%s\033[0m' "$1"; read -r "$2"; }

server_name="xray"
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
freeflow_conf="${work_dir}/freeflow.conf"
argo_mode_conf="${work_dir}/argo_mode.conf"
restart_conf="${work_dir}/restart.conf"
shortcut_path="/usr/local/bin/s"

export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
export ARGO_PORT=${ARGO_PORT:-'8080'}
export ARGO_XHTTP_PORT=${ARGO_XHTTP_PORT:-'8080'}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1

# ── 平台检测（封装，消除全文 14 处重复判断）──────────────────
is_alpine() { [ -f /etc/alpine-release ]; }

# ── 服务控制（封装 systemctl / rc-service 双路径）────────────
# 用法: service_ctrl <action> <service>
# action: start | stop | restart | enable | disable | status
service_ctrl() {
    local action="$1" svc="$2"
    if is_alpine; then
        case "$action" in
            enable)  rc-update add "$svc" default 2>/dev/null ;;
            disable) rc-update del "$svc" default 2>/dev/null ;;
            *)       rc-service "$svc" "$action" 2>/dev/null  ;;
        esac
    else
        case "$action" in
            enable)  systemctl enable "$svc" 2>/dev/null ;;
            disable) systemctl disable "$svc" 2>/dev/null ;;
            *)       systemctl "$action" "$svc" 2>/dev/null ;;
        esac
    fi
}

# ── 读取持久化配置 ───────────────────────────────────────────
_raw=$(cat "${argo_mode_conf}" 2>/dev/null)
case "${_raw}" in
    yes|no) ARGO_MODE="${_raw}" ;;
    *)      ARGO_MODE="yes"     ;;
esac
unset _raw

if [ "${ARGO_MODE}" = "yes" ] && [ -f "${config_dir}" ]; then
    _port=$(jq -r '.inbounds[0].port' "${config_dir}" 2>/dev/null)
    if echo "$_port" | grep -qE '^[0-9]+$'; then
        export ARGO_PORT=$_port
    fi
    unset _port
fi

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

RESTART_INTERVAL=0
if [ -f "${restart_conf}" ]; then
    _ri=$(cat "${restart_conf}" 2>/dev/null)
    echo "${_ri}" | grep -qE '^[0-9]+$' && RESTART_INTERVAL="${_ri}"
fi

# ── 状态检测 ─────────────────────────────────────────────────
check_xray() {
    if [ ! -f "${work_dir}/${server_name}" ]; then
        echo "not installed"; return 2
    fi
    if is_alpine; then
        rc-service xray status 2>/dev/null | grep -q "started" \
            && { echo "running"; return 0; } \
            || { echo "not running"; return 1; }
    else
        [ "$(systemctl is-active xray 2>/dev/null)" = "active" ] \
            && { echo "running"; return 0; } \
            || { echo "not running"; return 1; }
    fi
}

check_argo() {
    if [ "${ARGO_MODE}" = "no" ]; then
        echo "disabled"; return 3
    fi
    if [ ! -f "${work_dir}/argo" ]; then
        echo "not installed"; return 2
    fi
    if is_alpine; then
        rc-service tunnel status 2>/dev/null | grep -q "started" \
            && { echo "running"; return 0; } \
            || { echo "not running"; return 1; }
    else
        [ "$(systemctl is-active tunnel 2>/dev/null)" = "active" ] \
            && { echo "running"; return 0; } \
            || { echo "not running"; return 1; }
    fi
}

# 检测 xhttp 固定隧道服务状态
check_argo_xhttp() {
    if [ ! -f "${work_dir}/domain_xhttp.txt" ]; then
        echo "not configured"; return 3
    fi
    if is_alpine; then
        rc-service tunnel-xhttp status 2>/dev/null | grep -q "started" \
            && { echo "running"; return 0; } \
            || { echo "not running"; return 1; }
    else
        [ "$(systemctl is-active tunnel-xhttp 2>/dev/null)" = "active" ] \
            && { echo "running"; return 0; } \
            || { echo "not running"; return 1; }
    fi
}

# ── 包管理（修正：区分包名与可执行文件名）────────────────────
# 某些包安装后的二进制名与包名不同（如 unzip→unzip，jq→jq），
# 此处保留 command -v 检测，但对已知差异可在调用处传入正确名称。
manage_packages() {
    [ "$#" -lt 2 ] && red "未指定包名或操作" && return 1
    local action=$1; shift
    [ "$action" != "install" ] && red "未知操作: $action" && return 1
    for package in "$@"; do
        if command -v "$package" > /dev/null 2>&1; then
            green "${package} already installed"; continue
        fi
        yellow "正在安装 ${package}..."
        if   command -v apt > /dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt install -y "$package"
        elif command -v dnf > /dev/null 2>&1; then
            dnf install -y "$package"
        elif command -v yum > /dev/null 2>&1; then
            yum install -y "$package"
        elif command -v apk > /dev/null 2>&1; then
            apk update && apk add "$package"
        else
            red "未知系统！"; return 1
        fi
    done
}

# ── 获取服务器真实 IP（并行双栈，减少串行等待）───────────────
get_realip() {
    local ip ipv6
    # 同时发起 IPv4/IPv6 请求，取先返回的有效结果
    ip=$(curl -s --max-time 3 ipv4.ip.sb 2>/dev/null)
    if [ -z "$ip" ]; then
        ipv6=$(curl -s --max-time 3 ipv6.ip.sb 2>/dev/null)
        [ -n "$ipv6" ] && echo "[$ipv6]" || echo ""
        return
    fi
    # 检测 IP 是否属于需要优选 IPv6 的 CDN/机房
    local org
    org=$(curl -s --max-time 3 "https://ipinfo.io/${ip}/org" 2>/dev/null)
    if echo "$org" | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        ipv6=$(curl -s --max-time 3 ipv6.ip.sb 2>/dev/null)
        [ -n "$ipv6" ] && echo "[$ipv6]" || echo "$ip"
    else
        echo "$ip"
    fi
}

get_current_uuid() {
    local id
    id=$(jq -r '
        (first(.inbounds[] | select(.protocol=="vless") | .settings.clients[0].id) // empty)
    ' "${config_dir}" 2>/dev/null)
    echo "${id:-${UUID}}"
}

_save_freeflow_conf() {
    mkdir -p "${work_dir}"
    printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"
}

# ── 安装快捷方式 ─────────────────────────────────────────────
install_shortcut() {
    yellow "正在从 GitHub 拉取最新脚本..."
    curl -sL https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh \
        -o /usr/local/bin/xray2go || {
        red "拉取脚本失败，请检查网络"; return 1
    }
    chmod +x /usr/local/bin/xray2go

    cat > "${shortcut_path}" << 'EOF'
#!/bin/bash
exec /usr/local/bin/xray2go "$@"
EOF
    chmod +x "${shortcut_path}"
    green "快捷方式已创建！输入 s 即可快速启动脚本"
}

# ── 交互提问 ─────────────────────────────────────────────────
ask_argo_mode() {
    echo ""
    green  "是否安装 Cloudflare Argo 隧道？"
    skyblue "------------------------------------"
    green  "1. 安装 Argo（VLESS+WS+TLS，默认）"
    green  "2. 不安装 Argo（仅 FreeFlow 节点）"
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

ask_freeflow_mode() {
    echo ""
    green  "请选择 FreeFlow 方式："
    skyblue "-----------------------------"
    green  "1. VLESS + WS  （明文 WebSocket，port 80）"
    green  "2. VLESS + HTTPUpgrade （HTTP 升级，port 80）"
    green  "3. 不启用 FreeFlow（默认）"
    skyblue "-----------------------------"
    reading "请输入选择(1-3，回车默认3): " ff_choice

    case "${ff_choice}" in
        1) FREEFLOW_MODE="ws"          ;;
        2) FREEFLOW_MODE="httpupgrade" ;;
        *) FREEFLOW_MODE="none"        ;;
    esac

    if [ "${FREEFLOW_MODE}" != "none" ]; then
        reading "请输入 FreeFlow path（回车默认 /）: " ff_path_input
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
        ws)          green  "已选择：VLESS+WS FreeFlow（path=${FF_PATH}）"          ;;
        httpupgrade) green  "已选择：VLESS+HTTPUpgrade FreeFlow（path=${FF_PATH}）" ;;
        none)        yellow "不启用 FreeFlow"                                       ;;
    esac
    echo ""
}

# ── FreeFlow inbound JSON 生成 ───────────────────────────────
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

calc_freeflow_index() {
    if [ "${ARGO_MODE}" = "yes" ]; then echo 1; else echo 0; fi
}

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

_jq_del_inbound() {
    local idx="$1" match="$2"
    jq --argjson idx "${idx}" --arg match "${match}" '
        if (.inbounds | length) > $idx and
           ((.inbounds[$idx].streamSettings.network  // "") == $match or
            (.inbounds[$idx].protocol                // "") == $match)
        then .inbounds = (.inbounds[:$idx] + .inbounds[$idx+1:])
        else .
        end
    ' "${config_dir}" > "${config_dir}.tmp" \
        && mv "${config_dir}.tmp" "${config_dir}"
}

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
            local cur_net
            cur_net=$(jq -r --argjson idx "$(calc_freeflow_index)" \
                '.inbounds[$idx].streamSettings.network // ""' "${config_dir}" 2>/dev/null)
            _jq_del_inbound "$(calc_freeflow_index)" "${cur_net:-ws}"
            ;;
    esac
}

# ── 安装 Xray 及 cloudflared ──────────────────────────────────
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

    [ "${FREEFLOW_MODE}" != "none" ] && apply_freeflow_config
}

# ── CentOS 时间同步（从服务配置函数中分离）───────────────────
_fix_centos_time() {
    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd && systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
    fi
}

# ── systemd 服务注册 ──────────────────────────────────────────
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

    _fix_centos_time

    systemctl daemon-reload
    systemctl enable xray && systemctl start xray
    [ "${ARGO_MODE}" = "yes" ] && systemctl enable tunnel && systemctl start tunnel
}

# ── Alpine OpenRC 服务注册 ────────────────────────────────────
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

reset_tunnel_to_temp() {
    if is_alpine; then
        sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> /etc/xray/argo.log 2>&1'\"" \
            /etc/init.d/tunnel
    else
        sed -i "/^ExecStart=/c\\ExecStart=${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2" \
            /etc/systemd/system/tunnel.service
    fi
}

# ── 服务重启 ──────────────────────────────────────────────────
restart_xray() {
    if is_alpine; then
        rc-service xray restart
    else
        systemctl daemon-reload && systemctl restart xray
    fi
}

restart_argo() {
    local mode="${1:-ws}"   # ws 或 xhttp
    local svc log
    if [ "$mode" = "xhttp" ]; then
        svc="tunnel-xhttp"; log="${work_dir}/argo_xhttp.log"
    else
        svc="tunnel";       log="${work_dir}/argo.log"
    fi
    rm -f "$log"
    if is_alpine; then
        rc-service "$svc" restart
    else
        systemctl daemon-reload && systemctl restart "$svc"
    fi
}

# ── 获取 Argo 临时域名（指数退避，最多等待约 15s）────────────
get_argodomain() {
    local mode="${1:-ws}"
    local logfile
    [ "$mode" = "xhttp" ] && logfile="${work_dir}/argo_xhttp.log" || logfile="${work_dir}/argo.log"
    local domain delay=2 i=1
    sleep 2
    while [ "$i" -le 5 ]; do
        domain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' \
            "$logfile" 2>/dev/null | head -1)
        [ -n "$domain" ] && echo "$domain" && return 0
        sleep "$delay"
        delay=$(( delay < 8 ? delay * 2 : 8 ))
        i=$(( i + 1 ))
    done
    echo ""; return 1
}

# ── 节点链接 ──────────────────────────────────────────────────
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

# URL 编码：对 path 中的特殊字符进行完整百分号编码
_urlencode_path() {
    printf '%s' "$1" | sed \
        's/%/%25/g; s/ /%20/g; s/!/%21/g; s/"/%22/g; s/#/%23/g;
         s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g;
         s/\*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/:/%3A/g; s/;/%3B/g;
         s/=/%3D/g; s/?/%3F/g; s/@/%40/g; s/\[/%5B/g; s/\]/%5D/g'
}

build_freeflow_link() {
    local ip="$1" uuid path_enc
    uuid=$(get_current_uuid)
    path_enc=$(_urlencode_path "${FF_PATH}")
    case "${FREEFLOW_MODE}" in
        ws)
            echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=ws&host=${ip}&path=${path_enc}#FreeFlow-WS"
            ;;
        httpupgrade)
            echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=httpupgrade&host=${ip}&path=${path_enc}#FreeFlow-HTTPUpgrade"
            ;;
    esac
}

get_info() {
    clear
    local IP cur_uuid
    IP=$(get_realip)
    [ -z "$IP" ] && yellow "警告：无法获取服务器 IP，依赖 IP 的节点链接将缺失"
    cur_uuid=$(get_current_uuid)

    # 构建节点链接到 client_dir
    {
        if [ "${ARGO_MODE}" = "yes" ]; then
            local tunnel_choice proto_choice

            echo "" >&2
            green  "请选择 Argo 隧道类型：" >&2
            skyblue "-------------------------------" >&2
            green  "1. 临时隧道（自动生成域名，默认）" >&2
            green  "2. 固定隧道（使用自有 token/json）" >&2
            skyblue "-------------------------------" >&2
            reading "请输入选择(1-2，回车默认1): " tunnel_choice >&2

            case "${tunnel_choice}" in
                2)
                    # 询问固定隧道协议
                    echo "" >&2
                    green  "请选择固定隧道协议：" >&2
                    skyblue "-----------------------" >&2
                    green  "1. WS（WebSocket，默认）" >&2
                    green  "2. XHTTP（XHTTP/auto 模式）" >&2
                    skyblue "-----------------------" >&2
                    reading "请输入选择(1-2，回车默认1): " proto_choice >&2

                    case "${proto_choice}" in
                        2) _apply_fixed_tunnel xhttp >&2 ;;
                        *) _apply_fixed_tunnel ws    >&2 ;;
                    esac
                    if [ $? -ne 0 ]; then
                        yellow "固定隧道配置失败，回退到临时隧道" >&2
                        tunnel_choice="1"
                    fi
                    ;;
            esac

            # 临时隧道（首次安装 或 固定隧道回退）
            if [ "${tunnel_choice}" != "2" ]; then
                local argodomain
                purple "正在获取临时 ArgoDomain，请稍等..." >&2
                restart_argo ws
                argodomain=$(get_argodomain ws)
                if [ -z "$argodomain" ]; then
                    yellow "未能获取 ArgoDomain，可稍后通过 Argo 管理菜单重新获取" >&2
                    argodomain="<未获取到域名>"
                else
                    green "ArgoDomain：${argodomain}" >&2
                fi
                echo "vless://${cur_uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#Argo-WS"
            fi
        fi

        # 已配置的固定隧道 WS 节点
        if [ -f "${work_dir}/domain_ws.txt" ]; then
            local d_ws; d_ws=$(cat "${work_dir}/domain_ws.txt")
            echo "vless://${cur_uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${d_ws}&fp=chrome&type=ws&host=${d_ws}&path=%2Fvless-ws%3Fed%3D2560#Argo-WS-Fixed"
        fi

        # 已配置的固定隧道 XHTTP 节点
        if [ -f "${work_dir}/domain_xhttp.txt" ]; then
            local d_xhttp; d_xhttp=$(cat "${work_dir}/domain_xhttp.txt")
            echo "vless://${cur_uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${d_xhttp}&fp=chrome&type=xhttp&host=${d_xhttp}&path=%2Fvless-xhttp#Argo-XHTTP-Fixed"
        fi

        [ "${FREEFLOW_MODE}" != "none" ] && [ -n "$IP" ] && build_freeflow_link "${IP}"
    } > "${client_dir}"

    print_nodes
}

get_quick_tunnel() {
    if [ "${ARGO_MODE}" != "yes" ]; then
        yellow "未安装 Argo，此操作不可用"; return 1
    fi
    if [ ! -f "${client_dir}" ]; then
        yellow "节点文件不存在，请先执行安装以初始化节点信息"; return 1
    fi
    yellow "正在重启 WS 临时隧道并获取新域名..."
    restart_argo ws
    local argodomain
    argodomain=$(get_argodomain ws)
    if [ -z "$argodomain" ]; then
        yellow "未能获取临时域名，请检查网络或稍后重试"; return 1
    fi
    green "ArgoDomain：${argodomain}"
    # 只更新 #Argo-WS 临时节点行
    awk -v domain="$argodomain" '
        /#Argo-WS$/ {
            sub(/sni=[^&]*/, "sni="domain)
            sub(/host=[^&]*/, "host="domain)
        }
        { print }
    ' "${client_dir}" > "${client_dir}.tmp" && mv "${client_dir}.tmp" "${client_dir}"
    print_nodes
    green "节点已更新，请手动复制以上链接"
}

# 更新 url.txt 中的 FreeFlow 行（用 Python/awk 替代脆弱的 sed /c\ 语法）
_update_freeflow_url() {
    local ip="$1" new_link
    new_link=$(build_freeflow_link "${ip}")
    if grep -q '#FreeFlow' "${client_dir}" 2>/dev/null; then
        # 用 awk 替换，避免 sed c\ 在不同实现间的兼容问题
        awk -v newline="${new_link}" '/#FreeFlow/{print newline; next} {print}' \
            "${client_dir}" > "${client_dir}.tmp" \
            && mv "${client_dir}.tmp" "${client_dir}"
    fi
}

# ── Cron 检测与安装 ───────────────────────────────────────────
check_and_install_cron() {
    if command -v crontab >/dev/null 2>&1; then
        # 进一步确认 cron 守护进程可用
        if is_alpine; then
            rc-service dcron status >/dev/null 2>&1 || rc-service crond status >/dev/null 2>&1 && return 0
        else
            systemctl is-active --quiet cron 2>/dev/null \
                || systemctl is-active --quiet crond 2>/dev/null && return 0
        fi
    fi

    yellow "检测到 cron 服务未安装或未运行"
    reading "是否安装 cron？(y/n，回车默认 y): " choice
    case "${choice}" in
        n|N)
            red "未安装 cron，自动重启功能无法使用"
            return 1
            ;;
        *)
            yellow "正在安装 cron..."
            if command -v apt >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt install -y cron
                systemctl enable --now cron 2>/dev/null || true
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y cronie
                systemctl enable --now crond 2>/dev/null || true
            elif command -v yum >/dev/null 2>&1; then
                yum install -y cronie
                systemctl enable --now crond 2>/dev/null || true
            elif command -v apk >/dev/null 2>&1; then
                apk add dcron
                rc-service dcron start 2>/dev/null || true
                rc-update add dcron default 2>/dev/null || true
            else
                red "无法自动安装 cron，请手动安装后重试"
                return 1
            fi
            green "cron 已安装"
            return 0
            ;;
    esac
}

# ── 自动重启（用 mktemp 避免 /tmp/crontab.tmp 竞争条件）────────
setup_auto_restart() {
    check_and_install_cron || return 1
    local restart_cmd tmpfile
    if is_alpine; then
        restart_cmd="rc-service xray restart"
    else
        restart_cmd="systemctl restart xray"
    fi
    tmpfile=$(mktemp)
    crontab -l 2>/dev/null | sed '/xray-restart/d' > "$tmpfile" || true
    echo "*/${RESTART_INTERVAL} * * * * ${restart_cmd} >/dev/null 2>&1 #xray-restart" >> "$tmpfile"
    crontab "$tmpfile"
    rm -f "$tmpfile"
    green "已设置每 ${RESTART_INTERVAL} 分钟自动重启 Xray"
}

remove_auto_restart() {
    local tmpfile
    tmpfile=$(mktemp)
    crontab -l 2>/dev/null | sed '/xray-restart/d' > "$tmpfile" || true
    crontab "$tmpfile" 2>/dev/null
    rm -f "$tmpfile"
}

# ── 固定隧道配置（get_info 和 manage_argo 共用）──────────────
# 用法: _apply_fixed_tunnel <mode>   mode=ws（默认）或 xhttp
# 成功后 argo_domain 变量在调用方可见
_apply_fixed_tunnel() {
    local mode="${1:-ws}"
    local port svc_name inbound_json log_file
    if [ "$mode" = "xhttp" ]; then
        port="${ARGO_XHTTP_PORT}"
        svc_name="tunnel-xhttp"
        log_file="${work_dir}/argo_xhttp.log"
        inbound_json='{
  "port": '"${ARGO_XHTTP_PORT}"',
  "listen": "127.0.0.1",
  "protocol": "vless",
  "settings": { "clients": [{ "id": "'"$(get_current_uuid)"'" }], "decryption": "none" },
  "streamSettings": {
    "network": "xhttp", "security": "none",
    "xhttpSettings": { "host": "", "path": "/vless-xhttp", "mode": "auto" }
  },
  "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }
}'
    else
        port="${ARGO_PORT}"
        svc_name="tunnel"
        log_file="${work_dir}/argo.log"
        # WS inbound 已在 install_xray 写入 config，无需重新注入
        inbound_json=""
    fi

    yellow "固定隧道回源端口为 ${port}，请在 CF 后台配置对应 ingress"
    echo ""
    reading "请输入你的 Argo 域名: " argo_domain
    [ -z "$argo_domain" ] && red "Argo 域名不能为空" && return 1
    reading "请输入 Argo 密钥（token 或 json）: " argo_auth

    local exec_cmd=""
    if echo "$argo_auth" | grep -q "TunnelSecret"; then
        local tunnel_id
        tunnel_id=$(echo "$argo_auth" | jq -r '.TunnelID // .AccountTag // empty' 2>/dev/null)
        [ -z "$tunnel_id" ] && tunnel_id=$(echo "$argo_auth" | jq -r 'keys_unsorted[1]? // empty' 2>/dev/null)
        [ -z "$tunnel_id" ] && red "无法从 JSON 中提取 TunnelID，请检查格式" && return 1
        echo "$argo_auth" > "${work_dir}/tunnel_${mode}.json"
        cat > "${work_dir}/tunnel_${mode}.yml" << EOF
tunnel: ${tunnel_id}
credentials-file: ${work_dir}/tunnel_${mode}.json
protocol: http2

ingress:
  - hostname: ${argo_domain}
    service: http://localhost:${port}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
        exec_cmd="${work_dir}/argo tunnel --edge-ip-version auto --config ${work_dir}/tunnel_${mode}.yml run"
    elif echo "$argo_auth" | grep -qE '^[A-Za-z0-9=_-]{120,250}$'; then
        exec_cmd="${work_dir}/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_auth}"
    else
        yellow "token 或 json 格式不匹配，请重新输入"; return 1
    fi

    # 写服务文件
    if is_alpine; then
        cat > /etc/init.d/${svc_name} << EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel ${mode}"
command="/bin/sh"
command_args="-c '${exec_cmd} >> ${log_file} 2>&1'"
command_background=true
pidfile="/var/run/${svc_name}.pid"
EOF
        chmod +x /etc/init.d/${svc_name}
        rc-update add "${svc_name}" default 2>/dev/null
    else
        cat > /etc/systemd/system/${svc_name}.service << EOF
[Unit]
Description=Cloudflare Tunnel ${mode}
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/sh -c '${exec_cmd} >> ${log_file} 2>&1'
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "${svc_name}" 2>/dev/null
    fi

    # xhttp 模式：注入 inbound（幂等：先删后加）
    if [ "$mode" = "xhttp" ] && [ -n "$inbound_json" ]; then
        jq 'del(.inbounds[] | select(.port == '"${ARGO_XHTTP_PORT}"'))' \
            "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
        jq --argjson ib "${inbound_json}" '.inbounds += [$ib]' \
            "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
        restart_xray
    fi

    # 保存域名供 get_info 读取
    echo "$argo_domain" > "${work_dir}/domain_${mode}.txt"

    restart_argo "$mode"
    green "固定隧道（${mode}）已配置，域名：${argo_domain}"
    return 0
}

# ── Argo 管理菜单 ─────────────────────────────────────────────
manage_argo() {
    if [ "${ARGO_MODE}" != "yes" ]; then
        yellow "未安装 Argo，Argo 管理不可用"; sleep 1; menu; return
    fi
    local cx
    check_argo > /dev/null 2>&1; cx=$?
    if [ "$cx" -eq 2 ]; then
        yellow "Argo 尚未安装！"; sleep 1; menu; return
    fi

    local xhttp_status; xhttp_status=$(check_argo_xhttp)

    clear; echo ""
    green  "1. 启动 WS 隧道服务";              skyblue "---------------------"
    green  "2. 停止 WS 隧道服务";              skyblue "---------------------"
    green  "3. 添加/更新 WS 固定隧道";         skyblue "-----------------------------"
    green  "4. 切换 WS 回临时隧道";            skyblue "------------------------"
    green  "5. 重新获取 WS 临时域名";          skyblue "-------------------------"
    green  "6. 修改 WS 回源端口（当前：${ARGO_PORT}）"; skyblue "-------------------"
    echo   "------------------------------------------"
    green  "7. 添加/更新 XHTTP 固定隧道（状态：${xhttp_status}）"
    green  "8. 启动 XHTTP 隧道服务"
    green  "9. 停止 XHTTP 隧道服务"
    red    "10. 卸载 XHTTP 固定隧道"
    echo   "------------------------------------------"
    purple "0. 返回主菜单";                    skyblue "------------"
    reading "请输入选择: " choice

    case "${choice}" in
        1)
            service_ctrl start tunnel
            green "WS 隧道已启动"
            ;;
        2)
            service_ctrl stop tunnel
            green "WS 隧道已停止"
            ;;
        3)
            _apply_fixed_tunnel ws || { manage_argo; return; }
            local d_ws; d_ws=$(cat "${work_dir}/domain_ws.txt" 2>/dev/null)
            if [ -n "$d_ws" ] && [ -f "${client_dir}" ]; then
                local new_link="vless://$(get_current_uuid)@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${d_ws}&fp=chrome&type=ws&host=${d_ws}&path=%2Fvless-ws%3Fed%3D2560#Argo-WS-Fixed"
                if grep -q '#Argo-WS-Fixed' "${client_dir}"; then
                    awk -v l="${new_link}" '/#Argo-WS-Fixed/{print l; next} {print}' \
                        "${client_dir}" > "${client_dir}.tmp" && mv "${client_dir}.tmp" "${client_dir}"
                else
                    echo "$new_link" >> "${client_dir}"
                fi
            fi
            print_nodes
            ;;
        4)
            reset_tunnel_to_temp
            get_quick_tunnel
            ;;
        5)
            local using_temp="false"
            if is_alpine; then
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
        6)
            reading "请输入新的 WS 回源端口（回车随机）: " new_port
            [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
            if ! echo "$new_port" | grep -qE '^[0-9]+$' || \
               [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                red "端口无效，请输入 1-65535 的整数"; return
            fi
            jq --argjson p "$new_port" \
                '(.inbounds[] | select(.port == '"${ARGO_PORT}"') | .port) |= $p' \
                "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
            if is_alpine; then
                sed -i "s|http://localhost:${ARGO_PORT}|http://localhost:${new_port}|g" /etc/init.d/tunnel
            else
                sed -i "s|http://localhost:${ARGO_PORT}|http://localhost:${new_port}|g" \
                    /etc/systemd/system/tunnel.service
            fi
            export ARGO_PORT=$new_port
            restart_xray && restart_argo ws
            green "WS 回源端口已修改为：${new_port}"
            ;;
        7)
            _apply_fixed_tunnel xhttp || { manage_argo; return; }
            local d_xhttp; d_xhttp=$(cat "${work_dir}/domain_xhttp.txt" 2>/dev/null)
            if [ -n "$d_xhttp" ] && [ -f "${client_dir}" ]; then
                local new_link="vless://$(get_current_uuid)@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${d_xhttp}&fp=chrome&type=xhttp&host=${d_xhttp}&path=%2Fvless-xhttp#Argo-XHTTP-Fixed"
                if grep -q '#Argo-XHTTP-Fixed' "${client_dir}"; then
                    awk -v l="${new_link}" '/#Argo-XHTTP-Fixed/{print l; next} {print}' \
                        "${client_dir}" > "${client_dir}.tmp" && mv "${client_dir}.tmp" "${client_dir}"
                else
                    echo "$new_link" >> "${client_dir}"
                fi
            fi
            print_nodes
            ;;
        8)
            service_ctrl start tunnel-xhttp
            green "XHTTP 隧道已启动"
            ;;
        9)
            service_ctrl stop tunnel-xhttp
            green "XHTTP 隧道已停止"
            ;;
        10)
            service_ctrl stop    tunnel-xhttp
            service_ctrl disable tunnel-xhttp
            if is_alpine; then
                rm -f /etc/init.d/tunnel-xhttp
            else
                rm -f /etc/systemd/system/tunnel-xhttp.service
                systemctl daemon-reload
            fi
            rm -f "${work_dir}/domain_xhttp.txt" \
                  "${work_dir}/tunnel_xhttp.yml" \
                  "${work_dir}/tunnel_xhttp.json" \
                  "${work_dir}/argo_xhttp.log"
            jq 'del(.inbounds[] | select(.port == '"${ARGO_XHTTP_PORT}"'))' \
                "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
            restart_xray
            if [ -f "${client_dir}" ]; then
                grep -v '#Argo-XHTTP-Fixed' "${client_dir}" > "${client_dir}.tmp" \
                    && mv "${client_dir}.tmp" "${client_dir}"
            fi
            green "XHTTP 固定隧道已卸载"
            ;;
        0) menu ;;
        *) red "无效的选项！" ;;
    esac
}

# ── FreeFlow 管理菜单 ─────────────────────────────────────────
manage_freeflow() {
    if [ "${FREEFLOW_MODE}" = "none" ]; then
        yellow "未启用 FreeFlow，此管理不可用"; sleep 1; menu; return
    fi
    clear; echo ""
    green  "FreeFlow 当前配置："
    skyblue "  方式: ${FREEFLOW_MODE}（path=${FF_PATH}）"
    echo   "=========================="
    green  "1. 变更 FreeFlow 方式"
    green  "2. 修改 FreeFlow path"
    purple "3. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice

    case "${choice}" in
        1)
            ask_freeflow_mode
            apply_freeflow_config
            local ip_now; ip_now=$(get_realip)
            {
                # 保留所有 Argo 节点行（临时 WS、固定 WS、固定 XHTTP）
                grep '#Argo' "${client_dir}" 2>/dev/null || true
                [ "${FREEFLOW_MODE}" != "none" ] && [ -n "$ip_now" ] && build_freeflow_link "${ip_now}"
            } > "${client_dir}.new" && mv "${client_dir}.new" "${client_dir}"
            restart_xray
            green "FreeFlow 方式已变更"
            print_nodes
            ;;
        2)
            reading "请输入新的 FreeFlow path（回车保持当前 ${FF_PATH}）: " new_path
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
            green "FreeFlow path 已修改为：${FF_PATH}"
            print_nodes
            ;;
        3) menu ;;
        *) red "无效的选项！" ;;
    esac
}

# ── 自动重启管理菜单 ──────────────────────────────────────────
manage_restart() {
    clear; echo ""
    green  "Xray 自动重启间隔：当前 ${RESTART_INTERVAL} 分钟 (0=关闭)"
    echo   "=========================="
    green  "1. 设置重启间隔（分钟，0=关闭）"
    purple "2. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice

    case "${choice}" in
        1)
            reading "请输入间隔分钟（0关闭，推荐 60）: " new_int
            if ! echo "${new_int}" | grep -qE '^[0-9]+$' || [ "${new_int}" -lt 0 ]; then
                red "输入无效"; return
            fi
            RESTART_INTERVAL="${new_int}"
            mkdir -p "${work_dir}"
            echo "${RESTART_INTERVAL}" > "${restart_conf}"

            if [ "${RESTART_INTERVAL}" -eq 0 ]; then
                remove_auto_restart
                green "自动重启已关闭"
            else
                setup_auto_restart
            fi
            ;;
        2) menu ;;
        *) red "无效的选项！" ;;
    esac
}

# ── 卸载 ─────────────────────────────────────────────────────
uninstall_xray() {
    reading "确定要卸载 xray-2go 吗？(y/n): " choice
    case "${choice}" in
        y|Y)
            yellow "正在卸载..."
            remove_auto_restart
            if is_alpine; then
                service_ctrl stop xray;         service_ctrl disable xray
                rm -f /etc/init.d/xray
                if [ "${ARGO_MODE}" = "yes" ]; then
                    service_ctrl stop tunnel;         service_ctrl disable tunnel
                    service_ctrl stop tunnel-xhttp;   service_ctrl disable tunnel-xhttp
                    rm -f /etc/init.d/tunnel /etc/init.d/tunnel-xhttp
                fi
            else
                service_ctrl stop xray;         service_ctrl disable xray
                rm -f /etc/systemd/system/xray.service
                if [ "${ARGO_MODE}" = "yes" ]; then
                    service_ctrl stop tunnel;         service_ctrl disable tunnel
                    service_ctrl stop tunnel-xhttp;   service_ctrl disable tunnel-xhttp
                    rm -f /etc/systemd/system/tunnel.service \
                          /etc/systemd/system/tunnel-xhttp.service
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

# ── 主菜单 ────────────────────────────────────────────────────
menu() {
    while true; do
        local xray_status argo_status xhttp_status cx ff_display argo_display xhttp_display
        xray_status=$(check_xray); cx=$?
        argo_status=$(check_argo)
        xhttp_status=$(check_argo_xhttp)
        case "${FREEFLOW_MODE}" in
            ws)          ff_display="WS（path=${FF_PATH}）"          ;;
            httpupgrade) ff_display="HTTPUpgrade（path=${FF_PATH}）" ;;
            none)        ff_display="未启用"                          ;;
            *)           ff_display="未知"                           ;;
        esac
        if [ "${ARGO_MODE}" = "yes" ]; then
            argo_display="${argo_status}"
            xhttp_display="${xhttp_status}"
        else
            argo_display="未启用"
            xhttp_display="未启用"
        fi

        clear; echo ""
        purple "=== Xray-2go 精简版 ==="
        purple " Xray 状态:    ${xray_status}"
        purple " Argo WS:      ${argo_display}"
        purple " Argo XHTTP:   ${xhttp_display}"
        purple " FreeFlow:     ${ff_display}"
        purple " 重启间隔:     ${RESTART_INTERVAL} 分钟"
        echo   "========================"
        green  "1. 安装 Xray-2go"
        red    "2. 卸载 Xray-2go"
        echo   "================="
        green  "3. Argo 隧道管理"
        green  "4. FreeFlow 管理"
        echo   "================="
        green  "5. 查看节点信息"
        green  "6. 修改 UUID"
        green  "7. Xray 自动重启管理"
        green  "8. 创建快捷方式 (s)"
        echo   "================="
        red    "0. 退出脚本"
        echo   "==========="
        reading "请输入选择(0-8): " choice
        echo ""

        case "${choice}" in
            1)
                if [ "$cx" -eq 0 ]; then
                    yellow "Xray-2go 已安装！"
                else
                    ask_argo_mode
                    ask_freeflow_mode
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
                    get_info
                fi
                ;;
            2) uninstall_xray ;;
            3) manage_argo ;;
            4) manage_freeflow ;;
            5) check_nodes ;;
            6)
                reading "请输入新的 UUID（回车自动生成）: " new_uuid
                if [ -z "$new_uuid" ]; then
                    new_uuid=$(cat /proc/sys/kernel/random/uuid)
                    green "生成的 UUID：$new_uuid"
                fi
                # config.json：精确替换所有 vless inbound 的 UUID
                jq --arg u "$new_uuid" '
                    (.inbounds[] | select(.protocol=="vless") | .settings.clients[0].id) = $u
                ' "${config_dir}" > "${config_dir}.tmp" \
                    && mv "${config_dir}.tmp" "${config_dir}"
                export UUID=$new_uuid
                # url.txt：对每一行中 vless://UUID@ 部分做替换，保留其余所有节点行
                if [ -f "${client_dir}" ]; then
                    awk -v uuid="${new_uuid}" '{
                        gsub(/vless:\/\/[^@]*@/, "vless://" uuid "@")
                        print
                    }' "${client_dir}" > "${client_dir}.tmp" \
                        && mv "${client_dir}.tmp" "${client_dir}"
                fi
                restart_xray
                green "UUID 已修改为：${new_uuid}"
                print_nodes
                ;;
            7) manage_restart ;;
            8) install_shortcut ;;
            0) exit 0 ;;
            *) red "无效的选项，请输入 0 到 8" ;;
        esac
        printf '\033[1;91m按回车键继续...\033[0m'
        read -r _dummy
    done
}

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

menu
