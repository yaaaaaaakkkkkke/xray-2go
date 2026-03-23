#!/bin/bash

# ============================================================
# 精简版 Xray-Argo 一键脚本
# 协议：
#   必选：VLESS+WS+TLS（Cloudflare Argo 隧道）
#   可选：VLESS+WS 免流（port 80）| VLESS+TCP 免流（port 80）| 不安装
# ============================================================

# 颜色输出：printf 替代 echo -e，避免依赖 echo 的 -e 扩展行为
red()    { printf '\033[1;91m%s\033[0m\n' "$1"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$1"; }
purple() { printf '\033[1;35m%s\033[0m\n' "$1"; }
skyblue(){ printf '\033[1;36m%s\033[0m\n' "$1"; }
# reading：printf 输出提示（无末尾换行），read -r 读取输入
reading() { printf '\033[1;91m%s\033[0m' "$1"; read -r "$2"; }

# ── 常量 ────────────────────────────────────────────────────
server_name="xray"
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
freeflow_conf="${work_dir}/freeflow.conf"

# ── 环境变量（可外部注入） ───────────────────────────────────
export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
export ARGO_PORT=${ARGO_PORT:-'8080'}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

# root 检查：用 [ ] 替代 [[ ]]
[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1

# ── 读取持久化免流模式，校验合法值，非法值回退 none ──────────
# FREEFLOW_MODE: none | ws | tcp
_raw_mode=$(cat "${freeflow_conf}" 2>/dev/null)
case "${_raw_mode}" in
    ws|tcp) FREEFLOW_MODE="${_raw_mode}" ;;
    *)      FREEFLOW_MODE="none"         ;;
esac
unset _raw_mode

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
    [ $# -lt 2 ] && red "未指定包名或操作" && return 1
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
# 任一 IP 获取失败时回退，两者均失败则返回空字符串
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
# 从 config.json 读取当前实际 UUID，作为统一入口
# 避免全局变量 $UUID 与文件不同步
# ============================================================
get_current_uuid() {
    jq -r '.inbounds[0].settings.clients[0].id' "${config_dir}"
}

# ============================================================
# save_freeflow_mode
# 持久化 FREEFLOW_MODE 到文件
# work_dir 可能尚不存在（安装前调用），先 mkdir
# ============================================================
save_freeflow_mode() {
    mkdir -p "${work_dir}"
    echo "${FREEFLOW_MODE}" > "${freeflow_conf}"
}

# ============================================================
# ask_freeflow_mode
# 交互选择免流方式，写入 FREEFLOW_MODE 并持久化
# ============================================================
ask_freeflow_mode() {
    echo ""
    green  "请选择免流方式："
    skyblue "-----------------------------"
    green  "1. VLESS + WS  （明文 WebSocket，port 80）"
    green  "2. VLESS + TCP （明文 TCP，port 80）"
    green  "3. 不安装免流节点（默认）"
    skyblue "-----------------------------"
    reading "请输入选择(1-3，回车默认3): " ff_choice

    case "${ff_choice}" in
        1) FREEFLOW_MODE="ws"   ;;
        2) FREEFLOW_MODE="tcp"  ;;
        *) FREEFLOW_MODE="none" ;;
    esac
    save_freeflow_mode

    case "${FREEFLOW_MODE}" in
        ws)   green  "已选择：VLESS+WS 免流"  ;;
        tcp)  green  "已选择：VLESS+TCP 免流" ;;
        none) yellow "不安装免流节点"          ;;
    esac
    echo ""
}

# ============================================================
# get_freeflow_inbound_json <uuid>
# 根据 FREEFLOW_MODE 输出免流 inbound JSON 字符串
# VLESS+WS：port 80，path=/luckyss
# VLESS+TCP：port 80，TCP 裸连
# none：不输出
# ============================================================
get_freeflow_inbound_json() {
    local uuid="$1"
    case "${FREEFLOW_MODE}" in
        ws)
            cat << EOF
{
  "port": 80, "listen": "::", "protocol": "vless",
  "settings": { "clients": [{ "id": "${uuid}" }], "decryption": "none" },
  "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/luckyss" } },
  "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }
}
EOF
            ;;
        tcp)
            cat << EOF
{
  "port": 80, "listen": "::", "protocol": "vless",
  "settings": { "clients": [{ "id": "${uuid}" }], "decryption": "none" },
  "streamSettings": { "network": "tcp", "security": "none" },
  "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }
}
EOF
            ;;
    esac
}

