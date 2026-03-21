#!/bin/bash

# ============================================================
# 精简版 Xray-Argo 一键脚本
# 协议：VLESS+WS+TLS（Cloudflare Argo）+ VLESS+WS（端口80免流）
# ============================================================

red()    { echo -e "\e[1;91m$1\033[0m"; }
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

# ── 环境变量（可外部注入） ───────────────────────────────────
# UUID：节点身份标识，未设置时自动生成
export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
# ARGO_PORT：Xray WS 监听端口，cloudflared 回源至此，仅监听 127.0.0.1
export ARGO_PORT=${ARGO_PORT:-'8080'}
# CFIP / CFPORT：CF 优选 IP 和端口，用于生成 Argo 节点链接
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

[[ $EUID -ne 0 ]] && red "请在 root 用户下运行脚本" && exit 1

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
# 用法：manage_packages install pkg1 pkg2 ...
# ============================================================
manage_packages() {
    [ $# -lt 2 ] && red "未指定包名或操作" && return 1
    local action=$1; shift
    [ "$action" != "install" ] && red "未知操作: $action" && return 1
    for package in "$@"; do
        if command -v "$package" &>/dev/null; then
            green "${package} already installed"; continue
        fi
        yellow "正在安装 ${package}..."
        if   command -v apt &>/dev/null; then DEBIAN_FRONTEND=noninteractive apt install -y "$package"
        elif command -v dnf &>/dev/null; then dnf install -y "$package"
        elif command -v yum &>/dev/null; then yum install -y "$package"
        elif command -v apk &>/dev/null; then apk update && apk add "$package"
        else red "未知系统！"; return 1; fi
    done
}

# ============================================================
# get_realip
# 优先获取 IPv4；若归属 CF/特定 CDN 则切换 IPv6
# 所有请求均设置超时，避免网络异常时卡住
# ============================================================
get_realip() {
    local ip ipv6
    ip=$(curl -s --max-time 2 ipv4.ip.sb)
    if [ -z "$ip" ]; then
        ipv6=$(curl -s --max-time 2 ipv6.ip.sb)
        echo "[$ipv6]"
    else
        if curl -s --max-time 3 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
            ipv6=$(curl -s --max-time 2 ipv6.ip.sb)
            echo "[$ipv6]"
        else
            echo "$ip"
        fi
    fi
}

# ============================================================
# install_xray
# 下载 xray + cloudflared，生成 config.json
#
# inbound 1 (ARGO_PORT / 127.0.0.1)：VLESS+WS，供 cloudflared 回源
#   listen 127.0.0.1 确保外网无法直接访问
#   客户端视角：VLESS+WS+TLS（TLS 由 CF 边缘终结）
#
# inbound 2 (80 / ::)：VLESS+WS 明文，免流直连
#   listen :: 同时接受 IPv4/IPv6
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

    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}" && chmod 755 "${work_dir}"

    # 下载并检测结果，任一失败立即中止
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
    },
    {
      "port": 80,
      "listen": "::",
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}" }], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "/luckyss" }
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
}

# ============================================================
# main_systemd_services
# 写入 systemd 服务文件并启动（Debian / Ubuntu / CentOS）
#
# cloudflared 将隧道域名输出到 stderr，StandardOutput 和
# StandardError 均重定向到 argo.log 确保日志完整可解析
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
#
# stdout + stderr 均重定向到 argo.log 确保域名日志可解析
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

    # EOF 不加引号，允许 ${ARGO_PORT} 展开写入正确值
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

