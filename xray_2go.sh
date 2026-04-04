#!/usr/bin/env bash
# ==============================================================================
# xray-2go v6.0
# 协议支持：Argo 固定隧道(WS/XHTTP) · FreeFlow(WS/HTTPUpgrade/XHTTP)
#           Reality Vision(TCP/XHTTP) · VLESS-TCP 明文落地
# 平台支持：Debian/Ubuntu (systemd) · Alpine (OpenRC)
# 架构原则：SSOT(state.json) · 声明式配置合成 · 原子提交验证 · 零持久化节点解析
# ==============================================================================
set -uo pipefail

# ==============================================================================
# §1  全局常量与路径
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

# ==============================================================================
# §2  临时文件沙箱（EXIT trap 统一清理，零泄漏）
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

# 在沙箱中分配临时文件（$1 为 mktemp 模板）
_tmp_file() {
    if [ -z "${_TMP_DIR:-}" ]; then
        _TMP_DIR=$(mktemp -d /tmp/xray2go_XXXXXX) \
            || { printf '\033[1;91m[ERR ] 无法创建临时目录\033[0m\n' >&2; exit 1; }
    fi
    mktemp "${_TMP_DIR}/${1:-tmp_XXXXXX}"
}

# ==============================================================================
# §3  UI 层（日志 · Spinner · 交互）
# ==============================================================================
readonly C_RST=$'\033[0m'  C_BOLD=$'\033[1m'
readonly C_RED=$'\033[1;91m'  C_GRN=$'\033[1;32m'  C_YLW=$'\033[1;33m'
readonly C_PUR=$'\033[1;35m'  C_CYN=$'\033[1;36m'

log_info()  { printf "${C_CYN}[INFO]${C_RST} %s\n"      "$*"; }
log_ok()    { printf "${C_GRN}[ OK ]${C_RST} %s\n"      "$*"; }
log_warn()  { printf "${C_YLW}[WARN]${C_RST} %s\n"      "$*" >&2; }
log_error() { printf "${C_RED}[ERR ]${C_RST} %s\n"      "$*" >&2; }
log_step()  { printf "${C_PUR}[....] %s${C_RST}\n"      "$*"; }
log_title() { printf "\n${C_BOLD}${C_PUR}%s${C_RST}\n"  "$*"; }
die()       { log_error "$1"; exit "${2:-1}"; }

# 提示走 stderr，read 绑定 /dev/tty（兼容管道场景）
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
# §4  平台检测（业务代码只调用 is_systemd / is_openrc / is_alpine / is_debian）
# ==============================================================================
_INIT_SYS=""   # systemd | openrc
_ARCH_CF=""    # cloudflared 架构
_ARCH_XRAY=""  # xray 架构

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
# §5  工具函数（依赖 · 端口 · IP · URL编码 · 内核版本）
# ==============================================================================
check_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || die "请在 root 下运行脚本"; }

pkg_require() {
    local _pkg="$1" _bin="${2:-$1}"
    command -v "${_bin}" >/dev/null 2>&1 && return 0
    log_step "安装依赖: ${_pkg}"
    if   command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${_pkg}" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then dnf  install -y "${_pkg}" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then yum  install -y "${_pkg}" >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then apk  add        "${_pkg}" >/dev/null 2>&1
    else die "未找到包管理器，无法安装 ${_pkg}"; fi
    hash -r 2>/dev/null || true
    command -v "${_bin}" >/dev/null 2>&1 || die "${_pkg} 安装失败，请手动安装后重试"
    log_ok "${_pkg} 已就绪"
}