# ============================================================
# apply_freeflow_config
# 根据 FREEFLOW_MODE 用 jq 修改 config.json 的 inbounds[1]
# UUID 从 config.json 读取，与文件始终一致
# ============================================================
apply_freeflow_config() {
    local cur_uuid ff_json
    cur_uuid=$(get_current_uuid)

    case "${FREEFLOW_MODE}" in
        ws|tcp)
            ff_json=$(get_freeflow_inbound_json "${cur_uuid}")
            jq --argjson ib "${ff_json}" '
                if (.inbounds | length) == 1
                then .inbounds += [$ib]
                else .inbounds[1] = $ib
                end
            ' "${config_dir}" > "${config_dir}.tmp" \
                && mv "${config_dir}.tmp" "${config_dir}"
            ;;
        none)
            jq 'if (.inbounds | length) > 1 then .inbounds = [.inbounds[0]] else . end' \
                "${config_dir}" > "${config_dir}.tmp" \
                && mv "${config_dir}.tmp" "${config_dir}"
            ;;
    esac
}

# ============================================================
# install_xray
# 下载 xray + cloudflared，写入基础 config.json（仅 Argo inbound）
# 再调用 apply_freeflow_config 追加免流 inbound（复用 jq 逻辑）
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

    curl -sLo "${work_dir}/${server_name}.zip" \
        "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_ARG}.zip" \
        || { red "xray 下载失败，请检查网络"; exit 1; }

    curl -sLo "${work_dir}/argo" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" \
        || { red "cloudflared 下载失败，请检查网络"; exit 1; }

    unzip "${work_dir}/${server_name}.zip" -d "${work_dir}/" > /dev/null 2>&1 \
        || { red "xray 解压失败"; exit 1; }

    chmod +x "${work_dir}/${server_name}" "${work_dir}/argo"
    rm -rf "${work_dir}/${server_name}.zip" \
           "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" \
           "${work_dir}/README.md"   "${work_dir}/LICENSE"

    # 基础 config：仅 Argo inbound，合法完整 JSON，无字符串拼接
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

    apply_freeflow_config
}

# ============================================================
# main_systemd_services
# 写入 systemd 服务文件并启动（Debian / Ubuntu / CentOS）
# stdout + stderr 均写入 argo.log 确保域名日志可解析
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

    # CentOS：时间同步 + CA 证书，影响 cloudflared TLS 握手
    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd && systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
    fi

    systemctl daemon-reload
    systemctl enable xray   && systemctl start xray
    systemctl enable tunnel && systemctl start tunnel
}

# ============================================================
# alpine_openrc_services
# 写入 OpenRC 服务脚本并注册开机自启（Alpine Linux）
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

    cat > /etc/init.d/tunnel << EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '/etc/xray/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> /etc/xray/argo.log 2>&1'"
command_background=true
pidfile="/var/run/tunnel.pid"
EOF

    chmod +x /etc/init.d/xray /etc/init.d/tunnel
    rc-update add xray default
    rc-update add tunnel default
}

# change_hosts（Alpine 专用）
# 修复 cloudflared ping_group_range 报错和 /etc/hosts DNS 问题
change_hosts() {
    echo "0 0" > /proc/sys/net/ipv4/ping_group_range
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

# ============================================================
# reset_tunnel_to_temp
# 只重写 ExecStart/command_args 一行切换回临时隧道
# 格式与 manage_argo 选项5的 grep -Fq 匹配字符串保持一致
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
# restart_argo 删除旧 argo.log，避免解析到过期临时域名
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
# 先 sleep 3 等待 cloudflared 写入，再最多轮询 5 次（每次 sleep 2）
# 用 while 计数替代 bash-specific {1..5} brace expansion
# ============================================================
get_argodomain() {
    sleep 3
    local domain i
    i=1
    while [ "$i" -le 5 ]; do
        domain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' \
            "${work_dir}/argo.log" 2>/dev/null | head -1)
        if [ -n "$domain" ]; then echo "$domain"; return 0; fi
        sleep 2
        i=$(( i + 1 ))
    done
    echo ""; return 1
}

# ============================================================
# print_nodes
# 将 url.txt 内容以紫色逐行输出，跳过空行
# printf 替代 echo -e，避免依赖 echo 扩展行为
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
# 根据 FREEFLOW_MODE 输出免流节点链接行
# UUID 从 config.json 读取，与文件始终一致
# ============================================================
build_freeflow_link() {
    local ip="$1" uuid
    uuid=$(get_current_uuid)
    case "${FREEFLOW_MODE}" in
        ws)
            echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=ws&host=${ip}&path=%2Fluckyss#FreeFlow-WS"
            ;;
        tcp)
            echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=tcp#FreeFlow-TCP"
            ;;
        # none：不输出
    esac
}

