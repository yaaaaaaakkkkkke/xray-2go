#!/bin/bash

# ============================================================
# Xray-argo 脚本（固定隧道双协议 + Socks5 多端口版）
# 协议：
#   Argo WS隧道（独立）：VLESS + WS + TLS (纯固定隧道，端口 8080)
#   Argo XHTTP隧道（独立）：VLESS + XHTTP + TLS (纯固定隧道，auto模式，端口 8081)
#   FreeFlow（独立）：VLESS + WS / HTTPUpgrade (明文直连，端口 80)
#   Socks5（独立）：标准 Socks5 代理 (支持多用户多端口，支持 UDP)
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
restart_conf="${work_dir}/restart.conf"

UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
ARGO_WS_PORT=8080
ARGO_XHTTP_PORT=8081
CFIP=${CFIP:-'cdns.doon.eu.org'}
CFPORT=${CFPORT:-'443'}

[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1

# 初始化 FreeFlow 变量
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
[ -f "${restart_conf}" ] && RESTART_INTERVAL=$(cat "${restart_conf}" 2>/dev/null)

# ================= 状态检测模块 =================
check_xray() {
    [ ! -f "${work_dir}/${server_name}" ] && echo "未安装" && return 2
    if [ -f /etc/alpine-release ]; then
        rc-service xray status 2>/dev/null | grep -q "started" && echo "运行中" && return 0
    else
        [ "$(systemctl is-active xray 2>/dev/null)" = "active" ] && echo "运行中" && return 0
    fi
    echo "未运行"; return 1
}

check_service() {
    local svc_name="$1"
    [ ! -f "${work_dir}/argo" ] && echo "未安装" && return 2
    if [ -f /etc/alpine-release ]; then
        rc-service "${svc_name}" status 2>/dev/null | grep -q "started" && echo "运行中" && return 0
    else
        [ "$(systemctl is-active "${svc_name}" 2>/dev/null)" = "active" ] && echo "运行中" && return 0
    fi
    echo "未运行"; return 1
}

manage_packages() {
    local action=$1; shift
    for package in "$@"; do
        command -v "$package" > /dev/null 2>&1 && continue
        yellow "正在安装 ${package}..."
        if   command -v apt > /dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt install -y "$package" >/dev/null 2>&1
        elif command -v dnf > /dev/null 2>&1; then dnf install -y "$package" >/dev/null 2>&1
        elif command -v yum > /dev/null 2>&1; then yum install -y "$package" >/dev/null 2>&1
        elif command -v apk > /dev/null 2>&1; then apk update >/dev/null 2>&1 && apk add "$package" >/dev/null 2>&1
        fi
    done
}

get_realip() {
    local ip=$(curl -s --max-time 2 https://cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
    [ -z "$ip" ] && ip=$(curl -s --max-time 2 ipv6.ip.sb) && [ -n "$ip" ] && echo "[$ip]" && return
    echo "$ip"
}

get_current_uuid() {
    if [ -f "${config_dir}" ]; then
        local id=$(jq -r '(first(.inbounds[] | select(.protocol=="vless") | .settings.clients[0].id) // empty)' "${config_dir}" 2>/dev/null)
        [ -n "$id" ] && [ "$id" != "null" ] && echo "$id" && return
    fi
    echo "${UUID}"
}

# ================= Xray 核心管理 =================
init_xray_config() {
    mkdir -p "${work_dir}"
    if [ ! -f "${config_dir}" ]; then
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
}

install_core() {
    manage_packages install jq unzip curl
    mkdir -p "${work_dir}"
    
    # Xray
    if [ ! -f "${work_dir}/${server_name}" ]; then
        purple "下载 Xray 内核..."
        local ARCH_RAW=$(uname -m); local ARCH_ARG
        case "${ARCH_RAW}" in
            'x86_64') ARCH_ARG='64' ;;
            'aarch64'|'arm64') ARCH_ARG='arm64-v8a' ;;
            *) ARCH_ARG='32' ;;
        esac
        curl -sLo "${work_dir}/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_ARG}.zip"
        unzip -o "${work_dir}/xray.zip" -d "${work_dir}/" > /dev/null 2>&1
        chmod +x "${work_dir}/${server_name}"
        rm -f "${work_dir}/xray.zip" "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" "${work_dir}/README.md" "${work_dir}/LICENSE"
    fi

    # Argo
    if [ ! -f "${work_dir}/argo" ]; then
        purple "下载 Cloudflared..."
        local ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
        curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
        chmod +x "${work_dir}/argo"
    fi

    # 守护进程
    if [ ! -f /etc/systemd/system/xray.service ] && ! [ -f /etc/init.d/xray ]; then
        if [ -f /etc/alpine-release ]; then
            cat > /etc/init.d/xray << EOF