preflight_check() {
    log_step "依赖预检..."
    for _d in curl unzip jq; do pkg_require "${_d}"; done
    if ! command -v column >/dev/null 2>&1; then
        log_warn "column 未找到，节点展示将降级为纯文本"
        is_alpine && pkg_require util-linux-misc column 2>/dev/null || true \
                  || pkg_require bsdmainutils    column 2>/dev/null || true
    fi
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

# 内核版本比较（支持 4.9-generic 等非数字后缀）
_kernel_ge() {
    local cur cm cr; cur=$(uname -r)
    cm="${cur%%.*}"; cr="${cur#*.}"; cr="${cr%%.*}"; cr="${cr%%[^0-9]*}"
    [ "${cm}" -gt "$1" ] || { [ "${cm}" -eq "$1" ] && [ "${cr:-0}" -ge "$2" ]; }
}

# ==============================================================================
# §6  环境自愈（BBR · systemd-resolved · 时间同步）
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

check_systemd_resolved() {
    is_debian && is_systemd || return 0
    systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0
    local _s; _s=$(awk -F= '/^DNSStubListener/{gsub(/ /,"",$2);print $2}' \
                    /etc/systemd/resolved.conf 2>/dev/null || printf '')
    [ "${_s:-yes}" != "no" ] && \
        log_info "systemd-resolved stub 127.0.0.53:53 — xray 使用 DoH，无冲突"
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
# §7  SSOT 状态层（state.json 为唯一权威数据源）
#
# Schema:
# {
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
# ==============================================================================
_STATE=""

readonly _STATE_DEFAULT='{
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

# 读取 _STATE 中 jq 路径的值（null/空返回空字符串）
state_get() {
    local _v
    _v=$(printf '%s' "${_STATE}" | jq -r "${1} // empty" 2>/dev/null) || true
    printf '%s' "${_v}"
}

# 原地 jq 变换 _STATE
state_set() {
    local _f="$1"; shift
    local _n
    _n=$(printf '%s' "${_STATE}" | jq "$@" "${_f}" 2>/dev/null) \
        || { log_error "state_set 失败: ${_f}"; return 1; }
    [ -n "${_n:-}" ] && _STATE="${_n}" || { log_error "state_set 返回空 JSON"; return 1; }
}

# 原子持久化 _STATE → STATE_FILE
state_persist() {
    mkdir -p "${WORK_DIR}"
    local _t; _t=$(_tmp_file "state_XXXXXX.json") || return 1
    printf '%s\n' "${_STATE}" | jq . > "${_t}" || { log_error "state 序列化失败"; return 1; }
    mv "${_t}" "${STATE_FILE}"
}

# 补全缺失的 vltcp 节（旧版 state.json 向后兼容）
_state_ensure_vltcp() {
    local _c; _c=$(state_get '.vltcp')
    [ -z "${_c:-}" ] || [ "${_c}" = "null" ] && \
        state_set '.vltcp = {"enabled":false,"port":1234,"listen":"0.0.0.0"}'
}

# 补全缺失的 reality.network 字段
_state_ensure_reality_network() {
    local _c; _c=$(state_get '.reality.network')
    [ -z "${_c:-}" ] || [ "${_c}" = "null" ] && state_set '.reality.network = "tcp"'
}

# 从历代散落 conf 文件迁移到 _STATE（一次性）
_state_migrate_legacy() {
    local _r

    # UUID + Argo port ← config.json
    if [ -f "${CONFIG_FILE}" ]; then
        _r=$(jq -r 'first(.inbounds[]? | select(.protocol=="vless")
                    | .settings.clients[0].id) // empty' "${CONFIG_FILE}" 2>/dev/null || true)
        [ -n "${_r:-}" ] && state_set '.uuid = $u' --arg u "${_r}"
        _r=$(jq -r 'first(.inbounds[]? | select(.listen=="127.0.0.1") | .port) // empty' \
               "${CONFIG_FILE}" 2>/dev/null || true)
        case "${_r:-}" in ''|*[!0-9]*) :;; *)
            state_set '.argo.port = ($p|tonumber)' --arg p "${_r}";; esac
    fi

    # Argo ← argo_mode.conf / argo_protocol.conf / domain_fixed.txt
    _r=$(cat "${WORK_DIR}/argo_mode.conf" 2>/dev/null || true)
    case "${_r:-}" in yes) state_set '.argo.enabled = true';; no) state_set '.argo.enabled = false';; esac
    _r=$(cat "${WORK_DIR}/argo_protocol.conf" 2>/dev/null || true)
    case "${_r:-}" in ws|xhttp) state_set '.argo.protocol = $p' --arg p "${_r}";; esac
    _r=$(cat "${WORK_DIR}/domain_fixed.txt" 2>/dev/null || true)
    [ -n "${_r:-}" ] && state_set '.argo.domain = $d | .argo.mode = "fixed"' --arg d "${_r}"

    # FreeFlow ← freeflow.conf
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

    # Reality ← reality.conf
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

    # Cron ← restart.conf
    _r=$(cat "${WORK_DIR}/restart.conf" 2>/dev/null || true)
    case "${_r:-}" in ''|*[!0-9]*):;; *)
        state_set '.cron = ($r|tonumber)' --arg r "${_r}";; esac

    log_info "已从历史配置文件完成状态迁移"
}

# 初始化 _STATE：STATE_FILE → 迁移 → 默认值
state_init() {
    if [ -f "${STATE_FILE}" ]; then
        local _raw; _raw=$(cat "${STATE_FILE}" 2>/dev/null || true)
        if printf '%s' "${_raw}" | jq -e . >/dev/null 2>&1; then
            _STATE="${_raw}"
            _state_ensure_vltcp
            _state_ensure_reality_network
            # 确保 uuid 非空
            local _u; _u=$(state_get '.uuid')
            [ -z "${_u:-}" ] && state_set '.uuid = $u' --arg u "$(_gen_uuid)"
            return 0
        fi
        log_warn "state.json 损坏，尝试迁移..."
    fi
    _STATE="${_STATE_DEFAULT}"
    _state_migrate_legacy
    local _u; _u=$(state_get '.uuid')
    [ -z "${_u:-}" ] && state_set '.uuid = $u' --arg u "$(_gen_uuid)"
    [ -d "${WORK_DIR}" ] && { state_persist 2>/dev/null || true; log_info "状态已初始化并持久化"; }
}

# ==============================================================================
# §8  密钥生成工具
# ==============================================================================
_gen_uuid() {
    [ -r /proc/sys/kernel/random/uuid ] && { cat /proc/sys/kernel/random/uuid; return; }
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
    awk 'BEGIN{srand()}{h=$0;printf "%s-%s-4%s-%s%s-%s\n",
        substr(h,1,8),substr(h,9,4),substr(h,14,3),
        substr("89ab",int(rand()*4)+1,1),substr(h,18,3),substr(h,21,12)}'
}

# xray x25519 密钥对（2>&1 捕获全部输出，兼容 stderr 输出版本）
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
    state_set '.reality.pvk = $v | .reality.pbk = $b' --arg v "${_pvk}" --arg b "${_pbk}" || return 1
    log_ok "x25519 密钥对已生成 (pubkey: ${_pbk:0:16}...)"
}

