#!/usr/bin/env bash
# ==============================================================================
# xray-2go v7.1
# 协议支持：Argo 固定隧道(WS/XHTTP) · FreeFlow(WS/HTTPUpgrade/XHTTP)
#           Reality(TCP/XHTTP) · VLESS-TCP 明文落地
# 平台支持：Debian/Ubuntu (systemd) · Alpine (OpenRC)
# 架构分层：core → state → protocol → config → runtime → cli
#
# v7.1 变更（相对 v7.0）：
#   [安全] download_xray 添加 SHA256 校验（从 GitHub releases 获取）
#   [安全] _gen_reality_sid 改为 head+xxd 方式，避免 od 格式差异
#   [稳定] systemd unit 添加 Restart=always / RestartSec=3 / LimitNOFILE=1048576
#   [稳定] tunnel systemd unit 添加 Restart=always / RestartSec=5
#   [稳定] Argo tunnel 协议由 http2 改为 quic（Cloudflare 官方推荐）
#   [运维] state_persist / apply_config 写前自动备份（带时间戳）
#   [运维] loglevel "none" → "warning"，便于排障
#   [部署] 新增 open_firewall_port()，自动处理 ufw/firewalld/iptables
#   [部署] exec_install_core 安装后调用防火墙开放 + Argo 健康检查
# ==============================================================================
set -uo pipefail
[ "${BASH_VERSINFO[0]}" -ge 4 ] \
    || { printf '\033[1;91m[ERR ] 需要 bash 4.0 或更高版本\033[0m\n' >&2; exit 1; }

# ==============================================================================
# §1  全局常量
# ==============================================================================
readonly WORK_DIR="/etc/xray"
readonly XRAY_BIN="${WORK_DIR}/xray"
readonly ARGO_BIN="${WORK_DIR}/argo"
readonly CONFIG_FILE="${WORK_DIR}/config.json"
readonly STATE_FILE="${WORK_DIR}/state.json"
readonly ARGO_LOG="${WORK_DIR}/argo.log"
readonly SHORTCUT="/usr/local/bin/s"
readonly SELF_DEST="/usr/local/bin/xray2go"
readonly UPSTREAM_URL="https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh"
readonly _STATE_SCHEMA_VERSION=2

# ==============================================================================
# §2  临时文件沙箱
# ==============================================================================
_TMP_DIR=""
_SPINNER_PID=0

trap '_cleanup_exit' EXIT
trap '_cleanup_int'  INT TERM

_cleanup_exit() {
    [ "${_SPINNER_PID}" -ne 0 ] && kill "${_SPINNER_PID}" 2>/dev/null || true
    [ -n "${_TMP_DIR:-}" ]      && rm -rf "${_TMP_DIR}"   2>/dev/null || true
    tput cnorm 2>/dev/null || true
}

_cleanup_int() {
    printf '\n' >&2
    printf '\033[1;91m[ERR ] 已中断\033[0m\n' >&2
    exit 130
}

_tmp_file() {
    if [ -z "${_TMP_DIR:-}" ]; then
        _TMP_DIR=$(mktemp -d /tmp/xray2go_XXXXXX) \
            || { printf '\033[1;91m[ERR ] 无法创建临时目录\033[0m\n' >&2; exit 1; }
    fi
    mktemp "${_TMP_DIR}/${1:-tmp_XXXXXX}"
}

# ==============================================================================
# §3  CORE — UI
# ==============================================================================
readonly C_RST=$'\033[0m'  C_BOLD=$'\033[1m'
readonly C_RED=$'\033[1;91m'  C_GRN=$'\033[1;32m'  C_YLW=$'\033[1;33m'
readonly C_PUR=$'\033[1;35m'  C_CYN=$'\033[1;36m'

log_info()  { printf "${C_CYN}[INFO]${C_RST} %s\n"     "$*"; }
log_ok()    { printf "${C_GRN}[ OK ]${C_RST} %s\n"     "$*"; }
log_warn()  { printf "${C_YLW}[WARN]${C_RST} %s\n"     "$*" >&2; }
log_error() { printf "${C_RED}[ERR ]${C_RST} %s\n"     "$*" >&2; }
log_step()  { printf "${C_PUR}[....] %s${C_RST}\n"     "$*"; }
log_title() { printf "\n${C_BOLD}${C_PUR}%s${C_RST}\n" "$*"; }
die()       { log_error "$1"; exit "${2:-1}"; }

prompt() {
    printf "${C_RED}%s${C_RST}" "$1" >&2
    read -r "$2" </dev/tty
}

_pause() {
    local _d
    printf "${C_RED}按回车键继续...${C_RST}" >&2
    read -r _d </dev/tty || true
}

_hr() { printf "${C_PUR}  ──────────────────────────────────${C_RST}\n"; }

spinner_start() {
    printf "${C_CYN}[....] %s${C_RST}\n" "$1"
    ( local i=0 c='-\|/'
      while true; do
          printf "\r${C_CYN}[ %s  ]${C_RST} %s  " "${c:$(( i % 4 )):1}" "$1" >&2
          sleep 0.12; i=$(( i + 1 ))
      done ) &
    _SPINNER_PID=$!
    disown "${_SPINNER_PID}" 2>/dev/null || true
}

spinner_stop() {
    [ "${_SPINNER_PID}" -ne 0 ] && { kill "${_SPINNER_PID}" 2>/dev/null; _SPINNER_PID=0; }
    printf '\r\033[2K' >&2
}

# ==============================================================================
# §4  CORE — 平台检测
# ==============================================================================
_INIT_SYS=""
_ARCH_CF=""
_ARCH_XRAY=""

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

detect_arch() {
    [ -n "${_ARCH_XRAY:-}" ] && return 0
    case "$(uname -m)" in
        x86_64)        _ARCH_CF="amd64";  _ARCH_XRAY="64"        ;;
        x86|i686|i386) _ARCH_CF="386";    _ARCH_XRAY="32"        ;;
        aarch64|arm64) _ARCH_CF="arm64";  _ARCH_XRAY="arm64-v8a" ;;
        armv7l)        _ARCH_CF="armv7";  _ARCH_XRAY="arm32-v7a" ;;
        s390x)         _ARCH_CF="s390x";  _ARCH_XRAY="s390x"     ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

# ==============================================================================
# §5  CORE — 工具函数
# ==============================================================================
check_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || die "请在 root 下运行脚本"; }

pkg_require() {
    local _pkg="$1" _bin="${2:-$1}"
    command -v "${_bin}" >/dev/null 2>&1 && return 0
    log_step "安装依赖: ${_pkg}"
    if   command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${_pkg}" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then dnf install -y "${_pkg}" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then yum install -y "${_pkg}" >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then apk add       "${_pkg}" >/dev/null 2>&1
    else die "未找到包管理器，无法安装 ${_pkg}"; fi
    hash -r 2>/dev/null || true
    command -v "${_bin}" >/dev/null 2>&1 || die "${_pkg} 安装失败，请手动安装后重试"
    log_ok "${_pkg} 已就绪"
}

preflight_check() {
    log_step "依赖预检..."
    for _d in curl unzip jq; do pkg_require "${_d}"; done
    # xxd 用于 Reality shortId 生成（比 od 格式更稳定）
    command -v xxd >/dev/null 2>&1 || pkg_require "xxd" "xxd" 2>/dev/null || \
        log_info "xxd 未安装 — Reality shortId 将 fallback 到 openssl/od"
    command -v openssl >/dev/null 2>&1 \
        || log_info "openssl 未安装 — Reality shortId 将由 /dev/urandom 生成"
    if [ -f "${XRAY_BIN}" ]; then
        [ -x "${XRAY_BIN}" ] || { chmod +x "${XRAY_BIN}"; log_warn "已修复 xray 可执行位"; }
        "${XRAY_BIN}" version >/dev/null 2>&1 || log_warn "xray 二进制可能损坏，建议重新安装"
    fi
    [ -f "${ARGO_BIN}" ] && ! [ -x "${ARGO_BIN}" ] \
        && { chmod +x "${ARGO_BIN}"; log_warn "已修复 cloudflared 可执行位"; }
    log_ok "依赖预检通过"
}

