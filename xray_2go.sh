#!/usr/bin/env bash
# ==============================================================================
# xray-2go v2.1 — 自迭代优化版
# 协议插件架构：Argo WS/XHTTP + FreeFlow WS/HTTPUpgrade/XHTTP
# 首选平台：Debian 12 / Ubuntu | 兼容：CentOS/RHEL、Alpine (OpenRC)
# 变更摘要（相对 v2.0）：
#   [FIX-01] trap §0 移至 §3 之后，消除 log_error 前向引用
#   [FIX-02] spinner 子 shell 用 case 取字符，兼容 Alpine ash
#   [FIX-03] UUID 在调用链顶层取一次，消除重复 jq fork
#   [FIX-04] get_realip 并行 IPv4/IPv6 探测，最坏耗时从 15s→5s
#   [FIX-05] _write_service_file 改用 cmp -s 字节比较，消除字符串陷阱
#   [FIX-06] menu() 临时域名分支用函数封装，消除 local-in-case 歧义
#   [FIX-07] load_state 读 FF_CONF 改用单次 read，去掉两次 sed fork
#   [FIX-08] jq_edit 加 umask 022 限制临时文件权限
#   [FIX-09] check_bbr 单分支 case 改为 if，提升可读性
#   [FIX-10] _realip_cache 缓存 get_realip 结果，避免重复网络请求
#   [FIX-11] _save_ff_conf 改用 printf 双行写入，消除末尾多余换行
#   [FIX-12] restart_xray/argo 加 is-active 二次确认，真正验证启动
# ==============================================================================
set -uo pipefail

# ==============================================================================
# §1 ── FHS 路径常量
# ==============================================================================
readonly WORK_DIR="/etc/xray"
readonly XRAY_BIN="${WORK_DIR}/xray"
readonly ARGO_BIN="${WORK_DIR}/argo"
readonly CONFIG_FILE="${WORK_DIR}/config.json"
readonly CLIENT_FILE="${WORK_DIR}/url.txt"
readonly ARGO_LOG="${WORK_DIR}/argo.log"
readonly SHORTCUT="/usr/local/bin/s"
readonly SELF_DEST="/usr/local/bin/xray2go"
readonly UPSTREAM_URL="https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh"

readonly ST_ARGO_MODE="${WORK_DIR}/argo_mode.conf"
readonly ST_ARGO_PROTO="${WORK_DIR}/argo_protocol.conf"
readonly ST_ARGO_PORT="${WORK_DIR}/argo_port.conf"
readonly ST_FF_CONF="${WORK_DIR}/freeflow.conf"
readonly ST_DOMAIN_FIXED="${WORK_DIR}/domain_fixed.txt"
readonly ST_RESTART="${WORK_DIR}/restart.conf"

# ==============================================================================
# §2 ── 运行时全局状态
# ==============================================================================
ARGO_MODE="yes"
ARGO_PROTOCOL="ws"
ARGO_PORT="8080"
FREEFLOW_MODE="none"
FF_PATH="/"
RESTART_INTERVAL=0
UUID="${UUID:-}"
_INIT_SYS=""
_ARCH_CF=""
_ARCH_XRAY=""
_SYSTEMD_DIRTY=0
_realip_cache=""      # [FIX-10] get_realip 结果缓存，避免重复网络请求

# ==============================================================================
# §3 ── UI 层（统一色彩 + 信息等级 + 交互原语）
# ==============================================================================
readonly _C_RST=$'\033[0m'
readonly _C_BOLD=$'\033[1m'
readonly _C_RED=$'\033[1;91m'
readonly _C_GRN=$'\033[1;32m'
readonly _C_YLW=$'\033[1;33m'
readonly _C_PUR=$'\033[1;35m'
readonly _C_CYN=$'\033[1;36m'

log_info()  { printf "${_C_CYN}[INFO]${_C_RST} %s\n"      "$*"; }
log_ok()    { printf "${_C_GRN}[ OK ]${_C_RST} %s\n"      "$*"; }
log_warn()  { printf "${_C_YLW}[WARN]${_C_RST} %s\n"      "$*" >&2; }
log_error() { printf "${_C_RED}[ERR ]${_C_RST} %s\n"      "$*" >&2; }
log_step()  { printf "${_C_PUR}[....] %s${_C_RST}\n"      "$*"; }
log_title() { printf "\n${_C_BOLD}${_C_PUR}%s${_C_RST}\n" "$*"; }
die()       { log_error "$1"; exit "${2:-1}"; }

# 交互提示：走 stderr + /dev/tty，兼容管道/重定向
prompt() {
    printf "${_C_RED}%s${_C_RST}" "$1" >&2
    read -r "$2" </dev/tty
}

_spinner_pid=0

# [FIX-02] spinner 子 shell 改用 case 取字符，兼容 Alpine ash（无 ${var:n:1}）
spinner_start() {
    local msg="$1"
    printf "${_C_CYN}[....] %s${_C_RST}\n" "${msg}"
    (
        i=0
        while true; do
            case $(( i % 4 )) in
                0) c='-' ;; 1) c='\\' ;; 2) c='|' ;; *) c='/' ;;
            esac
            printf "\r${_C_CYN}[ %s  ]${_C_RST} %s  " "${c}" "${msg}" >&2
            sleep 0.15; i=$(( i + 1 ))
        done
    ) &
    _spinner_pid=$!
    disown "${_spinner_pid}" 2>/dev/null || true
}

spinner_stop() {
    [ "${_spinner_pid}" -ne 0 ] && kill "${_spinner_pid}" 2>/dev/null || true
    _spinner_pid=0
    printf '\r\033[2K' >&2
}

_pause() {
    printf "${_C_RED}按回车键继续...${_C_RST}" >&2
    read -r _dummy </dev/tty || true
}

_hr() { printf "${_C_PUR}%s${_C_RST}\n" "  ──────────────────────────────────"; }

# ==============================================================================
# §0 ── 全局中断处理（[FIX-01] 移至 §3 之后，log_error 已定义）
# ==============================================================================
_cleanup_on_exit() {
    spinner_stop
    tput cnorm 2>/dev/null || true
}
_cleanup_on_int() {
    spinner_stop
    printf '\n' >&2
    log_error "已中断"
    exit 130
}
trap '_cleanup_on_exit' EXIT
trap '_cleanup_on_int'  INT TERM

# ==============================================================================
# §4 ── 平台检测层
# ==============================================================================
_detect_init() {
    if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
        _INIT_SYS="systemd"
    elif command -v rc-update >/dev/null 2>&1; then
        _INIT_SYS="openrc"
    else
        die "不支持的 init 系统（需要 systemd 或 OpenRC）"
    fi
}

is_systemd() { [ "${_INIT_SYS}" = "systemd" ]; }
is_openrc()  { [ "${_INIT_SYS}" = "openrc"  ]; }
is_alpine()  { [ -f /etc/alpine-release ]; }
is_debian()  { [ -f /etc/debian_version ]; }

detect_arch() {
    [ -n "${_ARCH_XRAY}" ] && return 0
    case "$(uname -m)" in
        x86_64)          _ARCH_CF="amd64";  _ARCH_XRAY="64"        ;;
        x86|i686|i386)   _ARCH_CF="386";    _ARCH_XRAY="32"        ;;
        aarch64|arm64)   _ARCH_CF="arm64";  _ARCH_XRAY="arm64-v8a" ;;
        armv7l)          _ARCH_CF="armv7";  _ARCH_XRAY="arm32-v7a" ;;
        s390x)           _ARCH_CF="s390x";  _ARCH_XRAY="s390x"     ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

# ==============================================================================
# §5 ── 环境自愈层
# ==============================================================================
check_root() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || die "请在 root 下运行脚本"
}

pkg_require() {
    local pkg="$1" bin="${2:-$1}"
    command -v "${bin}" >/dev/null 2>&1 && return 0
    log_step "安装依赖: ${pkg}"
    if   command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}" >/dev/null 2>&1
    elif command -v dnf     >/dev/null 2>&1; then dnf  install -y "${pkg}" >/dev/null 2>&1
    elif command -v yum     >/dev/null 2>&1; then yum  install -y "${pkg}" >/dev/null 2>&1
    elif command -v apk     >/dev/null 2>&1; then apk  add        "${pkg}" >/dev/null 2>&1
    else die "未找到包管理器，无法安装 ${pkg}"
    fi
    hash -r 2>/dev/null || true
    command -v "${bin}" >/dev/null 2>&1 || die "${pkg} 安装失败，请手动安装后重试"
    log_ok "${pkg} 已就绪"
}