_gen_reality_sid() {
    command -v openssl >/dev/null 2>&1 && { openssl rand -hex 8 2>/dev/null; return; }
    od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

# ==============================================================================
# §9  声明式 Inbound 配置引擎
#
# _gen_inbound_snippet <type> → JSON inbound 对象（stdout）
# type: argo | ff | reality | vltcp
# 新增协议：在此处增加 case 分支，config_synthesize 无需修改
# ==============================================================================
readonly _SNIFF='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}'

_gen_inbound_snippet() {
    local _t="$1"
    local _uuid; _uuid=$(state_get '.uuid')

    case "${_t}" in

    # ── Argo（WS 或 XHTTP，回环监听 127.0.0.1，Cloudflare 隧道回源）
    argo)
        local _port _proto
        _port=$(state_get '.argo.port'); _proto=$(state_get '.argo.protocol')
        case "${_proto}" in
            xhttp)
                jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                       --argjson sniff "${_SNIFF}" '{
                    port:$port, listen:"127.0.0.1", protocol:"vless",
                    settings:{clients:[{id:$uuid}], decryption:"none"},
                    streamSettings:{network:"xhttp", security:"none",
                        xhttpSettings:{host:"", path:"/argo", mode:"auto"}},
                    sniffing:$sniff}' ;;
            *)  # ws（默认）
                jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                       --argjson sniff "${_SNIFF}" '{
                    port:$port, listen:"127.0.0.1", protocol:"vless",
                    settings:{clients:[{id:$uuid}], decryption:"none"},
                    streamSettings:{network:"ws", security:"none",
                        wsSettings:{path:"/argo"}},
                    sniffing:$sniff}' ;;
        esac ;;

    # ── FreeFlow（明文 port 8080：WS / HTTPUpgrade / XHTTP）
    ff)
        local _proto _path
        _proto=$(state_get '.ff.protocol'); _path=$(state_get '.ff.path')
        case "${_proto}" in
            ws)
                jq -n --arg uuid "${_uuid}" --arg path "${_path}" \
                       --argjson sniff "${_SNIFF}" '{
                    port:8080, listen:"::", protocol:"vless",
                    settings:{clients:[{id:$uuid}], decryption:"none"},
                    streamSettings:{network:"ws", security:"none",
                        wsSettings:{path:$path}},
                    sniffing:$sniff}' ;;
            httpupgrade)
                jq -n --arg uuid "${_uuid}" --arg path "${_path}" \
                       --argjson sniff "${_SNIFF}" '{
                    port:8080, listen:"::", protocol:"vless",
                    settings:{clients:[{id:$uuid}], decryption:"none"},
                    streamSettings:{network:"httpupgrade", security:"none",
                        httpupgradeSettings:{path:$path}},
                    sniffing:$sniff}' ;;
            xhttp)
                jq -n --arg uuid "${_uuid}" --arg path "${_path}" \
                       --argjson sniff "${_SNIFF}" '{
                    port:8080, listen:"::", protocol:"vless",
                    settings:{clients:[{id:$uuid}], decryption:"none"},
                    streamSettings:{network:"xhttp", security:"none",
                        xhttpSettings:{host:"", path:$path, mode:"stream-one"}},
                    sniffing:$sniff}' ;;
            *) log_error "_gen_inbound_snippet ff: 未知协议 ${_proto}"; return 1 ;;
        esac ;;

    # ── Reality（VLESS + Reality，tcp: xtls-rprx-vision / xhttp: auto）
    reality)
        local _port _sni _pvk _sid _net
        _port=$(state_get '.reality.port'); _sni=$(state_get '.reality.sni')
        _pvk=$(state_get  '.reality.pvk');  _sid=$(state_get  '.reality.sid')
        _net=$(state_get  '.reality.network'); _net="${_net:-tcp}"
        case "${_net}" in
            xhttp)
                jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                       --arg sni "${_sni}" --arg pvk "${_pvk}" --arg sid "${_sid}" \
                       --argjson sniff "${_SNIFF}" '{
                    port:$port, listen:"::", protocol:"vless",
                    settings:{clients:[{id:$uuid}], decryption:"none"},
                    streamSettings:{network:"xhttp", security:"reality",
                        realitySettings:{show:false, dest:($sni+":443"), xver:0,
                            serverNames:[$sni], privateKey:$pvk, shortIds:[$sid]},
                        xhttpSettings:{host:"", path:"/", mode:"auto"}},
                    sniffing:$sniff}' ;;
            *)  # tcp（默认）
                jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                       --arg sni "${_sni}" --arg pvk "${_pvk}" --arg sid "${_sid}" \
                       --argjson sniff "${_SNIFF}" '{
                    port:$port, listen:"::", protocol:"vless",
                    settings:{clients:[{id:$uuid, flow:"xtls-rprx-vision"}], decryption:"none"},
                    streamSettings:{network:"tcp", security:"reality",
                        realitySettings:{show:false, dest:($sni+":443"), xver:0,
                            serverNames:[$sni], privateKey:$pvk, shortIds:[$sid]}},
                    sniffing:$sniff}' ;;
        esac ;;

    # ── VLESS-TCP 明文落地（无安全层，用于内网落地/出口）
    vltcp)
        local _port _listen
        _port=$(state_get '.vltcp.port'); _listen=$(state_get '.vltcp.listen')
        jq -n --argjson port "${_port}" --arg listen "${_listen}" \
               --arg uuid "${_uuid}" --argjson sniff "${_SNIFF}" '{
            port:$port, listen:$listen, protocol:"vless",
            settings:{clients:[{id:$uuid}], decryption:"none"},
            streamSettings:{network:"tcp", security:"none"},
            sniffing:$sniff}' ;;

    *) log_error "_gen_inbound_snippet: 未知类型 '${_t}'"; return 1 ;;
    esac
}

# ==============================================================================
# §10 Xray 配置组装 · 原子提交 · 节点链接生成
# ==============================================================================