port_in_use() {
    local _p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null | awk -v p=":${_p}" '$4~p"$"||$4~p" "{f=1}END{exit !f}'; return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | awk -v p=":${_p}" '$4~p"$"||$4~p" "{f=1}END{exit !f}'; return
    fi
    local _h; _h=$(printf '%04X' "${_p}")
    awk -v h="${_h}" 'NR>1&&substr($2,index($2,":")+1,4)==h{f=1}END{exit !f}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

get_realip() {
    local _ip _org _v6
    _ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null) || true
    if [ -z "${_ip:-}" ]; then
        _v6=$(curl -sf --max-time 5 https://api6.ipify.org 2>/dev/null) || true
        [ -n "${_v6:-}" ] && printf '[%s]' "${_v6}" || printf ''; return
    fi
    _org=$(curl -sf --max-time 5 "https://ipinfo.io/${_ip}/org" 2>/dev/null) || true
    if printf '%s' "${_org:-}" | grep -qiE 'Cloudflare|UnReal|AEZA|Andrei'; then
        _v6=$(curl -sf --max-time 5 https://api6.ipify.org 2>/dev/null) || true
        [ -n "${_v6:-}" ] && printf '[%s]' "${_v6}" || printf '%s' "${_ip}"
    else
        printf '%s' "${_ip}"
    fi
}

urlencode_path() {
    printf '%s' "$1" | sed \
        's/%/%25/g;s/ /%20/g;s/!/%21/g;s/"/%22/g;s/#/%23/g;s/\$/%24/g;
         s/&/%26/g;s/'\''/%27/g;s/(/%28/g;s/)/%29/g;s/\*/%2A/g;s/+/%2B/g;
         s/,/%2C/g;s/:/%3A/g;s/;/%3B/g;s/=/%3D/g;s/?/%3F/g;s/@/%40/g;
         s/\[/%5B/g;s/\]/%5D/g'
}

_kernel_ge() {
    local cur cm cr; cur=$(uname -r)
    cm="${cur%%.*}"; cr="${cur#*.}"; cr="${cr%%.*}"; cr="${cr%%[^0-9]*}"
    [ "${cm}" -gt "$1" ] || { [ "${cm}" -eq "$1" ] && [ "${cr:-0}" -ge "$2" ]; }
}

# ==============================================================================
# §5a CORE — 防火墙自动开放（新增 v7.1）
#
# 优先级：ufw → firewall-cmd → iptables/ip6tables
# 仅开放 TCP，非阻塞（失败只 warn 不 die）
# ==============================================================================
open_firewall_port() {
    local _port="$1" _proto="${2:-tcp}"
    [ -z "${_port:-}" ] && return 0
    # ufw（Debian/Ubuntu 默认）
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'active'; then
        ufw allow "${_port}/${_proto}" >/dev/null 2>&1 \
            && { log_ok "ufw: 已开放 ${_port}/${_proto}"; return 0; } \
            || { log_warn "ufw: 开放 ${_port}/${_proto} 失败"; }
    fi
    # firewalld（RHEL/CentOS/Fedora）
    if command -v firewall-cmd >/dev/null 2>&1 && \
       firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${_port}/${_proto}" >/dev/null 2>&1 && \
        firewall-cmd --reload >/dev/null 2>&1 \
            && { log_ok "firewalld: 已开放 ${_port}/${_proto}"; return 0; } \
            || { log_warn "firewalld: 开放 ${_port}/${_proto} 失败"; }
    fi
    # iptables 兜底
    if command -v iptables >/dev/null 2>&1; then
        iptables  -I INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null && \
        ip6tables -I INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null || true
        # 尝试持久化
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save  > /etc/iptables/rules.v4  2>/dev/null || \
            iptables-save  > /etc/sysconfig/iptables 2>/dev/null || true
        fi
        log_ok "iptables: 已开放 ${_port}/${_proto}"
        return 0
    fi
    log_warn "未检测到活跃防火墙，端口 ${_port} 无需手动开放或请手动处理"
}

# ==============================================================================
# §5b CORE — Argo 隧道健康检查（新增 v7.1）
#
# 隧道启动后等待最多 15s，curl 探测 Cloudflare edge 连通性
# 通过 Argo 域名发起请求，HTTP 4xx 也视为连通（边缘已收到）
# ==============================================================================
check_argo_health() {
    local _domain; _domain=$(state_get '.argo.domain')
    [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ] || return 0

    log_step "Argo 健康检查（等待隧道就绪，最长 15s）..."
    local _i _rc=1
    for _i in 3 6 9 12 15; do
        sleep "${_i}" 2>/dev/null || sleep 3
        # HTTP 2xx/3xx/4xx 均表示边缘已收到请求，隧道连通
        local _code
        _code=$(curl -sfL --max-time 5 --connect-timeout 3 \
            -o /dev/null -w '%{http_code}' \
            "https://${_domain}/" 2>/dev/null) || true
        case "${_code:-000}" in
            [2345]??) log_ok "Argo 隧道连通 (HTTP ${_code}, domain=${_domain})"; return 0 ;;
        esac
        [ "${_i}" -lt 15 ] && printf '\r%s' "  等待中... (${_i}s)" >&2
    done
    printf '\n' >&2
    log_warn "Argo 健康检查超时，请稍后通过 [3. Argo 管理] 确认隧道状态"
    return 1
}

# ==============================================================================
# §6  CORE — 环境自愈
# ==============================================================================
check_bbr() {
    local _a; _a=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')
    [ "${_a}" = "bbr" ] && { log_ok "TCP BBR 已启用"; return 0; }
    log_warn "当前拥塞控制: ${_a}（推荐 BBR）"
    _kernel_ge 4 9 || { log_warn "内核 < 4.9，不支持 BBR"; return 0; }
    is_systemd || return 0
    local _ans; prompt "是否启用 BBR？(y/N): " _ans
    case "${_ans:-n}" in y|Y)
        modprobe tcp_bbr 2>/dev/null || true
        mkdir -p /etc/modules-load.d /etc/sysctl.d
        printf 'tcp_bbr\n' > /etc/modules-load.d/xray2go-bbr.conf
        printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' \
            > /etc/sysctl.d/88-xray2go-bbr.conf
        sysctl -p /etc/sysctl.d/88-xray2go-bbr.conf >/dev/null 2>&1
        log_ok "BBR 已启用"
    ;; esac
}

fix_time_sync() {
    [ -f /etc/redhat-release ] || [ -f /etc/centos-release ] || return 0
    local _pm; command -v dnf >/dev/null 2>&1 && _pm="dnf" || _pm="yum"
    log_step "RHEL 系：修正时间同步..."
    ${_pm} install -y chrony >/dev/null 2>&1 || true
    systemctl enable --now chronyd >/dev/null 2>&1 || true
    chronyc -a makestep >/dev/null 2>&1 || true
    ${_pm} update -y ca-certificates >/dev/null 2>&1 || true
    log_ok "时间同步已修正"
}

# ==============================================================================
# §7  STATE — 核心操作
#
# Schema v2:
# {
#   "_schema": 2,
#   "uuid":    "",
#   "argo":    {"enabled":true,  "protocol":"ws", "port":8888,
#               "mode":"fixed",  "domain":null,   "token":null},
#   "ff":      {"enabled":false, "protocol":"none", "path":"/"},
#   "reality": {"enabled":false, "port":443, "sni":"addons.mozilla.org",
#               "network":"tcp", "pbk":null, "pvk":null, "sid":null},
#   "vltcp":   {"enabled":false, "port":1234, "listen":"0.0.0.0"},
#   "cron":    0,
#   "cfip":    "cf.tencentapp.cn",
#   "cfport":  "443"
# }
# 写操作规则：所有写操作必须经由 state_set，禁止直接操作 _STATE
# ==============================================================================
_STATE=""

readonly _STATE_DEFAULT='{
  "_schema": 2,
  "uuid":    "",
  "argo":    {"enabled":true,  "protocol":"ws",   "port":8888,
              "mode":"fixed",  "domain":null,      "token":null},
  "ff":      {"enabled":false, "protocol":"none", "path":"/"},
  "reality": {"enabled":false, "port":443, "sni":"addons.mozilla.org",
              "network":"tcp", "pbk":null, "pvk":null, "sid":null},
  "vltcp":   {"enabled":false, "port":1234, "listen":"0.0.0.0"},
  "cron":    0,
  "cfip":    "cf.tencentapp.cn",
  "cfport":  "443"
}'

state_get() {
    local _v
    _v=$(printf '%s' "${_STATE}" | jq -r "${1} // empty" 2>/dev/null) || true
    printf '%s' "${_v}"
}

state_set() {
    local _f="$1"; shift
    local _n
    _n=$(printf '%s' "${_STATE}" | jq "$@" "${_f}" 2>/dev/null) \
        || { log_error "state_set 失败: ${_f}"; return 1; }
    [ -n "${_n:-}" ] && _STATE="${_n}" || { log_error "state_set 返回空 JSON"; return 1; }
}

# [v7.1] 写入前自动备份 state.json（带时间戳，保留最近一份）
state_persist() {
    mkdir -p "${WORK_DIR}"
    # 备份现有 state.json
    if [ -f "${STATE_FILE}" ]; then
        local _ts; _ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || printf 'bak')
        cp -f "${STATE_FILE}" "${STATE_FILE}.${_ts}.bak" 2>/dev/null || true
        # 仅保留最新一份备份，清理旧备份
        ls -t "${STATE_FILE}".*.bak 2>/dev/null | tail -n +2 | xargs rm -f 2>/dev/null || true
    fi
    local _t; _t=$(_tmp_file "state_XXXXXX.json") || return 1
    printf '%s\n' "${_STATE}" | jq . > "${_t}" || { log_error "state 序列化失败"; return 1; }
    mv "${_t}" "${STATE_FILE}"
}

# ==============================================================================
# §8  STATE — 默认值补全与 Schema 迁移
# ==============================================================================
state_merge_default() {
    local _c

    _c=$(state_get '.vltcp')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && \
        state_set '.vltcp = {"enabled":false,"port":1234,"listen":"0.0.0.0"}'

    _c=$(state_get '.reality.network')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && \
        state_set '.reality.network = "tcp"'

    _c=$(state_get '.cfip')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && \
        state_set '.cfip = "cf.tencentapp.cn"'

    _c=$(state_get '.cfport')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && \
        state_set '.cfport = "443"'
}

state_version() {
    local _sv; _sv=$(state_get '._schema // 0')
    [ "${_sv}" -ge "${_STATE_SCHEMA_VERSION}" ] && return 0
    [ "${_sv}" -lt 1 ] && _state_migrate_legacy
    state_merge_default
    state_set '._schema = ($v|tonumber)' --arg v "${_STATE_SCHEMA_VERSION}" \
        || log_warn "无法写入 _schema 版本号"
    log_info "state.json 已从 schema v${_sv} 升级到 v${_STATE_SCHEMA_VERSION}"
}

# ==============================================================================
# §9  STATE — 初始化与遗留文件迁移
# ==============================================================================
_state_migrate_legacy() {
    local _r

    if [ -f "${CONFIG_FILE}" ]; then
        _r=$(jq -r 'first(.inbounds[]? | select(.protocol=="vless")
                    | .settings.clients[0].id) // empty' "${CONFIG_FILE}" 2>/dev/null || true)
        [ -n "${_r:-}" ] && state_set '.uuid = $u' --arg u "${_r}"
        _r=$(jq -r 'first(.inbounds[]? | select(.listen=="127.0.0.1") | .port) // empty' \
               "${CONFIG_FILE}" 2>/dev/null || true)
        case "${_r:-}" in ''|*[!0-9]*) :;; *)
            state_set '.argo.port = ($p|tonumber)' --arg p "${_r}";; esac
    fi

    _r=$(cat "${WORK_DIR}/argo_mode.conf" 2>/dev/null || true)
    case "${_r:-}" in yes) state_set '.argo.enabled = true';;
                      no)  state_set '.argo.enabled = false';; esac
    _r=$(cat "${WORK_DIR}/argo_protocol.conf" 2>/dev/null || true)
    case "${_r:-}" in ws|xhttp) state_set '.argo.protocol = $p' --arg p "${_r}";; esac
    _r=$(cat "${WORK_DIR}/domain_fixed.txt" 2>/dev/null || true)
    [ -n "${_r:-}" ] && state_set '.argo.domain = $d | .argo.mode = "fixed"' --arg d "${_r}"

    if [ -f "${WORK_DIR}/freeflow.conf" ]; then
        local _l1 _l2
        _l1=$(sed -n '1p' "${WORK_DIR}/freeflow.conf" 2>/dev/null || true)
        _l2=$(sed -n '2p' "${WORK_DIR}/freeflow.conf" 2>/dev/null || true)
        case "${_l1:-}" in
            ws|httpupgrade|xhttp)
                state_set '.ff.enabled = true | .ff.protocol = $p' --arg p "${_l1}";;
            none|"") state_set '.ff.enabled = false | .ff.protocol = "none"';;
        esac
        [ -n "${_l2:-}" ] && state_set '.ff.path = $p' --arg p "${_l2}"
    fi

    if [ -f "${WORK_DIR}/reality.conf" ]; then
        local _rm _rp _rs _rpbk _rpvk _rsid
        _rm=$(  sed -n '1p' "${WORK_DIR}/reality.conf" 2>/dev/null || true)
        _rp=$(  sed -n '2p' "${WORK_DIR}/reality.conf" 2>/dev/null || true)
        _rs=$(  sed -n '3p' "${WORK_DIR}/reality.conf" 2>/dev/null || true)
        _rpbk=$(sed -n '4p' "${WORK_DIR}/reality.conf" 2>/dev/null || true)
        _rpvk=$(sed -n '5p' "${WORK_DIR}/reality.conf" 2>/dev/null || true)
        _rsid=$(sed -n '6p' "${WORK_DIR}/reality.conf" 2>/dev/null || true)
        [ "${_rm:-}" = "yes" ] && state_set '.reality.enabled = true'
        case "${_rp:-}" in ''|*[!0-9]*):;; *)
            state_set '.reality.port = ($p|tonumber)' --arg p "${_rp}";; esac
        [ -n "${_rs:-}"   ] && state_set '.reality.sni = $s' --arg s "${_rs}"
        [ -n "${_rpbk:-}" ] && state_set '.reality.pbk = $k' --arg k "${_rpbk}"
        [ -n "${_rpvk:-}" ] && state_set '.reality.pvk = $k' --arg k "${_rpvk}"
        [ -n "${_rsid:-}" ] && state_set '.reality.sid = $s' --arg s "${_rsid}"
    fi

    _r=$(cat "${WORK_DIR}/restart.conf" 2>/dev/null || true)
    case "${_r:-}" in ''|*[!0-9]*):;; *)
        state_set '.cron = ($r|tonumber)' --arg r "${_r}";; esac

    log_info "已从历史配置文件完成状态迁移"
}

