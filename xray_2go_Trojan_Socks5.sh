#!/bin/bash

# ============================================================
# Xray-Argo Trojan + Socks5 综合版 (Alpine/Debian/CentOS 通用)
# 功能：Trojan+WS+Argo 隧道 & 多 Socks5 端口管理
# ============================================================

red()    { echo -e "\e[1;31m$1\033[0m"; }
green()  { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue(){ echo -e "\e[1;36m$1\033[0m"; }
reading(){ read -p "$(red "$1")" "$2"; }

# ── 常量 ────────────────────────────────────────────────────
server_name="xray"
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"

# ── 环境变量 ───────────────────────────────────
export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
export ARGO_PORT=${ARGO_PORT:-'8080'}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

[[ $EUID -ne 0 ]] && red "请在 root 用户下运行脚本" && exit 1

# ================= 状态检查 =================
check_status() {
    local service=$1
    local status="Not Installed"
    local color_func="red"

    if [ "$service" == "xray" ]; then
        [ ! -f "${work_dir}/${server_name}" ] && { red "未安装"; return; }
        if [ -f /etc/alpine-release ]; then
            rc-service xray status 2>/dev/null | grep -q "started" && status="Running" && color_func="green"
        else
            [ "$(systemctl is-active xray 2>/dev/null)" = "active" ] && status="Running" && color_func="green"
        fi
    else
        [ ! -f "${work_dir}/argo" ] && { red "未安装"; return; }
        if [ -f /etc/alpine-release ]; then
            rc-service tunnel status 2>/dev/null | grep -q "started" && status="Running" && color_func="green"
        else
            [ "$(systemctl is-active tunnel 2>/dev/null)" = "active" ] && status="Running" && color_func="green"
        fi
    fi
    $color_func "$status"
}

manage_packages() {
    local action=$1; shift
    for package in "$@"; do
        command -v "$package" &>/dev/null && continue
        if   command -v apt &>/dev/null; then DEBIAN_FRONTEND=noninteractive apt install -y "$package"
        elif command -v dnf &>/dev/null; then dnf install -y "$package"
        elif command -v yum &>/dev/null; then yum install -y "$package"
        elif command -v apk &>/dev/null; then apk update && apk add "$package"
        fi
    done
}

# ================= 安装逻辑 =================
install_xray() {
    clear
    purple "正在安装 Xray-Argo (Trojan + Socks5 版)..."
    local ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') ARCH='amd64'; ARCH_ARG='64' ;;
        'aarch64'|'arm64') ARCH='arm64'; ARCH_ARG='arm64-v8a' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    mkdir -p "${work_dir}" && chmod 755 "${work_dir}"

    curl -sLo "${work_dir}/${server_name}.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_ARG}.zip" || exit 1
    curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" || exit 1
    unzip -o "${work_dir}/${server_name}.zip" -d "${work_dir}/" > /dev/null 2>&1
    chmod +x "${work_dir}/${server_name}" "${work_dir}/argo"
    rm -f "${work_dir}/${server_name}.zip"

    # 默认生成的配置文件：包含 Trojan 入站
    cat > "${config_dir}" << EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "tag": "trojan-in",
      "port": ${ARGO_PORT},
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": { 
        "clients": [{ "password": "${UUID}" }] 
      },
      "streamSettings": { 
        "network": "ws", 
        "wsSettings": { "path": "/vless-argo" } 
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
}

# ================= 服务管理 =================
main_services() {
    if [ ! -f /etc/alpine-release ]; then
        cat > /etc/systemd/system/xray.service << EOF
[Unit]
After=network.target
[Service]
ExecStart=${work_dir}/xray run -c ${config_dir}
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
        cat > /etc/systemd/system/tunnel.service << EOF
[Unit]
After=network.target
[Service]
ExecStart=/bin/sh -c '${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --protocol http2 >> ${work_dir}/argo.log 2>&1'
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now xray tunnel
    else
        echo "0 0" > /proc/sys/net/ipv4/ping_group_range
        cat > /etc/init.d/xray << EOF
#!/sbin/openrc-run
command="${work_dir}/xray"
command_args="run -c ${config_dir}"
command_background=true
pidfile="/var/run/xray.pid"
EOF
        cat > /etc/init.d/tunnel << EOF
#!/sbin/openrc-run
command="/bin/sh"
command_args="-c '${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --protocol http2 >> ${work_dir}/argo.log 2>&1'"
command_background=true
pidfile="/var/run/tunnel.pid"
EOF
        chmod +x /etc/init.d/xray /etc/init.d/tunnel
        rc-update add xray default && rc-update add tunnel default
        rc-service xray restart && rc-service tunnel restart
    fi
}