# 从 _STATE 合成完整 config.json 到 $1
config_synthesize() {
    local _out="$1" _ibs="[]" _ib

    if [ "$(state_get '.argo.enabled')" = "true" ]; then
        _ib=$(_gen_inbound_snippet argo)   || return 1
        _ibs=$(printf '%s' "${_ibs}" | jq --argjson ib "${_ib}" '. + [$ib]')
    fi

    local _ffp; _ffp=$(state_get '.ff.protocol')
    if [ "$(state_get '.ff.enabled')" = "true" ] && [ "${_ffp}" != "none" ]; then
        _ib=$(_gen_inbound_snippet ff)     || return 1
        _ibs=$(printf '%s' "${_ibs}" | jq --argjson ib "${_ib}" '. + [$ib]')
    fi

    if [ "$(state_get '.reality.enabled')" = "true" ]; then
        local _pvk; _pvk=$(state_get '.reality.pvk')
        if [ -n "${_pvk:-}" ]; then
            _ib=$(_gen_inbound_snippet reality) || return 1
            _ibs=$(printf '%s' "${_ibs}" | jq --argjson ib "${_ib}" '. + [$ib]')
        else
            log_warn "Reality 密钥未就绪，已跳过该入站"
        fi
    fi

    if [ "$(state_get '.vltcp.enabled')" = "true" ]; then
        _ib=$(_gen_inbound_snippet vltcp)  || return 1
        _ibs=$(printf '%s' "${_ibs}" | jq --argjson ib "${_ib}" '. + [$ib]')
    fi

    [ "$(printf '%s' "${_ibs}" | jq 'length')" -eq 0 ] && \
        log_warn "所有入站均已禁用，xray 将以零入站模式运行"

    jq -n --argjson inbounds "${_ibs}" '{
        log:      {access:"/dev/null", error:"/dev/null", loglevel:"none"},
        inbounds: $inbounds,
        dns:      {servers:["https+local://1.1.1.1/dns-query"]},
        outbounds:[{protocol:"freedom", tag:"direct"},
                   {protocol:"blackhole", tag:"block"}]
    }' > "${_out}" || { log_error "config 合成失败"; return 1; }
}

# 原子化提交：合成 → xray-test → mv → 重启
# 验证失败时现场保留为 config_failed.json，原配置不变
config_commit() {
    local _t; _t=$(_tmp_file "xray_next_XXXXXX.json") || return 1
    log_step "合成配置..."
    config_synthesize "${_t}" || return 1

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
    mv "${_t}" "${CONFIG_FILE}" || { log_error "config 写入失败"; return 1; }
    log_ok "config.json 已原子更新"

    if _svc_manager status xray >/dev/null 2>&1; then
        _svc_manager restart xray || { log_error "xray 重启失败"; return 1; }
        log_ok "xray 已重启"
    fi
}

# 从 _STATE 实时生成所有节点链接（零文件 I/O）
_get_share_links() {
    local _uuid _cfip _cfport _ip
    _uuid=$(state_get '.uuid')
    _cfip=$(state_get '.cfip')
    _cfport=$(state_get '.cfport')

    # Argo（WS 或 XHTTP over TLS + CDN）
    if [ "$(state_get '.argo.enabled')" = "true" ]; then
        local _domain _proto
        _domain=$(state_get '.argo.domain'); _proto=$(state_get '.argo.protocol')
        if [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ]; then
            case "${_proto}" in
                xhttp) printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=xhttp&host=%s&path=%%2Fargo&mode=auto#Argo-XHTTP\n' \
                           "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" ;;
                *)     printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=ws&host=%s&path=%%2Fargo%%3Fed%%3D2560#Argo-WS\n' \
                           "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" ;;
            esac
        fi
    fi

    # FreeFlow（明文直连 port 8080）
    local _ffp; _ffp=$(state_get '.ff.protocol')
    if [ "$(state_get '.ff.enabled')" = "true" ] && [ "${_ffp}" != "none" ]; then
        _ip=$(get_realip)
        if [ -n "${_ip:-}" ]; then
            local _path _penc
            _path=$(state_get '.ff.path'); _penc=$(urlencode_path "${_path}")
            case "${_ffp}" in
                ws)          printf 'vless://%s@%s:8080?encryption=none&security=none&type=ws&host=%s&path=%s#FreeFlow-WS\n' \
                                 "${_uuid}" "${_ip}" "${_ip}" "${_penc}" ;;
                httpupgrade) printf 'vless://%s@%s:8080?encryption=none&security=none&type=httpupgrade&host=%s&path=%s#FreeFlow-HTTPUpgrade\n' \
                                 "${_uuid}" "${_ip}" "${_ip}" "${_penc}" ;;
                xhttp)       printf 'vless://%s@%s:8080?encryption=none&security=none&type=xhttp&host=%s&path=%s&mode=stream-one#FreeFlow-XHTTP\n' \
                                 "${_uuid}" "${_ip}" "${_ip}" "${_penc}" ;;
            esac
        else
            log_warn "无法获取服务器 IP，FreeFlow 节点已跳过"
        fi
    fi

    # Reality（tcp: XTLS-Vision / xhttp: XHTTP+Reality）
    if [ "$(state_get '.reality.enabled')" = "true" ]; then
        local _rport _rsni _rpbk _rsid _rnet
        _rport=$(state_get '.reality.port'); _rsni=$(state_get '.reality.sni')
        _rpbk=$(state_get  '.reality.pbk');  _rsid=$(state_get  '.reality.sid')
        _rnet=$(state_get  '.reality.network'); _rnet="${_rnet:-tcp}"
        if [ -n "${_rpbk:-}" ] && [ "${_rpbk}" != "null" ]; then
            _ip=$(get_realip)
            if [ -n "${_ip:-}" ]; then
                case "${_rnet}" in
                    xhttp) printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%%2F&mode=auto#Reality-XHTTP\n' \
                               "${_uuid}" "${_ip}" "${_rport}" "${_rsni}" "${_rpbk}" "${_rsid}" ;;
                    *)     printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#Reality-Vision\n' \
                               "${_uuid}" "${_ip}" "${_rport}" "${_rsni}" "${_rpbk}" "${_rsid}" ;;
                esac
            else
                log_warn "无法获取服务器 IP，Reality 节点已跳过"
            fi
        fi
    fi

    # VLESS-TCP 明文落地
    if [ "$(state_get '.vltcp.enabled')" = "true" ]; then
        local _vport _vlisten _vhost
        _vport=$(state_get '.vltcp.port'); _vlisten=$(state_get '.vltcp.listen')
        [ "${_vlisten}" = "0.0.0.0" ] || [ "${_vlisten}" = "::" ] \
            && _vhost=$(get_realip) || _vhost="${_vlisten}"
        if [ -n "${_vhost:-}" ]; then
            printf 'vless://%s@%s:%s?type=tcp&security=none#VLESS-TCP\n' \
                "${_uuid}" "${_vhost}" "${_vport}"
        else
            log_warn "无法获取服务器 IP，VLESS-TCP 节点已跳过"
        fi
    fi
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
# §11 服务管理层（屏蔽 systemd / OpenRC 差异）
# ==============================================================================
_SYSD_DIRTY=0