state_init() {
    if [ -f "${STATE_FILE}" ]; then
        local _raw; _raw=$(cat "${STATE_FILE}" 2>/dev/null || true)
        if printf '%s' "${_raw}" | jq -e . >/dev/null 2>&1; then
            _STATE="${_raw}"
            state_version
            state_merge_default
            local _u; _u=$(state_get '.uuid')
            [ -z "${_u:-}" ] && state_set '.uuid = $u' --arg u "$(_gen_uuid)"
            return 0
        fi
        log_warn "state.json 损坏，尝试从遗留配置迁移..."
    fi
    _STATE="${_STATE_DEFAULT}"
    _state_migrate_legacy
    state_merge_default
    local _u; _u=$(state_get '.uuid')
    [ -z "${_u:-}" ] && state_set '.uuid = $u' --arg u "$(_gen_uuid)"
    [ -d "${WORK_DIR}" ] && { state_persist 2>/dev/null || true; log_info "状态已初始化并持久化"; }
}

# ==============================================================================
# §10 STATE — 密钥生成
# ==============================================================================
_gen_uuid() {
    [ -r /proc/sys/kernel/random/uuid ] && { cat /proc/sys/kernel/random/uuid; return; }
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
    awk 'BEGIN{srand()}{h=$0;printf "%s-%s-4%s-%s%s-%s\n",
        substr(h,1,8),substr(h,9,4),substr(h,14,3),
        substr("89ab",int(rand()*4)+1,1),substr(h,18,3),substr(h,21,12)}'
}

_gen_reality_keypair() {
    [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪，无法生成密钥对"; return 1; }
    local _out _rc
    _out=$("${XRAY_BIN}" x25519 2>&1); _rc=$?
    [ "${_rc}" -ne 0 ] && { log_error "xray x25519 失败 (exit ${_rc})"; return 1; }
    [ -z "${_out:-}" ] && { log_error "xray x25519 无输出，二进制可能损坏"; return 1; }
    local _pvk _pbk
    _pvk=$(printf '%s\n' "${_out}" | grep -i 'private' | awk '{print $NF}' | tr -d '\r\n')
    _pbk=$(printf '%s\n' "${_out}" | grep -i 'public'  | awk '{print $NF}' | tr -d '\r\n')
    if [ -z "${_pvk:-}" ] || [ -z "${_pbk:-}" ]; then
        log_error "密钥解析失败，xray 原始输出:"
        printf '%s\n' "${_out}" | while IFS= read -r _l; do log_error "  ${_l}"; done
        log_error "如持续失败请卸载后重装以更新 xray 二进制"
        return 1
    fi
    local _b64='^[A-Za-z0-9_=-]{20,}$'
    printf '%s' "${_pvk}" | grep -qE "${_b64}" || { log_error "私钥格式异常"; return 1; }
    printf '%s' "${_pbk}" | grep -qE "${_b64}" || { log_error "公钥格式异常"; return 1; }
    state_set '.reality.pvk = $v | .reality.pbk = $b' --arg v "${_pvk}" --arg b "${_pbk}" \
        || return 1
    log_ok "x25519 密钥对已生成 (pubkey: ${_pbk:0:16}...)"
}

# [v7.1] shortId 生成：优先 openssl → xxd → od，保证 hex 格式正确
_gen_reality_sid() {
    # 优先 openssl（最标准）
    command -v openssl >/dev/null 2>&1 && { openssl rand -hex 8 2>/dev/null; return; }
    # xxd 方式（比 od 格式更稳定，无空格问题）
    command -v xxd >/dev/null 2>&1 && \
        { head -c 8 /dev/urandom 2>/dev/null | xxd -p | tr -d '\n'; return; }
    # 最终 fallback：od
    od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

# ==============================================================================
# §11 PROTOCOL — 注册表
#
# 新增协议步骤：
#   1. 实现 protocol_<n>() 纯函数（§12）
#   2. 实现 link_<n>() 纯函数（§13）
#   3. 在 _protocol_registry_init() 注册两个函数
#   4. 在 _PROTOCOL_ORDER 末尾追加名称
#   → config_synthesize / _get_share_links 无需修改
# ==============================================================================
declare -A PROTOCOL_REGISTRY
declare -A LINK_REGISTRY
_PROTOCOL_ORDER="argo ff reality vltcp"

_protocol_registry_init() {
    PROTOCOL_REGISTRY[argo]="protocol_argo"
    PROTOCOL_REGISTRY[ff]="protocol_ff"
    PROTOCOL_REGISTRY[reality]="protocol_reality"
    PROTOCOL_REGISTRY[vltcp]="protocol_vltcp"

    LINK_REGISTRY[argo]="link_argo"
    LINK_REGISTRY[ff]="link_ff"
    LINK_REGISTRY[reality]="link_reality"
    LINK_REGISTRY[vltcp]="link_vltcp"
}

# ==============================================================================
# §12 PROTOCOL — 入站配置生成（纯函数，禁止副作用）
#
# 输出 xray inbound JSON 到 stdout；返回空串表示协议已禁用（非错误）。
# 精简原则（纯落地，无服务端路由）：
#   · 无 sniffing          结果无消费者
#   · 无 security:"none"   xray 默认值
#   · 无 show/xver         realitySettings 默认值
#   · 无 host:""           xhttpSettings 空字符串无效果
#   · vltcp 无 streamSettings  全为默认值，整块省略
# ==============================================================================
protocol_argo() {
    [ "$(state_get '.argo.enabled')" = "true" ] || return 0
    local _port _proto _uuid
    _port=$(state_get '.argo.port')
    _proto=$(state_get '.argo.protocol')
    _uuid=$(state_get '.uuid')
    case "${_proto}" in
        xhttp)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" '{
                port:$port, listen:"127.0.0.1", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp",
                    xhttpSettings:{path:"/argo", mode:"auto"}}}' ;;
        *)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" '{
                port:$port, listen:"127.0.0.1", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"ws",
                    wsSettings:{path:"/argo"}}}' ;;
    esac
}

protocol_ff() {
    [ "$(state_get '.ff.enabled')" = "true" ] || return 0
    local _proto; _proto=$(state_get '.ff.protocol')
    [ "${_proto}" != "none" ] || return 0
    local _path _uuid
    _path=$(state_get '.ff.path')
    _uuid=$(state_get '.uuid')
    case "${_proto}" in
        ws)
            jq -n --arg uuid "${_uuid}" --arg path "${_path}" '{
                port:8080, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"ws",
                    wsSettings:{path:$path}}}' ;;
        httpupgrade)
            jq -n --arg uuid "${_uuid}" --arg path "${_path}" '{
                port:8080, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"httpupgrade",
                    httpupgradeSettings:{path:$path}}}' ;;
        xhttp)
            jq -n --arg uuid "${_uuid}" --arg path "${_path}" '{
                port:8080, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp",
                    xhttpSettings:{path:$path, mode:"stream-one"}}}' ;;
        *)
            log_error "protocol_ff: 未知协议 ${_proto}"; return 1 ;;
    esac
}

protocol_reality() {
    [ "$(state_get '.reality.enabled')" = "true" ] || return 0
    local _pvk; _pvk=$(state_get '.reality.pvk')
    if [ -z "${_pvk:-}" ] || [ "${_pvk}" = "null" ]; then
        log_warn "Reality 密钥未就绪，已跳过该入站"
        return 0
    fi
    local _port _sni _sid _net _uuid
    _port=$(state_get '.reality.port')
    _sni=$(state_get  '.reality.sni')
    _sid=$(state_get  '.reality.sid')
    _net=$(state_get  '.reality.network'); _net="${_net:-tcp}"
    _uuid=$(state_get '.uuid')
    case "${_net}" in
        xhttp)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                   --arg sni "${_sni}" --arg pvk "${_pvk}" --arg sid "${_sid}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp", security:"reality",
                    realitySettings:{dest:($sni+":443"),
                        serverNames:[$sni], privateKey:$pvk, shortIds:[$sid]},
                    xhttpSettings:{path:"/", mode:"auto"}}}' ;;
        *)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                   --arg sni "${_sni}" --arg pvk "${_pvk}" --arg sid "${_sid}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid, flow:"xtls-rprx-vision"}], decryption:"none"},
                streamSettings:{network:"tcp", security:"reality",
                    realitySettings:{dest:($sni+":443"),
                        serverNames:[$sni], privateKey:$pvk, shortIds:[$sid]}}}' ;;
    esac
}

protocol_vltcp() {
    [ "$(state_get '.vltcp.enabled')" = "true" ] || return 0
    local _port _listen _uuid
    _port=$(state_get '.vltcp.port')
    _listen=$(state_get '.vltcp.listen')
    _uuid=$(state_get '.uuid')
    jq -n --argjson port "${_port}" --arg listen "${_listen}" --arg uuid "${_uuid}" '{
        port:$port, listen:$listen, protocol:"vless",
        settings:{clients:[{id:$uuid, flow:"xtls-rprx-vision"}], decryption:"none"}}'
}

# ==============================================================================
# §13 PROTOCOL — 节点链接生成（纯函数，禁止副作用）
# ==============================================================================
link_argo() {
    [ "$(state_get '.argo.enabled')" = "true" ] || return 0
    local _domain _proto _uuid _cfip _cfport
    _domain=$(state_get '.argo.domain')
    _proto=$(state_get  '.argo.protocol')
    _uuid=$(state_get   '.uuid')
    _cfip=$(state_get   '.cfip')
    _cfport=$(state_get '.cfport')
    [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ] || return 0
    case "${_proto}" in
        xhttp)
            printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=xhttp&host=%s&path=%%2Fargo&mode=auto#Argo-XHTTP\n' \
                "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" ;;
        *)
            printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%%2Fargo%%3Fed%%3D2560#Argo-WS\n' \
                "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" ;;
    esac
}

