#!/bin/bash
# ============================================================
# Xray-2go 一键脚本 (重构版)
# 协议：
#   Argo 临时隧道（WS 专属）：VLESS+WS+TLS（Cloudflare 随机域名）
#   Argo 固定隧道（WS/XHTTP 二选一）：VLESS+WS/XHTTP+TLS
#   FreeFlow（可选）：VLESS+WS/HTTPUpgrade/XHTTP（port 80，明文直连）
#   Shadowsocks（可选）：SS+TCP/UDP（port 自选）
#   Socks5（可选）：Socks5+TCP（port 自选，可选认证）
# 注意：Argo XHTTP 仅支持固定隧道，不支持临时隧道
# ============================================================

# ── 严格模式（pipefail 捕获管道中段失败）────────────────────
set -eo pipefail

# ── 全局常量 ─────────────────────────────────────────────────
readonly WORK_DIR="/etc/xray"
readonly CONFIG_FILE="${WORK_DIR}/config.json"
readonly CLIENT_FILE="${WORK_DIR}/url.txt"
readonly FREEFLOW_CONF="${WORK_DIR}/freeflow.conf"
readonly ARGO_MODE_CONF="${WORK_DIR}/argo_mode.conf"
readonly ARGO_PROTO_CONF="${WORK_DIR}/argo_protocol.conf"
readonly RESTART_CONF="${WORK_DIR}/restart.conf"
readonly SS_CONF="${WORK_DIR}/ss.conf"
readonly SOCKS5_CONF="${WORK_DIR}/socks5.conf"
readonly DOMAIN_FIXED_FILE="${WORK_DIR}/domain_fixed.txt"
readonly SHORTCUT="/usr/local/bin/s"
readonly XRAY_BIN="${WORK_DIR}/xray"
readonly ARGO_BIN="${WORK_DIR}/argo"
readonly ARGO_LOG="${WORK_DIR}/argo.log"
readonly ARGO_LOG_MAX=1048576   # 1 MiB，超出则截断

# ── 颜色输出 ─────────────────────────────────────────────────
red()    { printf '\033[1;91m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
purple() { printf '\033[1;35m%s\033[0m\n' "$*"; }
skyblue(){ printf '\033[1;36m%s\033[0m\n' "$*"; }

# 交互提示（写 stderr 避免污染 stdout 重定向，read 从 stdin）
prompt() { printf '\033[1;91m%s\033[0m' "$1" >&2; read -r "$2"; }
die()    { red "$1"; exit 1; }

# ── 前置检查 ─────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && die "请在 root 用户下运行脚本"

# ── 平台检测 ─────────────────────────────────────────────────
is_alpine() { [ -f /etc/alpine-release ]; }

# ── 全局变量（运行时可变）────────────────────────────────────
ARGO_MODE="yes"
ARGO_PROTOCOL="ws"
FREEFLOW_MODE="none"
FF_PATH="/"
ARGO_PORT="8080"
RESTART_INTERVAL=0
UUID="${UUID:-}"
SS_MODE="none"
SS_PORT=""
SS_PASSWORD=""
SS_METHOD="aes-128-gcm"
SOCKS5_MODE="none"
SOCKS5_PORT=""
SOCKS5_USER=""
SOCKS5_PASS=""

# ── 读取持久化配置 ───────────────────────────────────────────
_load_config() {
    # UUID：优先环境变量，次之随机生成
    if [ -z "${UUID}" ]; then
        UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) || \
        UUID=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 32 | \
               sed 's/.\{8\}/&-/;s/.\{13\}/&-/;s/.\{18\}/&-/;s/.\{23\}/&-/;s/-$//')
    fi

    local raw
    raw=$(cat "${ARGO_MODE_CONF}" 2>/dev/null) || true
    case "${raw}" in yes|no) ARGO_MODE="${raw}" ;; *) ARGO_MODE="yes" ;; esac

    raw=$(cat "${ARGO_PROTO_CONF}" 2>/dev/null) || true
    case "${raw}" in ws|xhttp) ARGO_PROTOCOL="${raw}" ;; *) ARGO_PROTOCOL="ws" ;; esac

    if [ -f "${FREEFLOW_CONF}" ]; then
        local l1 l2
        l1=$(sed -n '1p' "${FREEFLOW_CONF}" 2>/dev/null) || true
        l2=$(sed -n '2p' "${FREEFLOW_CONF}" 2>/dev/null) || true
        case "${l1}" in ws|httpupgrade|xhttp) FREEFLOW_MODE="${l1}" ;; *) FREEFLOW_MODE="none" ;; esac
        [ -n "${l2}" ] && FF_PATH="${l2}"
    fi

    # ARGO_PORT：精确匹配 listen==127.0.0.1 的 inbound
    if [ "${ARGO_MODE}" = "yes" ] && [ -f "${CONFIG_FILE}" ]; then
        local p
        p=$(jq -r 'first(.inbounds[]? | select(.listen=="127.0.0.1") | .port) // empty' \
            "${CONFIG_FILE}" 2>/dev/null) || true
        case "${p}" in ''|*[!0-9]*) : ;; *) ARGO_PORT="${p}" ;; esac
    fi

    if [ -f "${RESTART_CONF}" ]; then
        local ri
        ri=$(cat "${RESTART_CONF}" 2>/dev/null) || true
        case "${ri}" in ''|*[!0-9]*) : ;; *) RESTART_INTERVAL="${ri}" ;; esac
    fi

    # Shadowsocks 配置
    if [ -f "${SS_CONF}" ]; then
        local s1 s2 s3
        s1=$(sed -n '1p' "${SS_CONF}" 2>/dev/null) || true
        s2=$(sed -n '2p' "${SS_CONF}" 2>/dev/null) || true
        s3=$(sed -n '3p' "${SS_CONF}" 2>/dev/null) || true
        case "${s1}" in ''|*[!0-9]*) : ;; *)
            SS_MODE="enabled"; SS_PORT="${s1}"
            [ -n "${s2}" ] && SS_PASSWORD="${s2}"
            case "${s3}" in
                aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305|2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
                    SS_METHOD="${s3}" ;;
            esac
        esac
    fi

    # Socks5 配置
    if [ -f "${SOCKS5_CONF}" ]; then
        local k1 k2 k3
        k1=$(sed -n '1p' "${SOCKS5_CONF}" 2>/dev/null) || true
        k2=$(sed -n '2p' "${SOCKS5_CONF}" 2>/dev/null) || true
        k3=$(sed -n '3p' "${SOCKS5_CONF}" 2>/dev/null) || true
        case "${k1}" in ''|*[!0-9]*) : ;; *)
            SOCKS5_MODE="enabled"; SOCKS5_PORT="${k1}"
            SOCKS5_USER="${k2}"; SOCKS5_PASS="${k3}"
        esac
    fi
}
_load_config

# ── 服务控制 ─────────────────────────────────────────────────
svc() {
    local act="$1" name="$2"
    if is_alpine; then
        case "${act}" in
            enable)  rc-update add "${name}" default 2>/dev/null ;;
            disable) rc-update del "${name}" default 2>/dev/null ;;
            *)       rc-service "${name}" "${act}" 2>/dev/null   ;;
        esac
    else
        case "${act}" in
            enable)  systemctl enable  "${name}" 2>/dev/null ;;
            disable) systemctl disable "${name}" 2>/dev/null ;;
            *)       systemctl "${act}" "${name}" 2>/dev/null ;;
        esac
    fi
}

restart_xray() {
    if is_alpine; then rc-service xray restart
    else               systemctl restart xray
    fi || { red "xray 重启失败"; return 1; }
}

restart_argo() {
    # 轮转 argo.log，避免无限增长
    if [ -f "${ARGO_LOG}" ] && [ "$(stat -c%s "${ARGO_LOG}" 2>/dev/null || echo 0)" -gt "${ARGO_LOG_MAX}" ]; then
        : > "${ARGO_LOG}"
    fi
    if is_alpine; then rc-service tunnel restart
    else               systemctl daemon-reload && systemctl restart tunnel
    fi || { red "tunnel 重启失败"; return 1; }
}

# ── 包管理 ───────────────────────────────────────────────────
pkg_require() {
    local pkg="$1" bin="${2:-$1}"
    command -v "${bin}" >/dev/null 2>&1 && return 0
    yellow "正在安装 ${pkg}..."
    if   command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}" >/dev/null 2>&1
    elif command -v dnf     >/dev/null 2>&1; then dnf install -y "${pkg}" >/dev/null 2>&1
    elif command -v yum     >/dev/null 2>&1; then yum install -y "${pkg}" >/dev/null 2>&1
    elif command -v apk     >/dev/null 2>&1; then apk add       "${pkg}" >/dev/null 2>&1
    else die "未找到包管理器，无法安装 ${pkg}"
    fi
    command -v "${bin}" >/dev/null 2>&1 || die "${pkg} 安装失败"
}