check_deps() {
    log_step "检查运行时依赖 (curl / unzip / jq)..."
    for _dep in curl unzip jq; do pkg_require "${_dep}"; done
    log_ok "依赖检查通过"
}

# 内核版本比较：_kernel_ge MAJOR MINOR
_kernel_ge() {
    local cur; cur=$(uname -r)
    local cm="${cur%%.*}" cr="${cur#*.}"; cr="${cr%%.*}"
    [ "${cm}" -gt "$1" ] || { [ "${cm}" -eq "$1" ] && [ "${cr}" -ge "$2" ]; }
}

# [FIX-09] BBR 检测：单分支 case 改为 if，逻辑更清晰
check_bbr() {
    local algo; algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')
    if [ "${algo}" = "bbr" ]; then
        log_ok "TCP 拥塞控制: BBR（已启用）"; return 0
    fi
    log_warn "当前 TCP 拥塞控制: ${algo}（推荐 BBR）"
    _kernel_ge 4 9 || { log_warn "内核 $(uname -r) < 4.9，不支持 BBR，跳过"; return 0; }
    is_systemd || return 0
    prompt "是否现在启用 BBR？(y/N): " _bbr_ans
    if [ "${_bbr_ans:-n}" = "y" ] || [ "${_bbr_ans:-n}" = "Y" ]; then
        modprobe tcp_bbr 2>/dev/null || true
        printf 'tcp_bbr\n' > /etc/modules-load.d/xray2go-bbr.conf
        cat > /etc/sysctl.d/88-xray2go-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        sysctl -p /etc/sysctl.d/88-xray2go-bbr.conf >/dev/null 2>&1
        log_ok "BBR 已启用（重启后仍生效）"
    fi
}

# Debian 12 专项：systemd-resolved stub listener 检测
check_systemd_resolved() {
    is_debian || return 0
    is_systemd || return 0
    systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0
    local stub; stub=$(grep -E '^DNSStubListener\s*=' /etc/systemd/resolved.conf 2>/dev/null \
                       | awk -F= '{print $2}' | tr -d ' ')
    [ "${stub:-yes}" != "no" ] && \
        log_info "检测到 systemd-resolved stub (127.0.0.53:53) — xray 使用 DoH，无冲突"
}

# CentOS/RHEL 时间同步修正
fix_time_sync() {
    [ -f /etc/redhat-release ] || [ -f /etc/centos-release ] || return 0
    local pm; command -v dnf >/dev/null 2>&1 && pm="dnf" || pm="yum"
    log_step "RHEL 系：修正时间同步与 CA 证书..."
    ${pm} install -y chrony >/dev/null 2>&1 || true
    systemctl enable --now chronyd >/dev/null 2>&1 || true
    chronyc -a makestep >/dev/null 2>&1 || true
    ${pm} update -y ca-certificates >/dev/null 2>&1 || true
    log_ok "时间同步已修正"
}

# ==============================================================================
# §6 ── 配置 I/O 层
# ==============================================================================
_gen_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
        awk '{h=$0; printf "%s-%s-4%s-%s%s-%s\n",
            substr(h,1,8), substr(h,9,4), substr(h,14,3),
            substr("89ab",int(rand()*4)+1,1), substr(h,18,3), substr(h,21,12)}'
    fi
}

_st_read()  { cat "$1" 2>/dev/null || true; }

# [FIX-11] _st_write 明确用 printf '%s\n' 单值写入，两行数据用 _st_write2
_st_write()  { mkdir -p "${WORK_DIR}"; printf '%s\n' "$2" > "$1"; }
_st_write2() { mkdir -p "${WORK_DIR}"; printf '%s\n%s\n' "$2" "$3" > "$1"; }

# [FIX-07] load_state 读 FF_CONF 改用单次 read，消除两次 sed fork
load_state() {
    [ -z "${UUID:-}" ] && UUID=$(_gen_uuid)
    local raw

    raw=$(_st_read "${ST_ARGO_MODE}")
    case "${raw}" in yes|no) ARGO_MODE="${raw}" ;; esac

    raw=$(_st_read "${ST_ARGO_PROTO}")
    case "${raw}" in ws|xhttp) ARGO_PROTOCOL="${raw}" ;; esac

    if [ -f "${ST_FF_CONF}" ]; then
        local _l1="" _l2=""
        # 单次 read 两行，不需要 fork sed
        { read -r _l1; read -r _l2; } < "${ST_FF_CONF}" 2>/dev/null || true
        case "${_l1}" in ws|httpupgrade|xhttp|none) FREEFLOW_MODE="${_l1}" ;; esac
        [ -n "${_l2:-}" ] && FF_PATH="${_l2}"
    fi

    if [ "${ARGO_MODE}" = "yes" ] && [ -f "${CONFIG_FILE}" ]; then
        raw=$(jq -r 'first(.inbounds[]? | select(.listen=="127.0.0.1") | .port) // empty' \
              "${CONFIG_FILE}" 2>/dev/null || true)
        case "${raw:-}" in ''|*[!0-9]*) : ;; *) ARGO_PORT="${raw}" ;; esac
    fi

    raw=$(_st_read "${ST_RESTART}")
    case "${raw:-}" in ''|*[!0-9]*) : ;; *) RESTART_INTERVAL="${raw}" ;; esac
}

# [FIX-11] _save_ff_conf 用 _st_write2 写两行，消除末尾多余换行问题
_save_ff_conf() {
    _st_write2 "${ST_FF_CONF}" "${FREEFLOW_MODE}" "${FF_PATH}"
}

get_uuid() {
    local id
    id=$(jq -r 'first(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) // empty' \
         "${CONFIG_FILE}" 2>/dev/null || true)
    printf '%s' "${id:-${UUID}}"
}

# [FIX-08] jq_edit 加 umask 保护临时文件权限
jq_edit() {
    local file="$1" filter="$2"; shift 2
    local tmp
    tmp=$(umask 077; mktemp "${file}.XXXXXX") || { log_error "无法创建临时文件"; return 1; }
    if jq "$@" "${filter}" "${file}" > "${tmp}" 2>/dev/null && [ -s "${tmp}" ]; then
        mv "${tmp}" "${file}"; return 0
    fi
    rm -f "${tmp}"; log_error "jq 操作失败: ${filter}"; return 1
}

# ==============================================================================
# §7 ── 网络工具层
# ==============================================================================
port_in_use() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null | awk -v p=":${p}" '$4~p"$"||$4~p" "{f=1}END{exit !f}'
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | awk -v p=":${p}" '$4~p"$"||$4~p" "{f=1}END{exit !f}'
        return
    fi
    local hex; hex=$(printf '%04X' "${p}")
    awk -v h="${hex}" 'NR>1 && substr($2,index($2,":")+1,4)==h {f=1} END{exit !f}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# [FIX-04] get_realip 并行探测 IPv4/IPv6，最坏耗时 5s（原 15s）
get_realip() {
    # 命中缓存则直接返回
    [ -n "${_realip_cache}" ] && { printf '%s' "${_realip_cache}"; return 0; }

    local _tmp4 _tmp6 _pid4 _pid6 ip="" org="" ipv6=""

    _tmp4=$(mktemp) && _tmp6=$(mktemp) || { printf ''; return 1; }

    # 并行：IPv4 + IPv6 同时发起
    curl -sf --max-time 5 https://api.ipify.org  > "${_tmp4}" 2>/dev/null & _pid4=$!
    curl -sf --max-time 5 https://api6.ipify.org > "${_tmp6}" 2>/dev/null & _pid6=$!
    wait "${_pid4}" 2>/dev/null; wait "${_pid6}" 2>/dev/null

    ip=$(cat "${_tmp4}" 2>/dev/null || true)
    ipv6=$(cat "${_tmp6}" 2>/dev/null || true)
    rm -f "${_tmp4}" "${_tmp6}"

    local result=""
    if [ -z "${ip:-}" ]; then
        [ -n "${ipv6:-}" ] && result="[${ipv6}]" || result=""
    else
        org=$(curl -sf --max-time 5 "https://ipinfo.io/${ip}/org" 2>/dev/null || true)
        if echo "${org:-}" | grep -qiE 'Cloudflare|UnReal|AEZA|Andrei'; then
            [ -n "${ipv6:-}" ] && result="[${ipv6}]" || result="${ip}"
        else
            result="${ip}"
        fi
    fi

    # [FIX-10] 写入缓存
    _realip_cache="${result}"
    printf '%s' "${result}"
}