link_ff() {
    [ "$(state_get '.ff.enabled')" = "true" ] || return 0
    local _proto; _proto=$(state_get '.ff.protocol')
    [ "${_proto}" != "none" ] || return 0
    local _ip; _ip=$(get_realip)
    if [ -z "${_ip:-}" ]; then log_warn "无法获取服务器 IP，FreeFlow 节点已跳过"; return 0; fi
    local _penc _uuid
    _penc=$(urlencode_path "$(state_get '.ff.path')")
    _uuid=$(state_get '.uuid')
    case "${_proto}" in
        ws)
            printf 'vless://%s@%s:8080?encryption=none&security=none&type=ws&host=%s&path=%s#FreeFlow-WS\n' \
                "${_uuid}" "${_ip}" "${_ip}" "${_penc}" ;;
        httpupgrade)
            printf 'vless://%s@%s:8080?encryption=none&security=none&type=httpupgrade&host=%s&path=%s#FreeFlow-HTTPUpgrade\n' \
                "${_uuid}" "${_ip}" "${_ip}" "${_penc}" ;;
        xhttp)
            printf 'vless://%s@%s:8080?encryption=none&security=none&type=xhttp&host=%s&path=%s&mode=stream-one#FreeFlow-XHTTP\n' \
                "${_uuid}" "${_ip}" "${_ip}" "${_penc}" ;;
    esac
}

link_reality() {
    [ "$(state_get '.reality.enabled')" = "true" ] || return 0
    local _rpbk; _rpbk=$(state_get '.reality.pbk')
    [ -n "${_rpbk:-}" ] && [ "${_rpbk}" != "null" ] || return 0
    local _ip; _ip=$(get_realip)
    if [ -z "${_ip:-}" ]; then log_warn "无法获取服务器 IP，Reality 节点已跳过"; return 0; fi
    local _rnet _uuid
    _rnet=$(state_get '.reality.network'); _rnet="${_rnet:-tcp}"
    _uuid=$(state_get '.uuid')
    case "${_rnet}" in
        xhttp)
            printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%%2F&mode=auto#Reality-XHTTP\n' \
                "${_uuid}" "${_ip}" "$(state_get '.reality.port')" \
                "$(state_get '.reality.sni')" "${_rpbk}" "$(state_get '.reality.sid')" ;;
        *)
            printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#Reality-Vision\n' \
                "${_uuid}" "${_ip}" "$(state_get '.reality.port')" \
                "$(state_get '.reality.sni')" "${_rpbk}" "$(state_get '.reality.sid')" ;;
    esac
}

link_vltcp() {
    [ "$(state_get '.vltcp.enabled')" = "true" ] || return 0
    local _listen _vhost _uuid
    _listen=$(state_get '.vltcp.listen')
    _uuid=$(state_get   '.uuid')
    [ "${_listen}" = "0.0.0.0" ] || [ "${_listen}" = "::" ] \
        && _vhost=$(get_realip) || _vhost="${_listen}"
    if [ -z "${_vhost:-}" ]; then log_warn "无法获取服务器 IP，VLESS-TCP 节点已跳过"; return 0; fi
    printf 'vless://%s@%s:%s?type=tcp&flow=xtls-rprx-vision&security=none#VLESS-TCP\n' \
        "${_uuid}" "${_vhost}" "$(state_get '.vltcp.port')"
}

# ==============================================================================
# §14 CONFIG — 配置合成（state → stdout JSON，纯函数）
#
# 生成结构：log(loglevel:warning) + inbounds + outbounds(freedom only)
# [v7.1] loglevel 由 "none" 改为 "warning"，便于排障，不影响性能
# 无 dns / routing / policy / stats / blackhole：纯落地代理不需要任何服务端处理
# ==============================================================================
config_synthesize() {
    local _ibs="[]" _ib _name _fn

    for _name in ${_PROTOCOL_ORDER}; do
        _fn="${PROTOCOL_REGISTRY[${_name}]:-}"
        [ -n "${_fn:-}" ] || continue
        _ib=$("${_fn}") || { log_error "协议 ${_name} 配置生成失败"; return 1; }
        [ -n "${_ib:-}" ] || continue
        _ibs=$(printf '%s' "${_ibs}" | jq --argjson ib "${_ib}" '. + [$ib]') \
            || { log_error "inbounds 组装失败 (${_name})"; return 1; }
    done

    [ "$(printf '%s' "${_ibs}" | jq 'length')" -eq 0 ] && \
        log_warn "所有入站均已禁用，xray 将以零入站模式运行"

    # [v7.1] loglevel: "warning"（原 "none"）
    jq -n --argjson inbounds "${_ibs}" '{
        log:      {loglevel:"warning"},
        inbounds: $inbounds,
        outbounds:[{protocol:"freedom"}]
    }' || { log_error "config JSON 合成失败"; return 1; }
}

# ==============================================================================
# §15 CONFIG — 节点链接聚合与展示
# ==============================================================================
_get_share_links() {
    local _name _fn
    for _name in ${_PROTOCOL_ORDER}; do
        _fn="${LINK_REGISTRY[${_name}]:-}"
        [ -n "${_fn:-}" ] || continue
        "${_fn}" || true
    done
}

print_nodes() {
    echo ""
    local _links; _links=$(_get_share_links)
    if [ -z "${_links:-}" ]; then
        log_warn "暂无可用节点（请检查 Argo 域名或服务器 IP）"; return 1
    fi
    printf '%s\n' "${_links}" | while IFS= read -r _l; do
        [ -n "${_l:-}" ] && printf "${C_CYN}%s${C_RST}\n" "${_l}"
    done
    echo ""
}

# ==============================================================================
# §16 RUNTIME — 服务管理（屏蔽 systemd / OpenRC 差异）
# ==============================================================================
_SYSD_DIRTY=0

exec_svc() {
    local _act="$1" _name="$2" _rc=0
    if is_systemd; then
        case "${_act}" in
            enable)  systemctl enable  "${_name}" >/dev/null 2>&1; _rc=$? ;;
            disable) systemctl disable "${_name}" >/dev/null 2>&1; _rc=$? ;;
            status)  systemctl is-active --quiet "${_name}" 2>/dev/null; _rc=$? ;;
            *)       systemctl "${_act}" "${_name}" >/dev/null 2>&1; _rc=$? ;;
        esac
    else
        case "${_act}" in
            enable)  rc-update add "${_name}" default >/dev/null 2>&1; _rc=$? ;;
            disable) rc-update del "${_name}" default >/dev/null 2>&1; _rc=$? ;;
            status)  rc-service "${_name}" status >/dev/null 2>&1; _rc=$? ;;
            *)       rc-service "${_name}" "${_act}" >/dev/null 2>&1; _rc=$? ;;
        esac
    fi
    return "${_rc}"
}

exec_svc_reload() {
    is_systemd && [ "${_SYSD_DIRTY}" -eq 1 ] || return 0
    systemctl daemon-reload >/dev/null 2>&1 || true
    _SYSD_DIRTY=0
}

_svc_write() {
    local _dest="$1" _content="$2"
    local _cur; _cur=$(cat "${_dest}" 2>/dev/null || printf '')
    [ "${_cur}" = "${_content}" ] && return 0
    printf '%s' "${_content}" > "${_dest}"; return 1
}

# [v7.1] 添加 Restart=always / RestartSec=3 / LimitNOFILE=1048576
#        防止 VPS 重启/网络波动导致 xray downtime
_tpl_xray_systemd() {
    printf '[Unit]\nDescription=Xray Service\nDocumentation=https://github.com/XTLS/Xray-core\nAfter=network.target nss-lookup.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nExecStart=%s run -c %s\nRestart=always\nRestartSec=3\nRestartPreventExitStatus=23\nLimitNOFILE=1048576\n\n[Install]\nWantedBy=multi-user.target\n' \
        "${XRAY_BIN}" "${CONFIG_FILE}"
}

# [v7.1] tunnel 同样添加 Restart=always / RestartSec=5
#        Cloudflare QUIC 连接偶发中断时自动恢复
_tpl_tunnel_systemd() {
    printf '[Unit]\nDescription=Cloudflare Tunnel\nAfter=network.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nTimeoutStartSec=0\nExecStart=/bin/sh -c '"'"'%s >> %s 2>&1'"'"'\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\n' \
        "$1" "${ARGO_LOG}"
}

_tpl_xray_openrc() {
    printf '#!/sbin/openrc-run\ndescription="Xray service"\ncommand="%s"\ncommand_args="run -c %s"\ncommand_background=true\npidfile="/var/run/xray.pid"\n' \
        "${XRAY_BIN}" "${CONFIG_FILE}"
}

_tpl_tunnel_openrc() {
    printf '#!/sbin/openrc-run\ndescription="Cloudflare Tunnel"\ncommand="/bin/sh"\ncommand_args="-c '"'"'%s >> %s 2>&1'"'"'"\ncommand_background=true\npidfile="/var/run/tunnel.pid"\n' \
        "$1" "${ARGO_LOG}"
}

apply_xray_service() {
    if is_systemd; then
        _svc_write "/etc/systemd/system/xray.service" "$(_tpl_xray_systemd)" || _SYSD_DIRTY=1
    else
        _svc_write "/etc/init.d/xray" "$(_tpl_xray_openrc)" || chmod +x /etc/init.d/xray
    fi
}

apply_tunnel_service() {
    local _cmd; _cmd=$(_build_tunnel_cmd)
    if is_systemd; then
        _svc_write "/etc/systemd/system/tunnel.service" "$(_tpl_tunnel_systemd "${_cmd}")" \
            || _SYSD_DIRTY=1
    else
        _svc_write "/etc/init.d/tunnel" "$(_tpl_tunnel_openrc "${_cmd}")" \
            || chmod +x /etc/init.d/tunnel
    fi
}

# ==============================================================================
# §17 RUNTIME — Argo 隧道命令与配置文件
#
# [v7.1] 协议由 http2 改为 quic
#        Cloudflare 官方推荐 QUIC，减少握手延迟，连接更稳定
#        参考：https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
# ==============================================================================
_build_tunnel_cmd() {
    if [ -f "${WORK_DIR}/tunnel.yml" ]; then
        printf '%s tunnel --edge-ip-version auto --config %s run' \
            "${ARGO_BIN}" "${WORK_DIR}/tunnel.yml"
    else
        # [v7.1] --protocol quic（原 http2）
        printf '%s tunnel --edge-ip-version auto --no-autoupdate --protocol quic run --token %s' \
            "${ARGO_BIN}" "$(state_get '.argo.token')"
    fi
}