# ── 原子 jq 写入 ─────────────────────────────────────────────
jq_edit() {
    local file="$1" filter="$2"; shift 2
    local tmp
    tmp=$(mktemp "${file}.XXXXXX") || die "无法创建临时文件"
    if jq "$@" "${filter}" "${file}" > "${tmp}" 2>/dev/null && [ -s "${tmp}" ]; then
        mv "${tmp}" "${file}"
    else
        rm -f "${tmp}"
        red "jq 操作失败: ${filter}"; return 1
    fi
}

# ── 端口合法性 & 占用检测 ────────────────────────────────────
is_valid_port() {
    local p="$1"
    case "${p}" in ''|*[!0-9]*) return 1 ;; esac
    [ "${p}" -ge 1 ] && [ "${p}" -le 65535 ]
}

port_in_use() {
    local p="$1"
    if   command -v ss      >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | grep -qE ":${p}[[:space:]]"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | grep -qE ":${p}[[:space:]]"
    else
        awk -v h="$(printf '%04X' "${p}")" \
            'NR>1 && substr($2,index($2,":")+1)==h {found=1} END{exit !found}' \
            /proc/net/tcp 2>/dev/null
    fi
}

# 检查端口并询问是否继续（返回 0=继续，1=放弃）
check_port_conflict() {
    local p="$1" desc="${2:-该端口}"
    is_valid_port "${p}" || { red "端口 ${p} 不合法（须为 1-65535 整数）"; return 1; }
    if port_in_use "${p}"; then
        yellow "⚠ ${desc}（${p}）已被其他进程占用"
        local ans
        prompt "仍然继续？(y/n): " ans
        case "${ans}" in y|Y) return 0 ;; *) return 1 ;; esac
    fi
    return 0
}

# ── 获取服务器 IP ────────────────────────────────────────────
# 返回值：裸 IPv4 / 裸 IPv6 / 空串
# get_realip_raw：供内部使用，不含 [] 包裹
get_realip_raw() {
    local ip org ipv6
    ip=$(curl -sf --max-time 5 --connect-timeout 5 ipv4.ip.sb 2>/dev/null) || true
    if [ -z "${ip}" ]; then
        ipv6=$(curl -sf --max-time 5 --connect-timeout 5 ipv6.ip.sb 2>/dev/null) || true
        echo "${ipv6}"
        return
    fi
    org=$(curl -sf --max-time 5 --connect-timeout 5 "https://ipinfo.io/${ip}/org" 2>/dev/null) || true
    if echo "${org}" | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        ipv6=$(curl -sf --max-time 5 --connect-timeout 5 ipv6.ip.sb 2>/dev/null) || true
        [ -n "${ipv6}" ] && echo "${ipv6}" || echo "${ip}"
    else
        echo "${ip}"
    fi
}

# get_realip：供节点链接 host/address 字段使用，IPv6 包 []
get_realip() {
    local raw
    raw=$(get_realip_raw)
    # 判断是否为 IPv6（含冒号）
    case "${raw}" in
        *:*) echo "[${raw}]" ;;
        *)   echo "${raw}"   ;;
    esac
}

# ── 读取当前 UUID ────────────────────────────────────────────
get_uuid() {
    local id
    id=$(jq -r 'first(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) // empty' \
         "${CONFIG_FILE}" 2>/dev/null) || true
    echo "${id:-${UUID}}"
}

# ── JSON inbound 构建 ────────────────────────────────────────
_argo_inbound() {
    local uuid; uuid=$(get_uuid)
    if [ "${ARGO_PROTOCOL}" = "xhttp" ]; then
        jq -n --argjson port "${ARGO_PORT}" --arg uuid "${uuid}" '{
            port: $port, listen: "127.0.0.1", protocol: "vless",
            settings: {clients: [{id: $uuid}], decryption: "none"},
            streamSettings: {network: "xhttp", security: "none",
                xhttpSettings: {host: "", path: "/argo", mode: "auto"}},
            sniffing: {enabled: true, destOverride: ["http","tls","quic"], metadataOnly: false}
        }'
    else
        jq -n --argjson port "${ARGO_PORT}" --arg uuid "${uuid}" '{
            port: $port, listen: "127.0.0.1", protocol: "vless",
            settings: {clients: [{id: $uuid}], decryption: "none"},
            streamSettings: {network: "ws", security: "none",
                wsSettings: {path: "/argo"}},
            sniffing: {enabled: true, destOverride: ["http","tls","quic"], metadataOnly: false}
        }'
    fi
}

_freeflow_inbound() {
    local uuid; uuid=$(get_uuid)
    case "${FREEFLOW_MODE}" in
        ws)
            jq -n --arg uuid "${uuid}" --arg path "${FF_PATH}" '{
                port: 80, listen: "::", protocol: "vless",
                settings: {clients: [{id: $uuid}], decryption: "none"},
                streamSettings: {network: "ws", security: "none",
                    wsSettings: {path: $path}},
                sniffing: {enabled: true, destOverride: ["http","tls","quic"], metadataOnly: false}
            }' ;;
        httpupgrade)
            jq -n --arg uuid "${uuid}" --arg path "${FF_PATH}" '{
                port: 80, listen: "::", protocol: "vless",
                settings: {clients: [{id: $uuid}], decryption: "none"},
                streamSettings: {network: "httpupgrade", security: "none",
                    httpupgradeSettings: {path: $path}},
                sniffing: {enabled: true, destOverride: ["http","tls","quic"], metadataOnly: false}
            }' ;;
        xhttp)
            jq -n --arg uuid "${uuid}" --arg path "${FF_PATH}" '{
                port: 80, listen: "::", protocol: "vless",
                settings: {clients: [{id: $uuid}], decryption: "none"},
                streamSettings: {network: "xhttp", security: "none",
                    xhttpSettings: {host: "", path: $path, mode: "stream-one"}},
                sniffing: {enabled: true, destOverride: ["http","tls","quic"], metadataOnly: false}
            }' ;;
    esac
}

_ss_inbound() {
    jq -n --argjson port "${SS_PORT}" --arg method "${SS_METHOD}" --arg pass "${SS_PASSWORD}" '{
        port: $port, listen: "::", protocol: "shadowsocks",
        settings: {method: $method, password: $pass, network: "tcp,udp"},
        sniffing: {enabled: true, destOverride: ["http","tls","quic"], metadataOnly: false}
    }'
}

_socks5_inbound() {
    if [ -n "${SOCKS5_USER}" ] && [ -n "${SOCKS5_PASS}" ]; then
        jq -n --argjson port "${SOCKS5_PORT}" --arg user "${SOCKS5_USER}" --arg pass "${SOCKS5_PASS}" '{
            port: $port, listen: "::", protocol: "socks",
            settings: {auth: "password", accounts: [{user: $user, pass: $pass}], udp: true}
        }'
    else
        jq -n --argjson port "${SOCKS5_PORT}" '{
            port: $port, listen: "::", protocol: "socks",
            settings: {auth: "noauth", udp: true}
        }'
    fi
}

# ── 写入完整 config.json ─────────────────────────────────────
write_config() {
    mkdir -p "${WORK_DIR}"
    local inbounds_json="[]"

    if [ "${ARGO_MODE}" = "yes" ]; then
        local argo_ib
        argo_ib=$(_argo_inbound) || die "生成 Argo inbound 失败"
        inbounds_json=$(jq -n --argjson ib "${argo_ib}" '[$ib]')
    fi

    if [ "${FREEFLOW_MODE}" != "none" ]; then
        local ff_ib
        ff_ib=$(_freeflow_inbound) || die "生成 FreeFlow inbound 失败"
        inbounds_json=$(jq -n --argjson arr "${inbounds_json}" --argjson ib "${ff_ib}" '$arr + [$ib]')
    fi

    if [ "${SS_MODE}" = "enabled" ]; then
        local ss_ib
        ss_ib=$(_ss_inbound) || die "生成 Shadowsocks inbound 失败"
        inbounds_json=$(jq -n --argjson arr "${inbounds_json}" --argjson ib "${ss_ib}" '$arr + [$ib]')
    fi

    if [ "${SOCKS5_MODE}" = "enabled" ]; then
        local sk_ib
        sk_ib=$(_socks5_inbound) || die "生成 Socks5 inbound 失败"
        inbounds_json=$(jq -n --argjson arr "${inbounds_json}" --argjson ib "${sk_ib}" '$arr + [$ib]')
    fi

    jq -n --argjson inbounds "${inbounds_json}" '{
        log: {access: "/dev/null", error: "/dev/null", loglevel: "none"},
        inbounds: $inbounds,
        dns: {servers: ["https+local://1.1.1.1/dns-query"]},
        outbounds: [
            {protocol: "freedom", tag: "direct"},
            {protocol: "blackhole", tag: "block"}
        ]
    }' > "${CONFIG_FILE}" || die "生成 config.json 失败"
}