#!/sbin/openrc-run
description="Xray Service"
command="${work_dir}/xray"
command_args="run -c ${config_dir}"
command_background=true
pidfile="/var/run/xray.pid"
EOF
            chmod +x /etc/init.d/xray
            rc-update add xray default >/dev/null 2>&1
        else
            cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=${work_dir}/xray run -c ${config_dir}
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload && systemctl enable xray >/dev/null 2>&1
        fi
    fi
}

restart_xray() {
    [ -f /etc/alpine-release ] && rc-service xray restart >/dev/null 2>&1 || systemctl restart xray >/dev/null 2>&1
}

# ================= FreeFlow 模块 =================
_save_freeflow_conf() {
    mkdir -p "${work_dir}"
    printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"
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
            echo '{"port": 80, "listen": "::", "protocol": "vless", "settings": { "clients": [{ "id": "'${uuid}'" }], "decryption": "none" }, "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "'${FF_PATH}'" } }, "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }}'
            ;;
        httpupgrade)
            echo '{"port": 80, "listen": "::", "protocol": "vless", "settings": { "clients": [{ "id": "'${uuid}'" }], "decryption": "none" }, "streamSettings": { "network": "httpupgrade", "security": "none", "httpupgradeSettings": { "path": "'${FF_PATH}'" } }, "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }}'
            ;;
    esac
}

apply_freeflow_config() {
    init_xray_config
    local cur_uuid=$(get_current_uuid)
    
    # 外科手术：仅删除旧的 80 端口节点
    jq 'del(.inbounds[] | select(.port == 80))' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"

    if [ "${FREEFLOW_MODE}" != "none" ]; then
        local ff_json=$(get_freeflow_inbound_json "${cur_uuid}")
        jq --argjson ib "${ff_json}" '.inbounds += [$ib]' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
    fi
}