# ============================================================
# change_hosts（Alpine 专用）
# 修复 cloudflared 的 ping_group_range 报错和 /etc/hosts DNS 问题
# 仅在 Alpine 路径下调用，不放入 main_systemd_services
# ============================================================
change_hosts() {
    echo "0 0" > /proc/sys/net/ipv4/ping_group_range
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

# ============================================================
# reset_tunnel_to_temp
# 从固定隧道切换回临时隧道：只重写 ExecStart/command_args 一行
# 不重建整个服务文件，避免重复 enable/start 等副作用
# 写入格式与 manage_argo 选项5的 grep -Fq 匹配字符串保持一致
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
# 从 argo.log 中提取 trycloudflare.com 子域，输出到 stdout
# 先 sleep 3 等待 cloudflared 初始化写入，再开始最多5次轮询
# ============================================================
get_argodomain() {
    sleep 3
    local domain
    for i in {1..5}; do
        domain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' \
            "${work_dir}/argo.log" 2>/dev/null | head -1)
        if [ -n "$domain" ]; then
            echo "$domain"; return 0
        fi
        sleep 2
    done
    echo ""; return 1
}

# ============================================================
# print_nodes
# 将 url.txt 内容以紫色逐行输出，跳过空行
# client_dir 不存在时明确提示而非静默失败
# ============================================================
print_nodes() {
    echo ""
    if [ ! -f "${client_dir}" ]; then
        yellow "节点文件不存在，请先安装或重新获取节点信息"
        return 1
    fi
    while IFS= read -r line; do
        [ -n "$line" ] && echo -e "\e[1;35m$line\033[0m"
    done < "${client_dir}"
    echo ""
}

# ============================================================
# get_info
# 重启 Argo，获取临时域名，生成节点链接写入 url.txt 并打印
#
# 链接1 VLESS+WS+TLS via Argo：
#   security=tls，sni/host=argodomain，path=/vless-argo
#   ed=2560：Early Data，减少 WS 握手往返延迟
#
# 链接2 VLESS+WS 免流：
#   security=none，直连 IP:80，path=/luckyss
# ============================================================
get_info() {
    clear
    local IP argodomain
    IP=$(get_realip)

    purple "正在获取 ArgoDomain，请稍等...\n"
    restart_argo
    argodomain=$(get_argodomain)

    if [ -z "$argodomain" ]; then
        yellow "未能获取 ArgoDomain，Argo 节点链接暂时无效，可稍后通过 Argo 管理菜单重新获取"
        argodomain="<未获取到域名>"
    else
        green "\nArgoDomain：${argodomain}\n"
    fi

    cat > "${client_dir}" << EOF
vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#Argo

vless://${UUID}@${IP}:80?encryption=none&security=none&type=ws&host=${IP}&path=%2Fluckyss#FreeFlow
EOF
    print_nodes
}

# ============================================================
# get_quick_tunnel
# 重启 Argo，提取新临时域名，更新 url.txt 第一行节点的 sni/host
# ============================================================
get_quick_tunnel() {
    # client_dir 必须存在才能执行 sed 更新
    if [ ! -f "${client_dir}" ]; then
        yellow "节点文件不存在，请先执行安装以初始化节点信息"
        return 1
    fi
    yellow "正在重启 Argo 并获取新临时域名...\n"
    restart_argo
    local argodomain
    argodomain=$(get_argodomain)

    if [ -z "$argodomain" ]; then
        yellow "未能获取临时域名，请检查网络或稍后重试"
        return 1
    fi

    green "ArgoDomain：${argodomain}\n"
    sed -i "1s/sni=[^&]*/sni=${argodomain}/; 1s/host=[^&]*/host=${argodomain}/" "${client_dir}"
    print_nodes
    green "节点已更新，请手动复制以上链接\n"
}

# ============================================================
# manage_argo - Argo 隧道管理
# ============================================================
manage_argo() {
    local argo_status cx
    argo_status=$(check_argo); cx=$?
    if [ $cx -eq 2 ]; then
        yellow "Argo 尚未安装！"; sleep 1; menu; return
    fi
    clear; echo ""
    green  "1. 启动 Argo 服务";            skyblue "----------------"
    green  "2. 停止 Argo 服务";            skyblue "----------------"
    green  "3. 添加固定隧道（token/json）"; skyblue "----------------------------------"
    green  "4. 切换回临时隧道";             skyblue "-----------------------"
    green  "5. 重新获取临时域名";           skyblue "------------------------"
    purple "6. 返回主菜单";                skyblue "------------"
    reading "\n请输入选择: " choice

    case "${choice}" in
        1)
            if [ -f /etc/alpine-release ]; then rc-service tunnel start
            else systemctl start tunnel; fi
            green "Argo 已启动\n"
            ;;
        2)
            if [ -f /etc/alpine-release ]; then rc-service tunnel stop
            else systemctl stop tunnel; fi
            green "Argo 已停止\n"
            ;;
        3)
            # 固定隧道两种格式：
            #   json：包含 TunnelSecret，写入 tunnel.json + tunnel.yml
            #   token：120~250 位字母数字，直接传 --token 参数
            yellow "\n固定隧道回源端口为 ${ARGO_PORT}，请在 CF 后台配置对应 ingress\n"
            reading "请输入你的 Argo 域名: " argo_domain
            reading "请输入 Argo 密钥（token 或 json）: " argo_auth

            if [[ $argo_auth =~ TunnelSecret ]]; then
                echo "$argo_auth" > "${work_dir}/tunnel.json"
                cat > "${work_dir}/tunnel.yml" << EOF
