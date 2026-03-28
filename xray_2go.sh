#!/bin/bash

# ============================================================
# Xray-2go 一键脚本
# 协议：
#   Argo 临时隧道（WS 专属）：VLESS+WS+TLS（Cloudflare 随机域名）
#   Argo 固定隧道（WS/XHTTP 二选一，复用同端口）：VLESS+WS/XHTTP+TLS
#   FreeFlow（可选）：VLESS+WS/HTTPUpgrade/XHTTP（port 80，明文）
# 注意：Argo XHTTP 模式仅支持固定隧道，不支持临时隧道
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
argo_protocol_conf="${work_dir}/argo_protocol.conf"
restart_conf="${work_dir}/restart.conf"
shortcut_path="/usr/local/bin/s"

export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
export ARGO_PORT=${ARGO_PORT:-'8080'}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1

# ── 平台检测 ─────────────────────────────────────────────────
is_alpine() { [ -f /etc/alpine-release ]; }

# ── 服务控制 ─────────────────────────────────────────────────
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
    # Argo inbound listen 127.0.0.1，FreeFlow listen ::，精确区分
    _port=$(jq -r 'first(.inbounds[] | select(.listen=="127.0.0.1") | .port) // empty' "${config_dir}" 2>/dev/null)
    echo "$_port" | grep -qE '^[0-9]+$' && export ARGO_PORT=$_port
    unset _port
fi

FF_PATH="/"
if [ -f "${freeflow_conf}" ]; then
    _l1=$(sed -n '1p' "${freeflow_conf}" 2>/dev/null)
    _l2=$(sed -n '2p' "${freeflow_conf}" 2>/dev/null)
    case "${_l1}" in
        ws|httpupgrade|xhttp) FREEFLOW_MODE="${_l1}" ;;
        *)                    FREEFLOW_MODE="none"   ;;
    esac
    [ -n "${_l2}" ] && FF_PATH="${_l2}"
    unset _l1 _l2
else
    FREEFLOW_MODE="none"
fi

_proto=$(cat "${argo_protocol_conf}" 2>/dev/null)
case "${_proto}" in
    ws|xhttp) ARGO_PROTOCOL="${_proto}" ;;
    *)        ARGO_PROTOCOL="ws"        ;;
esac
unset _proto

RESTART_INTERVAL=0
if [ -f "${restart_conf}" ]; then
    _ri=$(cat "${restart_conf}" 2>/dev/null)
    echo "${_ri}" | grep -qE '^[0-9]+$' && RESTART_INTERVAL="${_ri}"
    unset _ri
fi

# ── 状态检测 ─────────────────────────────────────────────────
check_xray() {
    [ ! -f "${work_dir}/${server_name}" ] && echo "not installed" && return 2
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
    [ "${ARGO_MODE}" = "no" ] && echo "disabled" && return 3
    [ ! -f "${work_dir}/argo" ] && echo "not installed" && return 2
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

# ── Argo inbound JSON（ws/xhttp 二选一，复用 ARGO_PORT）──────
# Argo xhttp 用 auto 模式（兼容 CF Tunnel 的 HTTP/2 代理）
# path 统一 /argo
_argo_inbound_json() {
    local uuid; uuid=$(get_current_uuid)
    if [ "${ARGO_PROTOCOL}" = "xhttp" ]; then
        printf '{
  "port": %s, "listen": "127.0.0.1", "protocol": "vless",
  "settings": { "clients": [{ "id": "%s" }], "decryption": "none" },
  "streamSettings": {
    "network": "xhttp", "security": "none",
    "xhttpSettings": { "host": "", "path": "/argo", "mode": "auto" }
  },
  "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }
}' "${ARGO_PORT}" "${uuid}"
    else
        printf '{
  "port": %s, "listen": "127.0.0.1", "protocol": "vless",
  "settings": { "clients": [{ "id": "%s" }], "decryption": "none" },
  "streamSettings": {
    "network": "ws", "security": "none",
    "wsSettings": { "path": "/argo" }
  },
  "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }
}' "${ARGO_PORT}" "${uuid}"
    fi
}