# ============================================================
# get_info
# 重启 Argo，获取临时域名，生成 url.txt 并打印
#
# url.txt 结构：
#   第1行：Argo 节点（必选，get_quick_tunnel 的 sed 锚定此行）
#   第2行：免流节点（FREEFLOW_MODE != none 时存在）
# ============================================================
get_info() {
    clear
    local IP argodomain
    IP=$(get_realip)

    purple "正在获取 ArgoDomain，请稍等..."
    restart_argo
    argodomain=$(get_argodomain)

    if [ -z "$argodomain" ]; then
        yellow "未能获取 ArgoDomain，Argo 节点链接暂时无效，可稍后通过 Argo 管理菜单重新获取"
        argodomain="<未获取到域名>"
    else
        green "ArgoDomain：${argodomain}"
    fi
    echo ""

    {
        echo "vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#Argo"
        build_freeflow_link "${IP}"
    } > "${client_dir}"

    print_nodes
}

# ============================================================
# get_quick_tunnel
# 重启 Argo，提取新临时域名，更新 url.txt 第1行的 sni/host
# ============================================================
get_quick_tunnel() {
    if [ ! -f "${client_dir}" ]; then
        yellow "节点文件不存在，请先执行安装以初始化节点信息"
        return 1
    fi
    yellow "正在重启 Argo 并获取新临时域名..."
    restart_argo
    local argodomain
    argodomain=$(get_argodomain)

    if [ -z "$argodomain" ]; then
        yellow "未能获取临时域名，请检查网络或稍后重试"
        return 1
    fi

    green "ArgoDomain：${argodomain}"
    sed -i "1s/sni=[^&]*/sni=${argodomain}/; 1s/host=[^&]*/host=${argodomain}/" "${client_dir}"
    print_nodes
    green "节点已更新，请手动复制以上链接"
}

