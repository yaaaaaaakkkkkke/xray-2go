#!/bin/bash

# ============================================================
# 精简版 Xray-2go 一键脚本
# 协议：
#   Argo（可选）：VLESS+WS+TLS（Cloudflare Argo 隧道）
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

export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
export ARGO_PORT=${ARGO_PORT:-'8080'}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1

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
        none)        yellow "不启用 FreeFlow"                                     ;;
    esac
    echo ""
}

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

reset_tunnel_to_temp() {
    if [ -f /etc/alpine-release ]; then
        sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> /etc/xray/argo.log 2>&1'\"" \
            /etc/init.d/tunnel
    else
        sed -i "/^ExecStart=/c\\ExecStart=${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2" \
            /etc/systemd/system/tunnel.service
    fi
}

restart_xray() {
    if [ -f /etc/alpine-release ]; then rc-service xray restart
    else systemctl daemon-reload && systemctl restart xray; fi
}

restart_argo() {
    rm -f "${work_dir}/argo.log"
    if [ -f /etc/alpine-release ]; then rc-service tunnel restart
    else systemctl daemon-reload && systemctl restart tunnel; fi
}

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

get_info() {
    clear
    local IP
    IP=$(get_realip)
    [ -z "$IP" ] && yellow "警告：无法获取服务器 IP，依赖 IP 的节点链接将缺失"

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

_update_freeflow_url() {
    local ip="$1" new_link escaped
    new_link=$(build_freeflow_link "${ip}")
    if grep -q '#FreeFlow' "${client_dir}" 2>/dev/null; then
        escaped=$(printf '%s\n' "${new_link}" | sed 's/[\/&]/\\&/g')
        sed -i "/#FreeFlow/c\\${escaped}" "${client_dir}"
    fi
}

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
    green  "6. 修改 Argo 回源端口（当前：${ARGO_PORT}）"; skyblue "---------------------"
    purple "7. 返回主菜单";                skyblue "------------"
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
        6)
            reading "请输入新的 Argo 回源端口（回车随机）: " new_port
            [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
            if ! echo "$new_port" | grep -qE '^[0-9]+$' || \
               [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                red "端口无效，请输入 1-65535 的整数"; return
            fi
            jq --argjson p "$new_port" '.inbounds[0].port = $p' "${config_dir}" \
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
        7) menu ;;
        *) red "无效的选项！" ;;
    esac
}

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
            local old_mode="${FREEFLOW_MODE}"
            ask_freeflow_mode
            apply_freeflow_config
            local ip_now; ip_now=$(get_realip)
            {
                [ "${ARGO_MODE}" = "yes" ] && grep '#Argo$' "${client_dir}" 2>/dev/null
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
            green "Xray-2go 卸载完成"
            ;;
        *) purple "已取消卸载" ;;
    esac
}

trap 'red "已取消操作"; exit' INT

menu() {
    while true; do
        local xray_status argo_status cx ff_display argo_display
        xray_status=$(check_xray); cx=$?
        argo_status=$(check_argo)
        case "${FREEFLOW_MODE}" in
            ws)          ff_display="WS（path=${FF_PATH}）"          ;;
            httpupgrade) ff_display="HTTPUpgrade（path=${FF_PATH}）" ;;
            none)        ff_display="未启用"                          ;;
            *)           ff_display="未知"                           ;;
        esac
        if [ "${ARGO_MODE}" = "yes" ]; then
            argo_display="${argo_status}"
        else
            argo_display="未启用"
        fi

        clear; echo ""
        purple "=== Xray-2go 精简版 ==="
        purple " Xray 状态:   ${xray_status}"
        purple " Argo 状态:   ${argo_display}"
        purple " FreeFlow:    ${ff_display}"
        echo   "========================"
        green  "1. 安装 Xray-2go"
        red    "2. 卸载 Xray-2go"
        echo   "================="
        green  "3. Argo 隧道管理"
        green  "4. FreeFlow 管理"
        echo   "================="
        green  "5. 查看节点信息"
        green  "6. 修改 UUID"
        echo   "================="
        red    "0. 退出脚本"
        echo   "==========="
        reading "请输入选择(0-6): " choice
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
                sed -i "s/[a-fA-F0-9]\{8\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{12\}/$new_uuid/g" \
                    "${config_dir}" "${client_dir}" 2>/dev/null || true
                export UUID=$new_uuid
                restart_xray
                green "UUID 已修改为：${new_uuid}"
                print_nodes
                ;;
            0) exit 0 ;;
            *) red "无效的选项，请输入 0 到 6" ;;
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