# ── 包管理 ───────────────────────────────────────────────────
manage_packages() {
    shift  # 跳过 action 参数（仅支持 install）
    for pkg in "$@"; do
        command -v "$pkg" > /dev/null 2>&1 && continue
        yellow "正在安装 ${pkg}..."
        if   command -v apt > /dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt install -y "$pkg" >/dev/null 2>&1
        elif command -v dnf > /dev/null 2>&1; then dnf install -y "$pkg" >/dev/null 2>&1
        elif command -v yum > /dev/null 2>&1; then yum install -y "$pkg" >/dev/null 2>&1
        elif command -v apk > /dev/null 2>&1; then apk add "$pkg" >/dev/null 2>&1
        else red "未知系统，无法安装 ${pkg}"; return 1
        fi
    done
}

# ── 获取服务器真实 IP ─────────────────────────────────────────
get_realip() {
    local ip ipv6
    ip=$(curl -s --max-time 3 ipv4.ip.sb 2>/dev/null)
    if [ -z "$ip" ]; then
        ipv6=$(curl -s --max-time 3 ipv6.ip.sb 2>/dev/null)
        [ -n "$ipv6" ] && echo "[$ipv6]" || echo ""
        return
    fi
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
    id=$(jq -r '(first(.inbounds[] | select(.protocol=="vless") | .settings.clients[0].id) // empty)' \
        "${config_dir}" 2>/dev/null)
    echo "${id:-${UUID}}"
}

_save_freeflow_conf() {
    mkdir -p "${work_dir}"
    printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"
}

# ── 原位替换 Argo inbound（保持数组顺序，防止 ARGO_PORT 读错）
_replace_argo_inbound() {
    local _ib; _ib=$(_argo_inbound_json)
    jq --argjson ib "${_ib}" '
        (.inbounds | map(select(.listen == "127.0.0.1")) | length) as $n |
        if $n > 0 then
            .inbounds = [.inbounds[] | if .listen == "127.0.0.1" then $ib else . end]
        else
            .inbounds = [$ib] + .inbounds
        end
    ' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
}

# ── 安装快捷方式 ─────────────────────────────────────────────
install_shortcut() {
    yellow "正在从 GitHub 拉取最新脚本..."
    curl -sL https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh \
        -o /usr/local/bin/xray2go || { red "拉取脚本失败，请检查网络"; return 1; }
    chmod +x /usr/local/bin/xray2go
    printf '#!/bin/bash\nexec /usr/local/bin/xray2go "$@"\n' > "${shortcut_path}"
    chmod +x "${shortcut_path}"
    green "快捷方式已创建/脚本已更新！输入 s 即可快速启动脚本"
}

# ── 交互提问 ─────────────────────────────────────────────────
ask_argo_mode() {
    echo ""
    green  "是否安装 Cloudflare Argo 隧道？"
    skyblue "------------------------------------"
    green  "1. 安装 Argo（VLESS+WS/XHTTP+TLS，默认）"
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

ask_argo_protocol() {
    echo ""
    green  "请选择 Argo 隧道传输协议："
    skyblue "-----------------------------"
    green  "1. WS（WebSocket，支持临时/固定隧道，默认）"
    green  "2. XHTTP（auto 模式，仅支持固定隧道）"
    skyblue "-----------------------------"
    reading "请输入选择(1-2，回车默认1): " proto_choice
    case "${proto_choice}" in
        2)
            ARGO_PROTOCOL="xhttp"
            echo ""
            yellow "⚠ 警告：XHTTP 模式不支持临时隧道和临时域名！"
            yellow "⚠ 安装完成后将直接进入固定隧道配置流程，请提前准备好 Argo 域名和 Token/JSON。"
            echo ""
            ;;
        *) ARGO_PROTOCOL="ws" ;;
    esac
    mkdir -p "${work_dir}"
    echo "${ARGO_PROTOCOL}" > "${argo_protocol_conf}"
    case "${ARGO_PROTOCOL}" in
        xhttp) green "已选择：XHTTP 固定隧道（auto 模式）" ;;
        ws)    green "已选择：WS 隧道" ;;
    esac
    echo ""
}