# ============================================================
# manage_argo - Argo 隧道管理
# ============================================================
manage_argo() {
    local argo_status cx
    argo_status=$(check_argo); cx=$?
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
            if [ -z "$argo_domain" ]; then
                red "Argo 域名不能为空"; return
            fi
            reading "请输入 Argo 密钥（token 或 json）: " argo_auth

            # 用 grep 替代 [[ =~ ]] 检测 TunnelSecret
            if echo "$argo_auth" | grep -q "TunnelSecret"; then
                # 用 echo | cut 替代 <<< here-string
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
            # 用 grep -E 替代 [[ =~ regex ]] 检测 token 格式
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
# change_config - 修改 UUID / Argo 端口 / WS Path / 免流方式
# ============================================================
change_config() {
    local ff_label
    case "${FREEFLOW_MODE}" in
        ws)   ff_label="VLESS+WS（当前）"  ;;
        tcp)  ff_label="VLESS+TCP（当前）" ;;
        none) ff_label="未安装（当前）"    ;;
        *)    ff_label="未知"              ;;
    esac

    clear; echo ""
    green  "1. 修改 UUID"
    skyblue "------------"
    green  "2. 修改 Argo 回源端口（当前：${ARGO_PORT}）"
    skyblue "-------------------------------------------"
    green  "3. 修改免流 WS Path（仅 WS 模式有效）"
    skyblue "--------------------------------------"
    green  "4. 变更免流方式（${ff_label}）"
    skyblue "--------------------------------"
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
            reading "请输入新的 Argo 回源端口（回车随机）: " new_port
            if [ -z "$new_port" ]; then
                new_port=$(shuf -i 2000-65000 -n 1)
            fi
            # 用 grep -E 替代 [[ =~ ]] 做数字格式校验
            if ! echo "$new_port" | grep -qE '^[0-9]+$' || \
               [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                red "端口无效，请输入 1-65535 的整数"; return
            fi
            jq --argjson p "$new_port" '.inbounds[0].port = $p' "$config_dir" \
                > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
            if [ -f /etc/alpine-release ]; then
                sed -i "s|http://localhost:[0-9]*|http://localhost:${new_port}|g" \
                    /etc/init.d/tunnel
            else
                sed -i "s|http://localhost:[0-9]*|http://localhost:${new_port}|g" \
                    /etc/systemd/system/tunnel.service
            fi
            export ARGO_PORT=$new_port
            restart_xray && restart_argo
            green "Argo 回源端口已修改为：${new_port}"
            ;;
        3)
            if [ "${FREEFLOW_MODE}" != "ws" ]; then
                yellow "当前免流模式为「${FREEFLOW_MODE}」，WS Path 仅在 WS 模式下有效"; return
            fi
            reading "请输入新的 WS Path（仅限字母数字下划线连字符，回车默认 luckyss）: " new_path
            if [ -z "$new_path" ]; then
                new_path="luckyss"
            # 用 grep -E 替代 [[ =~ ]] 做字符集校验
            elif ! echo "$new_path" | grep -qE '^[A-Za-z0-9_-]+$'; then
                red "Path 仅允许字母、数字、下划线和连字符"; return
            fi
            jq --arg p "/${new_path}" \
                '.inbounds[1].streamSettings.wsSettings.path = $p' "$config_dir" \
                > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
            sed -i "2s|path=%2F[A-Za-z0-9_-]*|path=%2F${new_path}|" "$client_dir"
            restart_xray
            green "免流 WS Path 已修改为：/${new_path}"
            print_nodes
            ;;
        4)
            if [ ! -f "${client_dir}" ]; then
                yellow "节点文件不存在，请先完成安装后再变更免流方式"; return
            fi
            local old_mode="${FREEFLOW_MODE}"
            ask_freeflow_mode
            if [ "${FREEFLOW_MODE}" = "${old_mode}" ]; then
                yellow "免流方式未变更"; return
            fi
            apply_freeflow_config
            local argo_line ip_now
            argo_line=$(head -1 "${client_dir}")
            ip_now=$(get_realip)
            {
                echo "${argo_line}"
                build_freeflow_link "${ip_now}"
            } > "${client_dir}"
            restart_xray
            green "免流方式已变更"
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
# 顺序：stop → 注销自启 → 删文件
# ============================================================
uninstall_xray() {
    reading "确定要卸载 xray-2go 吗？(y/n): " choice
    case "${choice}" in
        y|Y)
            yellow "正在卸载..."
            if [ -f /etc/alpine-release ]; then
                rc-service xray stop   2>/dev/null
                rc-service tunnel stop 2>/dev/null
                rc-update del xray default   2>/dev/null
                rc-update del tunnel default 2>/dev/null
                rm -f /etc/init.d/xray /etc/init.d/tunnel
            else
                systemctl stop xray tunnel 2>/dev/null
                systemctl disable xray tunnel 2>/dev/null
                rm -f /etc/systemd/system/xray.service \
                      /etc/systemd/system/tunnel.service
                systemctl daemon-reload
            fi
            rm -rf "${work_dir}"
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
        local xray_status argo_status cx ff_display
        xray_status=$(check_xray); cx=$?
        argo_status=$(check_argo)
        case "${FREEFLOW_MODE}" in
            ws)   ff_display="WS"   ;;
            tcp)  ff_display="TCP"  ;;
            none) ff_display="无"   ;;
            *)    ff_display="未知" ;;
        esac

        clear; echo ""
        purple "=== Xray-2go 精简版（VLESS+WS）==="
        purple " Xray 状态: ${xray_status}"
        purple " Argo 状态: ${argo_status}"
        purple " 免流模式:  ${ff_display}"
        echo   "=================================="
        green  "1. 安装 Xray-2go"
        red    "2. 卸载 Xray-2go"
        echo   "================="
        green  "3. Argo 隧道管理"
        echo   "================="
        green  "4. 查看节点信息"
        green  "5. 修改节点配置"
        echo   "================="
        red    "0. 退出脚本"
        echo   "==========="
        reading "请输入选择(0-5): " choice
        echo ""

        case "${choice}" in
            1)
                if [ "$cx" -eq 0 ]; then
                    yellow "Xray-2go 已安装！"
                else
                    ask_freeflow_mode
                    manage_packages install jq unzip
                    install_xray
                    if command -v systemctl > /dev/null 2>&1; then
                        main_systemd_services
                    elif command -v rc-update > /dev/null 2>&1; then
                        alpine_openrc_services
                        change_hosts
                        rc-service xray restart
                        rc-service tunnel restart
                    else
                        red "不支持的 init 系统"; exit 1
                    fi
                    get_info
                fi
                ;;
            2) uninstall_xray ;;
            3) manage_argo ;;
            4) check_nodes ;;
            5) change_config ;;
            0) exit 0 ;;
            *) red "无效的选项，请输入 0 到 5" ;;
        esac
        # 等待任意键：printf 输出提示，read -r 读一行（回车即可）
        # 替代 bash-specific: read -n 1 -s -r -p $'...'
        printf '\033[1;91m按回车键继续...\033[0m'
        read -r _dummy
    done
}

menu