# ================= Socks5 管理模块 =================
manage_socks5() {
    while true; do
        clear
        purple "=== Socks5 用户与端口管理 ==="
        # 使用 jq 获取当前所有 socks 协议的入站
        local socks_list=$(jq -c '.inbounds[] | select(.protocol == "socks")' "$config_dir" 2>/dev/null)
        
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
                reading "输入监听端口 (如 1080): " ns_port
                reading "输入用户名: " ns_user
                reading "输入密码: " ns_pass
                jq --argjson p "$ns_port" --arg u "$ns_user" --arg pw "$ns_pass" \
                '.inbounds += [{
                    "tag": ("socks-" + ($p|tostring)),
                    "port": $p,
                    "listen": "0.0.0.0",
                    "protocol": "socks",
                    "settings": { "auth": "password", "accounts": [{ "user": $u, "pass": $pw }] }
                }]' "$config_dir" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "$config_dir"
                green "添加成功！"
                ;;
            2)
                reading "请输入要修改的端口号: " edit_port
                reading "输入新用户名: " nu
                reading "输入新密码: " np
                jq --argjson p "$edit_port" --arg u "$nu" --arg pw "$np" \
                '(.inbounds[] | select(.protocol=="socks" and .port==$p) | .settings.accounts[0]) |= {"user": $u, "pass": $pw}' "$config_dir" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "$config_dir"
                green "修改完成！"
                ;;
            3)
                reading "请输入要删除的端口号: " del_port
                jq --argjson p "$del_port" 'del(.inbounds[] | select(.protocol=="socks" and .port==$p))' "$config_dir" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "$config_dir"
                green "删除完成！"
                ;;
            0) break ;;
        esac
        # 重启服务
        if [ -f /etc/alpine-release ]; then rc-service xray restart; else systemctl restart xray; fi
        read -p "操作完成，按任意键继续..."
    done
}

# ================= 原有功能补充 =================
restart_argo() {
    rm -f "${work_dir}/argo.log"
    if [ -f /etc/alpine-release ]; then rc-service tunnel restart
    else systemctl restart tunnel; fi
}

get_argodomain() {
    sleep 4
    sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | head -1
}

get_info() {
    clear
    purple "正在获取域名...\n"
    restart_argo
    local domain=$(get_argodomain)
    [ -z "$domain" ] && domain="<获取失败>"
    echo "trojan://${UUID}@${CFIP}:${CFPORT}?security=tls&sni=${domain}&type=ws&host=${domain}&path=%2Fvless-argo%3Fed%3D2560#Argo_Trojan" > "${client_dir}"
    green "Trojan 节点已更新："
    purple "$(cat ${client_dir})\n"
}

manage_argo() {
    clear; echo ""
    green  "1. 启动 Argo"; green "2. 停止 Argo"
    green  "3. 添加固定隧道 (Token/Json)"; green "4. 切换回临时隧道"
    green  "5. 重新获取临时域名"; purple "0. 返回"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1) if [ -f /etc/alpine-release ]; then rc-service tunnel start; else systemctl start tunnel; fi ;;
        2) if [ -f /etc/alpine-release ]; then rc-service tunnel stop; else systemctl stop tunnel; fi ;;
        3) 
            reading "请输入域名: " argo_domain
            reading "请输入 Token/Json: " argo_auth
            if [[ $argo_auth =~ TunnelSecret ]]; then
                echo "$argo_auth" > "${work_dir}/tunnel.json"
                cat > "${work_dir}/tunnel.yml" << EOF