ask_freeflow_mode() {
    echo ""
    green  "请选择 FreeFlow 方式："
    skyblue "--------------------------------------"
    green  "1. VLESS + WS          （明文，port 80）"
    green  "2. VLESS + HTTPUpgrade （明文，port 80）"
    green  "3. VLESS + XHTTP       （stream-one 模式，port 80）"
    green  "4. 不启用 FreeFlow（默认）"
    skyblue "--------------------------------------"
    reading "请输入选择(1-4，回车默认4): " ff_choice
    case "${ff_choice}" in
        1) FREEFLOW_MODE="ws"          ;;
        2) FREEFLOW_MODE="httpupgrade" ;;
        3) FREEFLOW_MODE="xhttp"       ;;
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
        ws)          green  "已选择：VLESS+WS FreeFlow（path=${FF_PATH}）"                    ;;
        httpupgrade) green  "已选择：VLESS+HTTPUpgrade FreeFlow（path=${FF_PATH}）"           ;;
        xhttp)       green  "已选择：VLESS+XHTTP FreeFlow（stream-one，path=${FF_PATH}）"    ;;
        none)        yellow "不启用 FreeFlow"                                                 ;;
    esac
    echo ""
}

# ── FreeFlow inbound JSON 生成 ───────────────────────────────
# FreeFlow xhttp 用 stream-one（直连无中间代理，适合免流场景）
# Argo xhttp 用 auto（需兼容 CF Tunnel 的 HTTP/2 代理，见 _argo_inbound_json）
get_freeflow_inbound_json() {
    local uuid="$1"
    case "${FREEFLOW_MODE}" in
        ws)
            printf '{"port":80,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"%s"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"%s"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}' \
                "${uuid}" "${FF_PATH}"
            ;;
        httpupgrade)
            printf '{"port":80,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"%s"}],"decryption":"none"},"streamSettings":{"network":"httpupgrade","security":"none","httpupgradeSettings":{"path":"%s"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}' \
                "${uuid}" "${FF_PATH}"
            ;;
        xhttp)
            printf '{"port":80,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"%s"}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"host":"","path":"%s","mode":"stream-one"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}' \
                "${uuid}" "${FF_PATH}"
            ;;
    esac
}

apply_freeflow_config() {
    local cur_uuid ff_json
    cur_uuid=$(get_current_uuid)
    jq 'del(.inbounds[] | select(.port == 80))' \
        "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
    if [ "${FREEFLOW_MODE}" != "none" ]; then
        ff_json=$(get_freeflow_inbound_json "${cur_uuid}")
        jq --argjson ib "${ff_json}" '.inbounds += [$ib]' \
            "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
    fi
}

# ── 安装 Xray 及 cloudflared ─────────────────────────────────
install_xray() {
    clear
    purple "正在安装 Xray-2go，请稍等..."

    local ARCH_RAW ARCH ARCH_ARG
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64')             ARCH='amd64'; ARCH_ARG='64'        ;;
        'x86'|'i686'|'i386') ARCH='386';   ARCH_ARG='32'        ;;
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
        rm -f "${work_dir}/${server_name}.zip" \
              "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" \
              "${work_dir}/README.md"   "${work_dir}/LICENSE"
    else
        green "xray 已存在，跳过下载"
    fi

    if [ "${ARGO_MODE}" = "yes" ] && [ ! -f "${work_dir}/argo" ]; then
        curl -sLo "${work_dir}/argo" \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" \
            || { red "cloudflared 下载失败，请检查网络"; exit 1; }
        chmod +x "${work_dir}/argo"
    elif [ "${ARGO_MODE}" = "yes" ]; then
        green "cloudflared 已存在，跳过下载"
    fi

    if [ "${ARGO_MODE}" = "yes" ]; then
        local _ib; _ib=$(_argo_inbound_json)
        cat > "${config_dir}" << EOF
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [ ${_ib} ],
  "dns": { "servers": ["https+local://1.1.1.1/dns-query"] },
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
  "dns": { "servers": ["https+local://1.1.1.1/dns-query"] },
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
    fi

    [ "${FREEFLOW_MODE}" != "none" ] && apply_freeflow_config
}

# ── CentOS 时间同步 ───────────────────────────────────────────
_fix_centos_time() {
    [ ! -f /etc/centos-release ] && return
    yum install -y chrony
    systemctl start chronyd && systemctl enable chronyd
    chronyc -a makestep
    yum update -y ca-certificates
}