# ── 原位替换 Argo inbound ─────────────────────────────────────
replace_argo_inbound() {
    local ib; ib=$(_argo_inbound) || return 1
    jq_edit "${CONFIG_FILE}" '
        (.inbounds | map(select(.listen == "127.0.0.1")) | length) as $n |
        if $n > 0 then
            .inbounds = [.inbounds[] | if .listen == "127.0.0.1" then $ib else . end]
        else
            .inbounds = [$ib] + .inbounds
        end
    ' --argjson ib "${ib}"
}

# ── 应用 FreeFlow 配置（外科手术：删 port80，按需注入）──────
apply_freeflow() {
    jq_edit "${CONFIG_FILE}" 'del(.inbounds[]? | select(.port == 80))' || return 1
    if [ "${FREEFLOW_MODE}" != "none" ]; then
        local ib; ib=$(_freeflow_inbound) || return 1
        jq_edit "${CONFIG_FILE}" '.inbounds += [$ib]' --argjson ib "${ib}" || return 1
    fi
}

# ── 应用 SS inbound（外科手术）──────────────────────────────
apply_ss() {
    jq_edit "${CONFIG_FILE}" \
        'del(.inbounds[]? | select(.protocol == "shadowsocks"))' || return 1
    if [ "${SS_MODE}" = "enabled" ]; then
        local ib; ib=$(_ss_inbound) || return 1
        jq_edit "${CONFIG_FILE}" '.inbounds += [$ib]' --argjson ib "${ib}" || return 1
    fi
}

# ── 应用 Socks5 inbound（外科手术）─────────────────────────
apply_socks5() {
    jq_edit "${CONFIG_FILE}" \
        'del(.inbounds[]? | select(.protocol == "socks"))' || return 1
    if [ "${SOCKS5_MODE}" = "enabled" ]; then
        local ib; ib=$(_socks5_inbound) || return 1
        jq_edit "${CONFIG_FILE}" '.inbounds += [$ib]' --argjson ib "${ib}" || return 1
    fi
}

# ── 保存各协议配置文件 ───────────────────────────────────────
save_freeflow_conf() {
    mkdir -p "${WORK_DIR}"
    printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${FREEFLOW_CONF}"
}

save_ss_conf() {
    mkdir -p "${WORK_DIR}"
    if [ "${SS_MODE}" = "enabled" ]; then
        printf '%s\n%s\n%s\n' "${SS_PORT}" "${SS_PASSWORD}" "${SS_METHOD}" > "${SS_CONF}"
    else
        rm -f "${SS_CONF}"
    fi
}

save_socks5_conf() {
    mkdir -p "${WORK_DIR}"
    if [ "${SOCKS5_MODE}" = "enabled" ]; then
        printf '%s\n%s\n%s\n' "${SOCKS5_PORT}" "${SOCKS5_USER}" "${SOCKS5_PASS}" > "${SOCKS5_CONF}"
    else
        rm -f "${SOCKS5_CONF}"
    fi
}

# ── 架构检测 ─────────────────────────────────────────────────
detect_arch() {
    case "$(uname -m)" in
        x86_64)        ARCH_CF="amd64"; ARCH_XRAY="64"        ;;
        x86|i686|i386) ARCH_CF="386";   ARCH_XRAY="32"        ;;
        aarch64|arm64) ARCH_CF="arm64"; ARCH_XRAY="arm64-v8a" ;;
        armv7l)        ARCH_CF="armv7"; ARCH_XRAY="arm32-v7a" ;;
        s390x)         ARCH_CF="s390x"; ARCH_XRAY="s390x"     ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

# ── 下载二进制文件 ───────────────────────────────────────────
download_xray() {
    local arch_arg="$1"
    local url zip_path="${WORK_DIR}/xray.zip"
    url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch_arg}.zip"
    yellow "下载 Xray (${arch_arg})..."
    curl -sfL --connect-timeout 15 --max-time 120 -o "${zip_path}" "${url}" \
        || die "Xray 下载失败，请检查网络"
    unzip -t "${zip_path}" >/dev/null 2>&1 \
        || { rm -f "${zip_path}"; die "Xray zip 文件损坏"; }
    unzip -o "${zip_path}" -d "${WORK_DIR}/" >/dev/null 2>&1 \
        || { rm -f "${zip_path}"; die "Xray 解压失败"; }
    [ -f "${XRAY_BIN}" ] || die "解压后未找到 xray 二进制"
    chmod +x "${XRAY_BIN}"
    # 清理所有解压产物（仅保留 xray 主体）
    rm -f "${zip_path}" \
          "${WORK_DIR}/geosite.dat" "${WORK_DIR}/geoip.dat" \
          "${WORK_DIR}/README.md"   "${WORK_DIR}/LICENSE"
    green "Xray 下载完成"
}

download_cloudflared() {
    local arch_cf="$1"
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch_cf}"
    yellow "下载 cloudflared (${arch_cf})..."
    curl -sfL --connect-timeout 15 --max-time 120 -o "${ARGO_BIN}" "${url}" \
        || die "cloudflared 下载失败，请检查网络"
    [ -s "${ARGO_BIN}" ] || { rm -f "${ARGO_BIN}"; die "cloudflared 下载文件为空"; }
    chmod +x "${ARGO_BIN}"
    green "cloudflared 下载完成"
}

# ── 安装核心组件 ─────────────────────────────────────────────
install_xray() {
    clear; purple "正在安装 Xray-2go，请稍等..."
    pkg_require curl curl
    pkg_require unzip unzip
    pkg_require jq jq
    mkdir -p "${WORK_DIR}" && chmod 755 "${WORK_DIR}"

    local ARCH_CF ARCH_XRAY
    detect_arch

    [ -f "${XRAY_BIN}" ] || download_xray "${ARCH_XRAY}"
    if [ "${ARGO_MODE}" = "yes" ]; then
        [ -f "${ARGO_BIN}" ] || download_cloudflared "${ARCH_CF}"
    fi

    write_config
    green "安装完成"
}

# ── CentOS 时间修正 ──────────────────────────────────────────
fix_centos_time() {
    [ -f /etc/centos-release ] || return 0
    yum install -y chrony >/dev/null 2>&1 || true
    systemctl start chronyd && systemctl enable chronyd || true
    chronyc -a makestep >/dev/null 2>&1 || true
    yum update -y ca-certificates >/dev/null 2>&1 || true
}

# ── 写 tunnel 服务文件（systemd）────────────────────────────
_write_tunnel_service_systemd() {
    local exec_cmd="$1"
    cat > /etc/systemd/system/tunnel.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/sh -c '${exec_cmd} >> ${ARGO_LOG} 2>&1'
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}

# ── 写 tunnel 服务文件（OpenRC）─────────────────────────────
_write_tunnel_service_openrc() {
    local exec_cmd="$1"
    cat > /etc/init.d/tunnel << EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '${exec_cmd} >> ${ARGO_LOG} 2>&1'"
command_background=true
pidfile="/var/run/tunnel.pid"
EOF
    chmod +x /etc/init.d/tunnel
}