_svc_manager() {
    local _act="$1" _name="$2" _rc=0
    if is_systemd; then
        case "${_act}" in
            enable)  systemctl enable   "${_name}" >/dev/null 2>&1; _rc=$? ;;
            disable) systemctl disable  "${_name}" >/dev/null 2>&1; _rc=$? ;;
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

_svc_daemon_reload() {
    is_systemd && [ "${_SYSD_DIRTY}" -eq 1 ] || return 0
    systemctl daemon-reload >/dev/null 2>&1 || true
    _SYSD_DIRTY=0
}

# 幂等写入服务文件（内容不变则跳过）
_svc_write() {
    local _dest="$1" _content="$2"
    local _cur; _cur=$(cat "${_dest}" 2>/dev/null || printf '')
    [ "${_cur}" = "${_content}" ] && return 0
    printf '%s' "${_content}" > "${_dest}"; return 1
}

# 服务单元模板
_tpl_xray_systemd() {
    printf '[Unit]\nDescription=Xray Service\nDocumentation=https://github.com/XTLS/Xray-core\nAfter=network.target nss-lookup.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nExecStart=%s run -c %s\nRestart=on-failure\nRestartPreventExitStatus=23\n\n[Install]\nWantedBy=multi-user.target\n' \
        "${XRAY_BIN}" "${CONFIG_FILE}"
}

_tpl_tunnel_systemd() {
    printf '[Unit]\nDescription=Cloudflare Tunnel\nAfter=network.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nTimeoutStartSec=0\nExecStart=/bin/sh -c '"'"'%s >> %s 2>&1'"'"'\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\n' \
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

_register_xray_service() {
    if is_systemd; then
        _svc_write "/etc/systemd/system/xray.service" "$(_tpl_xray_systemd)" || _SYSD_DIRTY=1
    else
        _svc_write "/etc/init.d/xray" "$(_tpl_xray_openrc)" || chmod +x /etc/init.d/xray
    fi
}

_register_tunnel_service() {
    local _cmd; _cmd=$(_build_tunnel_cmd)
    if is_systemd; then
        _svc_write "/etc/systemd/system/tunnel.service" "$(_tpl_tunnel_systemd "${_cmd}")" \
            || _SYSD_DIRTY=1
    else
        _svc_write "/etc/init.d/tunnel" "$(_tpl_tunnel_openrc "${_cmd}")" \
            || chmod +x /etc/init.d/tunnel
    fi
}

# cloudflared 命令（固定隧道，从 _STATE 派生）
_build_tunnel_cmd() {
    if [ -f "${WORK_DIR}/tunnel.yml" ]; then
        printf '%s tunnel --edge-ip-version auto --config %s run' \
            "${ARGO_BIN}" "${WORK_DIR}/tunnel.yml"
    else
        printf '%s tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token %s' \
            "${ARGO_BIN}" "$(state_get '.argo.token')"
    fi
}

# tunnel.yml（ingress 规则从 _STATE 动态构建）
_gen_argo_config() {
    local _domain="$1" _tid="$2" _cred="$3"
    local _port; _port=$(state_get '.argo.port')
    printf 'tunnel: %s\ncredentials-file: %s\nprotocol: http2\n\ningress:\n  - hostname: %s\n    service: http://localhost:%s\n    originRequest:\n      noTLSVerify: true\n  - service: http_status:404\n' \
        "${_tid}" "${_cred}" "${_domain}" "${_port}" > "${WORK_DIR}/tunnel.yml" \
        || { log_error "tunnel.yml 写入失败"; return 1; }
    log_ok "tunnel.yml 已生成 (${_domain} → localhost:${_port})"
}

# ==============================================================================
# §12 下载层
# ==============================================================================
download_xray() {
    detect_arch
    [ -f "${XRAY_BIN}" ] && { log_info "xray 已存在，跳过下载"; return 0; }
    local _url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${_ARCH_XRAY}.zip"
    local _z; _z=$(_tmp_file "xray_XXXXXX.zip") || return 1
    spinner_start "下载 Xray (${_ARCH_XRAY})"
    curl -sfL --connect-timeout 15 --max-time 120 -o "${_z}" "${_url}"; local _rc=$?
    spinner_stop
    [ "${_rc}" -ne 0 ] && { log_error "Xray 下载失败"; return 1; }
    unzip -t "${_z}" >/dev/null 2>&1 || { log_error "Xray zip 损坏"; return 1; }
    unzip -o "${_z}" xray -d "${WORK_DIR}/" >/dev/null 2>&1 || { log_error "Xray 解压失败"; return 1; }
    [ -f "${XRAY_BIN}" ] || { log_error "解压后未找到 xray 二进制"; return 1; }
    chmod +x "${XRAY_BIN}"
    log_ok "Xray 下载完成 ($(${XRAY_BIN} version 2>/dev/null | head -1 | awk '{print $2}'))"
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
# §13 安装 / 卸载
# ==============================================================================
install_core() {
    clear; log_title "══════════ 安装 Xray-2go v6 ══════════"
    preflight_check
    mkdir -p "${WORK_DIR}" && chmod 750 "${WORK_DIR}"

    download_xray || return 1
    [ "$(state_get '.argo.enabled')" = "true" ] && { download_cloudflared || return 1; }

    # Reality 密钥对（依赖 xray 二进制）
    if [ "$(state_get '.reality.enabled')" = "true" ]; then
        log_step "生成 Reality x25519 密钥对..."
        _gen_reality_keypair || return 1
        state_set '.reality.sid = $s' --arg s "$(_gen_reality_sid)"
    fi

    config_commit || return 1

    _register_xray_service
    [ "$(state_get '.argo.enabled')" = "true" ] && _register_tunnel_service
    _svc_daemon_reload

    if is_openrc; then
        printf '0 0\n' > /proc/sys/net/ipv4/ping_group_range 2>/dev/null || true
        sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts 2>/dev/null || true
        sed -i '2s/.*/::1         localhost/'  /etc/hosts 2>/dev/null || true
    fi

    fix_time_sync

    log_step "启动服务..."
    _svc_manager enable xray
    _svc_manager start  xray   || { log_error "xray 启动失败"; return 1; }
    log_ok "xray 已启动"

    if [ "$(state_get '.argo.enabled')" = "true" ]; then
        _svc_manager enable tunnel
        _svc_manager start  tunnel || { log_error "tunnel 启动失败"; return 1; }
        log_ok "tunnel 已启动"
    fi

    state_persist || log_warn "state.json 写入失败（不影响运行）"
    log_ok "══ 安装完成 ══"
}

uninstall_all() {
    local _a; prompt "确定要卸载 xray-2go？(y/N): " _a
    case "${_a:-n}" in y|Y) :;; *) log_info "已取消"; return;; esac
    log_step "卸载中..."
    remove_auto_restart
    for _s in xray tunnel; do
        _svc_manager stop    "${_s}" 2>/dev/null || true
        _svc_manager disable "${_s}" 2>/dev/null || true
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
# §14 Argo 固定隧道操作
# ==============================================================================
configure_fixed_tunnel() {
    log_info "固定隧道 — 协议: $(state_get '.argo.protocol')  回源端口: $(state_get '.argo.port')"
    echo ""
    local _domain _auth
    prompt "请输入 Argo 域名: " _domain
    case "${_domain:-}" in ''|*' '*|*'/'*|*$'\t'*) log_error "域名格式不合法"; return 1;; esac
    printf '%s' "${_domain}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
        || { log_error "域名格式不合法"; return 1; }

    prompt "请输入 Argo 密钥 (token 或 JSON 内容): " _auth
    [ -z "${_auth:-}" ] && { log_error "密钥不能为空"; return 1; }

    if printf '%s' "${_auth}" | grep -q "TunnelSecret"; then
        printf '%s' "${_auth}" | jq . >/dev/null 2>&1 || { log_error "JSON 凭证格式不合法"; return 1; }
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

    _register_tunnel_service
    _svc_daemon_reload
    _svc_manager enable tunnel 2>/dev/null || true
    config_commit  || return 1
    state_persist  || log_warn "state.json 写入失败"
    _svc_manager restart tunnel || { log_error "tunnel 重启失败"; return 1; }
    log_ok "固定隧道已配置 (domain=${_domain})"
}