# ── systemd 服务注册 ─────────────────────────────────────────
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
        # xhttp 模式时此临时隧道 service 随后会被 _apply_fixed_tunnel 覆盖
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
    chmod +x /etc/init.d/xray
    rc-update add xray default

    if [ "${ARGO_MODE}" = "yes" ]; then
        cat > /etc/init.d/tunnel << EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> ${work_dir}/argo.log 2>&1'"
command_background=true
pidfile="/var/run/tunnel.pid"
EOF
        chmod +x /etc/init.d/tunnel
        rc-update add tunnel default
    fi
}

change_hosts() {
    echo "0 0" > /proc/sys/net/ipv4/ping_group_range
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

reset_tunnel_to_temp() {
    if is_alpine; then
        sed -i "/^command_args=/c\\command_args=\"-c '${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> ${work_dir}/argo.log 2>&1'\"" \
            /etc/init.d/tunnel
    else
        sed -i "/^ExecStart=/c\\ExecStart=${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2" \
            /etc/systemd/system/tunnel.service
    fi
    echo "ws" > "${argo_protocol_conf}"
    ARGO_PROTOCOL="ws"
    _replace_argo_inbound
}

# ── 服务重启 ─────────────────────────────────────────────────
restart_xray() {
    if is_alpine; then
        rc-service xray restart
    else
        systemctl restart xray
    fi
}

restart_argo() {
    rm -f "${work_dir}/argo.log"
    if is_alpine; then
        rc-service tunnel restart
    else
        systemctl daemon-reload && systemctl restart tunnel
    fi
}

# ── 获取 Argo 临时域名（指数退避，最多等待约 15s）────────────
get_argodomain() {
    local domain delay=2 i=1
    sleep 2
    while [ "$i" -le 5 ]; do
        domain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' \
            "${work_dir}/argo.log" 2>/dev/null | head -1)
        [ -n "$domain" ] && echo "$domain" && return 0
        sleep "$delay"
        delay=$(( delay < 8 ? delay * 2 : 8 ))
        i=$(( i + 1 ))
    done
    echo ""; return 1
}

# ── 节点链接打印 ─────────────────────────────────────────────
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
        xhttp)
            echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=xhttp&host=${ip}&path=${path_enc}&mode=stream-one#FreeFlow-XHTTP"
            ;;
    esac
}

# ── 固定隧道配置 ─────────────────────────────────────────────
_apply_fixed_tunnel() {
    yellow "固定隧道回源端口为 ${ARGO_PORT}（协议：${ARGO_PROTOCOL}），请在 CF 后台配置对应 ingress"
    echo ""
    reading "请输入你的 Argo 域名: " argo_domain
    [ -z "$argo_domain" ] && red "Argo 域名不能为空" && return 1
    reading "请输入 Argo 密钥（token 或 json）: " argo_auth
    [ -z "$argo_auth" ] && red "密钥不能为空" && return 1

    local exec_cmd=""
    if echo "$argo_auth" | grep -q "TunnelSecret"; then
        local tunnel_id
        tunnel_id=$(echo "$argo_auth" | jq -r '.TunnelID // .AccountTag // empty' 2>/dev/null)
        [ -z "$tunnel_id" ] && tunnel_id=$(echo "$argo_auth" | jq -r 'keys_unsorted[1]? // empty' 2>/dev/null)
        [ -z "$tunnel_id" ] && red "无法从 JSON 中提取 TunnelID，请检查格式" && return 1
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
        exec_cmd="${work_dir}/argo tunnel --edge-ip-version auto --config ${work_dir}/tunnel.yml run"
    elif echo "$argo_auth" | grep -qE '^[A-Za-z0-9=_-]{120,250}$'; then
        exec_cmd="${work_dir}/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_auth}"
    else
        yellow "token 或 json 格式不匹配，请重新输入"; return 1
    fi

    if is_alpine; then
        cat > /etc/init.d/tunnel << EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '${exec_cmd} >> ${work_dir}/argo.log 2>&1'"
command_background=true
pidfile="/var/run/tunnel.pid"
EOF
        chmod +x /etc/init.d/tunnel
        rc-update add tunnel default 2>/dev/null
    else
        cat > /etc/systemd/system/tunnel.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/sh -c '${exec_cmd} >> ${work_dir}/argo.log 2>&1'
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    fi

    # 原位替换 argo inbound（保持数组顺序，避免下次 ARGO_PORT 读到 FreeFlow 的 port 80）
    _replace_argo_inbound

    echo "$argo_domain"    > "${work_dir}/domain_fixed.txt"
    echo "${ARGO_PROTOCOL}" > "${argo_protocol_conf}"

    restart_xray
    restart_argo
    green "固定隧道（${ARGO_PROTOCOL}，path=/argo）已配置，域名：${argo_domain}"
    return 0
}