tunnel: $(cut -d\" -f12 <<< "$argo_auth")
credentials-file: ${work_dir}/tunnel.json
ingress:
  - hostname: ${argo_domain}
    service: http://localhost:${ARGO_PORT}
  - service: http_status:404
EOF
                CMD="${work_dir}/argo tunnel --config ${work_dir}/tunnel.yml run"
            else
                CMD="${work_dir}/argo tunnel --no-autoupdate --protocol http2 run --token ${argo_auth}"
            fi
            
            if [ -f /etc/alpine-release ]; then
                sed -i "/^command_args=/c\command_args=\"-c '$CMD >> ${work_dir}/argo.log 2>&1'\"" /etc/init.d/tunnel
            else
                sed -i "/^ExecStart=/c\\ExecStart=/bin/sh -c '$CMD >> ${work_dir}/argo.log 2>&1'" /etc/systemd/system/tunnel.service
            fi
            restart_argo
            sed -i "s/sni=[^&]*/sni=${argo_domain}/; s/host=[^&]*/host=${argo_domain}/" "${client_dir}"
            green "固定隧道配置完成";;
        4) 
            if [ -f /etc/alpine-release ]; then
                sed -i "/^command_args=/c\command_args=\"-c '${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --protocol http2 >> ${work_dir}/argo.log 2>&1'\"" /etc/init.d/tunnel
            else
                sed -i "/^ExecStart=/c\\ExecStart=/bin/sh -c '${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --protocol http2 >> ${work_dir}/argo.log 2>&1'" /etc/systemd/system/tunnel.service
            fi
            get_info ;;
        5) get_info ;;
        0) menu ;;
    esac
}

change_config() {
    clear; echo ""
    green "1. 修改 Trojan Password (原UUID)"; green "2. 修改 Argo 回源端口 (当前: ${ARGO_PORT})"
    purple "0. 返回"
    reading "选择: " choice
    case "${choice}" in
        1)
            reading "新 Password (留空随机): " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            sed -i "s/\"password\": \".*\"/\"password\": \"$new_uuid\"/g" "$config_dir"
            sed -i "s/trojan:\/\/[^@]*@/trojan:\/\/$new_uuid@/" "$client_dir"
            if [ -f /etc/alpine-release ]; then rc-service xray restart; else systemctl restart xray; fi
            green "Trojan Password 已更新: $new_uuid" ;;
        2)
            reading "新端口: " new_port
            jq --argjson p "$new_port" '(.inbounds[] | select(.tag=="trojan-in")).port = $p' "$config_dir" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "$config_dir"
            export ARGO_PORT=$new_port
            main_services
            green "回源端口已更新: $new_port" ;;
        0) menu ;;
    esac
}

# ================= 主菜单 =================
menu() {
    while true; do
        clear; echo ""
        purple "=== Xray-Argo Trojan & Socks5 Lite (Multi-OS) ==="
        echo -n "Xray 状态: "; check_status "xray"
        echo -n "Argo 状态: "; check_status "argo"
        echo "----------------------------------------------------"
        green "1. 安装/更新 Xray-Argo"
        red   "2. 彻底卸载"
        echo "----------------"
        green "3. Argo 隧道管理 (固定/临时)"
        green "4. 查看 Trojan 节点链接"
        green "5. 修改 Trojan 配置 (密码/端口)"
        skyblue "6. Socks5 管理 (多用户/多端口)"
        red   "0. 退出"
        reading "\n选择(0-6): " choice
        case "${choice}" in
            1) manage_packages install jq unzip curl bash; install_xray; main_services; get_info ;;
            2) 
               if [ -f /etc/alpine-release ]; then rc-service xray stop; rc-service tunnel stop; else systemctl stop xray tunnel; fi
               rm -rf "$work_dir" /etc/systemd/system/xray.service /etc/systemd/system/tunnel.service /etc/init.d/xray /etc/init.d/tunnel
               green "卸载完成" ;;
            3) manage_argo ;;
            4) [ -f "$client_dir" ] && purple "\n$(cat $client_dir)\n" || yellow "未安装" ;;
            5) change_config ;;
            6) manage_socks5 ;;
            0) exit 0 ;;
        esac
        read -p "按任意键继续..."
    done
}

menu