# ── 写 xray 服务文件（systemd）──────────────────────────────
_write_xray_service_systemd() {
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=${XRAY_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
}

# ── 写 xray 服务文件（OpenRC）───────────────────────────────
_write_xray_service_openrc() {
    cat > /etc/init.d/xray << EOF
#!/sbin/openrc-run
description="Xray service"
command="${XRAY_BIN}"
command_args="run -c ${CONFIG_FILE}"
command_background=true
pidfile="/var/run/xray.pid"
EOF
    chmod +x /etc/init.d/xray
}

# ── 注册系统服务 ─────────────────────────────────────────────
register_services() {
    local tmp_cmd="${ARGO_BIN} tunnel --url http://localhost:${ARGO_PORT} \
--no-autoupdate --edge-ip-version auto --protocol http2"

    if command -v systemctl >/dev/null 2>&1; then
        _write_xray_service_systemd
        [ "${ARGO_MODE}" = "yes" ] && _write_tunnel_service_systemd "${tmp_cmd}"
        fix_centos_time
        systemctl daemon-reload
        systemctl enable xray && systemctl start xray || die "xray 服务启动失败"
        if [ "${ARGO_MODE}" = "yes" ]; then
            systemctl enable tunnel && systemctl start tunnel || die "tunnel 服务启动失败"
        fi

    elif command -v rc-update >/dev/null 2>&1; then
        _write_xray_service_openrc
        rc-update add xray default
        if [ "${ARGO_MODE}" = "yes" ]; then
            _write_tunnel_service_openrc "${tmp_cmd}"
            rc-update add tunnel default
        fi
        # Alpine 网络特殊处理
        echo "0 0" > /proc/sys/net/ipv4/ping_group_range 2>/dev/null || true
        sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts 2>/dev/null || true
        sed -i '2s/.*/::1         localhost/' /etc/hosts 2>/dev/null || true
        rc-service xray restart 2>/dev/null || true
        [ "${ARGO_MODE}" = "yes" ] && rc-service tunnel restart 2>/dev/null || true
    else
        die "不支持的 init 系统（需要 systemd 或 OpenRC）"
    fi
}

# ── 配置固定隧道 ─────────────────────────────────────────────
configure_fixed_tunnel() {
    yellow "固定隧道回源端口: ${ARGO_PORT}（协议: ${ARGO_PROTOCOL}）"
    yellow "请确保 CF 后台已将该域名的 ingress 指向 http://localhost:${ARGO_PORT}"
    echo ""

    local domain auth
    prompt "请输入你的 Argo 域名: " domain
    case "${domain}" in
        ''|*' '*|*'/'*)
            red "Argo 域名格式不合法"; return 1 ;;
    esac
    echo "${domain}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
        || { red "Argo 域名格式不合法"; return 1; }

    prompt "请输入 Argo 密钥（token 或 JSON 内容）: " auth
    [ -z "${auth}" ] && { red "密钥不能为空"; return 1; }

    local exec_cmd
    if echo "${auth}" | grep -q "TunnelSecret"; then
        echo "${auth}" | jq . >/dev/null 2>&1 || { red "JSON 凭证格式不合法"; return 1; }
        local tid
        tid=$(echo "${auth}" | jq -r '.TunnelID // .AccountTag // empty' 2>/dev/null) || true
        [ -z "${tid}" ] && tid=$(echo "${auth}" | jq -r 'keys_unsorted[1]? // empty' 2>/dev/null) || true
        [ -z "${tid}" ] && { red "无法从 JSON 中提取 TunnelID"; return 1; }
        echo "${auth}" > "${WORK_DIR}/tunnel.json"
        cat > "${WORK_DIR}/tunnel.yml" << EOF
tunnel: ${tid}
credentials-file: ${WORK_DIR}/tunnel.json
protocol: http2

ingress:
  - hostname: ${domain}
    service: http://localhost:${ARGO_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
        exec_cmd="${ARGO_BIN} tunnel --edge-ip-version auto \
--config ${WORK_DIR}/tunnel.yml run"
    elif echo "${auth}" | grep -qE '^[A-Za-z0-9._-]{100,}$'; then
        # Token 格式：至少 100 字符，允许 JWT 点分隔
        exec_cmd="${ARGO_BIN} tunnel --edge-ip-version auto \
--no-autoupdate --protocol http2 run --token ${auth}"
    else
        red "密钥格式无法识别（JSON 凭证需含 TunnelSecret；Token 通常为 100+ 字符串）"
        return 1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        _write_tunnel_service_systemd "${exec_cmd}"
        systemctl daemon-reload
        systemctl enable tunnel 2>/dev/null || true
    else
        _write_tunnel_service_openrc "${exec_cmd}"
        rc-update add tunnel default 2>/dev/null || true
    fi

    replace_argo_inbound || { red "更新 xray inbound 失败"; return 1; }

    printf '%s\n' "${domain}"        > "${DOMAIN_FIXED_FILE}"
    printf '%s\n' "${ARGO_PROTOCOL}" > "${ARGO_PROTO_CONF}"

    restart_xray || return 1
    restart_argo  || return 1

    green "固定隧道（${ARGO_PROTOCOL}，path=/argo）已配置，域名：${domain}"
    return 0
}

# ── 重置为临时隧道 ───────────────────────────────────────────
reset_to_temp_tunnel() {
    local tmp_cmd="${ARGO_BIN} tunnel --url http://localhost:${ARGO_PORT} \
--no-autoupdate --edge-ip-version auto --protocol http2"
    if command -v systemctl >/dev/null 2>&1; then
        _write_tunnel_service_systemd "${tmp_cmd}"
    else
        _write_tunnel_service_openrc "${tmp_cmd}"
    fi
    ARGO_PROTOCOL="ws"
    printf '%s\n' "ws" > "${ARGO_PROTO_CONF}"
    replace_argo_inbound || red "更新 xray inbound 失败"
}

# ── 获取 Argo 临时域名（指数退避，最多等约 30s）─────────────
get_temp_domain() {
    local domain deadline delay=2
    deadline=$(( $(date +%s) + 30 ))
    sleep 2
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        domain=$(grep -o 'https://[^[:space:]]*trycloudflare\.com' \
                 "${ARGO_LOG}" 2>/dev/null | head -1 | sed 's|https://||')
        [ -n "${domain}" ] && echo "${domain}" && return 0
        sleep "${delay}"
        [ "${delay}" -lt 8 ] && delay=$(( delay * 2 ))
    done
    return 1
}

# ── URL path 编码（完整 RFC 3986 保留字符集）────────────────
_urlencode_path() {
    # 用 printf + od 逐字节编码，保留 / 和非保留字符
    local input="$1" output="" byte char
    local i=0 len="${#input}"
    while [ "${i}" -lt "${len}" ]; do
        char="${input:$i:1}"
        case "${char}" in
            [A-Za-z0-9/._~-]) output="${output}${char}" ;;
            *) byte=$(printf '%s' "${char}" | od -An -tx1 | tr -d ' \n')
               output="${output}%${byte}" ;;
        esac
        i=$(( i + 1 ))
    done
    printf '%s' "${output}"
}

# ── 节点链接构建 ─────────────────────────────────────────────
build_freeflow_link() {
    local ip="$1" uuid path_enc
    uuid=$(get_uuid)
    path_enc=$(_urlencode_path "${FF_PATH}")
    # host 参数：IPv6 去掉 [] 包裹，仅传裸地址
    local host_val
    case "${ip}" in
        \[*\]) host_val="${ip#[}"; host_val="${host_val%]}" ;;
        *)     host_val="${ip}" ;;
    esac
    case "${FREEFLOW_MODE}" in
        ws)
            echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=ws&host=${host_val}&path=${path_enc}#FreeFlow-WS" ;;
        httpupgrade)
            echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=httpupgrade&host=${host_val}&path=${path_enc}#FreeFlow-HTTPUpgrade" ;;
        xhttp)
            echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=xhttp&host=${host_val}&path=${path_enc}&mode=stream-one#FreeFlow-XHTTP" ;;
    esac
}

build_ss_link() {
    local ip="$1"
    # SS 链接格式：ss://BASE64(method:password)@host:port
    local userinfo b64
    userinfo="${SS_METHOD}:${SS_PASSWORD}"
    b64=$(printf '%s' "${userinfo}" | base64 | tr -d '\n')
    # host 地址（IPv6 裸地址用 [] 包裹）
    local addr
    case "${ip}" in
        \[*\]) addr="${ip}" ;;
        *:*)   addr="[${ip}]" ;;
        *)     addr="${ip}" ;;
    esac
    echo "ss://${b64}@${addr}:${SS_PORT}#SS-${SS_METHOD}"
}

build_socks5_link() {
    local ip="$1"
    local addr
    case "${ip}" in
        \[*\]) addr="${ip}" ;;
        *:*)   addr="[${ip}]" ;;
        *)     addr="${ip}" ;;
    esac
    if [ -n "${SOCKS5_USER}" ] && [ -n "${SOCKS5_PASS}" ]; then
        echo "socks5://${SOCKS5_USER}:${SOCKS5_PASS}@${addr}:${SOCKS5_PORT}#Socks5-Auth"
    else
        echo "socks5://${addr}:${SOCKS5_PORT}#Socks5-NoAuth"
    fi
}

print_nodes() {
    echo ""
    if [ ! -s "${CLIENT_FILE}" ]; then
        yellow "节点文件为空，请先安装或重新获取节点信息"
        return 1
    fi
    while IFS= read -r line; do
        [ -n "${line}" ] && printf '\033[1;35m%s\033[0m\n' "${line}"
    done < "${CLIENT_FILE}"
    echo ""
}