# ── 获取/刷新节点信息 ─────────────────────────────────────────
# $1=argodomain（传入时跳过交互直接生成链接）
# $2=skip_select（非空时跳过隧道类型选择）
get_info() {
    clear
    local IP cur_uuid argodomain="$1" skip_select="$2"
    IP=$(get_realip)
    [ -z "$IP" ] && yellow "警告：无法获取服务器 IP，FreeFlow 节点链接将缺失"
    cur_uuid=$(get_current_uuid)

    {
        if [ "${ARGO_MODE}" = "yes" ]; then
            if [ -z "$skip_select" ]; then
                local tunnel_choice
                echo "" >&2
                green  "请选择 Argo 隧道类型：" >&2
                skyblue "-------------------------------" >&2
                green  "1. 临时隧道（自动生成域名，仅 WS，默认）" >&2
                green  "2. 固定隧道（使用自有 token/json）" >&2
                skyblue "-------------------------------" >&2
                reading "请输入选择(1-2，回车默认1): " tunnel_choice

                case "${tunnel_choice}" in
                    2)
                        [ "${ARGO_PROTOCOL}" = "xhttp" ] && \
                            yellow "⚠ XHTTP 模式仅支持固定隧道" >&2
                        if _apply_fixed_tunnel; then
                            argodomain=$(cat "${work_dir}/domain_fixed.txt" 2>/dev/null)
                        else
                            yellow "固定隧道配置失败" >&2
                            if [ "${ARGO_PROTOCOL}" = "xhttp" ]; then
                                red "XHTTP 模式必须配置固定隧道，无法继续" >&2
                                return 1
                            fi
                            yellow "回退到 WS 临时隧道" >&2
                            ARGO_PROTOCOL="ws"
                            echo "ws" > "${argo_protocol_conf}"
                            tunnel_choice="1"
                        fi
                        ;;
                esac

                if [ "${tunnel_choice}" != "2" ]; then
                    if [ "${ARGO_PROTOCOL}" = "xhttp" ]; then
                        red "⚠ XHTTP 模式不支持临时隧道！请选择固定隧道。" >&2
                        return 1
                    fi
                    purple "正在获取临时 ArgoDomain，请稍等..." >&2
                    restart_argo
                    argodomain=$(get_argodomain)
                    if [ -z "$argodomain" ]; then
                        yellow "未能获取 ArgoDomain，可稍后通过 Argo 管理菜单重新获取" >&2
                        argodomain="<未获取到域名>"
                    else
                        green "ArgoDomain：${argodomain}" >&2
                    fi
                fi
            fi

            if [ "${ARGO_PROTOCOL}" = "xhttp" ]; then
                echo "vless://${cur_uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=firefox&type=xhttp&host=${argodomain}&path=%2Fargo&mode=auto#Argo-XHTTP"
            else
                echo "vless://${cur_uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=firefox&type=ws&host=${argodomain}&path=%2Fargo%3Fed%3D2560#Argo-WS"
            fi
        fi

        [ "${FREEFLOW_MODE}" != "none" ] && [ -n "$IP" ] && build_freeflow_link "${IP}"
    } > "${client_dir}"

    print_nodes
}