_gen_argo_config() {
    local _domain="$1" _tid="$2" _cred="$3"
    local _port; _port=$(state_get '.argo.port')
    # [v7.1] protocol: quic（原 http2）
    printf 'tunnel: %s\ncredentials-file: %s\nprotocol: quic\n\ningress:\n  - hostname: %s\n    service: http://localhost:%s\n    originRequest:\n      noTLSVerify: true\n  - service: http_status:404\n' \
        "${_tid}" "${_cred}" "${_domain}" "${_port}" > "${WORK_DIR}/tunnel.yml" \
        || { log_error "tunnel.yml 写入失败"; return 1; }
    log_ok "tunnel.yml 已生成 (${_domain} → localhost:${_port}, protocol=quic)"
}

# ==============================================================================
# §18 RUNTIME — 下载
#
# [v7.1] download_xray 添加 SHA256 校验
#        从 GitHub releases 获取 checksums 文件并验证，防止供应链攻击
# ==============================================================================
download_xray() {
    detect_arch
    [ -f "${XRAY_BIN}" ] && { log_info "xray 已存在，跳过下载"; return 0; }

    local _base_url="https://github.com/XTLS/Xray-core/releases/latest/download"
    local _zip_name="Xray-linux-${_ARCH_XRAY}.zip"
    local _url="${_base_url}/${_zip_name}"
    local _z; _z=$(_tmp_file "xray_XXXXXX.zip") || return 1

    spinner_start "下载 Xray (${_ARCH_XRAY})"
    curl -sfL --connect-timeout 15 --max-time 120 -o "${_z}" "${_url}"; local _rc=$?
    spinner_stop
    [ "${_rc}" -ne 0 ] && { log_error "Xray 下载失败"; return 1; }

    # [v7.1] SHA256 校验
    log_step "验证 Xray 文件完整性（SHA256）..."
    local _sha_url="${_base_url}/Xray-linux-${_ARCH_XRAY}.zip.dgst"
    local _sha_file; _sha_file=$(_tmp_file "xray_XXXXXX.dgst") || return 1
    if curl -sfL --connect-timeout 10 --max-time 30 -o "${_sha_file}" "${_sha_url}" 2>/dev/null; then
        # dgst 文件格式：多行，SHA2-256 行形如 "SHA2-256(filename)= <hash>"
        local _expected_hash
        _expected_hash=$(grep -i 'SHA2-256' "${_sha_file}" 2>/dev/null | \
                         awk '{print $NF}' | head -1 | tr -d '[:space:]') || true
        if [ -n "${_expected_hash:-}" ] && command -v sha256sum >/dev/null 2>&1; then
            local _actual_hash
            _actual_hash=$(sha256sum "${_z}" | awk '{print $1}' | tr -d '[:space:]')
            if [ "${_actual_hash}" = "${_expected_hash}" ]; then
                log_ok "SHA256 校验通过"
            else
                log_error "SHA256 校验失败！文件可能已损坏或被篡改"
                log_error "  期望: ${_expected_hash}"
                log_error "  实际: ${_actual_hash}"
                rm -f "${_z}"
                return 1
            fi
        else
            log_warn "无法执行 SHA256 校验（缺少 sha256sum 或 hash 文件格式异常），跳过校验"
        fi
    else
        log_warn "无法获取 SHA256 校验文件，跳过完整性验证"
    fi

    unzip -t "${_z}" >/dev/null 2>&1 || { log_error "Xray zip 损坏"; return 1; }
    unzip -o "${_z}" xray -d "${WORK_DIR}/" >/dev/null 2>&1 || { log_error "Xray 解压失败"; return 1; }
    [ -f "${XRAY_BIN}" ] || { log_error "解压后未找到 xray 二进制"; return 1; }
    chmod +x "${XRAY_BIN}"
    log_ok "Xray 下载完成 ($("${XRAY_BIN}" version 2>/dev/null | head -1 | awk '{print $2}'))"
}

download_cloudflared() {
    detect_arch
    [ -f "${ARGO_BIN}" ] && { log_info "cloudflared 已存在，跳过下载"; return 0; }
    local _url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${_ARCH_CF}"
    spinner_start "下载 cloudflared (${_ARCH_CF})"
    curl -sfL --connect-timeout 15 --max-time 120 -o "${ARGO_BIN}" "${_url}"; local _rc=$?
    spinner_stop
    [ "${_rc}" -ne 0 ] && { rm -f "${ARGO_BIN}"; log_error "cloudflared 下载失败"; return 1; }
    [ -s "${ARGO_BIN}" ] || { rm -f "${ARGO_BIN}"; log_error "cloudflared 文件为空"; return 1; }
    chmod +x "${ARGO_BIN}"
    log_ok "cloudflared 下载完成"
}

# ==============================================================================
# §19 RUNTIME — 配置原子提交（合成 → 验证 → 写入 → 重启）
#
# [v7.1] 写入前自动备份 config.json（带时间戳，保留最近一份）
# ==============================================================================
apply_config() {
    local _t; _t=$(_tmp_file "xray_next_XXXXXX.json") || return 1
    log_step "合成配置..."
    config_synthesize > "${_t}" || return 1

    if [ -x "${XRAY_BIN}" ]; then
        log_step "验证配置 (xray -test)..."
        if ! "${XRAY_BIN}" -test -c "${_t}" >/dev/null 2>&1; then
            log_error "config 验证失败！现场已保留: ${WORK_DIR}/config_failed.json"
            mv "${_t}" "${WORK_DIR}/config_failed.json" 2>/dev/null || true
            return 1
        fi
        log_ok "config 验证通过"
    else
        log_warn "xray 未就绪，跳过预检（安装阶段正常）"
    fi

    mkdir -p "${WORK_DIR}"

    # [v7.1] 写入前备份 config.json
    if [ -f "${CONFIG_FILE}" ]; then
        local _ts; _ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || printf 'bak')
        cp -f "${CONFIG_FILE}" "${CONFIG_FILE}.${_ts}.bak" 2>/dev/null || true
        ls -t "${CONFIG_FILE}".*.bak 2>/dev/null | tail -n +2 | xargs rm -f 2>/dev/null || true
    fi

    mv "${_t}" "${CONFIG_FILE}" || { log_error "config 写入失败"; return 1; }
    log_ok "config.json 已原子更新"

    if exec_svc status xray >/dev/null 2>&1; then
        exec_svc restart xray || { log_error "xray 重启失败"; return 1; }
        log_ok "xray 已重启"
    fi
}

# ==============================================================================
# §20 RUNTIME — 安装与卸载
#
# [v7.1] exec_install_core 新增：
#   - 防火墙自动开放所有启用协议的端口
#   - Argo 启动后健康检查
# ==============================================================================
exec_install_core() {
    clear; log_title "══════════ 安装 Xray-2go v7 ══════════"
    preflight_check
    mkdir -p "${WORK_DIR}" && chmod 750 "${WORK_DIR}"

    download_xray || return 1
    [ "$(state_get '.argo.enabled')" = "true" ] && { download_cloudflared || return 1; }

    if [ "$(state_get '.reality.enabled')" = "true" ]; then
        log_step "生成 Reality x25519 密钥对..."
        _gen_reality_keypair || return 1
        state_set '.reality.sid = $s' --arg s "$(_gen_reality_sid)"
    fi

    apply_config || return 1

    apply_xray_service
    [ "$(state_get '.argo.enabled')" = "true" ] && apply_tunnel_service
    exec_svc_reload

    if is_openrc; then
        printf '0 0\n' > /proc/sys/net/ipv4/ping_group_range 2>/dev/null || true
        sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts 2>/dev/null || true
        sed -i '2s/.*/::1         localhost/'  /etc/hosts 2>/dev/null || true
    fi

    fix_time_sync

    # [v7.1] 防火墙自动开放各协议端口
    log_step "检测并开放防火墙端口..."
    if [ "$(state_get '.reality.enabled')" = "true" ]; then
        open_firewall_port "$(state_get '.reality.port')" tcp
    fi
    if [ "$(state_get '.vltcp.enabled')" = "true" ]; then
        open_firewall_port "$(state_get '.vltcp.port')" tcp
    fi
    if [ "$(state_get '.ff.enabled')" = "true" ] && \
       [ "$(state_get '.ff.protocol')" != "none" ]; then
        open_firewall_port 8080 tcp
    fi

    log_step "启动服务..."
    exec_svc enable xray
    exec_svc start  xray   || { log_error "xray 启动失败"; return 1; }
    log_ok "xray 已启动"

    if [ "$(state_get '.argo.enabled')" = "true" ]; then
        exec_svc enable tunnel
        exec_svc start  tunnel || { log_error "tunnel 启动失败"; return 1; }
        log_ok "tunnel 已启动"
    fi

    state_persist || log_warn "state.json 写入失败（不影响运行）"
    log_ok "══ 安装完成 ══"
}

exec_uninstall() {
    local _a; prompt "确定要卸载 xray-2go？(y/N): " _a
    case "${_a:-n}" in y|Y) :;; *) log_info "已取消"; return;; esac
    log_step "卸载中..."
    exec_remove_auto_restart
    for _s in xray tunnel; do
        exec_svc stop    "${_s}" 2>/dev/null || true
        exec_svc disable "${_s}" 2>/dev/null || true
    done
    if is_systemd; then
        rm -f /etc/systemd/system/xray.service /etc/systemd/system/tunnel.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rm -f /etc/init.d/xray /etc/init.d/tunnel
    fi
    rm -rf "${WORK_DIR}"
    rm -f  "${SHORTCUT}" "${SELF_DEST}" "${SELF_DEST}.bak"
    log_ok "Xray-2go 卸载完成"
}