# 指数退避轮询 Argo 日志，最多等待约 30s
get_temp_domain() {
    local domain delay=3 i=1
    sleep 3
    while [ "${i}" -le 6 ]; do
        domain=$(grep -o 'https://[^[:space:]]*trycloudflare\.com' \
                 "${ARGO_LOG}" 2>/dev/null | head -1 | sed 's|https://||') || true
        [ -n "${domain:-}" ] && printf '%s' "${domain}" && return 0
        sleep "${delay}"; i=$(( i + 1 ))
        delay=$(( delay < 8 ? delay * 2 : 8 ))
    done
    return 1
}

# ==============================================================================
# §8 ── JSON 构建层（协议插件接口）
# 命名约定：_inbound_<scope>_<protocol>(uuid)
# [FIX-03] uuid 由调用方传入，消除每个插件函数内的 get_uuid fork
# ==============================================================================
_sniffing_json() {
    printf '{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}'
}

_inbound_argo_ws() {
    local uuid="$1"
    jq -n --argjson port "${ARGO_PORT}" --arg uuid "${uuid}" \
          --argjson sniff "$(_sniffing_json)" '{
        port:$port, listen:"127.0.0.1", protocol:"vless",
        settings:{clients:[{id:$uuid}], decryption:"none"},
        streamSettings:{network:"ws", security:"none",
            wsSettings:{path:"/argo"}},
        sniffing:$sniff
    }'
}

_inbound_argo_xhttp() {
    local uuid="$1"
    jq -n --argjson port "${ARGO_PORT}" --arg uuid "${uuid}" \
          --argjson sniff "$(_sniffing_json)" '{
        port:$port, listen:"127.0.0.1", protocol:"vless",
        settings:{clients:[{id:$uuid}], decryption:"none"},
        streamSettings:{network:"xhttp", security:"none",
            xhttpSettings:{host:"", path:"/argo", mode:"auto"}},
        sniffing:$sniff
    }'
}

_inbound_ff_ws() {
    local uuid="$1"
    jq -n --arg uuid "${uuid}" --arg path "${FF_PATH}" \
          --argjson sniff "$(_sniffing_json)" '{
        port:80, listen:"::", protocol:"vless",
        settings:{clients:[{id:$uuid}], decryption:"none"},
        streamSettings:{network:"ws", security:"none",
            wsSettings:{path:$path}},
        sniffing:$sniff
    }'
}

_inbound_ff_httpupgrade() {
    local uuid="$1"
    jq -n --arg uuid "${uuid}" --arg path "${FF_PATH}" \
          --argjson sniff "$(_sniffing_json)" '{
        port:80, listen:"::", protocol:"vless",
        settings:{clients:[{id:$uuid}], decryption:"none"},
        streamSettings:{network:"httpupgrade", security:"none",
            httpupgradeSettings:{path:$path}},
        sniffing:$sniff
    }'
}

_inbound_ff_xhttp() {
    local uuid="$1"
    jq -n --arg uuid "${uuid}" --arg path "${FF_PATH}" \
          --argjson sniff "$(_sniffing_json)" '{
        port:80, listen:"::", protocol:"vless",
        settings:{clients:[{id:$uuid}], decryption:"none"},
        streamSettings:{network:"xhttp", security:"none",
            xhttpSettings:{host:"", path:$path, mode:"stream-one"}},
        sniffing:$sniff
    }'
}

# [FIX-03] 协议分发：uuid 参数向下传递，避免子函数重复 fork
_get_argo_inbound() {
    local uuid="$1"
    case "${ARGO_PROTOCOL}" in
        xhttp) _inbound_argo_xhttp "${uuid}" ;;
        *)     _inbound_argo_ws    "${uuid}" ;;
    esac
}

_get_ff_inbound() {
    local uuid="$1"
    case "${FREEFLOW_MODE}" in
        ws)          _inbound_ff_ws          "${uuid}" ;;
        httpupgrade) _inbound_ff_httpupgrade "${uuid}" ;;
        xhttp)       _inbound_ff_xhttp       "${uuid}" ;;
        *) return 1 ;;
    esac
}

# config.json 全量写入（[FIX-03] 顶层取一次 UUID）
write_xray_config() {
    mkdir -p "${WORK_DIR}"
    local uuid; uuid=$(get_uuid)
    local inbounds="[]" argo_ib ff_ib

    if [ "${ARGO_MODE}" = "yes" ]; then
        argo_ib=$(_get_argo_inbound "${uuid}") || return 1
        inbounds="[${argo_ib}]"
    fi

    if [ "${FREEFLOW_MODE}" != "none" ]; then
        ff_ib=$(_get_ff_inbound "${uuid}") || return 1
        if [ "${ARGO_MODE}" = "yes" ]; then
            inbounds=$(printf '%s' "${inbounds}" | jq --argjson ib "${ff_ib}" '. + [$ib]')
        else
            inbounds="[${ff_ib}]"
        fi
    fi

    jq -n --argjson inbounds "${inbounds}" '{
        log:{access:"/dev/null", error:"/dev/null", loglevel:"none"},
        inbounds:$inbounds,
        dns:{servers:["https+local://1.1.1.1/dns-query"]},
        outbounds:[
            {protocol:"freedom",   tag:"direct"},
            {protocol:"blackhole", tag:"block"}
        ]
    }' > "${CONFIG_FILE}" || { log_error "生成 config.json 失败"; return 1; }

    if [ -x "${XRAY_BIN}" ]; then
        "${XRAY_BIN}" -test -c "${CONFIG_FILE}" >/dev/null 2>&1 \
            || { log_error "config.json 验证失败"; return 1; }
    fi
    log_ok "config.json 已写入并通过验证"
}

# 原位替换 Argo inbound（[FIX-03] 传入已取得的 uuid）
apply_argo_inbound() {
    local uuid; uuid=$(get_uuid)
    local ib; ib=$(_get_argo_inbound "${uuid}") || return 1
    jq_edit "${CONFIG_FILE}" '
        if ([.inbounds[]? | select(.listen=="127.0.0.1")] | length) > 0
        then .inbounds = [.inbounds[] | if .listen=="127.0.0.1" then $ib else . end]
        else .inbounds = [$ib] + .inbounds
        end
    ' --argjson ib "${ib}"
}

# FreeFlow inbound 应用（[FIX-03] 传入已取得的 uuid）
apply_ff_inbound() {
    jq_edit "${CONFIG_FILE}" 'del(.inbounds[]? | select(.port == 80))' || return 1
    [ "${FREEFLOW_MODE}" = "none" ] && return 0
    local uuid; uuid=$(get_uuid)
    local ib; ib=$(_get_ff_inbound "${uuid}") || return 1
    jq_edit "${CONFIG_FILE}" '.inbounds += [$ib]' --argjson ib "${ib}"
}

# ==============================================================================
# §9 ── 链接构建层（协议插件接口）
# ==============================================================================
_urlencode_path() {
    printf '%s' "$1" | sed \
        's/%/%25/g;s/ /%20/g;s/!/%21/g;s/"/%22/g;s/#/%23/g;
         s/\$/%24/g;s/&/%26/g;s/'\''/%27/g;s/(/%28/g;s/)/%29/g;
         s/\*/%2A/g;s/+/%2B/g;s/,/%2C/g;s/:/%3A/g;s/;/%3B/g;
         s/=/%3D/g;s/?/%3F/g;s/@/%40/g;s/\[/%5B/g;s/\]/%5D/g'
}

_link_argo_ws() {
    local uuid="$1" domain="$2" cfip="${3:-cdns.doon.eu.org}" cfport="${4:-443}"
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=ws&host=%s&path=%%2Fargo%%3Fed%%3D2560#Argo-WS\n' \
        "${uuid}" "${cfip}" "${cfport}" "${domain}" "${domain}"
}