get_quick_tunnel() {
    [ "${ARGO_MODE}" != "yes" ] && yellow "未安装 Argo，此操作不可用" && return 1
    if [ "${ARGO_PROTOCOL}" = "xhttp" ]; then
        red "⚠ 当前协议为 XHTTP，不支持临时隧道！请先在 Argo 管理中切换回 WS 协议。"
        return 1
    fi
    [ ! -f "${client_dir}" ] && yellow "节点文件不存在，请先执行安装" && return 1
    yellow "正在重启 WS 临时隧道并获取新域名..."
    restart_argo
    local argodomain
    argodomain=$(get_argodomain)
    if [ -z "$argodomain" ]; then
        yellow "未能获取临时域名，请检查网络或稍后重试"; return 1
    fi
    green "ArgoDomain：${argodomain}"
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

_update_freeflow_url() {
    local ip="$1" new_link
    new_link=$(build_freeflow_link "${ip}")
    grep -q '#FreeFlow' "${client_dir}" 2>/dev/null || return
    awk -v newline="${new_link}" '/#FreeFlow/{print newline; next} {print}' \
        "${client_dir}" > "${client_dir}.tmp" \
        && mv "${client_dir}.tmp" "${client_dir}"
}

# ── Cron 检测与安装 ───────────────────────────────────────────
check_and_install_cron() {
    if command -v crontab >/dev/null 2>&1; then
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
        n|N) red "未安装 cron，自动重启功能无法使用"; return 1 ;;
        *)
            yellow "正在安装 cron..."
            if command -v apt >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt install -y cron >/dev/null 2>&1
                systemctl enable --now cron 2>/dev/null || true
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y cronie >/dev/null 2>&1
                systemctl enable --now crond 2>/dev/null || true
            elif command -v yum >/dev/null 2>&1; then
                yum install -y cronie >/dev/null 2>&1
                systemctl enable --now crond 2>/dev/null || true
            elif command -v apk >/dev/null 2>&1; then
                apk add dcron >/dev/null 2>&1
                rc-service dcron start 2>/dev/null || true
                rc-update add dcron default 2>/dev/null || true
            else
                red "无法自动安装 cron，请手动安装后重试"; return 1
            fi
            green "cron 已安装"; return 0 ;;
    esac
}

setup_auto_restart() {
    check_and_install_cron || return 1
    local restart_cmd tmpfile
    is_alpine && restart_cmd="rc-service xray restart" \
              || restart_cmd="systemctl restart xray"
    tmpfile=$(mktemp)
    crontab -l 2>/dev/null | sed '/xray-restart/d' > "$tmpfile" || true
    echo "*/${RESTART_INTERVAL} * * * * ${restart_cmd} >/dev/null 2>&1 #xray-restart" >> "$tmpfile"
    crontab "$tmpfile"
    rm -f "$tmpfile"
    green "已设置每 ${RESTART_INTERVAL} 分钟自动重启 Xray"
}

remove_auto_restart() {
    local tmpfile; tmpfile=$(mktemp)
    crontab -l 2>/dev/null | sed '/xray-restart/d' > "$tmpfile" || true
    crontab "$tmpfile" 2>/dev/null
    rm -f "$tmpfile"
}