# ── 生成并保存节点信息 ───────────────────────────────────────
get_info() {
    clear
    local CFIP="${CFIP:-cdns.doon.eu.org}" CFPORT="${CFPORT:-443}"
    local ip uuid argo_domain="${1:-}" skip_select="${2:-}"

    ip=$(get_realip)
    [ -z "${ip}" ] && yellow "警告：无法获取服务器 IP，FreeFlow/SS/Socks5 节点链接将缺失"
    uuid=$(get_uuid)

    # 阶段一：所有交互在主 shell 中
    if [ "${ARGO_MODE}" = "yes" ] && [ -z "${skip_select}" ]; then
        local choice
        echo ""
        green  "请选择 Argo 隧道类型："
        skyblue "-------------------------------"
        green  "1. 临时隧道（自动生成域名，仅 WS，默认）"
        green  "2. 固定隧道（使用自有 token/json）"
        skyblue "-------------------------------"
        prompt "请输入选择(1-2，回车默认1): " choice

        case "${choice}" in
            2)
                [ "${ARGO_PROTOCOL}" = "xhttp" ] && yellow "⚠ XHTTP 仅支持固定隧道"
                if configure_fixed_tunnel; then
                    argo_domain=$(cat "${DOMAIN_FIXED_FILE}" 2>/dev/null) || true
                else
                    yellow "固定隧道配置失败"
                    if [ "${ARGO_PROTOCOL}" = "xhttp" ]; then
                        red "XHTTP 必须配置固定隧道，无法生成节点"
                        return 1
                    fi
                    yellow "回退到 WS 临时隧道"
                    ARGO_PROTOCOL="ws"
                    printf '%s\n' "ws" > "${ARGO_PROTO_CONF}"
                    choice="1"
                fi
                ;;
        esac

        if [ "${choice}" != "2" ]; then
            if [ "${ARGO_PROTOCOL}" = "xhttp" ]; then
                red "⚠ XHTTP 不支持临时隧道，请选择固定隧道"
                return 1
            fi
            purple "正在获取临时 ArgoDomain，请稍等..."
            restart_argo
            argo_domain=$(get_temp_domain) || true
            if [ -z "${argo_domain}" ]; then
                yellow "未能获取 ArgoDomain，可稍后通过 Argo 管理菜单重新获取"
                argo_domain="<未获取到域名>"
            else
                green "ArgoDomain：${argo_domain}"
            fi
        fi
    fi

    # 阶段二：纯输出写文件，零交互
    {
        if [ "${ARGO_MODE}" = "yes" ]; then
            if [ "${ARGO_PROTOCOL}" = "xhttp" ]; then
                echo "vless://${uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argo_domain}&fp=firefox&type=xhttp&host=${argo_domain}&path=%2Fargo&mode=auto#Argo-XHTTP"
            else
                echo "vless://${uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argo_domain}&fp=firefox&type=ws&host=${argo_domain}&path=%2Fargo%3Fed%3D2560#Argo-WS"
            fi
        fi
        [ "${FREEFLOW_MODE}" != "none" ] && [ -n "${ip}" ] && build_freeflow_link "${ip}"
        [ "${SS_MODE}" = "enabled" ]     && [ -n "${ip}" ] && build_ss_link "${ip}"
        [ "${SOCKS5_MODE}" = "enabled" ] && [ -n "${ip}" ] && build_socks5_link "${ip}"
    } > "${CLIENT_FILE}"

    print_nodes
}

# ── 快速刷新临时 WS 域名 ─────────────────────────────────────
refresh_temp_domain() {
    [ "${ARGO_MODE}" = "yes" ] || { yellow "未启用 Argo"; return 1; }
    [ "${ARGO_PROTOCOL}" = "xhttp" ] && \
        { red "⚠ XHTTP 不支持临时隧道，请先切换回 WS 协议"; return 1; }
    [ -s "${CLIENT_FILE}" ] || { yellow "节点文件为空，请先安装"; return 1; }

    yellow "正在重启隧道并获取新域名..."
    restart_argo || return 1
    local domain
    domain=$(get_temp_domain) || { yellow "未能获取临时域名，请检查网络"; return 1; }
    green "ArgoDomain：${domain}"

    awk -v d="${domain}" '
        /#Argo-WS$/ { sub(/sni=[^&]*/, "sni="d); sub(/host=[^&]*/, "host="d) }
        { print }
    ' "${CLIENT_FILE}" > "${CLIENT_FILE}.tmp" && mv "${CLIENT_FILE}.tmp" "${CLIENT_FILE}"

    print_nodes
    green "节点已更新"
}

# ── 更新 FreeFlow 节点链接 ───────────────────────────────────
update_freeflow_link() {
    local ip="$1"
    local new_link; new_link=$(build_freeflow_link "${ip}")
    grep -q '#FreeFlow' "${CLIENT_FILE}" 2>/dev/null || return 0
    awk -v nl="${new_link}" '/#FreeFlow/{print nl; next} {print}' \
        "${CLIENT_FILE}" > "${CLIENT_FILE}.tmp" \
        && mv "${CLIENT_FILE}.tmp" "${CLIENT_FILE}"
}

# ── Cron 管理 ────────────────────────────────────────────────
_cron_available() {
    command -v crontab >/dev/null 2>&1 || return 1
    if is_alpine; then
        rc-service dcron status >/dev/null 2>&1 || rc-service crond status >/dev/null 2>&1
    else
        systemctl is-active --quiet cron 2>/dev/null || \
        systemctl is-active --quiet crond 2>/dev/null
    fi
}

ensure_cron() {
    _cron_available && return 0
    yellow "cron 服务未安装或未运行"
    local ans
    prompt "是否安装 cron？(y/n，回车默认 y): " ans
    case "${ans}" in n|N) red "未安装 cron，自动重启功能不可用"; return 1 ;; esac
    if   command -v apt-get >/dev/null 2>&1; then
        pkg_require cron crontab; systemctl enable --now cron 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then
        pkg_require cronie crontab; systemctl enable --now crond 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        pkg_require cronie crontab; systemctl enable --now crond 2>/dev/null || true
    elif command -v apk >/dev/null 2>&1; then
        pkg_require dcron crontab
        rc-service dcron start 2>/dev/null || true
        rc-update add dcron default 2>/dev/null || true
    else
        die "无法安装 cron，请手动安装后重试"
    fi
}

setup_auto_restart() {
    ensure_cron || return 1
    local cmd tmp
    is_alpine && cmd="rc-service xray restart" || cmd="systemctl restart xray"
    tmp=$(mktemp) || die "无法创建临时文件"
    # 保证 mktemp 失败后临时文件被清理
    trap 'rm -f "${tmp}"' RETURN
    { crontab -l 2>/dev/null | sed '/xray-restart/d'; \
      echo "*/${RESTART_INTERVAL} * * * * ${cmd} >/dev/null 2>&1 #xray-restart"; } > "${tmp}"
    crontab "${tmp}" || { red "crontab 写入失败"; return 1; }
    green "已设置每 ${RESTART_INTERVAL} 分钟自动重启 Xray"
}

remove_auto_restart() {
    command -v crontab >/dev/null 2>&1 || return 0
    local tmp; tmp=$(mktemp) || return 0
    trap 'rm -f "${tmp}"' RETURN
    crontab -l 2>/dev/null | sed '/xray-restart/d' > "${tmp}" || true
    crontab "${tmp}" 2>/dev/null || true
}

# ── 更新脚本/快捷方式 ────────────────────────────────────────
install_shortcut() {
    yellow "正在拉取最新脚本..."
    local tmp="/usr/local/bin/xray2go.tmp"
    curl -sfL --connect-timeout 10 --max-time 60 -o "${tmp}" \
        "https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh" \
        || { red "拉取失败，请检查网络"; return 1; }
    bash -n "${tmp}" 2>/dev/null \
        || { rm -f "${tmp}"; red "下载的脚本语法验证失败，已中止"; return 1; }
    mv "${tmp}" /usr/local/bin/xray2go
    chmod +x /usr/local/bin/xray2go
    printf '#!/bin/bash\nexec /usr/local/bin/xray2go "$@"\n' > "${SHORTCUT}"
    chmod +x "${SHORTCUT}"
    green "快捷方式已创建/脚本已更新！输入 s 快速启动"
}

# ── 状态检测 ─────────────────────────────────────────────────
check_xray() {
    [ -f "${XRAY_BIN}" ] || { echo "not installed"; return 2; }
    if is_alpine; then
        rc-service xray status 2>/dev/null | grep -q "started" \
            && { echo "running"; return 0; } || { echo "not running"; return 1; }
    else
        [ "$(systemctl is-active xray 2>/dev/null)" = "active" ] \
            && { echo "running"; return 0; } || { echo "not running"; return 1; }
    fi
}