_link_argo_xhttp() {
    local uuid="$1" domain="$2" cfip="${3:-cdns.doon.eu.org}" cfport="${4:-443}"
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=xhttp&host=%s&path=%%2Fargo&mode=auto#Argo-XHTTP\n' \
        "${uuid}" "${cfip}" "${cfport}" "${domain}" "${domain}"
}

_link_ff() {
    local uuid="$1" ip="$2" path_enc
    path_enc=$(_urlencode_path "${FF_PATH}")
    case "${FREEFLOW_MODE}" in
        ws)
            printf 'vless://%s@%s:80?encryption=none&security=none&type=ws&host=%s&path=%s#FreeFlow-WS\n' \
                "${uuid}" "${ip}" "${ip}" "${path_enc}" ;;
        httpupgrade)
            printf 'vless://%s@%s:80?encryption=none&security=none&type=httpupgrade&host=%s&path=%s#FreeFlow-HTTPUpgrade\n' \
                "${uuid}" "${ip}" "${ip}" "${path_enc}" ;;
        xhttp)
            printf 'vless://%s@%s:80?encryption=none&security=none&type=xhttp&host=%s&path=%s&mode=stream-one#FreeFlow-XHTTP\n' \
                "${uuid}" "${ip}" "${ip}" "${path_enc}" ;;
    esac
}

# [FIX-10] build_all_links 利用 get_realip 缓存，重复调用零网络开销
build_all_links() {
    local argo_domain="${1:-}"
    local uuid; uuid=$(get_uuid)
    local ip; ip=$(get_realip)
    local cfip="${CFIP:-cdns.doon.eu.org}" cfport="${CFPORT:-443}"

    {
        if [ "${ARGO_MODE}" = "yes" ] && [ -n "${argo_domain:-}" ]; then
            case "${ARGO_PROTOCOL}" in
                xhttp) _link_argo_xhttp "${uuid}" "${argo_domain}" "${cfip}" "${cfport}" ;;
                *)     _link_argo_ws    "${uuid}" "${argo_domain}" "${cfip}" "${cfport}" ;;
            esac
        fi
        if [ "${FREEFLOW_MODE}" != "none" ] && [ -n "${ip:-}" ]; then
            _link_ff "${uuid}" "${ip}"
        fi
    } > "${CLIENT_FILE}"
}

print_nodes() {
    echo ""
    if [ ! -s "${CLIENT_FILE}" ]; then
        log_warn "节点文件为空，请先安装或重新获取节点信息"; return 1
    fi
    while IFS= read -r line; do
        [ -n "${line:-}" ] && printf "${_C_CYN}%s${_C_RST}\n" "${line}"
    done < "${CLIENT_FILE}"
    echo ""
}

# ==============================================================================
# §10 ── 服务管理层
# ==============================================================================

# [FIX-05] _write_service_file 改用 cmp -s 字节级比较，消除字符串处理陷阱
_write_service_file() {
    local dest="$1" content="$2"
    local tmp; tmp=$(mktemp) || return 1
    printf '%s' "${content}" > "${tmp}"
    if [ -f "${dest}" ] && cmp -s "${tmp}" "${dest}"; then
        rm -f "${tmp}"; return 0   # 内容无变化
    fi
    mv "${tmp}" "${dest}"
    return 1  # 内容已变更，调用方需 daemon-reload
}

_tpl_xray_systemd() {
    cat <<EOF
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

_tpl_tunnel_systemd() {
    local exec_cmd="$1"
    cat <<EOF
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

_tpl_xray_openrc() {
    cat <<EOF
#!/sbin/openrc-run
description="Xray service"
command="${XRAY_BIN}"
command_args="run -c ${CONFIG_FILE}"
command_background=true
pidfile="/var/run/xray.pid"
EOF
}

_tpl_tunnel_openrc() {
    local exec_cmd="$1"
    cat <<EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '${exec_cmd} >> ${ARGO_LOG} 2>&1'"
command_background=true
pidfile="/var/run/tunnel.pid"
EOF
}

_tunnel_cmd_temp() {
    printf '%s tunnel --url http://localhost:%s --no-autoupdate --edge-ip-version auto --protocol http2' \
        "${ARGO_BIN}" "${ARGO_PORT}"
}

register_xray_service() {
    if is_systemd; then
        _write_service_file "/etc/systemd/system/xray.service" "$(_tpl_xray_systemd)" \
            || _SYSTEMD_DIRTY=1
    else
        _write_service_file "/etc/init.d/xray" "$(_tpl_xray_openrc)" || chmod +x /etc/init.d/xray
    fi
}

register_tunnel_service() {
    local exec_cmd="${1:-$(_tunnel_cmd_temp)}"
    if is_systemd; then
        _write_service_file "/etc/systemd/system/tunnel.service" \
            "$(_tpl_tunnel_systemd "${exec_cmd}")" || _SYSTEMD_DIRTY=1
    else
        _write_service_file "/etc/init.d/tunnel" "$(_tpl_tunnel_openrc "${exec_cmd}")" \
            || chmod +x /etc/init.d/tunnel
    fi
}

_daemon_reload() {
    [ "${_SYSTEMD_DIRTY}" -eq 1 ] || return 0
    systemctl daemon-reload 2>/dev/null || true
    _SYSTEMD_DIRTY=0
}

svc_ctrl() {
    local act="$1" name="$2"
    if is_systemd; then
        case "${act}" in
            enable)  systemctl enable  "${name}" 2>/dev/null ;;
            disable) systemctl disable "${name}" 2>/dev/null ;;
            *)       systemctl "${act}" "${name}" 2>/dev/null ;;
        esac
    else
        case "${act}" in
            enable)  rc-update add "${name}" default 2>/dev/null ;;
            disable) rc-update del "${name}" default 2>/dev/null ;;
            *)       rc-service  "${name}" "${act}" 2>/dev/null  ;;
        esac
    fi
}

# [FIX-12] restart_* 加 is-active 二次确认，真正验证服务已 active
_svc_is_active() {
    local name="$1"
    if is_systemd; then
        [ "$(systemctl is-active "${name}" 2>/dev/null)" = "active" ]
    else
        rc-service "${name}" status 2>/dev/null | grep -q "started"
    fi
}

restart_xray() {
    log_step "重启 xray..."
    _daemon_reload
    svc_ctrl restart xray
    # 等待最多 5s 确认 active
    local i=0
    while [ "${i}" -lt 10 ]; do
        _svc_is_active xray && { log_ok "xray 已重启并运行"; return 0; }
        sleep 0.5; i=$(( i + 1 ))
    done
    log_error "xray 重启后未进入 active 状态"; return 1
}

restart_argo() {
    rm -f "${ARGO_LOG}"
    log_step "重启 Argo 隧道..."
    _daemon_reload
    svc_ctrl restart tunnel
    local i=0
    while [ "${i}" -lt 10 ]; do
        _svc_is_active tunnel && { log_ok "Argo 隧道已重启并运行"; return 0; }
        sleep 0.5; i=$(( i + 1 ))
    done
    log_error "tunnel 重启后未进入 active 状态"; return 1
}

# ==============================================================================
# §11 ── 下载层
# ==============================================================================
download_xray() {
    detect_arch
    [ -f "${XRAY_BIN}" ] && { log_info "xray 已存在，跳过下载"; return 0; }
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${_ARCH_XRAY}.zip"
    local zipfile="${WORK_DIR}/xray.zip"
    spinner_start "下载 Xray (${_ARCH_XRAY})"
    curl -sfL --connect-timeout 15 --max-time 120 -o "${zipfile}" "${url}"
    local rc=$?; spinner_stop
    [ "${rc}" -ne 0 ] && { rm -f "${zipfile}"; log_error "Xray 下载失败，请检查网络"; return 1; }
    unzip -t "${zipfile}" >/dev/null 2>&1 \
        || { rm -f "${zipfile}"; log_error "Xray zip 文件损坏"; return 1; }
    unzip -o "${zipfile}" xray -d "${WORK_DIR}/" >/dev/null 2>&1 \
        || { rm -f "${zipfile}"; log_error "Xray 解压失败"; return 1; }
    rm -f "${zipfile}"
    [ -f "${XRAY_BIN}" ] || { log_error "解压后未找到 xray 二进制"; return 1; }
    chmod +x "${XRAY_BIN}"
    log_ok "Xray 下载完成 ($(${XRAY_BIN} version 2>/dev/null | head -1 | awk '{print $2}'))"
}