# ── Argo 管理菜单 ─────────────────────────────────────────────
manage_argo() {
    [ "${ARGO_MODE}" != "yes" ] && yellow "未安装 Argo，Argo 管理不可用" && sleep 1 && menu && return
    [ ! -f "${work_dir}/argo" ]  && yellow "Argo 尚未安装！" && sleep 1 && menu && return

    local is_fixed="false"
    if is_alpine; then
        grep -Fq -- "--url http://localhost:${ARGO_PORT}" /etc/init.d/tunnel 2>/dev/null \
            && is_fixed="false" || is_fixed="true"
    else
        grep -Fq -- "--url http://localhost:${ARGO_PORT}" /etc/systemd/system/tunnel.service 2>/dev/null \
            && is_fixed="false" || is_fixed="true"
    fi
    local fixed_domain; fixed_domain=$(cat "${work_dir}/domain_fixed.txt" 2>/dev/null)
    local tunnel_type_display
    if [ "$is_fixed" = "true" ] && [ -n "$fixed_domain" ]; then
        tunnel_type_display="固定隧道（${ARGO_PROTOCOL}，${fixed_domain}）"
    else
        tunnel_type_display="临时隧道（WS）"
    fi

    clear; echo ""
    green  "Argo 当前状态：$(check_argo)"
    skyblue "  协议: ${ARGO_PROTOCOL}  端口: ${ARGO_PORT}  类型: ${tunnel_type_display}"
    echo   "========================================================"
    green  "1. 添加/更新固定隧道"
    green  "2. 切换协议（WS ↔ XHTTP，仅固定隧道）"
    green  "3. 切换回临时隧道（仅 WS 可用）"
    green  "4. 重新获取临时域名（WS）"
    green  "5. 修改回源端口（当前：${ARGO_PORT}）"
    green  "6. 启动隧道服务"
    green  "7. 停止隧道服务"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice

    case "${choice}" in
        1)
            echo ""
            green  "请选择固定隧道传输协议："
            skyblue "-----------------------------"
            green  "1. WS（WebSocket，默认）"
            green  "2. XHTTP（auto 模式）"
            skyblue "-----------------------------"
            reading "请输入选择(1-2，回车默认维持当前 ${ARGO_PROTOCOL}): " p_choice
            case "${p_choice}" in
                2) ARGO_PROTOCOL="xhttp" ;;
                1) ARGO_PROTOCOL="ws"    ;;
            esac
            echo "${ARGO_PROTOCOL}" > "${argo_protocol_conf}"
            if _apply_fixed_tunnel; then
                local d; d=$(cat "${work_dir}/domain_fixed.txt" 2>/dev/null)
                get_info "$d" "1"
            fi
            ;;
        2)
            if [ "$is_fixed" != "true" ]; then
                yellow "当前为临时隧道，请先配置固定隧道再切换协议"
                sleep 2; manage_argo; return
            fi
            [ "${ARGO_PROTOCOL}" = "ws" ] && ARGO_PROTOCOL="xhttp" || ARGO_PROTOCOL="ws"
            echo "${ARGO_PROTOCOL}" > "${argo_protocol_conf}"
            _replace_argo_inbound
            restart_xray
            green "协议已切换为：${ARGO_PROTOCOL}"
            local d; d=$(cat "${work_dir}/domain_fixed.txt" 2>/dev/null)
            get_info "$d" "1"
            ;;
        3)
            if [ "${ARGO_PROTOCOL}" = "xhttp" ]; then
                red "⚠ XHTTP 不支持临时隧道，请先切换协议为 WS！"
                sleep 2; manage_argo; return
            fi
            reset_tunnel_to_temp
            restart_xray
            get_quick_tunnel
            ;;
        4) get_quick_tunnel ;;
        5)
            reading "请输入新的回源端口（回车随机）: " new_port
            [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
            if ! echo "$new_port" | grep -qE '^[0-9]+$' || \
               [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                red "端口无效，请输入 1-65535 的整数"; return
            fi
            # 用 oldp/newp 避免与 jq 保留关键字 new 冲突
            jq --argjson oldp "${ARGO_PORT}" --argjson newp "$new_port" \
                '(.inbounds[] | select(.port == $oldp) | .port) |= $newp' \
                "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
            if is_alpine; then
                sed -i "s|http://localhost:${ARGO_PORT}|http://localhost:${new_port}|g" /etc/init.d/tunnel
            else
                sed -i "s|http://localhost:${ARGO_PORT}|http://localhost:${new_port}|g" \
                    /etc/systemd/system/tunnel.service
            fi
            export ARGO_PORT=$new_port
            restart_xray && restart_argo
            green "回源端口已修改为：${new_port}"
            ;;
        6) service_ctrl start tunnel; green "隧道服务已启动" ;;
        7) service_ctrl stop  tunnel; green "隧道服务已停止" ;;
        0) menu ;;
        *) red "无效的选项！" ;;
    esac
}