check_argo() {
    [ "${ARGO_MODE}" = "no" ] && { echo "disabled"; return 3; }
    [ -f "${ARGO_BIN}" ]      || { echo "not installed"; return 2; }
    if is_alpine; then
        rc-service tunnel status 2>/dev/null | grep -q "started" \
            && { echo "running"; return 0; } || { echo "not running"; return 1; }
    else
        [ "$(systemctl is-active tunnel 2>/dev/null)" = "active" ] \
            && { echo "running"; return 0; } || { echo "not running"; return 1; }
    fi
}

is_fixed_tunnel() {
    if command -v systemctl >/dev/null 2>&1; then
        ! grep -Fq -- "--url http://localhost:${ARGO_PORT}" \
            /etc/systemd/system/tunnel.service 2>/dev/null
    else
        ! grep -Fq -- "--url http://localhost:${ARGO_PORT}" \
            /etc/init.d/tunnel 2>/dev/null
    fi
}

# ════════════════════════════════════════════════════════════
# 交互菜单
# ════════════════════════════════════════════════════════════

ask_argo_mode() {
    echo ""
    green  "是否安装 Cloudflare Argo 隧道？"
    skyblue "------------------------------------"
    green  "1. 安装 Argo（VLESS+WS/XHTTP+TLS，默认）"
    green  "2. 不安装 Argo（仅 FreeFlow/SS/Socks5 节点）"
    skyblue "------------------------------------"
    local _c
    prompt "请输入选择(1-2，回车默认1): " _c
    case "${_c}" in 2) ARGO_MODE="no" ;; *) ARGO_MODE="yes" ;; esac
    mkdir -p "${WORK_DIR}"
    printf '%s\n' "${ARGO_MODE}" > "${ARGO_MODE_CONF}"
    case "${ARGO_MODE}" in yes) green "已选择：安装 Argo" ;; no) yellow "已选择：不安装 Argo" ;; esac
    echo ""
}