# ==============================================================================
# §21 RUNTIME — Argo 固定隧道配置
# ==============================================================================
apply_fixed_tunnel() {
    log_info "固定隧道 — 协议: $(state_get '.argo.protocol')  回源端口: $(state_get '.argo.port')"
    echo ""
    local _domain _auth
    prompt "请输入 Argo 域名: " _domain
    case "${_domain:-}" in ''|*' '*|*'/'*|*$'\t'*)
        log_error "域名格式不合法"; return 1;; esac
    printf '%s' "${_domain}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
        || { log_error "域名格式不合法"; return 1; }

    prompt "请输入 Argo 密钥 (token 或 JSON 内容): " _auth
    [ -z "${_auth:-}" ] && { log_error "密钥不能为空"; return 1; }

    if printf '%s' "${_auth}" | grep -q "TunnelSecret"; then
        printf '%s' "${_auth}" | jq . >/dev/null 2>&1 \
            || { log_error "JSON 凭证格式不合法"; return 1; }
        local _tid
        _tid=$(printf '%s' "${_auth}" | jq -r '
            if (.TunnelID? // "") != "" then .TunnelID
            elif (.AccountTag? // "") != "" then .AccountTag
            else empty end' 2>/dev/null)
        [ -z "${_tid:-}" ] && { log_error "无法提取 TunnelID/AccountTag"; return 1; }
        case "${_tid}" in *$'\n'*|*'"'*|*"'"*|*':'*)
            log_error "TunnelID 含非法字符，拒绝写入"; return 1;; esac
        local _cred="${WORK_DIR}/tunnel.json"
        printf '%s' "${_auth}" > "${_cred}"
        _gen_argo_config "${_domain}" "${_tid}" "${_cred}" || return 1
        state_set '.argo.token = null | .argo.domain = $d | .argo.mode = "fixed"' \
            --arg d "${_domain}" || return 1
    elif printf '%s' "${_auth}" | grep -qE '^[A-Za-z0-9=_-]{120,250}$'; then
        state_set '.argo.token = $t | .argo.domain = $d | .argo.mode = "fixed"' \
            --arg t "${_auth}" --arg d "${_domain}" || return 1
        rm -f "${WORK_DIR}/tunnel.yml" "${WORK_DIR}/tunnel.json"
    else
        log_error "密钥格式无法识别（JSON 需含 TunnelSecret；Token 为 120-250 位字母数字串）"
        return 1
    fi

    apply_tunnel_service
    exec_svc_reload
    exec_svc enable tunnel 2>/dev/null || true
    apply_config  || return 1
    state_persist || log_warn "state.json 写入失败"
    exec_svc restart tunnel || { log_error "tunnel 重启失败"; return 1; }
    log_ok "固定隧道已配置 (domain=${_domain})"

    # [v7.1] 固定隧道配置完成后执行健康检查
    check_argo_health || true
}

# ==============================================================================
# §22 RUNTIME — UUID 与端口更新
# ==============================================================================
exec_update_uuid() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先安装 Xray-2go"; return 1; }
    local _v; prompt "新 UUID（回车自动生成）: " _v
    if [ -z "${_v:-}" ]; then
        _v=$(_gen_uuid) || { log_error "UUID 生成失败"; return 1; }
        log_info "已生成 UUID: ${_v}"
    fi
    printf '%s' "${_v}" | grep -qiE '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' \
        || { log_error "UUID 格式不合法"; return 1; }
    state_set '.uuid = $u' --arg u "${_v}" || return 1
    apply_config  || return 1
    state_persist || log_warn "state.json 写入失败"
    log_ok "UUID 已更新: ${_v}"; print_nodes
}

exec_update_argo_port() {
    local _p; prompt "新回源端口（回车随机）: " _p
    [ -z "${_p:-}" ] && _p=$(shuf -i 2000-65000 -n 1 2>/dev/null || \
                              awk 'BEGIN{srand();print int(rand()*63000)+2000}')
    case "${_p:-}" in ''|*[!0-9]*) log_error "无效端口"; return 1;; esac
    { [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]; } \
        || { log_error "端口须在 1-65535 之间"; return 1; }
    if port_in_use "${_p}"; then
        log_warn "端口 ${_p} 已被占用"
        local _a; prompt "仍然继续？(y/N): " _a
        case "${_a:-n}" in y|Y) :;; *) return 1;; esac
    fi
    state_set '.argo.port = ($p|tonumber)' --arg p "${_p}" || return 1
    apply_config || return 1
    apply_tunnel_service; exec_svc_reload
    exec_svc restart tunnel || log_warn "tunnel 重启失败，请手动重启"
    state_persist || log_warn "state.json 写入失败"
    log_ok "回源端口已更新: ${_p}"; print_nodes
}

# ==============================================================================
# §23 RUNTIME — Cron 自动重启
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
    local _a; prompt "是否安装 cron？(Y/n): " _a
    case "${_a:-y}" in n|N) log_error "cron 不可用"; return 1;; esac
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
    else die "无法安装 cron"; fi
}

exec_setup_auto_restart() {
    local _iv; _iv=$(state_get '.cron')
    ensure_cron || return 1
    local _cmd; is_openrc && _cmd="rc-service xray restart" || _cmd="systemctl restart xray"
    local _t; _t=$(_tmp_file "cron_XXXXXX") || return 1
    { crontab -l 2>/dev/null | grep -v '#xray-restart'
      printf '*/%s * * * * %s >/dev/null 2>&1 #xray-restart\n' "${_iv}" "${_cmd}"
    } > "${_t}"
    crontab "${_t}" || { log_error "crontab 写入失败"; return 1; }
    log_ok "已设置每 ${_iv} 分钟自动重启 xray"
}

exec_remove_auto_restart() {
    command -v crontab >/dev/null 2>&1 || return 0
    local _t; _t=$(_tmp_file "cron_XXXXXX") || return 0
    crontab -l 2>/dev/null | grep -v '#xray-restart' > "${_t}" || true
    crontab "${_t}" 2>/dev/null || true
}

# ==============================================================================
# §24 RUNTIME — 快捷方式与脚本更新
# ==============================================================================
exec_install_shortcut() {
    log_step "拉取最新脚本..."
    local _t; _t=$(_tmp_file "xray2go_XXXXXX.sh") || return 1
    curl -sfL --connect-timeout 15 --max-time 60 -o "${_t}" "${UPSTREAM_URL}" \
        || { log_error "拉取失败，请检查网络"; return 1; }
    bash -n "${_t}" 2>/dev/null || { log_error "脚本语法验证失败，已中止"; return 1; }
    [ -f "${SELF_DEST}" ] && cp -f "${SELF_DEST}" "${SELF_DEST}.bak" 2>/dev/null || true
    mv "${_t}" "${SELF_DEST}" && chmod +x "${SELF_DEST}"
    printf '#!/bin/bash\nexec %s "$@"\n' "${SELF_DEST}" > "${SHORTCUT}"
    chmod +x "${SHORTCUT}"
    log_ok "脚本已更新！输入 ${C_GRN}s${C_RST} 快速启动"
}

# ==============================================================================
# §25 RUNTIME — 状态检测
# ==============================================================================
check_xray() {
    [ -f "${XRAY_BIN}" ] || { printf 'not installed'; return 2; }
    exec_svc status xray && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
}

check_argo() {
    [ "$(state_get '.argo.enabled')" = "true" ] || { printf 'disabled'; return 3; }
    [ -f "${ARGO_BIN}" ]                         || { printf 'not installed'; return 2; }
    exec_svc status tunnel && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
}

# ==============================================================================
# §26 CLI — 安装向导（纯交互输入）
# ==============================================================================
ask_argo_mode() {
    echo ""; log_title "Argo 固定隧道"
    printf "  ${C_GRN}1.${C_RST} 安装 Argo (VLESS+WS/XHTTP+TLS) ${C_YLW}[默认]${C_RST}\n"
    printf "  ${C_GRN}2.${C_RST} 不安装 Argo\n"
    local _c; prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2) state_set '.argo.enabled = false'; log_info "已选：不安装 Argo";;
        *) state_set '.argo.enabled = true';  log_info "已选：安装 Argo";;
    esac; echo ""
}

ask_argo_protocol() {
    echo ""; log_title "Argo 传输协议"
    printf "  ${C_GRN}1.${C_RST} WS ${C_YLW}[默认]${C_RST}\n"
    printf "  ${C_GRN}2.${C_RST} XHTTP (auto)\n"
    local _c; prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2) state_set '.argo.protocol = "xhttp"';;
        *) state_set '.argo.protocol = "ws"';;
    esac
    log_info "已选协议: $(state_get '.argo.protocol')"; echo ""
}