# ── FreeFlow 管理菜单 ─────────────────────────────────────────
manage_freeflow() {
    clear; echo ""
    green  "FreeFlow 当前配置："
    if [ "${FREEFLOW_MODE}" = "none" ]; then
        skyblue "  未启用"
    else
        skyblue "  方式: ${FREEFLOW_MODE}（path=${FF_PATH}）"
    fi
    echo   "=========================="
    green  "1. 添加/变更 FreeFlow 方式"
    green  "2. 修改 FreeFlow path"
    red    "3. 卸载 FreeFlow"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice

    case "${choice}" in
        1)
            ask_freeflow_mode
            apply_freeflow_config
            local ip_now; ip_now=$(get_realip)
            {
                grep '#Argo' "${client_dir}" 2>/dev/null || true
                [ "${FREEFLOW_MODE}" != "none" ] && [ -n "$ip_now" ] && build_freeflow_link "${ip_now}"
            } > "${client_dir}.new" && mv "${client_dir}.new" "${client_dir}"
            restart_xray
            green "FreeFlow 方式已变更"
            print_nodes
            ;;
        2)
            reading "请输入新的 FreeFlow path（回车保持当前 ${FF_PATH}）: " new_path
            if [ -n "${new_path}" ]; then
                case "${new_path}" in
                    /*) FF_PATH="${new_path}" ;;
                    *)  FF_PATH="/${new_path}" ;;
                esac
                _save_freeflow_conf
                apply_freeflow_config
                local ip_now; ip_now=$(get_realip)
                [ -n "$ip_now" ] && _update_freeflow_url "${ip_now}"
                restart_xray
                green "FreeFlow path 已修改为：${FF_PATH}"
                print_nodes
            fi
            ;;
        3)
            FREEFLOW_MODE="none"
            _save_freeflow_conf
            apply_freeflow_config
            [ -f "${client_dir}" ] && grep -v '#FreeFlow' "${client_dir}" > "${client_dir}.tmp" \
                && mv "${client_dir}.tmp" "${client_dir}"
            restart_xray
            green "FreeFlow 已卸载"
            ;;
        0) return ;;
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
                service_ctrl stop xray;   service_ctrl disable xray
                service_ctrl stop tunnel; service_ctrl disable tunnel
                rm -f /etc/init.d/xray /etc/init.d/tunnel
            else
                service_ctrl stop xray;   service_ctrl disable xray
                service_ctrl stop tunnel; service_ctrl disable tunnel
                rm -f /etc/systemd/system/xray.service \
                      /etc/systemd/system/tunnel.service
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
        local xray_status argo_status cx ff_display argo_display
        xray_status=$(check_xray); cx=$?
        argo_status=$(check_argo)

        case "${FREEFLOW_MODE}" in
            ws)          ff_display="WS（path=${FF_PATH}）"          ;;
            httpupgrade) ff_display="HTTPUpgrade（path=${FF_PATH}）" ;;
            xhttp)       ff_display="XHTTP（path=${FF_PATH}）"       ;;
            none|*)      ff_display="未启用"                          ;;
        esac

        if [ "${ARGO_MODE}" = "yes" ]; then
            local fixed_domain; fixed_domain=$(cat "${work_dir}/domain_fixed.txt" 2>/dev/null)
            if [ -n "$fixed_domain" ]; then
                argo_display="${argo_status}（${ARGO_PROTOCOL}，固定：${fixed_domain}）"
            else
                argo_display="${argo_status}（WS，临时隧道）"
            fi
        else
            argo_display="未启用"
        fi

        clear; echo ""
        purple "=== Xray-2go ==="
        purple " Xray 状态:  ${xray_status}"
        purple " Argo 隧道:  ${argo_display}"
        purple " FreeFlow:   ${ff_display}"
        purple " 重启间隔:   ${RESTART_INTERVAL} 分钟"
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
        green  "8. 创建快捷方式/脚本更新 (s)"
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
                    [ "${ARGO_MODE}" = "yes" ] && ask_argo_protocol
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

                    if [ "${ARGO_MODE}" = "yes" ] && [ "${ARGO_PROTOCOL}" = "xhttp" ]; then
                        echo ""
                        yellow "════════════════════════════════════════"
                        yellow " XHTTP 模式需要配置固定隧道才能使用"
                        yellow " 请按提示完成固定隧道配置"
                        yellow "════════════════════════════════════════"
                        echo ""
                        if _apply_fixed_tunnel; then
                            local d; d=$(cat "${work_dir}/domain_fixed.txt" 2>/dev/null)
                            get_info "$d" "1"
                        else
                            red "固定隧道配置失败，请从 Argo 管理菜单重新配置"
                        fi
                    else
                        get_info
                    fi
                fi
                ;;
            2) uninstall_xray ;;
            3) manage_argo ;;
            4) manage_freeflow ;;
            5)
                if [ "$cx" -eq 0 ]; then
                    print_nodes
                else
                    yellow "Xray-2go 尚未安装或未运行"
                fi
                ;;
            6)
                reading "请输入新的 UUID（回车自动生成）: " new_uuid
                [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid) \
                    && green "生成的 UUID：$new_uuid"
                jq --arg u "$new_uuid" \
                    '(.inbounds[] | select(.protocol=="vless") | .settings.clients[0].id) = $u' \
                    "${config_dir}" > "${config_dir}.tmp" \
                    && mv "${config_dir}.tmp" "${config_dir}"
                export UUID=$new_uuid
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

menu