# ==============================================================================
# §15 UUID / 端口管理（SSOT 标准工作流）
# ==============================================================================
manage_uuid() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先安装 Xray-2go"; return 1; }
    local _v; prompt "新 UUID（回车自动生成）: " _v
    if [ -z "${_v:-}" ]; then
        _v=$(_gen_uuid) || { log_error "UUID 生成失败"; return 1; }
        log_info "已生成 UUID: ${_v}"
    fi
    printf '%s' "${_v}" | grep -qiE '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' \
        || { log_error "UUID 格式不合法"; return 1; }
    state_set '.uuid = $u' --arg u "${_v}" || return 1
    config_commit  || return 1
    state_persist  || log_warn "state.json 写入失败"
    log_ok "UUID 已更新: ${_v}"; print_nodes
}

manage_port() {
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
    config_commit || return 1
    _register_tunnel_service; _svc_daemon_reload
    _svc_manager restart tunnel || log_warn "tunnel 重启失败，请手动重启"
    state_persist || log_warn "state.json 写入失败"
    log_ok "回源端口已更新: ${_p}"; print_nodes
}

# ==============================================================================
# §16 Cron 自动重启
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

setup_auto_restart() {
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

remove_auto_restart() {
    command -v crontab >/dev/null 2>&1 || return 0
    local _t; _t=$(_tmp_file "cron_XXXXXX") || return 0
    crontab -l 2>/dev/null | grep -v '#xray-restart' > "${_t}" || true
    crontab "${_t}" 2>/dev/null || true
}

# ==============================================================================
# §17 快捷方式 / 脚本更新
# ==============================================================================
install_shortcut() {
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
# §18 状态检测
# ==============================================================================
check_xray() {
    [ -f "${XRAY_BIN}" ] || { printf 'not installed'; return 2; }
    _svc_manager status xray && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
}

check_argo() {
    [ "$(state_get '.argo.enabled')" = "true" ] || { printf 'disabled'; return 3; }
    [ -f "${ARGO_BIN}" ]                         || { printf 'not installed'; return 2; }
    _svc_manager status tunnel && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
}

# ==============================================================================
# §19 交互询问函数（安装向导阶段：纯输入，不含业务逻辑）
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
# §20 管理子菜单
# ==============================================================================

# ── Argo 固定隧道管理
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
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c

        case "${_c:-}" in
            1)
                echo ""
                printf "  ${C_GRN}1.${C_RST} WS ${C_YLW}[默认]${C_RST}\n"; printf "  ${C_GRN}2.${C_RST} XHTTP\n"
                local _pp; prompt "协议 (回车维持 ${_proto}): " _pp
                case "${_pp:-}" in 2) state_set '.argo.protocol = "xhttp"';; 1) state_set '.argo.protocol = "ws"';; esac
                configure_fixed_tunnel && print_nodes || log_error "固定隧道配置失败" ;;
            2)
                local _np; [ "${_proto}" = "ws" ] && _np="xhttp" || _np="ws"
                state_set '.argo.protocol = $p' --arg p "${_np}" || { _pause; continue; }
                if config_commit && state_persist; then
                    log_ok "协议已切换: ${_np}"; print_nodes
                else
                    log_error "切换失败，回滚"
                    state_set '.argo.protocol = $p' --arg p "${_proto}"
                fi ;;
            3) manage_port ;;
            4) _svc_manager start  tunnel && log_ok "隧道已启动" || log_error "启动失败" ;;
            5) _svc_manager stop   tunnel && log_ok "隧道已停止" || log_error "停止失败" ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ── FreeFlow 管理
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
            1) ask_freeflow_mode
               config_commit || { log_error "配置更新失败"; _pause; continue; }
               state_persist  || log_warn "state.json 写入失败"
               log_ok "FreeFlow 已变更"; print_nodes ;;
            2)
                if [ "${_en}" != "true" ] || [ "${_proto}" = "none" ]; then
                    log_warn "FreeFlow 未启用，请先选择 [1]"; _pause; continue
                fi
                local _p; prompt "新 path（回车保持 ${_path}）: " _p
                if [ -n "${_p:-}" ]; then
                    case "${_p}" in /*) :;; *) _p="/${_p}";; esac
                    state_set '.ff.path = $p' --arg p "${_p}" || { _pause; continue; }
                    config_commit  || { log_error "更新失败"; _pause; continue; }
                    state_persist  || log_warn "state.json 写入失败"
                    log_ok "path 已修改: ${_p}"; print_nodes
                fi ;;
            3)
                state_set '.ff.enabled = false | .ff.protocol = "none"' || { _pause; continue; }
                config_commit  || { log_error "卸载失败"; _pause; continue; }
                state_persist  || log_warn "state.json 写入失败"
                log_ok "FreeFlow 已卸载" ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ── Reality 管理
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
                config_commit  || { _pause; continue; }
                state_persist  || log_warn "state.json 写入失败"
                log_ok "Reality 已启用"; print_nodes ;;
            2)
                state_set '.reality.enabled = false' || { _pause; continue; }
                config_commit  || { _pause; continue; }
                state_persist  || log_warn "state.json 写入失败"
                log_ok "Reality 已禁用" ;;
            3)
                local _p; prompt "新端口（回车随机）: " _p
                [ -z "${_p:-}" ] && _p=$(shuf -i 1024-65000 -n 1 2>/dev/null || \
                                         awk 'BEGIN{srand();print int(rand()*63976)+1024}')
                case "${_p:-}" in ''|*[!0-9]*) log_error "无效端口"; _pause; continue;; esac
                { [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]; } \
                    || { log_error "端口超范围"; _pause; continue; }
                if port_in_use "${_p}"; then
                    log_warn "端口 ${_p} 已被占用"
                    local _a; prompt "仍然继续？(y/N): " _a
                    case "${_a:-n}" in y|Y) :;; *) _pause; continue;; esac
                fi
                state_set '.reality.port = ($p|tonumber)' --arg p "${_p}" || { _pause; continue; }
                config_commit  || { _pause; continue; }
                state_persist  || log_warn "state.json 写入失败"
                log_ok "端口已更新: ${_p}"; print_nodes ;;
            4)
                log_info "建议：addons.mozilla.org / www.microsoft.com / www.apple.com"
                local _s; prompt "新 SNI（回车保持 ${_sni}）: " _s
                if [ -n "${_s:-}" ]; then
                    printf '%s' "${_s}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
                        || { log_error "SNI 格式不合法"; _pause; continue; }
                    state_set '.reality.sni = $s' --arg s "${_s}" || { _pause; continue; }
                    config_commit  || { _pause; continue; }
                    state_persist  || log_warn "state.json 写入失败"
                    log_ok "SNI 已更新: ${_s}"; print_nodes
                fi ;;
            5)
                local _nn; [ "${_net}" = "tcp" ] && _nn="xhttp" || _nn="tcp"
                state_set '.reality.network = $n' --arg n "${_nn}" || { _pause; continue; }
                config_commit  || { _pause; continue; }
                state_persist  || log_warn "state.json 写入失败"
                log_ok "传输方式已切换: ${_nn}"; print_nodes ;;
            6)
                [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪"; _pause; continue; }
                _gen_reality_keypair || { _pause; continue; }
                state_set '.reality.sid = $s' --arg s "$(_gen_reality_sid)" || { _pause; continue; }
                [ "$(state_get '.reality.enabled')" = "true" ] && config_commit || true
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

# ── VLESS-TCP 明文落地管理
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
                config_commit  || { _pause; continue; }
                state_persist  || log_warn "state.json 写入失败"
                log_ok "VLESS-TCP 已启用 (端口: ${_port})"; print_nodes ;;
            2)
                state_set '.vltcp.enabled = false' || { _pause; continue; }
                config_commit  || { _pause; continue; }
                state_persist  || log_warn "state.json 写入失败"
                log_ok "VLESS-TCP 已禁用" ;;
            3)
                local _p; prompt "新端口（回车随机）: " _p
                [ -z "${_p:-}" ] && _p=$(shuf -i 1024-65000 -n 1 2>/dev/null || \
                                         awk 'BEGIN{srand();print int(rand()*63976)+1024}')
                case "${_p:-}" in ''|*[!0-9]*) log_error "无效端口"; _pause; continue;; esac
                { [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]; } \
                    || { log_error "端口超范围"; _pause; continue; }
                if port_in_use "${_p}"; then
                    log_warn "端口 ${_p} 已被占用"
                    local _a; prompt "仍然继续？(y/N): " _a
                    case "${_a:-n}" in y|Y) :;; *) _pause; continue;; esac
                fi
                state_set '.vltcp.port = ($p|tonumber)' --arg p "${_p}" || { _pause; continue; }
                config_commit  || { _pause; continue; }
                state_persist  || log_warn "state.json 写入失败"
                log_ok "端口已更新: ${_p}"
                [ "${_en}" = "true" ] && print_nodes ;;
            4)
                local _l; prompt "新监听地址（0.0.0.0=所有，127.0.0.1=仅本地）: " _l
                if [ -n "${_l:-}" ]; then
                    state_set '.vltcp.listen = $l' --arg l "${_l}" || { _pause; continue; }
                    config_commit  || { _pause; continue; }
                    state_persist  || log_warn "state.json 写入失败"
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

# ── 自动重启管理
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
                if [ "${_v}" -eq 0 ]; then remove_auto_restart; log_ok "自动重启已关闭"
                else setup_auto_restart; fi ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ==============================================================================
# §21 主菜单
# ==============================================================================
menu() {
    while true; do
        # 采集状态
        local _xs _cx _xc; _xs=$(check_xray); _cx=$?
        local _as; _as=$(check_argo)
        [ "${_cx}" -eq 0 ] && _xc="${C_GRN}" || _xc="${C_RED}"

        # Argo 显示
        local _ad _dom; _dom=$(state_get '.argo.domain')
        if [ "$(state_get '.argo.enabled')" = "true" ]; then
            [ -n "${_dom:-}" ] && [ "${_dom}" != "null" ] \
                && _ad="${_as} [$(state_get '.argo.protocol'), ${_dom}]" \
                || _ad="${_as} [未配置域名]"
        else _ad="未启用"; fi

        # FF 显示
        local _fp _fpa _fd; _fp=$(state_get '.ff.protocol'); _fpa=$(state_get '.ff.path')
        [ "$(state_get '.ff.enabled')" = "true" ] && [ "${_fp}" != "none" ] \
            && _fd="${_fp} (path=${_fpa})" || _fd="未启用"

        # Reality 显示
        local _rd
        [ "$(state_get '.reality.enabled')" = "true" ] \
            && _rd="已启用 (port=$(state_get '.reality.port'), $(state_get '.reality.network'), sni=$(state_get '.reality.sni'))" \
            || _rd="未启用"

        # VLESS-TCP 显示
        local _vd
        [ "$(state_get '.vltcp.enabled')" = "true" ] \
            && _vd="已启用 (port=$(state_get '.vltcp.port'), listen=$(state_get '.vltcp.listen'))" \
            || _vd="未启用"

        clear; echo ""
        printf "${C_BOLD}${C_PUR}  ╔══════════════════════════════════════════╗${C_RST}\n"
        printf "${C_BOLD}${C_PUR}  ║             Xray-2go   SSOT/AC           ║${C_RST}\n"
        printf "${C_BOLD}${C_PUR}  ╠══════════════════════════════════════════╣${C_RST}\n"
        printf "${C_BOLD}${C_PUR}  ║${C_RST}  Xray     : ${_xc}%-29s${C_RST}${C_PUR} ${C_RST}\n"  "${_xs}"
        printf "${C_BOLD}${C_PUR}  ║${C_RST}  Argo     : %-29s${C_PUR} ${C_RST}\n"  "${_ad}"
        printf "${C_BOLD}${C_PUR}  ║${C_RST}  Reality  : %-29s${C_PUR} ${C_RST}\n"  "${_rd}"
        printf "${C_BOLD}${C_PUR}  ║${C_RST}  VLESS-TCP: %-29s${C_PUR} ${C_RST}\n"  "${_vd}"
        printf "${C_BOLD}${C_PUR}  ║${C_RST}  FF       : %-29s${C_PUR} ${C_RST}\n"  "${_fd}"
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
        local _c; prompt "请输入选择 (0-9/s): " _c; echo ""

        case "${_c:-}" in
            1)
                if [ "${_cx}" -eq 0 ]; then
                    log_warn "Xray-2go 已安装，如需重装请先卸载 (选项 2)"
                else
                    # 安装向导
                    ask_argo_mode
                    [ "$(state_get '.argo.enabled')" = "true" ] && ask_argo_protocol
                    ask_freeflow_mode
                    ask_reality_mode
                    ask_vltcp_mode

                    # 端口冲突检测
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
                    if [ "$(state_get '.vltcp.enabled')" = "true" ]; then
                        port_in_use "$(state_get '.vltcp.port')" && \
                            log_warn "VLESS-TCP 端口 $(state_get '.vltcp.port') 已被占用，可安装后修改"
                    fi

                    check_systemd_resolved
                    check_bbr
                    install_core || { log_error "安装失败"; _pause; continue; }

                    # Argo 固定隧道配置
                    if [ "$(state_get '.argo.enabled')" = "true" ]; then
                        configure_fixed_tunnel \
                            || log_error "固定隧道配置失败，请从 [3. Argo 管理] 重新配置"
                    fi
                    print_nodes
                fi ;;
            2) uninstall_all ;;
            3) manage_argo ;;
            4) manage_reality ;;
            5) manage_vltcp ;;
            6) manage_freeflow ;;
            7) [ "${_cx}" -eq 0 ] && print_nodes || log_warn "Xray-2go 未安装或未运行" ;;
            8) [ -f "${CONFIG_FILE}" ] && manage_uuid || log_warn "请先安装 Xray-2go" ;;
            9) manage_restart ;;
            s) install_shortcut ;;
            0) log_info "已退出"; exit 0 ;;
            *) log_error "无效选项，请输入 0-9 或 s" ;;
        esac
        _pause
    done
}

# ==============================================================================
# §22 入口
# ==============================================================================
main() {
    check_root
    _detect_init
    preflight_check
    state_init
    menu
}

main "$@"