download_cloudflared() {
    detect_arch
    [ -f "${ARGO_BIN}" ] && { log_info "cloudflared 已存在，跳过下载"; return 0; }
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${_ARCH_CF}"
    spinner_start "下载 cloudflared (${_ARCH_CF})"
    curl -sfL --connect-timeout 15 --max-time 120 -o "${ARGO_BIN}" "${url}"
    local rc=$?; spinner_stop
    [ "${rc}" -ne 0 ] && { rm -f "${ARGO_BIN}"; log_error "cloudflared 下载失败"; return 1; }
    [ -s "${ARGO_BIN}" ] || { rm -f "${ARGO_BIN}"; log_error "cloudflared 文件为空"; return 1; }
    chmod +x "${ARGO_BIN}"
    log_ok "cloudflared 下载完成"
}

# ==============================================================================
# §12 ── 安装/卸载核心
# ==============================================================================
install_core() {
    clear
    log_title "══════════ 安装 Xray-2go ══════════"
    check_deps
    mkdir -p "${WORK_DIR}" && chmod 750 "${WORK_DIR}"

    download_xray || return 1
    [ "${ARGO_MODE}" = "yes" ] && { download_cloudflared || return 1; }

    write_xray_config || return 1

    register_xray_service
    [ "${ARGO_MODE}" = "yes" ] && register_tunnel_service
    _daemon_reload

    if is_openrc; then
        printf '0 0\n' > /proc/sys/net/ipv4/ping_group_range 2>/dev/null || true
        sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts 2>/dev/null || true
        sed -i '2s/.*/::1         localhost/'  /etc/hosts 2>/dev/null || true
    fi

    fix_time_sync

    log_step "启动服务..."
    svc_ctrl enable xray
    svc_ctrl start  xray
    _svc_is_active xray || { log_error "xray 启动失败"; return 1; }
    log_ok "xray 已启动"

    if [ "${ARGO_MODE}" = "yes" ]; then
        svc_ctrl enable tunnel
        svc_ctrl start  tunnel
        _svc_is_active tunnel || { log_error "tunnel 启动失败"; return 1; }
        log_ok "tunnel 已启动"
    fi

    _st_write "${ST_ARGO_MODE}"  "${ARGO_MODE}"
    _st_write "${ST_ARGO_PROTO}" "${ARGO_PROTOCOL}"
    _save_ff_conf

    log_ok "══ 安装完成 ══"
}

uninstall_all() {
    prompt "确定要卸载 xray-2go？(y/N): " _c
    case "${_c:-n}" in y|Y) : ;; *) log_info "已取消"; return ;; esac
    log_step "卸载中..."
    remove_auto_restart

    for _svc in xray tunnel; do
        svc_ctrl stop    "${_svc}" 2>/dev/null || true
        svc_ctrl disable "${_svc}" 2>/dev/null || true
    done

    if is_systemd; then
        rm -f /etc/systemd/system/xray.service /etc/systemd/system/tunnel.service
        systemctl daemon-reload 2>/dev/null || true
    else
        rm -f /etc/init.d/xray /etc/init.d/tunnel
    fi

    rm -rf "${WORK_DIR}"
    rm -f  "${SHORTCUT}" "${SELF_DEST}" "${SELF_DEST}.bak"
    log_ok "Xray-2go 卸载完成"
}

# ==============================================================================
# §13 ── 隧道操作层
# ==============================================================================
configure_fixed_tunnel() {
    log_info "固定隧道 — 协议: ${ARGO_PROTOCOL}  回源端口: ${ARGO_PORT}"
    log_info "请确认 CF 后台 ingress 已指向 http://localhost:${ARGO_PORT}"
    echo ""

    local domain auth
    prompt "请输入 Argo 域名: " domain
    case "${domain:-}" in ''|*' '*|*'/'*|*$'\t'*)
        log_error "域名格式不合法"; return 1 ;; esac
    echo "${domain}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
        || { log_error "域名格式不合法"; return 1; }

    prompt "请输入 Argo 密钥 (token 或 JSON 内容): " auth
    [ -z "${auth:-}" ] && { log_error "密钥不能为空"; return 1; }

    local exec_cmd
    if echo "${auth}" | grep -q "TunnelSecret"; then
        echo "${auth}" | jq . >/dev/null 2>&1 || { log_error "JSON 凭证格式不合法"; return 1; }
        local tid
        tid=$(echo "${auth}" | jq -r '
            if (.TunnelID?  // "") != "" then .TunnelID
            elif (.AccountTag? // "") != "" then .AccountTag
            else empty end' 2>/dev/null)
        [ -z "${tid:-}" ] && { log_error "无法从 JSON 提取 TunnelID/AccountTag"; return 1; }
        case "${tid}" in *$'\n'*|*'"'*|*"'"*|*':'*)
            log_error "TunnelID 含非法字符，拒绝写入"; return 1 ;; esac

        printf '%s\n' "${auth}" > "${WORK_DIR}/tunnel.json"
        cat > "${WORK_DIR}/tunnel.yml" <<EOF
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
        exec_cmd="${ARGO_BIN} tunnel --edge-ip-version auto --config ${WORK_DIR}/tunnel.yml run"

    elif echo "${auth}" | grep -qE '^[A-Za-z0-9=_-]{120,250}$'; then
        exec_cmd="${ARGO_BIN} tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${auth}"
    else
        log_error "密钥格式无法识别（JSON 需含 TunnelSecret；Token 为 120-250 位字母数字串）"
        return 1
    fi

    register_tunnel_service "${exec_cmd}"
    _daemon_reload
    svc_ctrl enable tunnel 2>/dev/null || true

    apply_argo_inbound || { log_error "更新 xray inbound 失败"; return 1; }
    _st_write "${ST_DOMAIN_FIXED}" "${domain}"
    _st_write "${ST_ARGO_PROTO}"   "${ARGO_PROTOCOL}"

    restart_xray || return 1
    restart_argo  || return 1
    log_ok "固定隧道 (${ARGO_PROTOCOL}, path=/argo) 已配置，域名: ${domain}"
}

reset_temp_tunnel() {
    register_tunnel_service "$(_tunnel_cmd_temp)"
    _daemon_reload
    rm -f "${ST_DOMAIN_FIXED}"
    ARGO_PROTOCOL="ws"
    _st_write "${ST_ARGO_PROTO}" "ws"
    apply_argo_inbound || log_error "更新 xray inbound 失败"
}

refresh_temp_domain() {
    [ "${ARGO_MODE}" = "yes" ]    || { log_warn "未启用 Argo"; return 1; }
    [ "${ARGO_PROTOCOL}" = "ws" ] || { log_error "XHTTP 不支持临时隧道，请先切换协议"; return 1; }
    [ -s "${CLIENT_FILE}" ]       || { log_warn "节点文件为空，请先安装"; return 1; }

    log_step "重启隧道并等待新域名..."
    restart_argo || return 1

    local domain
    domain=$(get_temp_domain) || { log_warn "未能获取临时域名，请检查网络"; return 1; }
    log_ok "ArgoDomain: ${domain}"

    awk -v d="${domain}" '
        /#Argo-WS$/ { sub(/sni=[^&]*/, "sni="d); sub(/host=[^&]*/, "host="d) }
        { print }
    ' "${CLIENT_FILE}" > "${CLIENT_FILE}.tmp" && mv "${CLIENT_FILE}.tmp" "${CLIENT_FILE}"

    print_nodes
    log_ok "节点已更新"
}

# ==============================================================================
# §14 ── Cron 自动重启
# ==============================================================================
_cron_available() {
    command -v crontab >/dev/null 2>&1 || return 1
    if is_openrc; then
        rc-service dcron status >/dev/null 2>&1 || rc-service crond status >/dev/null 2>&1
    else
        systemctl is-active --quiet cron  2>/dev/null || \
        systemctl is-active --quiet crond 2>/dev/null
    fi
}

ensure_cron() {
    _cron_available && return 0
    log_warn "cron 未运行"
    prompt "是否安装 cron？(Y/n): " _cron_ans
    case "${_cron_ans:-y}" in n|N) log_error "cron 不可用，自动重启无法配置"; return 1 ;; esac
    if   command -v apt-get >/dev/null 2>&1; then
        pkg_require cron crontab; systemctl enable --now cron 2>/dev/null || true
    elif command -v dnf     >/dev/null 2>&1; then
        pkg_require cronie crontab; systemctl enable --now crond 2>/dev/null || true
    elif command -v yum     >/dev/null 2>&1; then
        pkg_require cronie crontab; systemctl enable --now crond 2>/dev/null || true
    elif command -v apk     >/dev/null 2>&1; then
        pkg_require dcron crontab
        rc-service dcron start 2>/dev/null || true
        rc-update add dcron default 2>/dev/null || true
    else
        die "无法安装 cron，请手动安装"
    fi
}