ask_argo_protocol() {
    echo ""
    green  "请选择 Argo 隧道传输协议："
    skyblue "-----------------------------"
    green  "1. WS（WebSocket，支持临时/固定隧道，默认）"
    green  "2. XHTTP（auto 模式，仅支持固定隧道）"
    skyblue "-----------------------------"
    local _c
    prompt "请输入选择(1-2，回车默认1): " _c
    case "${_c}" in
        2)
            ARGO_PROTOCOL="xhttp"
            echo ""
            yellow "⚠ XHTTP 不支持临时隧道！安装后将直接进入固定隧道配置流程。"
            echo ""
            ;;
        *) ARGO_PROTOCOL="ws" ;;
    esac
    mkdir -p "${WORK_DIR}"
    printf '%s\n' "${ARGO_PROTOCOL}" > "${ARGO_PROTO_CONF}"
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
    green  "3. VLESS + XHTTP       （stream-one，port 80）"
    green  "4. 不启用 FreeFlow（默认）"
    skyblue "--------------------------------------"
    local _c
    prompt "请输入选择(1-4，回车默认4): " _c
    case "${_c}" in
        1) FREEFLOW_MODE="ws"          ;;
        2) FREEFLOW_MODE="httpupgrade" ;;
        3) FREEFLOW_MODE="xhttp"       ;;
        *) FREEFLOW_MODE="none"        ;;
    esac

    if [ "${FREEFLOW_MODE}" != "none" ]; then
        local _p
        prompt "请输入 FreeFlow path（回车默认 /）: " _p
        if [ -z "${_p}" ]; then
            FF_PATH="/"
        else
            case "${_p}" in /*) FF_PATH="${_p}" ;; *) FF_PATH="/${_p}" ;; esac
        fi
        port_in_use 80 && yellow "⚠ 端口 80 已被占用，FreeFlow 可能无法启动"
    else
        FF_PATH="/"
    fi

    save_freeflow_conf
    case "${FREEFLOW_MODE}" in
        ws)          green  "已选择：WS FreeFlow（path=${FF_PATH}）"                   ;;
        httpupgrade) green  "已选择：HTTPUpgrade FreeFlow（path=${FF_PATH}）"          ;;
        xhttp)       green  "已选择：XHTTP FreeFlow（stream-one，path=${FF_PATH}）"    ;;
        none)        yellow "不启用 FreeFlow"                                           ;;
    esac
    echo ""
}

ask_ss_mode() {
    echo ""
    green  "是否启用 Shadowsocks？"
    skyblue "------------------------------------"
    green  "1. 启用"
    green  "2. 不启用（默认）"
    skyblue "------------------------------------"
    local _c _port _pass _method
    prompt "请输入选择(1-2，回车默认2): " _c
    case "${_c}" in
        1)
            while true; do
                prompt "请输入 SS 监听端口（1-65535）: " _port
                is_valid_port "${_port}" && break
                red "端口不合法，请重新输入"
            done
            check_port_conflict "${_port}" "SS 端口" || { SS_MODE="none"; save_ss_conf; return; }

            prompt "请输入 SS 密码（回车随机生成）: " _pass
            [ -z "${_pass}" ] && _pass=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
            green "SS 密码：${_pass}"

            echo ""
            green  "请选择加密方式："
            skyblue "--------------------------------------"
            green  "1. aes-128-gcm（默认）"
            green  "2. aes-256-gcm"
            green  "3. chacha20-ietf-poly1305"
            green  "4. 2022-blake3-aes-128-gcm（SS2022）"
            green  "5. 2022-blake3-aes-256-gcm（SS2022）"
            green  "6. 2022-blake3-chacha20-poly1305（SS2022）"
            skyblue "--------------------------------------"
            local _m
            prompt "请输入选择(1-6，回车默认1): " _m
            case "${_m}" in
                2) _method="aes-256-gcm"                      ;;
                3) _method="chacha20-ietf-poly1305"           ;;
                4) _method="2022-blake3-aes-128-gcm"          ;;
                5) _method="2022-blake3-aes-256-gcm"          ;;
                6) _method="2022-blake3-chacha20-poly1305"    ;;
                *) _method="aes-128-gcm"                      ;;
            esac

            SS_MODE="enabled"; SS_PORT="${_port}"
            SS_PASSWORD="${_pass}"; SS_METHOD="${_method}"
            save_ss_conf
            green "已选择：Shadowsocks ${_method}，端口 ${_port}"
            ;;
        *) SS_MODE="none"; save_ss_conf; yellow "不启用 Shadowsocks" ;;
    esac
    echo ""
}

ask_socks5_mode() {
    echo ""
    green  "是否启用 Socks5？"
    skyblue "------------------------------------"
    green  "1. 启用（无认证）"
    green  "2. 启用（用户名/密码认证）"
    green  "3. 不启用（默认）"
    skyblue "------------------------------------"
    local _c _port _u _p
    prompt "请输入选择(1-3，回车默认3): " _c
    case "${_c}" in
        1|2)
            while true; do
                prompt "请输入 Socks5 监听端口（1-65535）: " _port
                is_valid_port "${_port}" && break
                red "端口不合法，请重新输入"
            done
            check_port_conflict "${_port}" "Socks5 端口" || { SOCKS5_MODE="none"; save_socks5_conf; return; }

            if [ "${_c}" = "2" ]; then
                prompt "请输入用户名: " _u
                prompt "请输入密码: " _p
                [ -z "${_u}" ] && { red "用户名不能为空"; SOCKS5_MODE="none"; save_socks5_conf; return; }
                SOCKS5_USER="${_u}"; SOCKS5_PASS="${_p}"
                green "已选择：Socks5（认证），端口 ${_port}"
            else
                SOCKS5_USER=""; SOCKS5_PASS=""
                green "已选择：Socks5（无认证），端口 ${_port}"
            fi

            SOCKS5_MODE="enabled"; SOCKS5_PORT="${_port}"
            save_socks5_conf
            ;;
        *) SOCKS5_MODE="none"; save_socks5_conf; yellow "不启用 Socks5" ;;
    esac
    echo ""
}

# ── Argo 管理菜单 ─────────────────────────────────────────────
manage_argo() {
    [ "${ARGO_MODE}" = "yes" ] || { yellow "未启用 Argo"; sleep 1; return; }
    [ -f "${ARGO_BIN}" ]       || { yellow "Argo 未安装"; sleep 1; return; }

    local fixed_domain; fixed_domain=$(cat "${DOMAIN_FIXED_FILE}" 2>/dev/null) || true
    local type_disp
    if is_fixed_tunnel && [ -n "${fixed_domain}" ]; then
        type_disp="固定（${ARGO_PROTOCOL}，${fixed_domain}）"
    else
        type_disp="临时（WS）"
    fi

    clear; echo ""
    green  "Argo 状态：$(check_argo)"
    skyblue "  协议: ${ARGO_PROTOCOL}  端口: ${ARGO_PORT}  类型: ${type_disp}"
    echo   "========================================================"
    green  "1. 添加/更新固定隧道"
    green  "2. 切换协议（WS ↔ XHTTP，仅固定隧道）"
    green  "3. 切换回临时隧道（仅 WS）"
    green  "4. 重新获取临时域名（WS）"
    green  "5. 修改回源端口（当前：${ARGO_PORT}）"
    green  "6. 启动隧道"
    green  "7. 停止隧道"
    purple "0. 返回"
    skyblue "------------"
    local _c
    prompt "请输入选择: " _c

    case "${_c}" in
        1)
            echo ""
            green  "请选择固定隧道协议："
            skyblue "-----------------------------"
            green  "1. WS（默认）"
            green  "2. XHTTP（auto 模式）"
            skyblue "-----------------------------"
            local _p
            prompt "请输入选择(1-2，回车维持当前 ${ARGO_PROTOCOL}): " _p
            case "${_p}" in 2) ARGO_PROTOCOL="xhttp" ;; 1) ARGO_PROTOCOL="ws" ;; esac
            printf '%s\n' "${ARGO_PROTOCOL}" > "${ARGO_PROTO_CONF}"
            if configure_fixed_tunnel; then
                get_info "$(cat "${DOMAIN_FIXED_FILE}" 2>/dev/null)" "1"
            else
                red "固定隧道配置失败，请检查域名和密钥"
            fi
            ;;
        2)
            is_fixed_tunnel || { yellow "当前为临时隧道，请先配置固定隧道"; return; }
            [ "${ARGO_PROTOCOL}" = "ws" ] && ARGO_PROTOCOL="xhttp" || ARGO_PROTOCOL="ws"
            printf '%s\n' "${ARGO_PROTOCOL}" > "${ARGO_PROTO_CONF}"
            replace_argo_inbound || { red "inbound 更新失败"; return; }
            restart_xray || return
            green "协议已切换为：${ARGO_PROTOCOL}"
            get_info "$(cat "${DOMAIN_FIXED_FILE}" 2>/dev/null)" "1"
            ;;
        3)
            [ "${ARGO_PROTOCOL}" = "xhttp" ] && \
                { red "⚠ XHTTP 不支持临时隧道，请先切换协议为 WS"; return; }
            reset_to_temp_tunnel
            restart_xray
            refresh_temp_domain
            ;;
        4) refresh_temp_domain ;;
        5)
            local _p _port
            prompt "请输入新的回源端口（回车随机）: " _p
            [ -z "${_p}" ] && _p=$(shuf -i 2000-65000 -n 1 2>/dev/null || \
                                   awk 'BEGIN{srand(); print int(rand()*63000+2000)}')
            is_valid_port "${_p}" || { red "端口不合法（须为 1-65535 整数）"; return; }
            check_port_conflict "${_p}" "回源端口" || return
            jq_edit "${CONFIG_FILE}" \
                '(.inbounds[]? | select(.port == $oldp) | .port) |= $newp' \
                --argjson oldp "${ARGO_PORT}" --argjson newp "${_p}" \
                || { red "端口修改失败"; return; }
            if command -v systemctl >/dev/null 2>&1; then
                sed -i "s|localhost:${ARGO_PORT}|localhost:${_p}|g" \
                    /etc/systemd/system/tunnel.service 2>/dev/null
            else
                sed -i "s|localhost:${ARGO_PORT}|localhost:${_p}|g" \
                    /etc/init.d/tunnel 2>/dev/null
            fi
            ARGO_PORT="${_p}"
            restart_xray && restart_argo
            green "回源端口已修改为：${_p}"
            ;;
        6) svc start tunnel; green "隧道已启动" ;;
        7) svc stop  tunnel; green "隧道已停止" ;;
        0) return ;;
        *) red "无效选项" ;;
    esac
}

# ── FreeFlow 管理菜单 ─────────────────────────────────────────
manage_freeflow() {
    clear; echo ""
    green  "FreeFlow 当前配置："
    [ "${FREEFLOW_MODE}" = "none" ] \
        && skyblue "  未启用" \
        || skyblue "  方式: ${FREEFLOW_MODE}（path=${FF_PATH}）"
    echo   "=========================="
    green  "1. 添加/变更方式"
    green  "2. 修改 path"
    red    "3. 卸载 FreeFlow"
    purple "0. 返回"
    skyblue "------------"
    local _c
    prompt "请输入选择: " _c

    case "${_c}" in
        1)
            ask_freeflow_mode
            apply_freeflow || { red "FreeFlow 配置更新失败"; return; }
            local ip_now; ip_now=$(get_realip)
            {
                grep '#Argo' "${CLIENT_FILE}" 2>/dev/null || true
                [ "${FREEFLOW_MODE}" != "none" ] && [ -n "${ip_now}" ] && \
                    build_freeflow_link "${ip_now}"
            } > "${CLIENT_FILE}.new" && mv "${CLIENT_FILE}.new" "${CLIENT_FILE}"
            restart_xray; green "FreeFlow 已变更"; print_nodes
            ;;
        2)
            local _p
            prompt "请输入新的 path（回车保持 ${FF_PATH}）: " _p
            if [ -n "${_p}" ]; then
                case "${_p}" in /*) FF_PATH="${_p}" ;; *) FF_PATH="/${_p}" ;; esac
                save_freeflow_conf
                apply_freeflow || { red "FreeFlow 配置更新失败"; return; }
                local ip_now; ip_now=$(get_realip)
                [ -n "${ip_now}" ] && update_freeflow_link "${ip_now}"
                restart_xray; green "FreeFlow path 已修改为：${FF_PATH}"; print_nodes
            fi
            ;;
        3)
            FREEFLOW_MODE="none"; save_freeflow_conf
            apply_freeflow || { red "卸载 FreeFlow 失败"; return; }
            [ -f "${CLIENT_FILE}" ] && \
                grep -v '#FreeFlow' "${CLIENT_FILE}" > "${CLIENT_FILE}.tmp" && \
                mv "${CLIENT_FILE}.tmp" "${CLIENT_FILE}"
            restart_xray; green "FreeFlow 已卸载"
            ;;
        0) return ;;
        *) red "无效选项" ;;
    esac
}

# ── SS 管理菜单 ───────────────────────────────────────────────
manage_ss() {
    clear; echo ""
    green  "Shadowsocks 当前配置："
    if [ "${SS_MODE}" = "enabled" ]; then
        skyblue "  方式: ${SS_METHOD}  端口: ${SS_PORT}"
    else
        skyblue "  未启用"
    fi
    echo   "=========================="
    green  "1. 启用/变更 Shadowsocks"
    red    "2. 卸载 Shadowsocks"
    purple "0. 返回"
    skyblue "------------"
    local _c
    prompt "请输入选择: " _c

    case "${_c}" in
        1)
            ask_ss_mode
            apply_ss || { red "Shadowsocks 配置更新失败"; return; }
            # 重建 url.txt
            local ip_now; ip_now=$(get_realip)
            {
                grep -v '#SS-' "${CLIENT_FILE}" 2>/dev/null || true
                [ "${SS_MODE}" = "enabled" ] && [ -n "${ip_now}" ] && build_ss_link "${ip_now}"
            } > "${CLIENT_FILE}.new" && mv "${CLIENT_FILE}.new" "${CLIENT_FILE}"
            restart_xray; green "Shadowsocks 已变更"; print_nodes
            ;;
        2)
            SS_MODE="none"; save_ss_conf
            apply_ss || { red "卸载 Shadowsocks 失败"; return; }
            [ -f "${CLIENT_FILE}" ] && \
                grep -v '#SS-' "${CLIENT_FILE}" > "${CLIENT_FILE}.tmp" && \
                mv "${CLIENT_FILE}.tmp" "${CLIENT_FILE}"
            restart_xray; green "Shadowsocks 已卸载"
            ;;
        0) return ;;
        *) red "无效选项" ;;
    esac
}

# ── Socks5 管理菜单 ───────────────────────────────────────────
manage_socks5() {
    clear; echo ""
    green  "Socks5 当前配置："
    if [ "${SOCKS5_MODE}" = "enabled" ]; then
        local auth_disp
        [ -n "${SOCKS5_USER}" ] && auth_disp="用户: ${SOCKS5_USER}" || auth_disp="无认证"
        skyblue "  端口: ${SOCKS5_PORT}  ${auth_disp}"
    else
        skyblue "  未启用"
    fi
    echo   "=========================="
    green  "1. 启用/变更 Socks5"
    red    "2. 卸载 Socks5"
    purple "0. 返回"
    skyblue "------------"
    local _c
    prompt "请输入选择: " _c

    case "${_c}" in
        1)
            ask_socks5_mode
            apply_socks5 || { red "Socks5 配置更新失败"; return; }
            local ip_now; ip_now=$(get_realip)
            {
                grep -v '#Socks5-' "${CLIENT_FILE}" 2>/dev/null || true
                [ "${SOCKS5_MODE}" = "enabled" ] && [ -n "${ip_now}" ] && build_socks5_link "${ip_now}"
            } > "${CLIENT_FILE}.new" && mv "${CLIENT_FILE}.new" "${CLIENT_FILE}"
            restart_xray; green "Socks5 已变更"; print_nodes
            ;;
        2)
            SOCKS5_MODE="none"; save_socks5_conf
            apply_socks5 || { red "卸载 Socks5 失败"; return; }
            [ -f "${CLIENT_FILE}" ] && \
                grep -v '#Socks5-' "${CLIENT_FILE}" > "${CLIENT_FILE}.tmp" && \
                mv "${CLIENT_FILE}.tmp" "${CLIENT_FILE}"
            restart_xray; green "Socks5 已卸载"
            ;;
        0) return ;;
        *) red "无效选项" ;;
    esac
}

# ── 自动重启管理 ─────────────────────────────────────────────
manage_restart() {
    clear; echo ""
    green  "自动重启间隔：当前 ${RESTART_INTERVAL} 分钟（0=关闭）"
    echo   "=========================="
    green  "1. 设置间隔"
    purple "2. 返回"
    skyblue "------------"
    local _c
    prompt "请输入选择: " _c
    case "${_c}" in
        1)
            local _v
            prompt "请输入间隔分钟（0关闭，推荐 60）: " _v
            case "${_v}" in ''|*[!0-9]*) red "无效输入"; return ;; esac
            RESTART_INTERVAL="${_v}"
            mkdir -p "${WORK_DIR}"
            printf '%s\n' "${RESTART_INTERVAL}" > "${RESTART_CONF}"
            if [ "${RESTART_INTERVAL}" -eq 0 ]; then
                remove_auto_restart; green "自动重启已关闭"
            else
                setup_auto_restart
            fi
            ;;
        2) return ;;
        *) red "无效选项" ;;
    esac
}

# ── 卸载 ─────────────────────────────────────────────────────
uninstall_all() {
    local _c
    prompt "确定要卸载 xray-2go 吗？(y/n): " _c
    case "${_c}" in y|Y) : ;; *) purple "已取消"; return ;; esac
    yellow "正在卸载..."
    remove_auto_restart
    if command -v systemctl >/dev/null 2>&1; then
        svc stop xray;   svc disable xray
        svc stop tunnel; svc disable tunnel
        rm -f /etc/systemd/system/xray.service \
              /etc/systemd/system/tunnel.service
        systemctl daemon-reload
    else
        svc stop xray;   svc disable xray
        svc stop tunnel; svc disable tunnel
        rm -f /etc/init.d/xray /etc/init.d/tunnel
    fi
    rm -rf "${WORK_DIR}"
    rm -f "${SHORTCUT}" /usr/local/bin/xray2go
    green "Xray-2go 卸载完成"
}

# ── 主菜单 ────────────────────────────────────────────────────
trap 'echo ""; red "已中断"; exit 130' INT

menu() {
    while true; do
        local xstat astat cx ff_disp argo_disp ss_disp sk_disp
        xstat=$(check_xray); cx=$?
        astat=$(check_argo)

        case "${FREEFLOW_MODE}" in
            ws)          ff_disp="WS（path=${FF_PATH}）"          ;;
            httpupgrade) ff_disp="HTTPUpgrade（path=${FF_PATH}）" ;;
            xhttp)       ff_disp="XHTTP（path=${FF_PATH}）"       ;;
            *)           ff_disp="未启用"                          ;;
        esac

        [ "${SS_MODE}" = "enabled" ]     && ss_disp="${SS_METHOD}:${SS_PORT}"  || ss_disp="未启用"
        [ "${SOCKS5_MODE}" = "enabled" ] && sk_disp="port ${SOCKS5_PORT}"      || sk_disp="未启用"

        local fixed_domain; fixed_domain=$(cat "${DOMAIN_FIXED_FILE}" 2>/dev/null) || true
        if [ "${ARGO_MODE}" = "yes" ]; then
            [ -n "${fixed_domain}" ] \
                && argo_disp="${astat}（${ARGO_PROTOCOL}，固定：${fixed_domain}）" \
                || argo_disp="${astat}（WS，临时隧道）"
        else
            argo_disp="未启用"
        fi

        clear; echo ""
        purple "=== Xray-2go ==="
        purple " Xray:        ${xstat}"
        purple " Argo:        ${argo_disp}"
        purple " FreeFlow:    ${ff_disp}"
        purple " Shadowsocks: ${ss_disp}"
        purple " Socks5:      ${sk_disp}"
        purple " 重启间隔:    ${RESTART_INTERVAL} 分钟"
        echo   "========================"
        green  "1. 安装 Xray-2go"
        red    "2. 卸载 Xray-2go"
        echo   "================="
        green  "3. Argo 管理"
        green  "4. FreeFlow 管理"
        green  "5. Shadowsocks 管理"
        green  "6. Socks5 管理"
        echo   "================="
        green  "7. 查看节点"
        green  "8. 修改 UUID"
        green  "9. 自动重启管理"
        green  "10. 快捷方式/脚本更新"
        echo   "================="
        red    "0. 退出"
        echo   "==========="
        local _c
        prompt "请输入选择(0-10): " _c
        echo ""

        case "${_c}" in
            1)
                if [ "${cx}" -eq 0 ]; then
                    yellow "Xray-2go 已安装，如需重装请先卸载"
                else
                    ask_argo_mode
                    [ "${ARGO_MODE}" = "yes" ] && ask_argo_protocol
                    ask_freeflow_mode
                    ask_ss_mode
                    ask_socks5_mode

                    if [ "${ARGO_MODE}" = "yes" ]; then
                        port_in_use "${ARGO_PORT}" && \
                            yellow "⚠ 端口 ${ARGO_PORT} 已被占用，可安装后通过 Argo 管理修改"
                    fi

                    install_xray       || { red "安装失败"; continue; }
                    register_services  || { red "服务注册失败"; continue; }

                    if [ "${ARGO_MODE}" = "yes" ] && [ "${ARGO_PROTOCOL}" = "xhttp" ]; then
                        echo ""
                        yellow "════════════════════════════════"
                        yellow " XHTTP 需配置固定隧道才能使用"
                        yellow "════════════════════════════════"
                        echo ""
                        if configure_fixed_tunnel; then
                            get_info "$(cat "${DOMAIN_FIXED_FILE}" 2>/dev/null)" "1"
                        else
                            red "固定隧道配置失败，请从 Argo 管理菜单重新配置"
                        fi
                    else
                        get_info
                    fi
                fi
                ;;
            2)  uninstall_all ;;
            3)  manage_argo ;;
            4)  manage_freeflow ;;
            5)  manage_ss ;;
            6)  manage_socks5 ;;
            7)
                [ "${cx}" -eq 0 ] && print_nodes || yellow "Xray-2go 未安装或未运行"
                ;;
            8)
                [ -f "${CONFIG_FILE}" ] || { yellow "请先安装 Xray-2go"; continue; }
                local _v
                prompt "请输入新的 UUID（回车自动生成）: " _v
                if [ -z "${_v}" ]; then
                    _v=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) \
                        || { red "无法生成 UUID"; continue; }
                    green "生成的 UUID：${_v}"
                fi
                echo "${_v}" | grep -qiE \
                    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
                    || { red "UUID 格式不合法"; continue; }
                jq_edit "${CONFIG_FILE}" \
                    '(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) = $u' \
                    --arg u "${_v}" || { red "UUID 更新失败"; continue; }
                UUID="${_v}"
                if [ -s "${CLIENT_FILE}" ]; then
                    awk -v u="${_v}" \
                        '{gsub(/vless:\/\/[^@]*@/, "vless://"u"@"); print}' \
                        "${CLIENT_FILE}" > "${CLIENT_FILE}.tmp" \
                        && mv "${CLIENT_FILE}.tmp" "${CLIENT_FILE}"
                fi
                restart_xray && green "UUID 已修改为：${_v}"
                print_nodes
                ;;
            9)  manage_restart ;;
            10) install_shortcut ;;
            0)  exit 0 ;;
            *)  red "无效选项，请输入 0 到 10" ;;
        esac
        printf '\033[1;91m按回车键继续...\033[0m' >&2
        read -r _dummy
    done
}

menu