tunnel: $(cut -d\" -f12 <<< "$argo_auth")
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
            elif [[ $argo_auth =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
                if [ -f /etc/alpine-release ]; then
                    sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_auth} >> /etc/xray/argo.log 2>&1'\"" \
                        /etc/init.d/tunnel
                else
                    # token 用单引号包裹 sh -c 参数，避免特殊字符导致 sed 表达式损坏
                    sed -i "/^ExecStart=/c\\ExecStart=/bin/sh -c '/etc/xray/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_auth} >> /etc/xray/argo.log 2>&1'" \
                        /etc/systemd/system/tunnel.service
                fi
            else
                yellow "token 或 json 格式不匹配，请重新输入"
                manage_argo; return
            fi

            restart_argo
            # 更新 url.txt 第一行 Argo 节点的 sni 和 host
            if [ -f "${client_dir}" ]; then
                sed -i "1s/sni=[^&]*/sni=${argo_domain}/; 1s/host=[^&]*/host=${argo_domain}/" "${client_dir}"
                print_nodes
            else
                yellow "节点文件不存在，固定隧道已配置但无法更新链接，请重新安装后获取"
            fi
            green "固定隧道已配置\n"
            ;;
        4)
            # 只重写 ExecStart 行，不重建整个服务文件
            reset_tunnel_to_temp
            get_quick_tunnel
            ;;
        5)
            # grep -Fq 固定字符串匹配，与 reset_tunnel_to_temp 写入格式一致
            local using_temp=false
            if [ -f /etc/alpine-release ]; then
                grep -Fq -- "--url http://localhost:${ARGO_PORT}" /etc/init.d/tunnel \
                    && using_temp=true
            else
                grep -Fq -- "--url http://localhost:${ARGO_PORT}" \
                    /etc/systemd/system/tunnel.service && using_temp=true
            fi
            if $using_temp; then
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
# change_config - 修改 UUID / Argo 回源端口 / 免流 WS Path
# 使用 jq 操作 JSON，避免 sed 行号硬编码
# ============================================================
change_config() {
    clear; echo ""
    green  "1. 修改 UUID"
    skyblue "------------"
    green  "2. 修改 Argo 回源端口（当前：${ARGO_PORT}）"
    skyblue "-------------------------------------------"
    green  "3. 修改免流 WS Path（当前：/luckyss）"
    skyblue "--------------------------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice

    case "${choice}" in
        1)
            reading "\n请输入新的 UUID（回车自动生成）: " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid) \
                && green "\n生成的 UUID：$new_uuid"
            # 同时替换 config.json 和 url.txt 中所有 UUID
            sed -i "s/[a-fA-F0-9]\{8\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{12\}/$new_uuid/g" \
                "$config_dir" "$client_dir"
            restart_xray
            green "\nUUID 已修改为：${new_uuid}\n"
            print_nodes
            ;;
        2)
            reading "\n请输入新的 Argo 回源端口（回车随机）: " new_port
            [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
            # 端口范围校验
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || \
               [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                red "端口无效，请输入 1-65535 的整数"; return
            fi
            jq --argjson p "$new_port" '.inbounds[0].port = $p' "$config_dir" \
                > "${config_dir}.tmp" && mv "${config_dir}.tmp" "$config_dir"
            # 同步更新服务文件中 cloudflared 的 --url 回源地址
            if [ -f /etc/alpine-release ]; then
                sed -i "s|http://localhost:[0-9]*|http://localhost:${new_port}|g" \
                    /etc/init.d/tunnel
            else
                sed -i "s|http://localhost:[0-9]*|http://localhost:${new_port}|g" \
                    /etc/systemd/system/tunnel.service
            fi
            # export 确保变量在后续菜单循环中保持最新值
            export ARGO_PORT=$new_port
            restart_xray && restart_argo
            green "\nArgo 回源端口已修改为：${new_port}\n"
            ;;
        3)
            reading "\n请输入新的免流 WS Path（仅限字母数字下划线，回车默认 luckyss）: " new_path
            # 限制 path 字符集，防止注入或 URL 编码异常
            if [ -z "$new_path" ]; then
                new_path="luckyss"
            elif ! [[ "$new_path" =~ ^[A-Za-z0-9_-]+$ ]]; then
                red "Path 仅允许字母、数字、下划线和连字符"; return
            fi
            jq --arg p "/${new_path}" \
                '.inbounds[1].streamSettings.wsSettings.path = $p' "$config_dir" \
                > "${config_dir}.tmp" && mv "${config_dir}.tmp" "$config_dir"
            # 更新 url.txt 第二行免流节点的 path 参数
            sed -i "2s|path=%2F[A-Za-z0-9_-]*|path=%2F${new_path}|" "$client_dir"
            restart_xray
            green "\n免流 WS Path 已修改为：/${new_path}\n"
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
    check_xray &>/dev/null; cx=$?
    if [ $cx -eq 0 ]; then
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
            green "\nXray-2go 卸载完成\n"
            ;;
        *) purple "已取消卸载\n" ;;
    esac
}

trap 'red "已取消操作"; exit' INT

# ============================================================
# menu - 主菜单
# 每轮只调用 check_xray/check_argo 一次：
#   status=$(check_func) 捕获文字，$? 同时取得返回码
# ============================================================
menu() {
    while true; do
        local xray_status argo_status cx
        xray_status=$(check_xray); cx=$?
        argo_status=$(check_argo)

        clear; echo ""
        purple "=== Xray-2go 精简版（VLESS+WS）===\n"
        purple " Xray 状态: ${xray_status}\n"
        purple " Argo 状态: ${argo_status}\n"
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
                if [ $cx -eq 0 ]; then
                    yellow "Xray-2go 已安装！"
                else
                    manage_packages install jq unzip
                    install_xray
                    if command -v systemctl &>/dev/null; then
                        main_systemd_services
                    elif command -v rc-update &>/dev/null; then
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
        read -n 1 -s -r -p $'\033[1;91m按任意键继续...\033[0m'
    done
}

menu