setup_auto_restart() {
    ensure_cron || return 1
    local cmd; is_openrc && cmd="rc-service xray restart" || cmd="systemctl restart xray"
    local tmp; tmp=$(mktemp) || { log_error "无法创建临时文件"; return 1; }
    { crontab -l 2>/dev/null | grep -v '#xray-restart'
      printf '*/%s * * * * %s >/dev/null 2>&1 #xray-restart\n' \
          "${RESTART_INTERVAL}" "${cmd}"
    } > "${tmp}"
    crontab "${tmp}" || { rm -f "${tmp}"; log_error "crontab 写入失败"; return 1; }
    rm -f "${tmp}"
    log_ok "已设置每 ${RESTART_INTERVAL} 分钟自动重启 xray"
}

remove_auto_restart() {
    command -v crontab >/dev/null 2>&1 || return 0
    local tmp; tmp=$(mktemp) || return 0
    crontab -l 2>/dev/null | grep -v '#xray-restart' > "${tmp}" || true
    crontab "${tmp}" 2>/dev/null || true
    rm -f "${tmp}"
}

# ==============================================================================
# §15 ── 快捷方式 / 脚本更新
# ==============================================================================
install_shortcut() {
    log_step "拉取最新脚本..."
    local tmp="${SELF_DEST}.tmp"
    curl -sfL --connect-timeout 15 --max-time 60 -o "${tmp}" "${UPSTREAM_URL}" \
        || { rm -f "${tmp}"; log_error "拉取失败，请检查网络"; return 1; }
    bash -n "${tmp}" 2>/dev/null \
        || { rm -f "${tmp}"; log_error "脚本语法验证失败，已中止"; return 1; }
    [ -f "${SELF_DEST}" ] && cp -f "${SELF_DEST}" "${SELF_DEST}.bak" 2>/dev/null || true
    mv "${tmp}" "${SELF_DEST}" && chmod +x "${SELF_DEST}"
    printf '#!/bin/bash\nexec %s "$@"\n' "${SELF_DEST}" > "${SHORTCUT}"
    chmod +x "${SHORTCUT}"
    log_ok "脚本已更新！输入 ${_C_GRN}s${_C_RST} 快速启动"
}

# ==============================================================================
# §16 ── 状态检测层
# ==============================================================================
check_xray() {
    [ -f "${XRAY_BIN}" ] || { printf 'not installed'; return 2; }
    _svc_is_active xray && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
}

check_argo() {
    [ "${ARGO_MODE}" = "no" ] && { printf 'disabled';      return 3; }
    [ -f "${ARGO_BIN}" ]      || { printf 'not installed'; return 2; }
    _svc_is_active tunnel && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
}

is_fixed_tunnel() {
    local svc_file
    is_systemd && svc_file="/etc/systemd/system/tunnel.service" \
               || svc_file="/etc/init.d/tunnel"
    [ -f "${svc_file}" ] || return 1
    ! grep -Fq -- "--url http://localhost:${ARGO_PORT}" "${svc_file}" 2>/dev/null
}

# ==============================================================================
# §17 ── 交互询问函数
# ==============================================================================
ask_argo_mode() {
    echo ""; log_title "Argo 隧道选项"
    printf "  ${_C_GRN}1.${_C_RST} 安装 Argo（VLESS+WS/XHTTP+TLS）${_C_YLW}[默认]${_C_RST}\n"
    printf "  ${_C_GRN}2.${_C_RST} 不安装 Argo（仅 FreeFlow 节点）\n"
    prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2) ARGO_MODE="no";  log_info "已选：不安装 Argo" ;;
        *) ARGO_MODE="yes"; log_info "已选：安装 Argo"   ;;
    esac
    mkdir -p "${WORK_DIR}"; _st_write "${ST_ARGO_MODE}" "${ARGO_MODE}"; echo ""
}

ask_argo_protocol() {
    echo ""; log_title "Argo 传输协议"
    printf "  ${_C_GRN}1.${_C_RST} WS（临时+固定均支持）${_C_YLW}[默认]${_C_RST}\n"
    printf "  ${_C_GRN}2.${_C_RST} XHTTP（auto 模式，仅固定隧道）\n"
    prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2) ARGO_PROTOCOL="xhttp"; log_warn "XHTTP 不支持临时隧道！安装后将进入固定隧道配置。" ;;
        *) ARGO_PROTOCOL="ws"    ;;
    esac
    mkdir -p "${WORK_DIR}"; _st_write "${ST_ARGO_PROTO}" "${ARGO_PROTOCOL}"
    log_info "已选协议: ${ARGO_PROTOCOL}"; echo ""
}