ask_freeflow_mode() {
    echo ""; log_title "FreeFlow（明文 port 8080）"
    printf "  ${C_GRN}1.${C_RST} VLESS + WS\n"
    printf "  ${C_GRN}2.${C_RST} VLESS + HTTPUpgrade\n"
    printf "  ${C_GRN}3.${C_RST} VLESS + XHTTP (stream-one)\n"
    printf "  ${C_GRN}4.${C_RST} 不启用 ${C_YLW}[默认]${C_RST}\n"
    local _c; prompt "请选择 (1-4，回车默认4): " _c
    case "${_c:-4}" in
        1) state_set '.ff.enabled = true | .ff.protocol = "ws"';;
        2) state_set '.ff.enabled = true | .ff.protocol = "httpupgrade"';;
        3) state_set '.ff.enabled = true | .ff.protocol = "xhttp"';;
        *) state_set '.ff.enabled = false | .ff.protocol = "none"'
           log_info "不启用 FreeFlow"; echo ""; return 0;;
    esac
    port_in_use 8080 && log_warn "端口 8080 已被占用，FreeFlow 可能无法启动"
    local _p; prompt "FreeFlow path（回车默认 /）: " _p
    case "${_p:-/}" in /*) :;; *) _p="/${_p}";; esac
    state_set '.ff.path = $p' --arg p "${_p:-/}"
    log_info "已选: $(state_get '.ff.protocol')（path=${_p:-/}）"; echo ""
}

ask_reality_mode() {
    echo ""; log_title "VLESS + Reality（TCP 直连，独立端口）"
    printf "  ${C_GRN}1.${C_RST} 启用 Reality\n"
    printf "  ${C_GRN}2.${C_RST} 不启用 ${C_YLW}[默认]${C_RST}\n"
    local _c; prompt "请选择 (1-2，回车默认2): " _c
    case "${_c:-2}" in
        1) state_set '.reality.enabled = true';;
        *) state_set '.reality.enabled = false'; log_info "不启用 Reality"; echo ""; return 0;;
    esac

    local _dp; _dp=$(state_get '.reality.port')
    local _rp; prompt "监听端口（回车默认 ${_dp}）: " _rp
    if [ -n "${_rp:-}" ]; then
        case "${_rp}" in
            *[!0-9]*) log_warn "端口无效，使用默认值 ${_dp}";;
            *) if [ "${_rp}" -ge 1 ] && [ "${_rp}" -le 65535 ]; then
                   state_set '.reality.port = ($p|tonumber)' --arg p "${_rp}"
               else log_warn "端口超范围，使用默认值 ${_dp}"; fi;;
        esac
    fi
    port_in_use "$(state_get '.reality.port')" && \
        log_warn "端口 $(state_get '.reality.port') 已被占用，可安装后修改"

    local _ds; _ds=$(state_get '.reality.sni')
    log_info "SNI 建议：addons.mozilla.org / www.microsoft.com / www.apple.com"
    local _sni; prompt "伪装 SNI（回车默认 ${_ds}）: " _sni
    if [ -n "${_sni:-}" ]; then
        printf '%s' "${_sni}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
            && state_set '.reality.sni = $s' --arg s "${_sni}" \
            || log_warn "SNI 格式不合法，使用默认值 ${_ds}"
    fi

    echo ""
    printf "  ${C_GRN}1.${C_RST} TCP + XTLS-Vision ${C_YLW}[默认]${C_RST}\n"
    printf "  ${C_GRN}2.${C_RST} XHTTP + Reality (auto)\n"
    local _nc; prompt "传输方式 (1-2，回车默认1): " _nc
    case "${_nc:-1}" in
        2) state_set '.reality.network = "xhttp"'; log_info "已选：XHTTP + Reality";;
        *) state_set '.reality.network = "tcp"';   log_info "已选：TCP + XTLS-Vision";;
    esac
    log_info "Reality 配置完成 — 端口:$(state_get '.reality.port') SNI:$(state_get '.reality.sni') 传输:$(state_get '.reality.network')"
    log_info "密钥对将在安装时自动生成"; echo ""
}

ask_vltcp_mode() {
    echo ""; log_title "VLESS-TCP 明文落地（无加密，用于内网/出口落地）"
    printf "  ${C_GRN}1.${C_RST} 启用 VLESS-TCP\n"
    printf "  ${C_GRN}2.${C_RST} 不启用 ${C_YLW}[默认]${C_RST}\n"
    local _c; prompt "请选择 (1-2，回车默认2): " _c
    case "${_c:-2}" in
        1) state_set '.vltcp.enabled = true';;
        *) state_set '.vltcp.enabled = false'; log_info "不启用 VLESS-TCP"; echo ""; return 0;;
    esac

    local _dp; _dp=$(state_get '.vltcp.port')
    local _vp; prompt "监听端口（回车默认 ${_dp}）: " _vp
    if [ -n "${_vp:-}" ]; then
        case "${_vp}" in
            *[!0-9]*) log_warn "端口无效，使用默认值 ${_dp}";;
            *) if [ "${_vp}" -ge 1 ] && [ "${_vp}" -le 65535 ]; then
                   state_set '.vltcp.port = ($p|tonumber)' --arg p "${_vp}"
               else log_warn "端口超范围，使用默认值 ${_dp}"; fi;;
        esac
    fi
    port_in_use "$(state_get '.vltcp.port')" && \
        log_warn "端口 $(state_get '.vltcp.port') 已被占用，可安装后修改"

    local _dl; _dl=$(state_get '.vltcp.listen')
    local _vl; prompt "监听地址（回车默认 ${_dl}，0.0.0.0=所有接口）: " _vl
    [ -n "${_vl:-}" ] && state_set '.vltcp.listen = $l' --arg l "${_vl}"

    log_info "VLESS-TCP 配置完成 — 端口:$(state_get '.vltcp.port') 监听:$(state_get '.vltcp.listen')"
    echo ""
}

# ==============================================================================
# §27 CLI — 管理子菜单
# ==============================================================================

# 通用端口输入（输出新端口到 stdout，已调用 state_set 更新；失败返回非零）
_input_port() {
    local _jq_path="$1" _p
    prompt "新端口（回车随机）: " _p
    [ -z "${_p:-}" ] && _p=$(shuf -i 1024-65000 -n 1 2>/dev/null || \
                              awk 'BEGIN{srand();print int(rand()*63976)+1024}')
    case "${_p:-}" in ''|*[!0-9]*) log_error "无效端口"; return 1;; esac
    { [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]; } || { log_error "端口超范围"; return 1; }
    if port_in_use "${_p}"; then
        log_warn "端口 ${_p} 已被占用"
        local _a; prompt "仍然继续？(y/N): " _a
        case "${_a:-n}" in y|Y) :;; *) return 1;; esac
    fi
    state_set "${_jq_path} = (\$p|tonumber)" --arg p "${_p}" || return 1
    printf '%s' "${_p}"
}

manage_argo() {
    [ "$(state_get '.argo.enabled')" = "true" ] || { log_warn "未启用 Argo"; sleep 1; return; }
    [ -f "${ARGO_BIN}" ]                         || { log_warn "Argo 未安装"; sleep 1; return; }

    while true; do
        local _astat _domain _proto _port
        _astat=$(check_argo)
        _domain=$(state_get '.argo.domain'); _proto=$(state_get '.argo.protocol')
        _port=$(state_get '.argo.port')

        clear; echo ""; log_title "══ Argo 固定隧道管理 ══"
        printf "  状态: ${C_GRN}%s${C_RST}  协议: ${C_CYN}%s${C_RST}  端口: ${C_YLW}%s${C_RST}\n" \
            "${_astat}" "${_proto}" "${_port}"
        if [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ]; then
            printf "  域名: ${C_GRN}%s${C_RST}\n" "${_domain}"
        else
            printf "  域名: ${C_YLW}未配置（请选项1配置）${C_RST}\n"
        fi
        _hr
        printf "  ${C_GRN}1.${C_RST} 添加/更新固定隧道\n"
        printf "  ${C_GRN}2.${C_RST} 切换协议 (WS ↔ XHTTP)\n"
        printf "  ${C_GRN}3.${C_RST} 修改回源端口 (当前: ${C_YLW}${_port}${C_RST})\n"
        printf "  ${C_GRN}4.${C_RST} 启动隧道\n"
        printf "  ${C_GRN}5.${C_RST} 停止隧道\n"
        printf "  ${C_GRN}6.${C_RST} 健康检查\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c

        case "${_c:-}" in
            1)
                echo ""
                printf "  ${C_GRN}1.${C_RST} WS ${C_YLW}[默认]${C_RST}\n"
                printf "  ${C_GRN}2.${C_RST} XHTTP\n"
                local _pp; prompt "协议 (回车维持 ${_proto}): " _pp
                case "${_pp:-}" in
                    2) state_set '.argo.protocol = "xhttp"';;
                    1) state_set '.argo.protocol = "ws"';;
                esac
                apply_fixed_tunnel && print_nodes || log_error "固定隧道配置失败" ;;
            2)
                local _np; [ "${_proto}" = "ws" ] && _np="xhttp" || _np="ws"
                state_set '.argo.protocol = $p' --arg p "${_np}" || { _pause; continue; }
                if apply_config && state_persist; then
                    log_ok "协议已切换: ${_np}"; print_nodes
                else
                    log_error "切换失败，回滚"
                    state_set '.argo.protocol = $p' --arg p "${_proto}"
                fi ;;
            3) exec_update_argo_port ;;
            4) exec_svc start  tunnel && log_ok "隧道已启动" || log_error "启动失败" ;;
            5) exec_svc stop   tunnel && log_ok "隧道已停止" || log_error "停止失败" ;;
            6) check_argo_health || true ;;   # [v7.1] 新增健康检查入口
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

manage_freeflow() {
    while true; do
        local _en _proto _path
        _en=$(state_get '.ff.enabled'); _proto=$(state_get '.ff.protocol')
        _path=$(state_get '.ff.path')

        clear; echo ""; log_title "══ FreeFlow 管理 ══"
        [ "${_en}" = "true" ] && [ "${_proto}" != "none" ] \
            && printf "  状态: ${C_GRN}已启用${C_RST}  协议: ${C_CYN}%s${C_RST}  path: ${C_YLW}%s${C_RST}\n" \
                "${_proto}" "${_path}" \
            || printf "  状态: ${C_YLW}未启用${C_RST}\n"
        _hr
        printf "  ${C_GRN}1.${C_RST} 添加/变更方式\n"
        printf "  ${C_GRN}2.${C_RST} 修改 path\n"
        printf "  ${C_RED}3.${C_RST} 卸载 FreeFlow\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c

        case "${_c:-}" in
            1)
                ask_freeflow_mode
                apply_config  || { log_error "配置更新失败"; _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                log_ok "FreeFlow 已变更"; print_nodes ;;
            2)
                if [ "${_en}" != "true" ] || [ "${_proto}" = "none" ]; then
                    log_warn "FreeFlow 未启用，请先选择 [1]"; _pause; continue
                fi
                local _p; prompt "新 path（回车保持 ${_path}）: " _p
                if [ -n "${_p:-}" ]; then
                    case "${_p}" in /*) :;; *) _p="/${_p}";; esac
                    state_set '.ff.path = $p' --arg p "${_p}" || { _pause; continue; }
                    apply_config  || { log_error "更新失败"; _pause; continue; }
                    state_persist || log_warn "state.json 写入失败"
                    log_ok "path 已修改: ${_p}"; print_nodes
                fi ;;
            3)
                state_set '.ff.enabled = false | .ff.protocol = "none"' || { _pause; continue; }
                apply_config  || { log_error "卸载失败"; _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                log_ok "FreeFlow 已卸载" ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

manage_reality() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先安装 Xray-2go"; sleep 1; return; }

    while true; do
        local _en _port _sni _pbk _pvk _sid _net _pbk_disp
        _en=$(  state_get '.reality.enabled');  _port=$(state_get '.reality.port')
        _sni=$( state_get '.reality.sni');      _pbk=$(state_get  '.reality.pbk')
        _pvk=$( state_get '.reality.pvk');      _sid=$(state_get  '.reality.sid')
        _net=$( state_get '.reality.network');  _net="${_net:-tcp}"
        _pbk_disp="未生成"
        [ -n "${_pbk:-}" ] && [ "${_pbk}" != "null" ] && _pbk_disp="${_pbk:0:16}..."

        clear; echo ""; log_title "══ Reality 管理 ══"
        [ "${_en}" = "true" ] \
            && printf "  状态: ${C_GRN}已启用${C_RST}\n" \
            || printf "  状态: ${C_YLW}未启用${C_RST}\n"
        printf "  端口: ${C_YLW}%s${C_RST}  SNI: ${C_CYN}%s${C_RST}  传输: ${C_GRN}%s${C_RST}\n" \
            "${_port}" "${_sni}" "${_net}"
        printf "  公钥: %s\n" "${_pbk_disp}"
        [ -n "${_sid:-}" ] && [ "${_sid}" != "null" ] \
            && printf "  ShortId: ${C_CYN}%s${C_RST}\n" "${_sid}"
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用\n"
        printf "  ${C_RED}2.${C_RST} 禁用\n"
        printf "  ${C_GRN}3.${C_RST} 修改端口（当前: ${C_YLW}${_port}${C_RST}）\n"
        printf "  ${C_GRN}4.${C_RST} 修改 SNI（当前: ${C_CYN}${_sni}${C_RST}）\n"
        printf "  ${C_GRN}5.${C_RST} 切换传输方式（当前: ${C_GRN}${_net}${C_RST}）\n"
        printf "  ${C_GRN}6.${C_RST} 重新生成密钥对\n"
        printf "  ${C_GRN}7.${C_RST} 查看节点\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c

        case "${_c:-}" in
            1)
                if [ -z "${_pvk:-}" ] || [ "${_pvk}" = "null" ]; then
                    [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪"; _pause; continue; }
                    _gen_reality_keypair || { _pause; continue; }
                    state_set '.reality.sid = $s' --arg s "$(_gen_reality_sid)" || true
                fi
                state_set '.reality.enabled = true' || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                log_ok "Reality 已启用"; print_nodes ;;
            2)
                state_set '.reality.enabled = false' || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                log_ok "Reality 已禁用" ;;
            3)
                local _np; _np=$(_input_port '.reality.port') || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                # [v7.1] 端口变更后同步防火墙
                open_firewall_port "${_np}" tcp || true
                log_ok "端口已更新: ${_np}"; print_nodes ;;
            4)
                log_info "建议：addons.mozilla.org / www.microsoft.com / www.apple.com"
                local _s; prompt "新 SNI（回车保持 ${_sni}）: " _s
                if [ -n "${_s:-}" ]; then
                    printf '%s' "${_s}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
                        || { log_error "SNI 格式不合法"; _pause; continue; }
                    state_set '.reality.sni = $s' --arg s "${_s}" || { _pause; continue; }
                    apply_config  || { _pause; continue; }
                    state_persist || log_warn "state.json 写入失败"
                    log_ok "SNI 已更新: ${_s}"; print_nodes
                fi ;;
            5)
                local _nn; [ "${_net}" = "tcp" ] && _nn="xhttp" || _nn="tcp"
                state_set '.reality.network = $n' --arg n "${_nn}" || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                log_ok "传输方式已切换: ${_nn}"; print_nodes ;;
            6)
                [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪"; _pause; continue; }
                _gen_reality_keypair || { _pause; continue; }
                state_set '.reality.sid = $s' --arg s "$(_gen_reality_sid)" || { _pause; continue; }
                [ "$(state_get '.reality.enabled')" = "true" ] && apply_config || true
                state_persist || log_warn "state.json 写入失败"
                log_ok "密钥对已更新"
                [ "$(state_get '.reality.enabled')" = "true" ] && print_nodes ;;
            7) print_nodes ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

manage_vltcp() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先安装 Xray-2go"; sleep 1; return; }

    while true; do
        local _en _port _listen
        _en=$(    state_get '.vltcp.enabled')
        _port=$(  state_get '.vltcp.port')
        _listen=$(state_get '.vltcp.listen')

        clear; echo ""; log_title "══ VLESS-TCP 明文落地管理 ══"
        [ "${_en}" = "true" ] \
            && printf "  状态: ${C_GRN}已启用${C_RST}\n" \
            || printf "  状态: ${C_YLW}未启用${C_RST}\n"
        printf "  端口: ${C_YLW}%s${C_RST}  监听: ${C_CYN}%s${C_RST}\n" "${_port}" "${_listen}"
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用\n"
        printf "  ${C_RED}2.${C_RST} 禁用\n"
        printf "  ${C_GRN}3.${C_RST} 修改端口（当前: ${C_YLW}${_port}${C_RST}）\n"
        printf "  ${C_GRN}4.${C_RST} 修改监听地址（当前: ${C_CYN}${_listen}${C_RST}）\n"
        printf "  ${C_GRN}5.${C_RST} 查看节点链接\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c

        case "${_c:-}" in
            1)
                state_set '.vltcp.enabled = true' || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                # [v7.1] 启用时同步防火墙
                open_firewall_port "${_port}" tcp || true
                log_ok "VLESS-TCP 已启用 (端口: ${_port})"; print_nodes ;;
            2)
                state_set '.vltcp.enabled = false' || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                log_ok "VLESS-TCP 已禁用" ;;
            3)
                local _np; _np=$(_input_port '.vltcp.port') || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                # [v7.1] 端口变更后同步防火墙
                open_firewall_port "${_np}" tcp || true
                log_ok "端口已更新: ${_np}"
                [ "${_en}" = "true" ] && print_nodes ;;
            4)
                local _l; prompt "新监听地址（0.0.0.0=所有，127.0.0.1=仅本地）: " _l
                if [ -n "${_l:-}" ]; then
                    state_set '.vltcp.listen = $l' --arg l "${_l}" || { _pause; continue; }
                    apply_config  || { _pause; continue; }
                    state_persist || log_warn "state.json 写入失败"
                    log_ok "监听地址已更新: ${_l}"
                    [ "${_en}" = "true" ] && print_nodes
                fi ;;
            5) print_nodes ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

manage_restart() {
    while true; do
        local _iv; _iv=$(state_get '.cron')
        clear; echo ""; log_title "══ 自动重启管理 ══"
        printf "  当前间隔: ${C_CYN}%s 分钟${C_RST}（0 = 关闭）\n" "${_iv}"; _hr
        printf "  ${C_GRN}1.${C_RST} 设置间隔\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)
                local _v; prompt "间隔分钟（0=关闭，推荐 60）: " _v
                case "${_v:-}" in ''|*[!0-9]*) log_error "无效输入"; _pause; continue;; esac
                state_set '.cron = ($r|tonumber)' --arg r "${_v}" || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                if [ "${_v}" -eq 0 ]; then
                    exec_remove_auto_restart; log_ok "自动重启已关闭"
                else
                    exec_setup_auto_restart
                fi ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ==============================================================================
# §28 CLI — 主菜单
# ==============================================================================
_menu_collect_status() {
    local _xs _cx
    _xs=$(check_xray); _cx=$?
    [ "${_cx}" -eq 0 ] && _MENU_XC="${C_GRN}" || _MENU_XC="${C_RED}"
    _MENU_XS="${_xs}"; _MENU_CX="${_cx}"

    local _as; _as=$(check_argo)
    local _dom; _dom=$(state_get '.argo.domain')
    if [ "$(state_get '.argo.enabled')" = "true" ]; then
        [ -n "${_dom:-}" ] && [ "${_dom}" != "null" ] \
            && _MENU_AD="${_as} [$(state_get '.argo.protocol'), ${_dom}]" \
            || _MENU_AD="${_as} [未配置域名]"
    else _MENU_AD="未启用"; fi

    local _fp _fpa; _fp=$(state_get '.ff.protocol'); _fpa=$(state_get '.ff.path')
    [ "$(state_get '.ff.enabled')" = "true" ] && [ "${_fp}" != "none" ] \
        && _MENU_FD="${_fp} (path=${_fpa})" || _MENU_FD="未启用"

    [ "$(state_get '.reality.enabled')" = "true" ] \
        && _MENU_RD="已启用 (port=$(state_get '.reality.port'), $(state_get '.reality.network'), sni=$(state_get '.reality.sni'))" \
        || _MENU_RD="未启用"

    [ "$(state_get '.vltcp.enabled')" = "true" ] \
        && _MENU_VD="已启用 (port=$(state_get '.vltcp.port'), listen=$(state_get '.vltcp.listen'))" \
        || _MENU_VD="未启用"
}

_menu_render() {
    clear; echo ""
    printf "${C_BOLD}${C_PUR}  ╔══════════════════════════════════════════╗${C_RST}\n"
    printf "${C_BOLD}${C_PUR}  ║           Xray-2go  v7.1  SSOT/AC        ║${C_RST}\n"
    printf "${C_BOLD}${C_PUR}  ╠══════════════════════════════════════════╣${C_RST}\n"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  Xray     : ${_MENU_XC}%-29s${C_RST}${C_PUR} ${C_RST}\n"  "${_MENU_XS}"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  Argo     : %-29s${C_PUR} ${C_RST}\n"  "${_MENU_AD}"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  Reality  : %-29s${C_PUR} ${C_RST}\n"  "${_MENU_RD}"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  VLESS-TCP: %-29s${C_PUR} ${C_RST}\n"  "${_MENU_VD}"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  FF       : %-29s${C_PUR} ${C_RST}\n"  "${_MENU_FD}"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  Cron     : ${C_CYN}%-2s min${C_RST}                         ${C_PUR} ${C_RST}\n" "$(state_get '.cron')"
    printf "${C_BOLD}${C_PUR}  ╚══════════════════════════════════════════╝${C_RST}\n\n"
    printf "  ${C_GRN}1.${C_RST} 安装 Xray-2go\n"
    printf "  ${C_RED}2.${C_RST} 卸载 Xray-2go\n"; _hr
    printf "  ${C_GRN}3.${C_RST} Argo 管理\n"
    printf "  ${C_GRN}4.${C_RST} Reality 管理\n"
    printf "  ${C_GRN}5.${C_RST} VLESS-TCP 管理\n"
    printf "  ${C_GRN}6.${C_RST} FreeFlow 管理\n"; _hr
    printf "  ${C_GRN}7.${C_RST} 查看节点\n"
    printf "  ${C_GRN}8.${C_RST} 修改 UUID\n"
    printf "  ${C_GRN}9.${C_RST} 自动重启管理\n"
    printf "  ${C_GRN}s.${C_RST} 快捷方式/脚本更新\n"; _hr
    printf "  ${C_RED}0.${C_RST} 退出\n\n"
}

_menu_do_install() {
    if [ "${_MENU_CX}" -eq 0 ]; then
        log_warn "Xray-2go 已安装，如需重装请先卸载 (选项 2)"; return
    fi

    ask_argo_mode
    [ "$(state_get '.argo.enabled')" = "true" ] && ask_argo_protocol
    ask_freeflow_mode
    ask_reality_mode
    ask_vltcp_mode

    [ "$(state_get '.argo.enabled')" = "true" ] && \
        port_in_use "$(state_get '.argo.port')" && \
        log_warn "Argo 端口 $(state_get '.argo.port') 已被占用，可安装后修改"
    [ "$(state_get '.ff.enabled')" = "true" ] && port_in_use 8080 && \
        log_warn "端口 8080 已被占用，FreeFlow 可能无法启动"
    if [ "$(state_get '.reality.enabled')" = "true" ]; then
        local _rp _ap
        _rp=$(state_get '.reality.port'); _ap=$(state_get '.argo.port')
        [ "${_rp}" = "${_ap}" ] && \
            log_warn "Reality 端口与 Argo 回源端口相同，请安装后修改其中一个"
    fi
    [ "$(state_get '.vltcp.enabled')" = "true" ] && \
        port_in_use "$(state_get '.vltcp.port')" && \
        log_warn "VLESS-TCP 端口 $(state_get '.vltcp.port') 已被占用，可安装后修改"

    check_bbr
    exec_install_core || { log_error "安装失败"; _pause; return; }
    [ "$(state_get '.argo.enabled')" = "true" ] && \
        { apply_fixed_tunnel || log_error "固定隧道配置失败，请从 [3. Argo 管理] 重新配置"; }
    print_nodes
}

menu() {
    local _MENU_XS="" _MENU_XC="" _MENU_CX=1
    local _MENU_AD="" _MENU_FD="" _MENU_RD="" _MENU_VD=""

    while true; do
        _menu_collect_status
        _menu_render
        local _c; prompt "请输入选择 (0-9/s): " _c; echo ""

        case "${_c:-}" in
            1) _menu_do_install ;;
            2) exec_uninstall ;;
            3) manage_argo ;;
            4) manage_reality ;;
            5) manage_vltcp ;;
            6) manage_freeflow ;;
            7) [ "${_MENU_CX}" -eq 0 ] && print_nodes \
                    || log_warn "Xray-2go 未安装或未运行" ;;
            8) [ -f "${CONFIG_FILE}" ] && exec_update_uuid \
                    || log_warn "请先安装 Xray-2go" ;;
            9) manage_restart ;;
            s) exec_install_shortcut ;;
            0) log_info "已退出"; exit 0 ;;
            *) log_error "无效选项，请输入 0-9 或 s" ;;
        esac
        _pause
    done
}

# ==============================================================================
# §29 入口
# ==============================================================================
main() {
    check_root
    _detect_init
    preflight_check
    _protocol_registry_init
    state_init
    menu
}
main "$@"