manage_freeflow() {
    clear; echo ""
    green  "FreeFlow 当前配置："
    if [ "${FREEFLOW_MODE}" = "none" ]; then
        skyblue "  未启用"
    else
        skyblue "  方式: ${FREEFLOW_MODE}（path=${FF_PATH}）"
    fi
    echo   "=========================="
    green  "1. 变更 FreeFlow 方式"
    green  "2. 修改 FreeFlow path"
    red    "3. 卸载 FreeFlow"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice

    case "${choice}" in
        1)
            ask_freeflow_mode
            apply_freeflow_config
            restart_xray
            green "FreeFlow 方式已变更"
            get_info
            ;;
        2)
            [ "${FREEFLOW_MODE}" = "none" ] && red "请先启用 FreeFlow！" && sleep 1 && return
            reading "请输入新的 FreeFlow path（回车保持当前 ${FF_PATH}）: " new_path
            if [ -n "${new_path}" ]; then
                case "${new_path}" in
                    /*) FF_PATH="${new_path}" ;;
                    *)  FF_PATH="/${new_path}" ;;
                esac
                _save_freeflow_conf
                apply_freeflow_config
                restart_xray
                green "FreeFlow path 已修改为：${FF_PATH}"
            fi
            get_info
            ;;
        3)
            FREEFLOW_MODE="none"
            _save_freeflow_conf
            apply_freeflow_config
            restart_xray
            green "FreeFlow 已关闭并卸载"
            ;;
        0) return ;;
        *) red "无效的选项！" ;;
    esac
}

# ================= Socks5 多端口管理模块 =================
manage_socks5() {
    while true; do
        clear; echo ""
        purple "=== Socks5 用户与端口管理 ==="
        init_xray_config
        local socks_list=$(jq -c '.inbounds[]? | select(.protocol == "socks")' "$config_dir" 2>/dev/null)
        
        if [ -z "$socks_list" ]; then
            yellow "当前未配置任何 Socks5 端口。"
        else
            echo "当前 Socks5 列表："
            echo "----------------------------------------------------"
            printf "%-10s | %-15s | %-15s\n" "端口" "用户名" "密码"
            while read -r line; do
                local p=$(echo "$line" | jq -r '.port')
                local u=$(echo "$line" | jq -r '.settings.accounts[0].user')
                local pass=$(echo "$line" | jq -r '.settings.accounts[0].pass')
                printf "%-10s | %-15s | %-15s\n" "$p" "$u" "$pass"
            done <<< "$socks_list"
            echo "----------------------------------------------------"
        fi

        green "1. 添加新 Socks5 端口"
        green "2. 修改已有端口/用户/密码"
        red   "3. 删除 Socks5 端口"
        purple "0. 返回主菜单"
        reading "\n请输入选择: " s_choice

        case "${s_choice}" in
            1)
                install_core
                reading "输入监听端口 (如 1080): " ns_port
                reading "输入用户名: " ns_user
                reading "输入密码: " ns_pass
                if [[ -n "$ns_port" && "$ns_port" =~ ^[0-9]+$ && -n "$ns_user" && -n "$ns_pass" ]]; then
                    # 关键修复：listen 设为 0.0.0.0 避免 IPv6 绑定失败，并开启 udp: true
                    jq --argjson p "$ns_port" --arg u "$ns_user" --arg pw "$ns_pass" \
                    '.inbounds += [{
                        "tag": ("socks-" + ($p|tostring)),
                        "port": $p,
                        "listen": "0.0.0.0",
                        "protocol": "socks",
                        "settings": { "auth": "password", "accounts": [{ "user": $u, "pass": $pw }], "udp": true }
                    }]' "$config_dir" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "$config_dir"
                    green "添加成功！请确保服务器防火墙已放行 $ns_port 端口。"
                    restart_xray
                else
                    red "输入无效！端口必须为数字，且用户名和密码不能为空。"
                fi
                ;;
            2)
                reading "请输入要修改的端口号: " edit_port
                reading "输入新用户名: " nu
                reading "输入新密码: " np
                if [[ -n "$edit_port" && "$edit_port" =~ ^[0-9]+$ && -n "$nu" && -n "$np" ]]; then
                    jq --argjson p "$edit_port" --arg u "$nu" --arg pw "$np" \
                    '(.inbounds[] | select(.protocol=="socks" and .port==$p) | .settings.accounts[0]) |= {"user": $u, "pass": $pw}' "$config_dir" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "$config_dir"
                    green "修改完成！"
                    restart_xray
                else
                    red "输入无效！"
                fi
                ;;
            3)
                reading "请输入要删除的端口号: " del_port
                if [[ -n "$del_port" && "$del_port" =~ ^[0-9]+$ ]]; then
                    jq --argjson p "$del_port" 'del(.inbounds[] | select(.protocol=="socks" and .port==$p))' "$config_dir" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "$config_dir"
                    green "删除完成！"
                    restart_xray
                else
                    red "输入无效！"
                fi
                ;;
            0) break ;;
            *) red "无效选择" ;;
        esac
        read -r -p "按回车键继续..." _dummy
    done
}

# ================= Argo 固定隧道挂载 =================
setup_argo_fixed() {
    local mode="$1"
    local port="$2"
    local svc_name="tunnel-${mode}"
    
    echo ""
    yellow "正在配置 ${mode^^} 专属隧道"
    reading "请输入你的 Argo 域名 (例如: node.yourdomain.com): " argo_domain
    [ -z "$argo_domain" ] && red "Argo 域名不能为空" && return 1
    
    reading "请输入 Argo 密钥（token 字符串 或 json 凭证文件内容）: " argo_auth
    [ -z "$argo_auth" ] && red "密钥不能为空" && return 1

    echo "$argo_domain" > "${work_dir}/domain_${mode}.txt"
    local exec_cmd=""

    if echo "$argo_auth" | grep -q "TunnelSecret"; then
        local tunnel_id=$(echo "$argo_auth" | jq -r '.TunnelID' 2>/dev/null || echo "$argo_auth" | cut -d'"' -f12)
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
    elif echo "$argo_auth" | grep -qE '^[A-Z0-9a-z=]{120,250}$'; then
        yellow "⚠️ 检测到 Token 模式！脚本会在本地将流量发往 ${port} 端口。"
        yellow "⚠️ 请务必确保在 Cloudflare Zero Trust 后台中，将该隧道的 Public Hostname 的 Service 设置为了: HTTP://localhost:${port}"
        exec_cmd="${work_dir}/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_auth}"
    else
        red "未识别的密钥格式！安装终止。"
        rm -f "${work_dir}/domain_${mode}.txt"
        return 1
    fi

    # 注册系统服务
    if [ -f /etc/alpine-release ]; then
        cat > /etc/init.d/${svc_name} << EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel ${mode^^}"
command="/bin/sh"
command_args="-c '${exec_cmd} >> ${work_dir}/argo_${mode}.log 2>&1'"
command_background=true
pidfile="/var/run/${svc_name}.pid"
EOF
        chmod +x /etc/init.d/${svc_name}
        rc-update add ${svc_name} default >/dev/null 2>&1
        rc-service ${svc_name} restart >/dev/null 2>&1
    else
        cat > /etc/systemd/system/${svc_name}.service << EOF
[Unit]
Description=Cloudflare Tunnel ${mode^^}
After=network.target
[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=${exec_cmd}
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ${svc_name} >/dev/null 2>&1
        systemctl restart ${svc_name} >/dev/null 2>&1
    fi
    green "Argo ${mode^^} 隧道服务已启动！"
    return 0
}

install_argo_ws() {
    install_core
    init_xray_config
    local cur_uuid=$(get_current_uuid)
    
    # 外科手术：确保留空 8080 后再注入
    jq 'del(.inbounds[] | select(.port == 8080))' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
    local ws_json='{"port": '${ARGO_WS_PORT}', "listen": "127.0.0.1", "protocol": "vless", "settings": {"clients": [{"id": "'${cur_uuid}'"}], "decryption": "none"}, "streamSettings": {"network": "ws", "security": "none", "wsSettings": {"path": "/vless-ws"}}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": false}}'
    jq --argjson ib "${ws_json}" '.inbounds += [$ib]' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
    
    if setup_argo_fixed "ws" "${ARGO_WS_PORT}"; then
        restart_xray
        get_info
    else
        uninstall_component "ws" # 失败自动回滚
    fi
}

install_argo_xhttp() {
    install_core
    init_xray_config
    local cur_uuid=$(get_current_uuid)
    
    # 外科手术：确保留空 8081 后再注入 (强制使用 auto 模式)
    jq 'del(.inbounds[] | select(.port == 8081))' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
    local xhttp_json='{"port": '${ARGO_XHTTP_PORT}', "listen": "127.0.0.1", "protocol": "vless", "settings": {"clients": [{"id": "'${cur_uuid}'"}], "decryption": "none"}, "streamSettings": {"network": "xhttp", "security": "none", "xhttpSettings": {"host": "", "path": "/vless-xhttp", "mode": "auto"}}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": false}}'
    jq --argjson ib "${xhttp_json}" '.inbounds += [$ib]' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
    
    if setup_argo_fixed "xhttp" "${ARGO_XHTTP_PORT}"; then
        restart_xray
        get_info
    else
        uninstall_component "xhttp"
    fi
}

# ================= 节点链接汇总 =================
get_info() {
    clear; local IP=$(get_realip)
    local cur_uuid=$(get_current_uuid)
    > "${client_dir}"
    echo ""
    green "============ 当前可用节点链接 ============"

    # 检查 WS
    if [ -f "${work_dir}/domain_ws.txt" ]; then
        local domain_ws=$(cat "${work_dir}/domain_ws.txt")
        local link="vless://${cur_uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${domain_ws}&fp=chrome&type=ws&host=${domain_ws}&path=%2Fvless-ws%3Fed%3D2560#Argo-WS"
        echo "${link}" >> "${client_dir}"
        purple "${link}"
        echo ""
    fi

    # 检查 XHTTP
    if [ -f "${work_dir}/domain_xhttp.txt" ]; then
        local domain_xhttp=$(cat "${work_dir}/domain_xhttp.txt")
        local link="vless://${cur_uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${domain_xhttp}&fp=chrome&type=xhttp&host=${domain_xhttp}&path=%2Fvless-xhttp#Argo-XHTTP"
        echo "${link}" >> "${client_dir}"
        purple "${link}"
        echo ""
    fi

    # 检查 FreeFlow
    if [ "${FREEFLOW_MODE}" != "none" ] && [ -n "$IP" ]; then
        local path_enc=$(printf '%s' "${FF_PATH}" | sed 's|%|%25|g; s| |%20|g')
        local link="vless://${cur_uuid}@${IP}:80?encryption=none&security=none&type=${FREEFLOW_MODE}&host=${IP}&path=${path_enc}#FreeFlow-${FREEFLOW_MODE^^}"
        echo "${link}" >> "${client_dir}"
        purple "${link}"
        echo ""
    fi
    
    # 检查 Socks5
    if [ -f "${config_dir}" ] && [ -n "$IP" ]; then
        local socks_list=$(jq -c '.inbounds[]? | select(.protocol == "socks")' "$config_dir" 2>/dev/null)
        if [ -n "$socks_list" ]; then
            while read -r line; do
                local p=$(echo "$line" | jq -r '.port')
                local u=$(echo "$line" | jq -r '.settings.accounts[0].user')
                local pw=$(echo "$line" | jq -r '.settings.accounts[0].pass')
                local link="socks5://${u}:${pw}@${IP}:${p}#Socks5-${p}"
                echo "${link}" >> "${client_dir}"
                purple "${link}"
                echo ""
            done <<< "$socks_list"
        fi
    fi
    
    [ ! -s "${client_dir}" ] && yellow "当前没有任何节点配置。"
    echo "=========================================="
    echo ""
}

# ================= 卸载模块 =================
uninstall_component() {
    local target="$1"
    
    if [ "$target" = "ws" ]; then
        if [ -f /etc/alpine-release ]; then
            rc-service tunnel-ws stop 2>/dev/null; rc-update del tunnel-ws default 2>/dev/null; rm -f /etc/init.d/tunnel-ws
        else
            systemctl stop tunnel-ws 2>/dev/null; systemctl disable tunnel-ws 2>/dev/null; rm -f /etc/systemd/system/tunnel-ws.service
        fi
        rm -f "${work_dir}/domain_ws.txt" "${work_dir}/tunnel_ws.yml" "${work_dir}/tunnel_ws.json"
        [ -f "${config_dir}" ] && jq 'del(.inbounds[] | select(.port == 8080))' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
        green "Argo WS 已卸载！"
        restart_xray
    fi

    if [ "$target" = "xhttp" ]; then
        if [ -f /etc/alpine-release ]; then
            rc-service tunnel-xhttp stop 2>/dev/null; rc-update del tunnel-xhttp default 2>/dev/null; rm -f /etc/init.d/tunnel-xhttp
        else
            systemctl stop tunnel-xhttp 2>/dev/null; systemctl disable tunnel-xhttp 2>/dev/null; rm -f /etc/systemd/system/tunnel-xhttp.service
        fi
        rm -f "${work_dir}/domain_xhttp.txt" "${work_dir}/tunnel_xhttp.yml" "${work_dir}/tunnel_xhttp.json"
        [ -f "${config_dir}" ] && jq 'del(.inbounds[] | select(.port == 8081))' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
        green "Argo XHTTP 已卸载！"
        restart_xray
    fi

    if [ "$target" = "all" ]; then
        if [ -f /etc/alpine-release ]; then
            rc-service tunnel-ws stop 2>/dev/null; rc-update del tunnel-ws default 2>/dev/null; rm -f /etc/init.d/tunnel-ws
            rc-service tunnel-xhttp stop 2>/dev/null; rc-update del tunnel-xhttp default 2>/dev/null; rm -f /etc/init.d/tunnel-xhttp
            rc-service xray stop 2>/dev/null; rc-update del xray default 2>/dev/null; rm -f /etc/init.d/xray
        else
            systemctl stop tunnel-ws 2>/dev/null; systemctl disable tunnel-ws 2>/dev/null; rm -f /etc/systemd/system/tunnel-ws.service
            systemctl stop tunnel-xhttp 2>/dev/null; systemctl disable tunnel-xhttp 2>/dev/null; rm -f /etc/systemd/system/tunnel-xhttp.service
            systemctl stop xray 2>/dev/null; systemctl disable xray 2>/dev/null; rm -f /etc/systemd/system/xray.service
        fi
        rm -rf "${work_dir}"
        green "所有组件彻底卸载完成！"
        exit 0
    fi
}

# ================= 自动重启与杂项 =================
setup_auto_restart() {
    local restart_cmd="systemctl restart xray"
    [ -f /etc/alpine-release ] && restart_cmd="rc-service xray restart"
    (crontab -l 2>/dev/null || true) | sed '/xray-restart/d' > /tmp/crontab.tmp
    echo "*/${RESTART_INTERVAL} * * * * ${restart_cmd} >/dev/null 2>&1 #xray-restart" >> /tmp/crontab.tmp
    crontab /tmp/crontab.tmp && rm -f /tmp/crontab.tmp
}