ask_freeflow_mode() {
    echo ""; log_title "FreeFlow（明文 port 80）"
    printf "  ${_C_GRN}1.${_C_RST} VLESS + WS\n"
    printf "  ${_C_GRN}2.${_C_RST} VLESS + HTTPUpgrade\n"
    printf "  ${_C_GRN}3.${_C_RST} VLESS + XHTTP (stream-one)\n"
    printf "  ${_C_GRN}4.${_C_RST} 不启用 FreeFlow ${_C_YLW}[默认]${_C_RST}\n"
    prompt "请选择 (1-4，回车默认4): " _c
    case "${_c:-4}" in
        1) FREEFLOW_MODE="ws"          ;;
        2) FREEFLOW_MODE="httpupgrade" ;;
        3) FREEFLOW_MODE="xhttp"       ;;
        *) FREEFLOW_MODE="none"        ;;
    esac

    if [ "${FREEFLOW_MODE}" != "none" ]; then
        port_in_use 80 && log_warn "端口 80 已被占用，FreeFlow 可能无法启动"
        prompt "FreeFlow path（回车默认 /）: " _p
        case "${_p:-/}" in
            /*) FF_PATH="${_p:-/}" ;;
             *) FF_PATH="/${_p}"   ;;
        esac
        log_info "已选: ${FREEFLOW_MODE}（path=${FF_PATH}）"
    else
        FF_PATH="/"; log_info "不启用 FreeFlow"
    fi
    mkdir -p "${WORK_DIR}"; _save_ff_conf; echo ""
}

# ==============================================================================
# §18 ── 管理子菜单
# ==============================================================================
manage_argo() {
    [ "${ARGO_MODE}" = "yes" ] || { log_warn "未启用 Argo"; sleep 1; return; }
    [ -f "${ARGO_BIN}" ]       || { log_warn "Argo 未安装"; sleep 1; return; }

    while true; do
        local fixed_domain type_disp astat
        fixed_domain=$(_st_read "${ST_DOMAIN_FIXED}")
        astat=$(check_argo)
        is_fixed_tunnel && [ -n "${fixed_domain:-}" ] \
            && type_disp="固定 (${ARGO_PROTOCOL}, ${fixed_domain})" \
            || type_disp="临时 (WS)"

        clear; echo ""; log_title "══ Argo 隧道管理 ══"
        printf "  状态: ${_C_GRN}%s${_C_RST}  协议: ${_C_CYN}%s${_C_RST}  端口: ${_C_YLW}%s${_C_RST}\n" \
            "${astat}" "${ARGO_PROTOCOL}" "${ARGO_PORT}"
        printf "  类型: %s\n" "${type_disp}"
        _hr
        printf "  ${_C_GRN}1.${_C_RST} 添加/更新固定隧道\n"
        printf "  ${_C_GRN}2.${_C_RST} 切换协议 (WS ↔ XHTTP，仅固定隧道)\n"
        printf "  ${_C_GRN}3.${_C_RST} 切换回临时隧道 (WS)\n"
        printf "  ${_C_GRN}4.${_C_RST} 刷新临时域名\n"
        printf "  ${_C_GRN}5.${_C_RST} 修改回源端口（当前: ${_C_YLW}${ARGO_PORT}${_C_RST}）\n"
        printf "  ${_C_GRN}6.${_C_RST} 启动隧道\n"
        printf "  ${_C_GRN}7.${_C_RST} 停止隧道\n"
        printf "  ${_C_PUR}0.${_C_RST} 返回主菜单\n"
        _hr
        prompt "请输入选择: " _c

        case "${_c:-}" in
            1)
                echo ""
                printf "  ${_C_GRN}1.${_C_RST} WS ${_C_YLW}[默认]${_C_RST}\n"
                printf "  ${_C_GRN}2.${_C_RST} XHTTP (auto)\n"
                prompt "协议 (1-2，回车维持当前 ${ARGO_PROTOCOL}): " _p
                case "${_p:-}" in 2) ARGO_PROTOCOL="xhttp" ;; 1) ARGO_PROTOCOL="ws" ;; esac
                _st_write "${ST_ARGO_PROTO}" "${ARGO_PROTOCOL}"
                if configure_fixed_tunnel; then
                    fixed_domain=$(_st_read "${ST_DOMAIN_FIXED}")
                    build_all_links "${fixed_domain}"; print_nodes
                else
                    log_error "固定隧道配置失败"
                fi
                ;;
            2)
                is_fixed_tunnel || { log_warn "当前为临时隧道，请先配置固定隧道"; _pause; continue; }
                [ "${ARGO_PROTOCOL}" = "ws" ] && ARGO_PROTOCOL="xhttp" || ARGO_PROTOCOL="ws"
                _st_write "${ST_ARGO_PROTO}" "${ARGO_PROTOCOL}"
                apply_argo_inbound && restart_xray && log_ok "协议已切换: ${ARGO_PROTOCOL}"
                fixed_domain=$(_st_read "${ST_DOMAIN_FIXED}")
                build_all_links "${fixed_domain:-}"; print_nodes
                ;;
            3)
                [ "${ARGO_PROTOCOL}" = "xhttp" ] && \
                    { log_error "请先切换协议为 WS 再切回临时隧道"; _pause; continue; }
                reset_temp_tunnel && restart_xray && refresh_temp_domain
                ;;
            4) refresh_temp_domain ;;
            5)
                prompt "请输入新端口（回车随机）: " _p
                [ -z "${_p:-}" ] && \
                    _p=$(shuf -i 2000-65000 -n 1 2>/dev/null || \
                         awk 'BEGIN{srand();print int(rand()*63000)+2000}')
                case "${_p:-}" in ''|*[!0-9]*) log_error "无效端口"; _pause; continue ;; esac
                { [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]; } \
                    || { log_error "端口须在 1-65535 之间"; _pause; continue; }
                if port_in_use "${_p}"; then
                    log_warn "端口 ${_p} 已被占用"
                    prompt "仍然继续？(y/N): " _ans
                    case "${_ans:-n}" in y|Y) : ;; *) _pause; continue ;; esac
                fi
                jq_edit "${CONFIG_FILE}" \
                    '(.inbounds[]? | select(.port == $oldp) | .port) |= $newp' \
                    --argjson oldp "${ARGO_PORT}" --argjson newp "${_p}" \
                    || { log_error "端口修改失败"; _pause; continue; }
                if is_systemd; then
                    sed -i "s|localhost:${ARGO_PORT}|localhost:${_p}|g" \
                        /etc/systemd/system/tunnel.service 2>/dev/null
                    _SYSTEMD_DIRTY=1
                else
                    sed -i "s|localhost:${ARGO_PORT}|localhost:${_p}|g" \
                        /etc/init.d/tunnel 2>/dev/null
                fi
                ARGO_PORT="${_p}"
                _st_write "${ST_ARGO_PORT}" "${_p}"
                restart_xray && restart_argo
                log_ok "回源端口已修改: ${_p}"
                ;;
            6) svc_ctrl start  tunnel && log_ok "隧道已启动" ;;
            7) svc_ctrl stop   tunnel && log_ok "隧道已停止" ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

manage_freeflow() {
    while true; do
        clear; echo ""; log_title "══ FreeFlow 管理 ══"
        if [ "${FREEFLOW_MODE}" = "none" ]; then
            printf "  当前状态: ${_C_YLW}未启用${_C_RST}\n"
        else
            printf "  当前状态: ${_C_GRN}%s${_C_RST}  path: ${_C_CYN}%s${_C_RST}\n" \
                "${FREEFLOW_MODE}" "${FF_PATH}"
        fi
        _hr
        printf "  ${_C_GRN}1.${_C_RST} 添加/变更方式\n"
        printf "  ${_C_GRN}2.${_C_RST} 修改 path\n"
        printf "  ${_C_RED}3.${_C_RST} 卸载 FreeFlow\n"
        printf "  ${_C_PUR}0.${_C_RST} 返回主菜单\n"
        _hr
        prompt "请输入选择: " _c

        case "${_c:-}" in
            1)
                ask_freeflow_mode
                apply_ff_inbound || { log_error "FreeFlow 配置更新失败"; _pause; continue; }
                local ip_now; ip_now=$(get_realip)
                {
                    grep '#Argo' "${CLIENT_FILE}" 2>/dev/null || true
                    [ "${FREEFLOW_MODE}" != "none" ] && [ -n "${ip_now:-}" ] && \
                        _link_ff "$(get_uuid)" "${ip_now}"
                } > "${CLIENT_FILE}.new" && mv "${CLIENT_FILE}.new" "${CLIENT_FILE}"
                restart_xray; log_ok "FreeFlow 已变更"; print_nodes
                ;;
            2)
                prompt "新 path（回车保持 ${FF_PATH}）: " _p
                if [ -n "${_p:-}" ]; then
                    case "${_p}" in /*) FF_PATH="${_p}" ;; *) FF_PATH="/${_p}" ;; esac
                    _save_ff_conf
                    apply_ff_inbound || { log_error "更新失败"; _pause; continue; }
                    local ip_now; ip_now=$(get_realip)
                    if [ -n "${ip_now:-}" ]; then
                        local new_link; new_link=$(_link_ff "$(get_uuid)" "${ip_now}")
                        awk -v nl="${new_link}" \
                            '/#FreeFlow/{print nl; next} {print}' \
                            "${CLIENT_FILE}" > "${CLIENT_FILE}.tmp" \
                            && mv "${CLIENT_FILE}.tmp" "${CLIENT_FILE}"
                    fi
                    restart_xray; log_ok "path 已修改: ${FF_PATH}"; print_nodes
                fi
                ;;
            3)
                FREEFLOW_MODE="none"; _save_ff_conf
                apply_ff_inbound || { log_error "卸载失败"; _pause; continue; }
                grep -v '#FreeFlow' "${CLIENT_FILE}" 2>/dev/null > "${CLIENT_FILE}.tmp" \
                    && mv "${CLIENT_FILE}.tmp" "${CLIENT_FILE}"
                restart_xray; log_ok "FreeFlow 已卸载"
                ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

manage_restart() {
    while true; do
        clear; echo ""; log_title "══ 自动重启管理 ══"
        printf "  当前间隔: ${_C_CYN}%s 分钟${_C_RST}（0 = 关闭）\n" "${RESTART_INTERVAL}"
        _hr
        printf "  ${_C_GRN}1.${_C_RST} 设置间隔\n"
        printf "  ${_C_PUR}0.${_C_RST} 返回主菜单\n"
        _hr
        prompt "请输入选择: " _c
        case "${_c:-}" in
            1)
                prompt "间隔分钟（0=关闭，推荐 60）: " _v
                case "${_v:-}" in ''|*[!0-9]*) log_error "无效输入"; _pause; continue ;; esac
                RESTART_INTERVAL="${_v}"
                mkdir -p "${WORK_DIR}"; _st_write "${ST_RESTART}" "${RESTART_INTERVAL}"
                if [ "${RESTART_INTERVAL}" -eq 0 ]; then
                    remove_auto_restart; log_ok "自动重启已关闭"
                else
                    setup_auto_restart
                fi
                ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ==============================================================================
# §19 ── 主菜单
# [FIX-06] 临时域名获取提取为 _fetch_temp_domain_flow()，消除 local-in-case 歧义
# ==============================================================================

# 安装后临时隧道域名获取流程（返回域名字符串到 stdout）
_fetch_temp_domain_flow() {
    log_step "等待 Argo 临时域名..."
    restart_argo 2>/dev/null || true
    local _td
    _td=$(get_temp_domain 2>/dev/null) || _td=""
    if [ -z "${_td}" ]; then
        log_warn "未能获取临时域名，可从 [3. Argo 管理] 刷新"
        _td="<未获取>"
    else
        log_ok "ArgoDomain: ${_td}"
    fi
    printf '%s' "${_td}"
}

menu() {
    while true; do
        local xstat astat cx fixed_domain ff_disp argo_disp xcolor
        xstat=$(check_xray); cx=$?
        astat=$(check_argo)
        fixed_domain=$(_st_read "${ST_DOMAIN_FIXED}")

        [ "${cx}" -eq 0 ] && xcolor="${_C_GRN}" || xcolor="${_C_RED}"

        case "${FREEFLOW_MODE}" in
            ws)          ff_disp="WS (path=${FF_PATH})"          ;;
            httpupgrade) ff_disp="HTTPUpgrade (path=${FF_PATH})" ;;
            xhttp)       ff_disp="XHTTP (path=${FF_PATH})"       ;;
            *)           ff_disp="未启用"                         ;;
        esac

        if [ "${ARGO_MODE}" = "yes" ]; then
            [ -n "${fixed_domain:-}" ] \
                && argo_disp="${astat} [${ARGO_PROTOCOL}, 固定: ${fixed_domain}]" \
                || argo_disp="${astat} [WS, 临时隧道]"
        else
            argo_disp="未启用"
        fi

        clear; echo ""
        printf "${_C_BOLD}${_C_PUR}  ╔══════════════════════════════╗${_C_RST}\n"
        printf "${_C_BOLD}${_C_PUR}  ║      Xray-2go  v2.1          ║${_C_RST}\n"
        printf "${_C_BOLD}${_C_PUR}  ╠══════════════════════════════╣${_C_RST}\n"
        printf "${_C_BOLD}${_C_PUR}  ║${_C_RST}  Xray:     ${xcolor}%-20s${_C_RST}${_C_PUR}║${_C_RST}\n"  "${xstat}"
        printf "${_C_BOLD}${_C_PUR}  ║${_C_RST}  Argo:     %-20s${_C_PUR}║${_C_RST}\n"  "${argo_disp}"
        printf "${_C_BOLD}${_C_PUR}  ║${_C_RST}  FF:       %-20s${_C_PUR}║${_C_RST}\n"  "${ff_disp}"
        printf "${_C_BOLD}${_C_PUR}  ║${_C_RST}  重启间隔: ${_C_CYN}%-2s min${_C_RST}               ${_C_PUR}║${_C_RST}\n" "${RESTART_INTERVAL}"
        printf "${_C_BOLD}${_C_PUR}  ╚══════════════════════════════╝${_C_RST}\n"
        echo ""
        printf "  ${_C_GRN}1.${_C_RST} 安装 Xray-2go\n"
        printf "  ${_C_RED}2.${_C_RST} 卸载 Xray-2go\n"
        _hr
        printf "  ${_C_GRN}3.${_C_RST} Argo 管理\n"
        printf "  ${_C_GRN}4.${_C_RST} FreeFlow 管理\n"
        _hr
        printf "  ${_C_GRN}5.${_C_RST} 查看节点\n"
        printf "  ${_C_GRN}6.${_C_RST} 修改 UUID\n"
        printf "  ${_C_GRN}7.${_C_RST} 自动重启管理\n"
        printf "  ${_C_GRN}8.${_C_RST} 快捷方式/脚本更新\n"
        _hr
        printf "  ${_C_RED}0.${_C_RST} 退出\n"
        echo ""
        prompt "请输入选择 (0-8): " _c
        echo ""

        case "${_c:-}" in
            1)
                if [ "${cx}" -eq 0 ]; then
                    log_warn "Xray-2go 已安装，如需重装请先卸载 (选项 2)"
                else
                    ask_argo_mode
                    [ "${ARGO_MODE}" = "yes" ] && ask_argo_protocol
                    ask_freeflow_mode

                    [ "${ARGO_MODE}" = "yes" ] && port_in_use "${ARGO_PORT}" && \
                        log_warn "端口 ${ARGO_PORT} 已被占用，可安装后通过 Argo 管理修改"
                    [ "${FREEFLOW_MODE}" != "none" ] && port_in_use 80 && \
                        log_warn "端口 80 已被占用，FreeFlow 可能无法启动"

                    check_systemd_resolved
                    check_bbr

                    install_core || { log_error "安装失败，请查看以上错误信息"; _pause; continue; }

                    # [FIX-06] 用函数封装临时域名获取，local 在函数作用域内声明
                    local _argo_domain=""
                    if [ "${ARGO_MODE}" = "yes" ] && [ "${ARGO_PROTOCOL}" = "xhttp" ]; then
                        echo ""; log_warn "XHTTP 仅支持固定隧道，现在进入配置..."
                        configure_fixed_tunnel && \
                            _argo_domain=$(_st_read "${ST_DOMAIN_FIXED}") || \
                            log_error "固定隧道配置失败，请从 [3. Argo 管理] 重新配置"

                    elif [ "${ARGO_MODE}" = "yes" ]; then
                        echo ""
                        printf "  ${_C_GRN}1.${_C_RST} 临时隧道（WS，自动生成域名）${_C_YLW}[默认]${_C_RST}\n"
                        printf "  ${_C_GRN}2.${_C_RST} 固定隧道（使用自有 token/json）\n"
                        prompt "请选择隧道类型 (1-2，回车默认1): " _tc
                        case "${_tc:-1}" in
                            2)
                                if configure_fixed_tunnel; then
                                    _argo_domain=$(_st_read "${ST_DOMAIN_FIXED}")
                                else
                                    log_warn "固定隧道配置失败，回退临时隧道"
                                    _argo_domain=$(_fetch_temp_domain_flow)
                                fi
                                ;;
                            *)
                                _argo_domain=$(_fetch_temp_domain_flow)
                                ;;
                        esac
                    fi

                    build_all_links "${_argo_domain:-}"
                    print_nodes
                fi
                ;;
            2) uninstall_all ;;
            3) manage_argo ;;
            4) manage_freeflow ;;
            5)
                [ "${cx}" -eq 0 ] && print_nodes || log_warn "Xray-2go 未安装或未运行"
                ;;
            6)
                [ -f "${CONFIG_FILE}" ] || { log_warn "请先安装 Xray-2go"; _pause; continue; }
                prompt "新 UUID（回车自动生成）: " _v
                if [ -z "${_v:-}" ]; then
                    _v=$(_gen_uuid) || { log_error "无法生成 UUID"; _pause; continue; }
                    log_info "生成 UUID: ${_v}"
                fi
                echo "${_v}" | grep -qiE \
                    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
                    || { log_error "UUID 格式不合法"; _pause; continue; }
                jq_edit "${CONFIG_FILE}" \
                    '(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) = $u' \
                    --arg u "${_v}" || { log_error "UUID 更新失败"; _pause; continue; }
                UUID="${_v}"
                [ -s "${CLIENT_FILE}" ] && \
                    awk -v u="${_v}" \
                        '{gsub(/vless:\/\/[^@]*@/, "vless://"u"@"); print}' \
                        "${CLIENT_FILE}" > "${CLIENT_FILE}.tmp" \
                        && mv "${CLIENT_FILE}.tmp" "${CLIENT_FILE}"
                restart_xray && log_ok "UUID 已修改: ${_v}"
                print_nodes
                ;;
            7) manage_restart ;;
            8) install_shortcut ;;
            0) log_info "已退出"; exit 0 ;;
            *) log_error "无效选项，请输入 0-8" ;;
        esac
        _pause
    done
}

# ==============================================================================
# §20 ── 入口点 main()
# ==============================================================================
main() {
    check_root
    _detect_init
    load_state
    menu
}

main "$@"