manage_restart() {
    clear; echo ""
    green "Xray 自动重启间隔：当前 ${RESTART_INTERVAL} 分钟 (0=关闭)"
    reading "请输入间隔分钟（0关闭，推荐 60）: " new_int
    if echo "${new_int}" | grep -qE '^[0-9]+$'; then
        RESTART_INTERVAL="${new_int}"
        echo "${RESTART_INTERVAL}" > "${restart_conf}"
        if [ "${RESTART_INTERVAL}" -eq 0 ]; then
            (crontab -l 2>/dev/null || true) | sed '/xray-restart/d' | crontab -
            green "自动重启已关闭"
        else
            setup_auto_restart
            green "已设置每 ${RESTART_INTERVAL} 分钟自动重启"
        fi
    fi
}

modify_uuid() {
    reading "输入新 UUID (回车自动生成): " new_uuid
    [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
    if [ -f "${config_dir}" ]; then
        jq --arg uuid "$new_uuid" '(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) |= $uuid' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
        restart_xray
        green "UUID 已修改为: $new_uuid"
        get_info
    else
        yellow "配置文件不存在，请先安装节点"
    fi
}

# ================= 主菜单 =================
menu() {
    while true; do
        local x_stat=$(check_xray)
        local ws_stat=$(check_service "tunnel-ws")
        local xhttp_stat=$(check_service "tunnel-xhttp")
        
        [ ! -f "${work_dir}/domain_ws.txt" ] && ws_stat="未配置"
        [ ! -f "${work_dir}/domain_xhttp.txt" ] && xhttp_stat="未配置"
        
        local ff_display="未启用"
        [ "${FREEFLOW_MODE}" != "none" ] && ff_display="${FREEFLOW_MODE} (path=${FF_PATH})"
        
        local socks_count=$(jq '[.inbounds[]? | select(.protocol == "socks")] | length' "$config_dir" 2>/dev/null)
        local socks_display="未启用"
        [ -n "$socks_count" ] && [ "$socks_count" -gt 0 ] && socks_display="已启用 ($socks_count 个端口)"

        clear; echo ""
        purple "=== Xray-argo 脚本（固定隧道双协议 + Socks5 版） ==="
        purple " Xray 核心:   ${x_stat}"
        purple " Argo WS:     ${ws_stat}"
        purple " Argo XHTTP:  ${xhttp_stat}"
        purple " FreeFlow:    ${ff_display}"
        purple " Socks5:      ${socks_display}"
        echo   "=========================================="
        green  "1. 安装 Argo 隧道 (WS 模式)"
        red    "2. 卸载 Argo 隧道 (WS 模式)"
        echo   "------------------------------------------"
        green  "3. 安装 Argo 隧道 (XHTTP 模式)"
        red    "4. 卸载 Argo 隧道 (XHTTP 模式)"
        echo   "------------------------------------------"
        green  "5. FreeFlow (直连) 模块管理"
        green  "6. Socks5 代理模块管理"
        echo   "------------------------------------------"
        green  "7. 查看所有节点链接"
        green  "8. 修改用户 UUID"
        green  "9. Xray 自动重启管理"
        red    "10. 一键卸载全部组件"
        echo   "------------------------------------------"
        red    "0. 退出脚本"
        echo   "=========================================="
        reading "请输入选择(0-10): " choice
        echo ""

        case "${choice}" in
            1) install_argo_ws ;;
            2) uninstall_component "ws" ;;
            3) install_argo_xhttp ;;
            4) uninstall_component "xhttp" ;;
            5) manage_freeflow ;;
            6) manage_socks5 ;;
            7) get_info ;;
            8) modify_uuid ;;
            9) manage_restart ;;
            10) uninstall_component "all" ;;
            0) exit 0 ;;
            *) red "无效选项" ;;
        esac
        printf '\033[1;91m按回车键继续...\033[0m'
        read -r _dummy
    done
}

menu