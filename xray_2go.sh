#!/usr/bin/env bash

set -uo pipefail

# ====================== 初始化与全局变量 ======================

# --- 临时文件沙箱 ---
_TMP_DIR=""
_SPINNER_PID=0

trap '_global_cleanup' EXIT
trap '_int_handler'    INT TERM

# @description 全局清理：杀 spinner、删临时目录、恢复光标
_global_cleanup() {
    [ "${_SPINNER_PID}" -ne 0 ] && kill "${_SPINNER_PID}" 2>/dev/null || true
    [ -n "${_TMP_DIR:-}" ]      && rm -rf "${_TMP_DIR}"   2>/dev/null || true
    tput cnorm 2>/dev/null || true
}

# @description 捕获 INT/TERM 信号，打印中断信息后退出
_int_handler() {
    printf '\n' >&2
    printf '\033[1;91m[ERR ] 已中断\033[0m\n' >&2
    exit 130
}

# @description 懒初始化沙箱目录（首次调用时创建，后续复用）
# @return 沙箱目录路径
_tmp_dir() {
    if [ -z "${_TMP_DIR:-}" ]; then
        _TMP_DIR=$(mktemp -d /tmp/xray2go_XXXXXX) \
            || { printf '\033[1;91m[ERR ] 无法创建临时目录\033[0m\n' >&2; exit 1; }
    fi
    printf '%s' "${_TMP_DIR}"
}

# @description 在沙箱中创建临时文件
# @param $1 mktemp 模板，默认 "tmp_XXXXXX"
# @return 临时文件路径
_tmp_file() { mktemp "$(_tmp_dir)/${1:-tmp_XXXXXX}"; }

# --- FHS 路径常量 ---
readonly WORK_DIR="/etc/xray"
readonly XRAY_BIN="${WORK_DIR}/xray"
readonly ARGO_BIN="${WORK_DIR}/argo"
readonly CONFIG_FILE="${WORK_DIR}/config.json"
readonly STATE_FILE="${WORK_DIR}/state.json"
readonly ARGO_LOG="${WORK_DIR}/argo.log"
readonly SHORTCUT="/usr/local/bin/s"
readonly SELF_DEST="/usr/local/bin/xray2go"
readonly UPSTREAM_URL="https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh"

# --- 平台检测状态 ---
_INIT_SYS=""    # systemd | openrc
_ARCH_CF=""     # cloudflared 架构标识
_ARCH_XRAY=""   # xray 架构标识
_SYSD_DIRTY=0   # deferred daemon-reload 标志

# ====================== 工具函数与日志 ======================

# --- ANSI 颜色 ---
readonly _C_RST=$'\033[0m'
readonly _C_BOLD=$'\033[1m'
readonly _C_RED=$'\033[1;91m'
readonly _C_GRN=$'\033[1;32m'
readonly _C_YLW=$'\033[1;33m'
readonly _C_PUR=$'\033[1;35m'
readonly _C_CYN=$'\033[1;36m'

# --- 日志函数 ---
log_info()  { printf "${_C_CYN}[INFO]${_C_RST} %s\n"      "$*"; }
log_ok()    { printf "${_C_GRN}[ OK ]${_C_RST} %s\n"      "$*"; }
log_warn()  { printf "${_C_YLW}[WARN]${_C_RST} %s\n"      "$*" >&2; }
log_error() { printf "${_C_RED}[ERR ]${_C_RST} %s\n"      "$*" >&2; }
log_step()  { printf "${_C_PUR}[....] %s${_C_RST}\n"      "$*"; }
log_title() { printf "\n${_C_BOLD}${_C_PUR}%s${_C_RST}\n" "$*"; }
die()       { log_error "$1"; exit "${2:-1}"; }

# @description 交互提示：提示走 stderr，read 绑定 /dev/tty
# @param $1 提示文本
# @param $2 接收输入的变量名
prompt() {
    local _msg="$1" _var="$2"
    printf "${_C_RED}%s${_C_RST}" "${_msg}" >&2
    read -r "${_var}" </dev/tty
}

# @description 按回车继续提示
_pause() {
    local _dummy
    printf "${_C_RED}按回车键继续...${_C_RST}" >&2
    read -r _dummy </dev/tty || true
}

_hr()     { printf "${_C_PUR}  ──────────────────────────────────${_C_RST}\n"; }
_hr_dbl() { printf "${_C_PUR}  ══════════════════════════════════${_C_RST}\n"; }

# @description 启动后台 spinner
# @param $1 提示文本
spinner_start() {
    local _msg="$1"
    printf "${_C_CYN}[....] %s${_C_RST}\n" "${_msg}"
    ( local i=0 chars='-\|/'
      while true; do
          printf "\r${_C_CYN}[ %s  ]${_C_RST} %s  " "${chars:$(( i % 4 )):1}" "${_msg}" >&2
          sleep 0.12
          i=$(( i + 1 ))
      done ) &
    _SPINNER_PID=$!
    disown "${_SPINNER_PID}" 2>/dev/null || true
}

# @description 停止 spinner 并清行
spinner_stop() {
    [ "${_SPINNER_PID}" -ne 0 ] && { kill "${_SPINNER_PID}" 2>/dev/null; _SPINNER_PID=0; }
    printf '\r\033[2K' >&2
}

# --- 平台检测 ---

# @description 检测 init 系统（systemd / openrc），结果存入 _INIT_SYS
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

# @description 检测 CPU 架构，填充 _ARCH_CF / _ARCH_XRAY（幂等）
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

# --- 网络工具 ---

# @description 检查端口是否被占用（ss → netstat → /proc/net/tcp 三级降级）
# @param $1 端口号
# @return 0=占用, 1=空闲
port_in_use() {
    local _p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null | awk -v p=":${_p}" '$4~p"$"||$4~p" "{f=1}END{exit !f}'
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | awk -v p=":${_p}" '$4~p"$"||$4~p" "{f=1}END{exit !f}'
        return
    fi
    local _hex; _hex=$(printf '%04X' "${_p}")
    awk -v h="${_hex}" 'NR>1 && substr($2,index($2,":")+1,4)==h {f=1} END{exit !f}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# @description 获取服务器真实 IP（优先 IPv4，CF/特殊 ASN 优先 IPv6）
# @return IP 字符串（IPv6 含方括号）
get_realip() {
    local _ip _org _ipv6
    _ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null) || true
    if [ -z "${_ip:-}" ]; then
        _ipv6=$(curl -sf --max-time 5 https://api6.ipify.org 2>/dev/null) || true
        [ -n "${_ipv6:-}" ] && printf '[%s]' "${_ipv6}" || printf ''
        return
    fi
    _org=$(curl -sf --max-time 5 "https://ipinfo.io/${_ip}/org" 2>/dev/null) || true
    if printf '%s' "${_org:-}" | grep -qiE 'Cloudflare|UnReal|AEZA|Andrei'; then
        _ipv6=$(curl -sf --max-time 5 https://api6.ipify.org 2>/dev/null) || true
        [ -n "${_ipv6:-}" ] && printf '[%s]' "${_ipv6}" || printf '%s' "${_ip}"
    else
        printf '%s' "${_ip}"
    fi
}

# @description 轮询 Argo 日志获取临时域名（指数退避，最多约 44s）
# @return 临时域名字符串，失败返回 1
get_temp_domain() {
    local _d _delay=3 _i=1
    sleep 3
    while [ "${_i}" -le 6 ]; do
        _d=$(grep -o 'https://[^[:space:]]*trycloudflare\.com' \
             "${ARGO_LOG}" 2>/dev/null | head -1 | sed 's|https://||') || true
        [ -n "${_d:-}" ] && printf '%s' "${_d}" && return 0
        sleep "${_delay}"
        _i=$(( _i + 1 ))
        _delay=$(( _delay < 8 ? _delay * 2 : 8 ))
    done
    return 1
}

# @description URL 编码路径字符串
# @param $1 原始路径
# @return 编码后字符串
_urlencode_path() {
    printf '%s' "$1" | sed \
        's/%/%25/g;s/ /%20/g;s/!/%21/g;s/"/%22/g;s/#/%23/g;
         s/\$/%24/g;s/&/%26/g;s/'\''/%27/g;s/(/%28/g;s/)/%29/g;
         s/\*/%2A/g;s/+/%2B/g;s/,/%2C/g;s/:/%3A/g;s/;/%3B/g;
         s/=/%3D/g;s/?/%3F/g;s/@/%40/g;s/\[/%5B/g;s/\]/%5D/g'
}

# --- 环境自愈 ---

# @description 检查 root 权限
check_root() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || die "请在 root 下运行脚本"
}

# @description 安装单个软件包（支持 apt/dnf/yum/apk）
# @param $1 包名
# @param $2 可执行文件名（默认同包名）
pkg_require() {
    local _pkg="$1" _bin="${2:-$1}"
    command -v "${_bin}" >/dev/null 2>&1 && return 0
    log_step "安装依赖: ${_pkg}"
    if   command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${_pkg}" >/dev/null 2>&1
    elif command -v dnf     >/dev/null 2>&1; then dnf  install -y "${_pkg}" >/dev/null 2>&1
    elif command -v yum     >/dev/null 2>&1; then yum  install -y "${_pkg}" >/dev/null 2>&1
    elif command -v apk     >/dev/null 2>&1; then apk  add        "${_pkg}" >/dev/null 2>&1
    else die "未找到包管理器，无法安装 ${_pkg}"
    fi
    hash -r 2>/dev/null || true
    command -v "${_bin}" >/dev/null 2>&1 || die "${_pkg} 安装失败，请手动安装后重试"
    log_ok "${_pkg} 已就绪"
}

# @description 依赖预检：强制(curl/unzip/jq) + 可选(column/openssl) + 二进制完整性
preflight_check() {
    log_step "依赖预检..."
    for _d in curl unzip jq; do pkg_require "${_d}"; done

    # column 可选（节点格式化）
    if ! command -v column >/dev/null 2>&1; then
        log_warn "column 未找到，节点展示将降级为纯文本"
        if is_alpine; then
            pkg_require util-linux-misc column 2>/dev/null || true
        else
            pkg_require bsdmainutils column 2>/dev/null || true
        fi
    fi

    # openssl 可选（Reality shortId 备用随机源）
    command -v openssl >/dev/null 2>&1 \
        || log_info "openssl 未安装 — Reality shortId 将由 /dev/urandom 生成（无影响）"

    # xray 二进制完整性
    if [ -f "${XRAY_BIN}" ]; then
        [ -x "${XRAY_BIN}" ] || { chmod +x "${XRAY_BIN}"; log_warn "已修复 xray 可执行位"; }
        "${XRAY_BIN}" version >/dev/null 2>&1 \
            || log_warn "xray 二进制可能损坏，建议通过菜单重新安装"
    fi

    # cloudflared 可执行位修复
    [ -f "${ARGO_BIN}" ] && ! [ -x "${ARGO_BIN}" ] \
        && { chmod +x "${ARGO_BIN}"; log_warn "已修复 cloudflared 可执行位"; }

    log_ok "依赖预检通过"
}

# @description BBR 检测与可选启用
check_bbr() {
    local _algo; _algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')
    [ "${_algo}" = "bbr" ] && { log_ok "TCP BBR 已启用"; return 0; }
    log_warn "当前拥塞控制: ${_algo}（推荐 BBR）"
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

# @description Debian 12 专项：systemd-resolved stub 检测（xray 用 DoH 无冲突，仅告知）
check_systemd_resolved() {
    is_debian  || return 0
    is_systemd || return 0
    systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0
    local _stub; _stub=$(awk -F= '/^DNSStubListener/{gsub(/ /,"",$2); print $2}' \
                         /etc/systemd/resolved.conf 2>/dev/null || printf '')
    [ "${_stub:-yes}" != "no" ] && \
        log_info "systemd-resolved stub 127.0.0.53:53 — xray 使用 DoH，无冲突"
}

# @description RHEL/CentOS 时间同步修正（时间偏差会导致 TLS 握手失败）
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

# @description 内核版本比较（支持 4.9-generic 等非数字后缀格式）
# @param $1 主版本号
# @param $2 次版本号
# @return 0=当前内核>=目标版本
_kernel_ge() {
    local cur; cur=$(uname -r)
    local cm="${cur%%.*}"
    local cr="${cur#*.}"; cr="${cr%%.*}"; cr="${cr%%[^0-9]*}"
    [ "${cm}" -gt "$1" ] || { [ "${cm}" -eq "$1" ] && [ "${cr:-0}" -ge "$2" ]; }
}

# ====================== 状态管理 (state.json) ======================

# --- SSOT 内存状态 ---
_STATE=""

# state.json Schema（含 SOCKS5 节，向后兼容旧版本）：
# {
#   "uuid":    "<自动生成>",
#   "argo":    { "enabled":true,  "protocol":"ws",   "port":8888,
#                "mode":"temp",   "domain":null,      "token":null },
#   "ff":      { "enabled":false, "protocol":"none", "path":"/" },
#   "reality": { "enabled":false, "port":443, "sni":"addons.mozilla.org",
#                "pbk":null, "pvk":null, "sid":null },
#   "socks5":  { "enabled":false, "port":18888, "listen":"0.0.0.0",
#                "auth":"noauth", "user":"", "pass":"" },
#   "cron":    0,
#   "cfip":    "cf.tencentapp.cn",
#   "cfport":  "443"
# }
readonly _STATE_DEFAULT='{
  "uuid":    "",
  "argo":    {"enabled":true,  "protocol":"ws",   "port":8888,
              "mode":"temp",   "domain":null,      "token":null},
  "ff":      {"enabled":false, "protocol":"none", "path":"/"},
  "reality": {"enabled":false, "port":443, "sni":"addons.mozilla.org",
              "pbk":null, "pvk":null, "sid":null},
  "socks5":  {"enabled":false, "port":18888, "listen":"0.0.0.0",
              "auth":"noauth", "user":"", "pass":""},
  "cron":    0,
  "cfip":    "cf.tencentapp.cn",
  "cfport":  "443"
}'

# @description 读取 _STATE 中指定 jq 路径的值（null/空返回空字符串）
# @param $1 jq 路径表达式
# @return 字段字符串值
state_get() {
    local _val
    _val=$(printf '%s' "${_STATE}" | jq -r "${1} // empty" 2>/dev/null) || true
    printf '%s' "${_val}"
}

# @description 更新 _STATE 中的字段（原地 jq 变换）
# @param $1 jq filter 表达式
# @param ... 额外 jq 参数（--arg/--argjson）
state_set() {
    local _filter="$1"; shift
    local _new
    _new=$(printf '%s' "${_STATE}" | jq "$@" "${_filter}" 2>/dev/null) \
        || { log_error "state_set 失败: ${_filter}"; return 1; }
    [ -n "${_new:-}" ] && _STATE="${_new}" || { log_error "state_set 返回空 JSON"; return 1; }
}

# @description 原子持久化 _STATE 到 STATE_FILE（tmp → mv，保证写入完整性）
state_persist() {
    mkdir -p "${WORK_DIR}"
    local _tmp; _tmp=$(_tmp_file "state_XXXXXX.json") || return 1
    printf '%s\n' "${_STATE}" | jq . > "${_tmp}" \
        || { log_error "state 序列化失败"; return 1; }
    mv "${_tmp}" "${STATE_FILE}"
}

# @description 确保 _STATE 中 uuid 字段非空，缺失时自动生成
_state_ensure_uuid() {
    local _u; _u=$(state_get '.uuid')
    [ -z "${_u:-}" ] && state_set '.uuid = $u' --arg u "$(_gen_uuid)"
}

# @description 确保旧版 state.json 缺少 socks5 节时自动补全默认值（向后兼容）
_state_ensure_socks5() {
    local _check; _check=$(state_get '.socks5')
    if [ -z "${_check:-}" ] || [ "${_check}" = "null" ]; then
        state_set '.socks5 = {"enabled":false,"port":18888,"listen":"0.0.0.0",
                              "auth":"noauth","user":"","pass":""}'
    fi
}

# @description 从 v2 散落配置文件迁移到 _STATE（一次性，无副作用）
_state_migrate_v2() {
    local _raw

    # UUID + Argo port ← config.json
    if [ -f "${CONFIG_FILE}" ]; then
        _raw=$(jq -r 'first(.inbounds[]? | select(.protocol=="vless")
                      | .settings.clients[0].id) // empty' "${CONFIG_FILE}" 2>/dev/null || true)
        [ -n "${_raw:-}" ] && state_set '.uuid = $u' --arg u "${_raw}"

        _raw=$(jq -r 'first(.inbounds[]? | select(.listen=="127.0.0.1") | .port) // empty' \
               "${CONFIG_FILE}" 2>/dev/null || true)
        case "${_raw:-}" in ''|*[!0-9]*) : ;; *)
            state_set '.argo.port = ($p|tonumber)' --arg p "${_raw}" ;; esac
    fi

    # Argo mode ← argo_mode.conf
    _raw=$(cat "${WORK_DIR}/argo_mode.conf" 2>/dev/null || true)
    case "${_raw:-}" in
        yes) state_set '.argo.enabled = true'  ;;
        no)  state_set '.argo.enabled = false' ;;
    esac

    # Argo protocol ← argo_protocol.conf
    _raw=$(cat "${WORK_DIR}/argo_protocol.conf" 2>/dev/null || true)
    case "${_raw:-}" in ws|xhttp)
        state_set '.argo.protocol = $p' --arg p "${_raw}" ;; esac

    # Argo fixed domain ← domain_fixed.txt
    _raw=$(cat "${WORK_DIR}/domain_fixed.txt" 2>/dev/null || true)
    [ -n "${_raw:-}" ] && state_set '.argo.domain = $d | .argo.mode = "fixed"' --arg d "${_raw}"

    # FreeFlow ← freeflow.conf (line1=protocol, line2=path)
    if [ -f "${WORK_DIR}/freeflow.conf" ]; then
        local _l1 _l2
        _l1=$(sed -n '1p' "${WORK_DIR}/freeflow.conf" 2>/dev/null || true)
        _l2=$(sed -n '2p' "${WORK_DIR}/freeflow.conf" 2>/dev/null || true)
        case "${_l1:-}" in
            ws|httpupgrade|xhttp)
                state_set '.ff.enabled = true | .ff.protocol = $p' --arg p "${_l1}" ;;
            none|"")
                state_set '.ff.enabled = false | .ff.protocol = "none"' ;;
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
        case "${_rp:-}" in ''|*[!0-9]*) : ;; *)
            state_set '.reality.port = ($p|tonumber)' --arg p "${_rp}" ;; esac
        [ -n "${_rs:-}"   ] && state_set '.reality.sni = $s' --arg s "${_rs}"
        [ -n "${_rpbk:-}" ] && state_set '.reality.pbk = $k' --arg k "${_rpbk}"
        [ -n "${_rpvk:-}" ] && state_set '.reality.pvk = $k' --arg k "${_rpvk}"
        [ -n "${_rsid:-}" ] && state_set '.reality.sid = $s' --arg s "${_rsid}"
    fi

    # Cron interval ← restart.conf
    _raw=$(cat "${WORK_DIR}/restart.conf" 2>/dev/null || true)
    case "${_raw:-}" in ''|*[!0-9]*) : ;; *)
        state_set '.cron = ($r|tonumber)' --arg r "${_raw}" ;; esac

    log_info "已从 v2 配置文件完成状态迁移"
}

# @description 初始化 _STATE：优先读 STATE_FILE，否则迁移 v2 数据，否则用默认值
state_init() {
    if [ -f "${STATE_FILE}" ]; then
        local _raw; _raw=$(cat "${STATE_FILE}" 2>/dev/null || true)
        if printf '%s' "${_raw}" | jq -e . >/dev/null 2>&1; then
            _STATE="${_raw}"
            # 补全旧版本缺少的 socks5 节（向后兼容）
            _state_ensure_socks5
            _state_ensure_uuid
            return 0
        fi
        log_warn "state.json 损坏，尝试迁移..."
    fi

    _STATE="${_STATE_DEFAULT}"
    _state_migrate_v2
    _state_ensure_uuid

    if [ -d "${WORK_DIR}" ]; then
        state_persist 2>/dev/null || true
        log_info "状态已初始化并持久化"
    fi
}

# --- UUID / Reality 密钥生成 ---

# @description 生成 UUID v4（优先内核接口，降级 od+awk）
# @return UUID 字符串
_gen_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
        awk 'BEGIN{srand()} {h=$0; printf "%s-%s-4%s-%s%s-%s\n",
            substr(h,1,8), substr(h,9,4), substr(h,14,3),
            substr("89ab",int(rand()*4)+1,1), substr(h,18,3), substr(h,21,12)}'
    fi
}

# @description 调用 xray x25519 生成 Reality 密钥对并写入 _STATE
# 修复说明：xray 部分构建版本将密钥输出到 stderr，统一用 2>&1 捕获，
#           并用 grep -i + tr -d '\r' 消除大小写变体和 CRLF 污染
_gen_reality_keypair() {
    [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪，无法生成密钥对"; return 1; }

    local _out _rc
    _out=$("${XRAY_BIN}" x25519 2>&1)
    _rc=$?

    if [ "${_rc}" -ne 0 ]; then
        log_error "xray x25519 执行失败 (exit ${_rc})"
        [ -n "${_out:-}" ] && printf '%s\n' "${_out}" | while IFS= read -r _l; do
            log_error "  xray: ${_l}"
        done
        return 1
    fi

    [ -z "${_out:-}" ] && {
        log_error "xray x25519 无任何输出，二进制可能损坏（尝试重新安装）"
        return 1
    }

    local _pvk _pbk
    _pvk=$(printf '%s\n' "${_out}" | grep -i 'private' | awk '{print $NF}' | tr -d '\r\n')
    _pbk=$(printf '%s\n' "${_out}" | grep -i 'public'  | awk '{print $NF}' | tr -d '\r\n')

    if [ -z "${_pvk:-}" ] || [ -z "${_pbk:-}" ]; then
        log_error "密钥字段解析失败 — xray x25519 原始输出:"
        printf '%s\n' "${_out}" | while IFS= read -r _l; do log_error "  xray: ${_l}"; done
        log_error "如持续失败请通过 [选项 2. 卸载] 后重装以更新 xray 二进制"
        return 1
    fi

    local _b64url='^[A-Za-z0-9_=-]{20,}$'
    printf '%s' "${_pvk}" | grep -qE "${_b64url}" \
        || { log_error "私钥格式异常: ${_pvk}"; return 1; }
    printf '%s' "${_pbk}" | grep -qE "${_b64url}" \
        || { log_error "公钥格式异常: ${_pbk}"; return 1; }

    state_set '.reality.pvk = $v | .reality.pbk = $b' \
        --arg v "${_pvk}" --arg b "${_pbk}" || return 1
    log_ok "x25519 密钥对已生成 (pubkey: ${_pbk:0:16}...)"
}

# @description 生成 Reality shortId（8 字节十六进制，优先 openssl，降级 od）
# @return 16 字符十六进制字符串
_gen_reality_sid() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 8 2>/dev/null
    else
        od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

# ====================== Inbound 配置生成 ======================

# 全局 sniffing 配置（所有 inbound 共用）
readonly _SNIFF_JSON='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}'

# @description 声明式 inbound 生成插件（jq 驱动，所有字段经 --arg 序列化）
# @param $1 类型：argo | ff | reality | socks5
# @return JSON inbound 对象（stdout）
_gen_inbound_snippet() {
    local _type="$1"
    local _uuid; _uuid=$(state_get '.uuid')

    case "${_type}" in

        # ── Argo（WS 或 XHTTP，回环监听 127.0.0.1）
        argo)
            local _port _proto
            _port=$(state_get '.argo.port')
            _proto=$(state_get '.argo.protocol')
            case "${_proto}" in
                xhttp)
                    jq -n \
                        --argjson port  "${_port}" \
                        --arg     uuid  "${_uuid}" \
                        --argjson sniff "${_SNIFF_JSON}" '{
                        port:$port, listen:"127.0.0.1", protocol:"vless",
                        settings:{clients:[{id:$uuid}], decryption:"none"},
                        streamSettings:{network:"xhttp", security:"none",
                            xhttpSettings:{host:"", path:"/argo", mode:"auto"}},
                        sniffing:$sniff
                    }' ;;
                *)  # ws（默认）
                    jq -n \
                        --argjson port  "${_port}" \
                        --arg     uuid  "${_uuid}" \
                        --argjson sniff "${_SNIFF_JSON}" '{
                        port:$port, listen:"127.0.0.1", protocol:"vless",
                        settings:{clients:[{id:$uuid}], decryption:"none"},
                        streamSettings:{network:"ws", security:"none",
                            wsSettings:{path:"/argo"}},
                        sniffing:$sniff
                    }' ;;
            esac ;;

        # ── FreeFlow（明文 port 8080，WS/HTTPUpgrade/XHTTP）
        ff)
            local _ff_proto _ff_path
            _ff_proto=$(state_get '.ff.protocol')
            _ff_path=$( state_get '.ff.path')
            case "${_ff_proto}" in
                ws)
                    jq -n \
                        --arg uuid  "${_uuid}" \
                        --arg path  "${_ff_path}" \
                        --argjson sniff "${_SNIFF_JSON}" '{
                        port:8080, listen:"::", protocol:"vless",
                        settings:{clients:[{id:$uuid}], decryption:"none"},
                        streamSettings:{network:"ws", security:"none",
                            wsSettings:{path:$path}},
                        sniffing:$sniff
                    }' ;;
                httpupgrade)
                    jq -n \
                        --arg uuid  "${_uuid}" \
                        --arg path  "${_ff_path}" \
                        --argjson sniff "${_SNIFF_JSON}" '{
                        port:8080, listen:"::", protocol:"vless",
                        settings:{clients:[{id:$uuid}], decryption:"none"},
                        streamSettings:{network:"httpupgrade", security:"none",
                            httpupgradeSettings:{path:$path}},
                        sniffing:$sniff
                    }' ;;
                xhttp)
                    jq -n \
                        --arg uuid  "${_uuid}" \
                        --arg path  "${_ff_path}" \
                        --argjson sniff "${_SNIFF_JSON}" '{
                        port:8080, listen:"::", protocol:"vless",
                        settings:{clients:[{id:$uuid}], decryption:"none"},
                        streamSettings:{network:"xhttp", security:"none",
                            xhttpSettings:{host:"", path:$path, mode:"stream-one"}},
                        sniffing:$sniff
                    }' ;;
                *) log_error "_gen_inbound_snippet ff: 未知协议 ${_ff_proto}"; return 1 ;;
            esac ;;

        # ── Reality（VLESS + TCP + XTLS-Vision）
        reality)
            local _r_port _r_sni _r_pvk _r_sid
            _r_port=$(state_get '.reality.port')
            _r_sni=$( state_get '.reality.sni')
            _r_pvk=$( state_get '.reality.pvk')
            _r_sid=$( state_get '.reality.sid')
            jq -n \
                --argjson port  "${_r_port}" \
                --arg     uuid  "${_uuid}" \
                --arg     sni   "${_r_sni}" \
                --arg     pvk   "${_r_pvk}" \
                --arg     sid   "${_r_sid}" \
                --argjson sniff "${_SNIFF_JSON}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid, flow:"xtls-rprx-vision"}], decryption:"none"},
                streamSettings:{network:"tcp", security:"reality",
                    realitySettings:{show:false, dest:($sni+":443"), xver:0,
                        serverNames:[$sni], privateKey:$pvk, shortIds:[$sid]}},
                sniffing:$sniff
            }' ;;

        # ── SOCKS5（noauth 或 password 两种认证模式）
        socks5)
            local _s5_port _s5_listen _s5_auth _s5_user _s5_pass
            _s5_port=$(  state_get '.socks5.port')
            _s5_listen=$(state_get '.socks5.listen')
            _s5_auth=$(  state_get '.socks5.auth')
            _s5_user=$(  state_get '.socks5.user')
            _s5_pass=$(  state_get '.socks5.pass')

            if [ "${_s5_auth}" = "password" ]; then
                # 密码认证模式
                jq -n \
                    --argjson port    "${_s5_port}" \
                    --arg     listen  "${_s5_listen}" \
                    --arg     user    "${_s5_user}" \
                    --arg     pass    "${_s5_pass}" '{
                    port:$port, listen:$listen, protocol:"socks",
                    settings:{
                        auth:"password",
                        accounts:[{user:$user, pass:$pass}],
                        udp:true
                    }
                }'
            else
                # 无认证模式（noauth）
                jq -n \
                    --argjson port   "${_s5_port}" \
                    --arg     listen "${_s5_listen}" '{
                    port:$port, listen:$listen, protocol:"socks",
                    settings:{auth:"noauth", udp:true}
                }'
            fi ;;

        *) log_error "_gen_inbound_snippet: 未知类型 '${_type}'"; return 1 ;;
    esac
}

# ====================== Xray 配置组装与验证 ======================

# @description 从 _STATE 合成完整 config.json 到指定输出文件
# @param $1 输出文件路径
config_synthesize() {
    local _outfile="$1"
    local _ibs="[]" _ib

    # Argo inbound
    if [ "$(state_get '.argo.enabled')" = "true" ]; then
        _ib=$(_gen_inbound_snippet argo) || return 1
        _ibs=$(printf '%s' "${_ibs}" | jq --argjson ib "${_ib}" '. + [$ib]')
    fi

    # FreeFlow inbound
    local _ff_proto; _ff_proto=$(state_get '.ff.protocol')
    if [ "$(state_get '.ff.enabled')" = "true" ] && [ "${_ff_proto}" != "none" ]; then
        _ib=$(_gen_inbound_snippet ff) || return 1
        _ibs=$(printf '%s' "${_ibs}" | jq --argjson ib "${_ib}" '. + [$ib]')
    fi

    # Reality inbound
    if [ "$(state_get '.reality.enabled')" = "true" ]; then
        local _pvk; _pvk=$(state_get '.reality.pvk')
        if [ -n "${_pvk:-}" ]; then
            _ib=$(_gen_inbound_snippet reality) || return 1
            _ibs=$(printf '%s' "${_ibs}" | jq --argjson ib "${_ib}" '. + [$ib]')
        else
            log_warn "Reality 密钥未就绪，已跳过该入站"
        fi
    fi

    # SOCKS5 inbound
    if [ "$(state_get '.socks5.enabled')" = "true" ]; then
        _ib=$(_gen_inbound_snippet socks5) || return 1
        _ibs=$(printf '%s' "${_ibs}" | jq --argjson ib "${_ib}" '. + [$ib]')
    fi

    # 零入站警告（不阻断）
    [ "$(printf '%s' "${_ibs}" | jq 'length')" -eq 0 ] && \
        log_warn "所有入站均已禁用，xray 将以零入站模式运行（无可用节点）"

    jq -n --argjson inbounds "${_ibs}" '{
        log:      {access:"/dev/null", error:"/dev/null", loglevel:"none"},
        inbounds: $inbounds,
        dns:      {servers:["https+local://1.1.1.1/dns-query"]},
        outbounds:[
            {protocol:"freedom",   tag:"direct"},
            {protocol:"blackhole", tag:"block"}
        ]
    }' > "${_outfile}" || { log_error "config 合成失败"; return 1; }
}

# @description 原子化提交：合成 → xray-test → mv → 重启
# 失败时保留现场文件 config_failed.json，原配置保持不变
config_commit() {
    local _tmp; _tmp=$(_tmp_file "xray_next_XXXXXX.json") || return 1

    log_step "合成配置..."
    config_synthesize "${_tmp}" || return 1

    if [ -x "${XRAY_BIN}" ]; then
        log_step "验证配置 (xray -test)..."
        if ! "${XRAY_BIN}" -test -c "${_tmp}" >/dev/null 2>&1; then
            log_error "config 验证失败！现场已保留于 ${WORK_DIR}/config_failed.json"
            mv "${_tmp}" "${WORK_DIR}/config_failed.json" 2>/dev/null || true
            return 1
        fi
        log_ok "config 验证通过"
    else
        log_warn "xray 二进制未就绪，跳过预检（安装阶段正常）"
    fi

    mkdir -p "${WORK_DIR}"
    mv "${_tmp}" "${CONFIG_FILE}" || { log_error "config 写入失败"; return 1; }
    log_ok "config.json 已原子更新"

    if _svc_manager status xray >/dev/null 2>&1; then
        _svc_manager restart xray || { log_error "xray 重启失败"; return 1; }
        log_ok "xray 已重启"
    fi
}

# @description 从 _STATE 实时生成所有节点 share links（零文件 I/O）
# @return 每行一个链接，stdout 输出
_get_share_links() {
    local _uuid _cfip _cfport _ip
    _uuid=$(state_get '.uuid')
    _cfip=$(state_get '.cfip')
    _cfport=$(state_get '.cfport')

    # ── Argo 链接（WS 或 XHTTP over TLS + CDN）
    if [ "$(state_get '.argo.enabled')" = "true" ]; then
        local _domain _proto
        _domain=$(state_get '.argo.domain')
        _proto=$(state_get '.argo.protocol')
        if [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ]; then
            case "${_proto}" in
                xhttp)
                    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=xhttp&host=%s&path=%%2Fargo&mode=auto#Argo-XHTTP\n' \
                        "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" ;;
                *)
                    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=ws&host=%s&path=%%2Fargo%%3Fed%%3D2560#Argo-WS\n' \
                        "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" ;;
            esac
        fi
    fi

    # ── FreeFlow 链接（明文直连）
    local _ff_proto; _ff_proto=$(state_get '.ff.protocol')
    if [ "$(state_get '.ff.enabled')" = "true" ] && [ "${_ff_proto}" != "none" ]; then
        _ip=$(get_realip)
        if [ -n "${_ip:-}" ]; then
            local _path _penc
            _path=$(state_get '.ff.path')
            _penc=$(_urlencode_path "${_path}")
            case "${_ff_proto}" in
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
        else
            log_warn "无法获取服务器 IP，FreeFlow 节点已跳过"
        fi
    fi

    # ── Reality 链接（VLESS + TCP + XTLS-Vision）
    if [ "$(state_get '.reality.enabled')" = "true" ]; then
        local _r_port _r_sni _r_pbk _r_sid
        _r_port=$(state_get '.reality.port')
        _r_sni=$( state_get '.reality.sni')
        _r_pbk=$( state_get '.reality.pbk')
        _r_sid=$( state_get '.reality.sid')
        if [ -n "${_r_pbk:-}" ] && [ "${_r_pbk}" != "null" ]; then
            _ip=$(get_realip)
            if [ -n "${_ip:-}" ]; then
                printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#Reality-Vision\n' \
                    "${_uuid}" "${_ip}" "${_r_port}" "${_r_sni}" "${_r_pbk}" "${_r_sid}"
            else
                log_warn "无法获取服务器 IP，Reality 节点已跳过"
            fi
        fi
    fi

    # ── SOCKS5 链接（socks5://[user:pass@]host:port 格式）
    if [ "$(state_get '.socks5.enabled')" = "true" ]; then
        local _s5_port _s5_listen _s5_auth _s5_user _s5_pass _s5_host
        _s5_port=$(  state_get '.socks5.port')
        _s5_listen=$(state_get '.socks5.listen')
        _s5_auth=$(  state_get '.socks5.auth')
        _s5_user=$(  state_get '.socks5.user')
        _s5_pass=$(  state_get '.socks5.pass')

        # 监听地址为 0.0.0.0 时使用服务器真实 IP
        if [ "${_s5_listen}" = "0.0.0.0" ] || [ "${_s5_listen}" = "::" ]; then
            _s5_host=$(get_realip)
        else
            _s5_host="${_s5_listen}"
        fi

        if [ -n "${_s5_host:-}" ]; then
            if [ "${_s5_auth}" = "password" ] \
                && [ -n "${_s5_user:-}" ] && [ -n "${_s5_pass:-}" ]; then
                printf 'socks5://%s:%s@%s:%s#SOCKS5-Auth\n' \
                    "${_s5_user}" "${_s5_pass}" "${_s5_host}" "${_s5_port}"
            else
                printf 'socks5://%s:%s#SOCKS5-NoAuth\n' "${_s5_host}" "${_s5_port}"
            fi
        else
            log_warn "无法获取服务器 IP，SOCKS5 节点已跳过"
        fi
    fi
}

# @description 彩色打印所有节点链接
print_nodes() {
    echo ""
    local _links; _links=$(_get_share_links)
    if [ -z "${_links:-}" ]; then
        log_warn "暂无可用节点（请检查 Argo 域名或服务器 IP）"
        return 1
    fi
    printf '%s\n' "${_links}" | while IFS= read -r _line; do
        [ -n "${_line:-}" ] && printf "${_C_CYN}%s${_C_RST}\n" "${_line}"
    done
    echo ""
}

# ====================== 服务管理 ======================

# @description 统一服务控制接口（屏蔽 systemd/OpenRC 差异）
# @param $1 操作：start|stop|restart|enable|disable|status
# @param $2 服务名：xray|tunnel
# @return 0=成功
_svc_manager() {
    local _act="$1" _name="$2" _rc=0
    if is_systemd; then
        case "${_act}" in
            enable)  systemctl enable   "${_name}" >/dev/null 2>&1; _rc=$? ;;
            disable) systemctl disable  "${_name}" >/dev/null 2>&1; _rc=$? ;;
            status)  systemctl is-active --quiet "${_name}" 2>/dev/null;   _rc=$? ;;
            *)       systemctl "${_act}" "${_name}" >/dev/null 2>&1;       _rc=$? ;;
        esac
    else
        case "${_act}" in
            enable)  rc-update add "${_name}" default >/dev/null 2>&1; _rc=$? ;;
            disable) rc-update del "${_name}" default >/dev/null 2>&1; _rc=$? ;;
            status)  rc-service "${_name}" status >/dev/null 2>&1;     _rc=$? ;;
            *)       rc-service "${_name}" "${_act}" >/dev/null 2>&1;  _rc=$? ;;
        esac
    fi
    return "${_rc}"
}

# @description 延迟 daemon-reload（仅 systemd 且服务文件有变更时执行）
_svc_daemon_reload() {
    is_systemd                  || return 0
    [ "${_SYSD_DIRTY}" -eq 1 ] || return 0
    systemctl daemon-reload >/dev/null 2>&1 || true
    _SYSD_DIRTY=0
}

# @description 幂等写入服务文件（内容无变化则跳过，有变化标记需要 daemon-reload）
# @param $1 目标文件路径
# @param $2 文件内容
# @return 0=未变化, 1=已写入新内容
_svc_write_file() {
    local _dest="$1" _content="$2"
    local _cur; _cur=$(cat "${_dest}" 2>/dev/null || printf '')
    [ "${_cur}" = "${_content}" ] && return 0
    printf '%s' "${_content}" > "${_dest}"
    return 1
}

# --- 服务单元模板 ---

_svc_content_xray_systemd() {
    printf '[Unit]\nDescription=Xray Service\nDocumentation=https://github.com/XTLS/Xray-core\nAfter=network.target nss-lookup.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nExecStart=%s run -c %s\nRestart=on-failure\nRestartPreventExitStatus=23\n\n[Install]\nWantedBy=multi-user.target\n' \
        "${XRAY_BIN}" "${CONFIG_FILE}"
}

_svc_content_tunnel_systemd() {
    local _cmd="$1"
    printf '[Unit]\nDescription=Cloudflare Tunnel\nAfter=network.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nTimeoutStartSec=0\nExecStart=/bin/sh -c '"'"'%s >> %s 2>&1'"'"'\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\n' \
        "${_cmd}" "${ARGO_LOG}"
}

_svc_content_xray_openrc() {
    printf '#!/sbin/openrc-run\ndescription="Xray service"\ncommand="%s"\ncommand_args="run -c %s"\ncommand_background=true\npidfile="/var/run/xray.pid"\n' \
        "${XRAY_BIN}" "${CONFIG_FILE}"
}

_svc_content_tunnel_openrc() {
    local _cmd="$1"
    printf '#!/sbin/openrc-run\ndescription="Cloudflare Tunnel"\ncommand="/bin/sh"\ncommand_args="-c '"'"'%s >> %s 2>&1'"'"'"\ncommand_background=true\npidfile="/var/run/tunnel.pid"\n' \
        "${_cmd}" "${ARGO_LOG}"
}

# @description 注册 xray 服务（幂等）
_register_xray_service() {
    if is_systemd; then
        _svc_write_file "/etc/systemd/system/xray.service" \
            "$(_svc_content_xray_systemd)" || _SYSD_DIRTY=1
    else
        _svc_write_file "/etc/init.d/xray" "$(_svc_content_xray_openrc)" \
            || chmod +x /etc/init.d/xray
    fi
}

# @description 注册 tunnel 服务（幂等；启动命令由 _build_tunnel_cmd 从 _STATE 派生）
_register_tunnel_service() {
    local _cmd; _cmd=$(_build_tunnel_cmd)
    if is_systemd; then
        _svc_write_file "/etc/systemd/system/tunnel.service" \
            "$(_svc_content_tunnel_systemd "${_cmd}")" || _SYSD_DIRTY=1
    else
        _svc_write_file "/etc/init.d/tunnel" \
            "$(_svc_content_tunnel_openrc "${_cmd}")" || chmod +x /etc/init.d/tunnel
    fi
}

# @description 从 _STATE 派生 cloudflared 启动命令（temp/fixed 两种模式）
# @return cloudflared 命令行字符串
_build_tunnel_cmd() {
    local _mode; _mode=$(state_get '.argo.mode')
    local _port; _port=$(state_get '.argo.port')
    case "${_mode}" in
        fixed)
            if [ -f "${WORK_DIR}/tunnel.yml" ]; then
                printf '%s tunnel --edge-ip-version auto --config %s run' \
                    "${ARGO_BIN}" "${WORK_DIR}/tunnel.yml"
            else
                local _tok; _tok=$(state_get '.argo.token')
                printf '%s tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token %s' \
                    "${ARGO_BIN}" "${_tok}"
            fi ;;
        *)  # temp
            printf '%s tunnel --url http://localhost:%s --no-autoupdate --edge-ip-version auto --protocol http2' \
                "${ARGO_BIN}" "${_port}" ;;
    esac
}

# @description 生成 Argo 固定隧道配置 tunnel.yml（ingress 规则从 _STATE 动态构建）
# @param $1 Argo 域名
# @param $2 Tunnel ID
# @param $3 凭证文件路径
_gen_argo_config() {
    local _domain="$1" _tid="$2" _cred_file="$3"
    local _port; _port=$(state_get '.argo.port')
    local _ingress
    _ingress=$(printf '  - hostname: %s\n    service: http://localhost:%s\n    originRequest:\n      noTLSVerify: true\n' \
        "${_domain}" "${_port}")
    printf 'tunnel: %s\ncredentials-file: %s\nprotocol: http2\n\ningress:\n%s  - service: http_status:404\n' \
        "${_tid}" "${_cred_file}" "${_ingress}" > "${WORK_DIR}/tunnel.yml" \
        || { log_error "tunnel.yml 写入失败"; return 1; }
    log_ok "tunnel.yml 已生成 (hostname=${_domain} → localhost:${_port})"
}

# --- 下载层 ---

# @description 下载 xray 二进制（带 spinner + zip 完整性校验 + 幂等跳过）
download_xray() {
    detect_arch
    [ -f "${XRAY_BIN}" ] && { log_info "xray 已存在，跳过下载"; return 0; }
    local _url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${_ARCH_XRAY}.zip"
    local _zip; _zip=$(_tmp_file "xray_XXXXXX.zip") || return 1
    spinner_start "下载 Xray (${_ARCH_XRAY})"
    curl -sfL --connect-timeout 15 --max-time 120 -o "${_zip}" "${_url}"
    local _rc=$?; spinner_stop
    [ "${_rc}" -ne 0 ] && { log_error "Xray 下载失败"; return 1; }
    unzip -t "${_zip}" >/dev/null 2>&1 || { log_error "Xray zip 损坏"; return 1; }
    unzip -o "${_zip}" xray -d "${WORK_DIR}/" >/dev/null 2>&1 \
        || { log_error "Xray 解压失败"; return 1; }
    [ -f "${XRAY_BIN}" ] || { log_error "解压后未找到 xray 二进制"; return 1; }
    chmod +x "${XRAY_BIN}"
    log_ok "Xray 下载完成 ($(${XRAY_BIN} version 2>/dev/null | head -1 | awk '{print $2}'))"
}

# @description 下载 cloudflared 二进制（带 spinner + 幂等跳过）
download_cloudflared() {
    detect_arch
    [ -f "${ARGO_BIN}" ] && { log_info "cloudflared 已存在，跳过下载"; return 0; }
    local _url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${_ARCH_CF}"
    spinner_start "下载 cloudflared (${_ARCH_CF})"
    curl -sfL --connect-timeout 15 --max-time 120 -o "${ARGO_BIN}" "${_url}"
    local _rc=$?; spinner_stop
    [ "${_rc}" -ne 0 ] && { rm -f "${ARGO_BIN}"; log_error "cloudflared 下载失败"; return 1; }
    [ -s "${ARGO_BIN}" ] || { rm -f "${ARGO_BIN}"; log_error "cloudflared 文件为空"; return 1; }
    chmod +x "${ARGO_BIN}"
    log_ok "cloudflared 下载完成"
}

# --- 安装/卸载 ---

# @description 核心安装流程：下载 → 密钥生成 → 原子提交配置 → 注册服务 → 启动
install_core() {
    clear; log_title "══════════ 安装 Xray-2go v4 ══════════"
    preflight_check
    mkdir -p "${WORK_DIR}" && chmod 750 "${WORK_DIR}"

    download_xray || return 1
    [ "$(state_get '.argo.enabled')" = "true" ] && { download_cloudflared || return 1; }

    # Reality 密钥对（依赖 xray 二进制，下载后立即生成）
    if [ "$(state_get '.reality.enabled')" = "true" ]; then
        log_step "生成 Reality x25519 密钥对..."
        _gen_reality_keypair || return 1
        state_set '.reality.sid = $s' --arg s "$(_gen_reality_sid)"
    fi

    config_commit || return 1

    _register_xray_service
    [ "$(state_get '.argo.enabled')" = "true" ] && _register_tunnel_service
    _svc_daemon_reload

    # Alpine/OpenRC 特殊初始化
    if is_openrc; then
        printf '0 0\n' > /proc/sys/net/ipv4/ping_group_range 2>/dev/null || true
        sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts 2>/dev/null || true
        sed -i '2s/.*/::1         localhost/'  /etc/hosts 2>/dev/null || true
    fi

    fix_time_sync

    log_step "启动服务..."
    _svc_manager enable xray
    _svc_manager start  xray  || { log_error "xray 启动失败"; return 1; }
    log_ok "xray 已启动"

    if [ "$(state_get '.argo.enabled')" = "true" ]; then
        _svc_manager enable tunnel
        _svc_manager start  tunnel || { log_error "tunnel 启动失败"; return 1; }
        log_ok "tunnel 已启动"
    fi

    state_persist || log_warn "state.json 写入失败（不影响运行）"
    log_ok "══ 安装完成 ══"
}

# @description 完全卸载 xray-2go（停服务、删文件、删快捷方式）
uninstall_all() {
    local _ans; prompt "确定要卸载 xray-2go？(y/N): " _ans
    case "${_ans:-n}" in y|Y) : ;; *) log_info "已取消"; return ;; esac
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

# --- Argo 隧道操作 ---

# @description 配置 Argo 固定隧道（交互收集域名/密钥 → 更新服务文件 → 提交配置）
configure_fixed_tunnel() {
    local _argo_proto; _argo_proto=$(state_get '.argo.protocol')
    log_info "固定隧道 — 协议: ${_argo_proto}  回源端口: $(state_get '.argo.port')"
    echo ""

    local _domain _auth
    prompt "请输入 Argo 域名: " _domain
    case "${_domain:-}" in ''|*' '*|*'/'*|*$'\t'*) log_error "域名格式不合法"; return 1 ;; esac
    printf '%s' "${_domain}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
        || { log_error "域名格式不合法"; return 1; }

    prompt "请输入 Argo 密钥 (token 或 JSON 内容): " _auth
    [ -z "${_auth:-}" ] && { log_error "密钥不能为空"; return 1; }

    if printf '%s' "${_auth}" | grep -q "TunnelSecret"; then
        printf '%s' "${_auth}" | jq . >/dev/null 2>&1 || { log_error "JSON 凭证格式不合法"; return 1; }
        local _tid
        _tid=$(printf '%s' "${_auth}" | jq -r '
            if (.TunnelID?  // "") != "" then .TunnelID
            elif (.AccountTag? // "") != "" then .AccountTag
            else empty end' 2>/dev/null)
        [ -z "${_tid:-}" ] && { log_error "无法提取 TunnelID/AccountTag"; return 1; }
        case "${_tid}" in *$'\n'*|*'"'*|*"'"*|*':'*)
            log_error "TunnelID 含非法字符，拒绝写入"; return 1 ;; esac

        local _cred_file="${WORK_DIR}/tunnel.json"
        printf '%s' "${_auth}" > "${_cred_file}"
        _gen_argo_config "${_domain}" "${_tid}" "${_cred_file}" || return 1
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

    config_commit || return 1
    state_persist || log_warn "state.json 写入失败"

    _svc_manager restart tunnel || { log_error "tunnel 重启失败"; return 1; }
    log_ok "固定隧道已配置 (${_argo_proto}, domain=${_domain})"
}

# @description 重置为临时隧道（清理 tunnel.yml/json，强制回 ws 协议）
reset_temp_tunnel() {
    state_set '.argo.mode = "temp" | .argo.domain = null | .argo.token = null' || return 1
    rm -f "${WORK_DIR}/tunnel.yml" "${WORK_DIR}/tunnel.json"
    _register_tunnel_service
    _svc_daemon_reload
    state_set '.argo.protocol = "ws"' || return 1
    config_commit || return 1
    state_persist || log_warn "state.json 写入失败"
    log_ok "已切换至临时隧道"
}

# @description 刷新临时域名（重启 tunnel → 轮询日志 → 更新 _STATE）
refresh_temp_domain() {
    [ "$(state_get '.argo.enabled')" = "true" ] || { log_warn "未启用 Argo"; return 1; }
    [ "$(state_get '.argo.protocol')" = "ws" ]  || { log_error "XHTTP 不支持临时隧道"; return 1; }
    [ "$(state_get '.argo.mode')" = "temp" ]    || { log_warn "当前为固定隧道，无需刷新"; return 1; }

    rm -f "${ARGO_LOG}"
    log_step "重启隧道并等待新域名（最多约 44s）..."
    _svc_manager restart tunnel || return 1

    local _d
    _d=$(get_temp_domain) || { log_warn "未能获取临时域名，请检查网络"; return 1; }
    log_ok "ArgoDomain: ${_d}"

    state_set '.argo.domain = $d' --arg d "${_d}" || return 1
    state_persist || log_warn "state.json 写入失败"
    print_nodes
}

# --- UUID / 端口管理 ---

# @description 修改 UUID（SSOT 工作流：state_set → config_commit → persist → print）
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
    log_ok "UUID 已更新: ${_v}"
    print_nodes
}

# @description 修改 Argo 回源端口（SSOT 工作流：state_set → commit → 更新 tunnel 服务）
manage_port() {
    local _p; prompt "新回源端口（回车随机）: " _p
    [ -z "${_p:-}" ] && \
        _p=$(shuf -i 2000-65000 -n 1 2>/dev/null || \
             awk 'BEGIN{srand();print int(rand()*63000)+2000}')
    case "${_p:-}" in ''|*[!0-9]*) log_error "无效端口"; return 1 ;; esac
    { [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]; } \
        || { log_error "端口须在 1-65535 之间"; return 1; }

    if port_in_use "${_p}"; then
        log_warn "端口 ${_p} 已被占用"
        local _ans; prompt "仍然继续？(y/N): " _ans
        case "${_ans:-n}" in y|Y) : ;; *) return 1 ;; esac
    fi

    state_set '.argo.port = ($p|tonumber)' --arg p "${_p}" || return 1
    config_commit || return 1
    _register_tunnel_service
    _svc_daemon_reload
    _svc_manager restart tunnel || log_warn "tunnel 重启失败，请手动重启"
    state_persist || log_warn "state.json 写入失败"
    log_ok "回源端口已更新: ${_p}"
    print_nodes
}

# --- Cron 自动重启 ---

_cron_available() {
    command -v crontab >/dev/null 2>&1 || return 1
    if is_openrc; then
        rc-service dcron status >/dev/null 2>&1 || rc-service crond status >/dev/null 2>&1
    else
        systemctl is-active --quiet cron  2>/dev/null || \
        systemctl is-active --quiet crond 2>/dev/null
    fi
}

# @description 确保 cron 已安装并运行（按需提示安装）
ensure_cron() {
    _cron_available && return 0
    log_warn "cron 未运行"
    local _ans; prompt "是否安装 cron？(Y/n): " _ans
    case "${_ans:-y}" in n|N) log_error "cron 不可用"; return 1 ;; esac
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
    else die "无法安装 cron"
    fi
}

# @description 设置 cron 定时重启 xray
setup_auto_restart() {
    local _iv; _iv=$(state_get '.cron')
    ensure_cron || return 1
    local _cmd; is_openrc && _cmd="rc-service xray restart" || _cmd="systemctl restart xray"
    local _tmp; _tmp=$(_tmp_file "cron_XXXXXX") || return 1
    { crontab -l 2>/dev/null | grep -v '#xray-restart'
      printf '*/%s * * * * %s >/dev/null 2>&1 #xray-restart\n' "${_iv}" "${_cmd}"
    } > "${_tmp}"
    crontab "${_tmp}" || { log_error "crontab 写入失败"; return 1; }
    log_ok "已设置每 ${_iv} 分钟自动重启 xray"
}

# @description 移除 xray cron 自动重启任务
remove_auto_restart() {
    command -v crontab >/dev/null 2>&1 || return 0
    local _tmp; _tmp=$(_tmp_file "cron_XXXXXX") || return 0
    crontab -l 2>/dev/null | grep -v '#xray-restart' > "${_tmp}" || true
    crontab "${_tmp}" 2>/dev/null || true
}

# --- 快捷方式更新 ---

# @description 原子拉取最新脚本（语法验证 → 备份 → 替换 → 更新快捷方式）
install_shortcut() {
    log_step "拉取最新脚本..."
    local _tmp; _tmp=$(_tmp_file "xray2go_XXXXXX.sh") || return 1
    curl -sfL --connect-timeout 15 --max-time 60 -o "${_tmp}" "${UPSTREAM_URL}" \
        || { log_error "拉取失败，请检查网络"; return 1; }
    bash -n "${_tmp}" 2>/dev/null \
        || { log_error "脚本语法验证失败，已中止"; return 1; }
    [ -f "${SELF_DEST}" ] && cp -f "${SELF_DEST}" "${SELF_DEST}.bak" 2>/dev/null || true
    mv "${_tmp}" "${SELF_DEST}" && chmod +x "${SELF_DEST}"
    printf '#!/bin/bash\nexec %s "$@"\n' "${SELF_DEST}" > "${SHORTCUT}"
    chmod +x "${SHORTCUT}"
    log_ok "脚本已更新！输入 ${_C_GRN}s${_C_RST} 快速启动"
}

# --- 状态检测 ---

# @description 检测 xray 服务状态
# @return "running"|"stopped"|"not installed"
check_xray() {
    [ -f "${XRAY_BIN}" ] || { printf 'not installed'; return 2; }
    _svc_manager status xray && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
}

# @description 检测 Argo tunnel 状态
# @return "running"|"stopped"|"not installed"|"disabled"
check_argo() {
    [ "$(state_get '.argo.enabled')" = "true" ] || { printf 'disabled'; return 3; }
    [ -f "${ARGO_BIN}" ]                         || { printf 'not installed'; return 2; }
    _svc_manager status tunnel && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
}

# @description 判断当前是否为固定隧道（读 _STATE）
is_fixed_tunnel() { [ "$(state_get '.argo.mode')" = "fixed" ]; }

# ====================== 用户交互与菜单 ======================

# --- 安装向导询问函数 ---

# @description 安装向导：询问是否安装 Argo 及其模式
ask_argo_mode() {
    echo ""; log_title "Argo 隧道选项"
    printf "  ${_C_GRN}1.${_C_RST} 安装 Argo (VLESS+WS/XHTTP+TLS) ${_C_YLW}[默认]${_C_RST}\n"
    printf "  ${_C_GRN}2.${_C_RST} 不安装 Argo（仅 FreeFlow 节点）\n"
    local _c; prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2) state_set '.argo.enabled = false'; log_info "已选：不安装 Argo" ;;
        *) state_set '.argo.enabled = true';  log_info "已选：安装 Argo"   ;;
    esac
    echo ""
}

# @description 安装向导：询问 Argo 传输协议（WS / XHTTP）
ask_argo_protocol() {
    echo ""; log_title "Argo 传输协议"
    printf "  ${_C_GRN}1.${_C_RST} WS（临时+固定均支持）${_C_YLW}[默认]${_C_RST}\n"
    printf "  ${_C_GRN}2.${_C_RST} XHTTP（auto 模式，仅固定隧道）\n"
    local _c; prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2)
            state_set '.argo.protocol = "xhttp"'
            log_warn "XHTTP 不支持临时隧道！安装后将进入固定隧道配置。" ;;
        *) state_set '.argo.protocol = "ws"' ;;
    esac
    log_info "已选协议: $(state_get '.argo.protocol')"; echo ""
}

# @description 安装向导：询问 FreeFlow 明文协议
ask_freeflow_mode() {
    echo ""; log_title "FreeFlow（明文 port 8080）"
    printf "  ${_C_GRN}1.${_C_RST} VLESS + WS\n"
    printf "  ${_C_GRN}2.${_C_RST} VLESS + HTTPUpgrade\n"
    printf "  ${_C_GRN}3.${_C_RST} VLESS + XHTTP (stream-one)\n"
    printf "  ${_C_GRN}4.${_C_RST} 不启用 FreeFlow ${_C_YLW}[默认]${_C_RST}\n"
    local _c; prompt "请选择 (1-4，回车默认4): " _c
    case "${_c:-4}" in
        1) state_set '.ff.enabled = true | .ff.protocol = "ws"'          ;;
        2) state_set '.ff.enabled = true | .ff.protocol = "httpupgrade"' ;;
        3) state_set '.ff.enabled = true | .ff.protocol = "xhttp"'       ;;
        *) state_set '.ff.enabled = false | .ff.protocol = "none"'
           log_info "不启用 FreeFlow"; echo ""; return 0 ;;
    esac
    port_in_use 8080 && log_warn "端口 8080 已被占用，FreeFlow 可能无法启动"
    local _p; prompt "FreeFlow path（回车默认 /）: " _p
    case "${_p:-/}" in /*) : ;; *) _p="/${_p}" ;; esac
    state_set '.ff.path = $p' --arg p "${_p:-/}"
    log_info "已选: $(state_get '.ff.protocol')（path=${_p:-/}）"; echo ""
}

# @description 安装向导：询问 Reality 配置（端口/SNI）
ask_reality_mode() {
    echo ""; log_title "VLESS + Reality Vision（TCP 直连，独立端口，无需 Argo）"
    printf "  ${_C_GRN}1.${_C_RST} 启用 Reality\n"
    printf "  ${_C_GRN}2.${_C_RST} 不启用 ${_C_YLW}[默认]${_C_RST}\n"
    local _c; prompt "请选择 (1-2，回车默认2): " _c
    case "${_c:-2}" in
        1) state_set '.reality.enabled = true' ;;
        *) state_set '.reality.enabled = false'; log_info "不启用 Reality"; echo ""; return 0 ;;
    esac

    local _default_port; _default_port=$(state_get '.reality.port')
    local _rp; prompt "监听端口（回车默认 ${_default_port}）: " _rp
    if [ -n "${_rp:-}" ]; then
        case "${_rp}" in
            *[!0-9]*) log_warn "端口格式无效，使用默认值 ${_default_port}" ;;
            *)
                if [ "${_rp}" -ge 1 ] && [ "${_rp}" -le 65535 ]; then
                    state_set '.reality.port = ($p|tonumber)' --arg p "${_rp}"
                else
                    log_warn "端口超出范围，使用默认值 ${_default_port}"
                fi ;;
        esac
    fi
    port_in_use "$(state_get '.reality.port')" \
        && log_warn "端口 $(state_get '.reality.port') 已被占用，可安装后通过 Reality 管理修改"

    local _default_sni; _default_sni=$(state_get '.reality.sni')
    log_info "SNI 建议：addons.mozilla.org / www.microsoft.com"
    local _sni; prompt "伪装 SNI 域名（回车默认 ${_default_sni}）: " _sni
    if [ -n "${_sni:-}" ]; then
        printf '%s' "${_sni}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
            && state_set '.reality.sni = $s' --arg s "${_sni}" \
            || log_warn "SNI 格式不合法，使用默认值 ${_default_sni}"
    fi

    log_info "Reality 配置完成 — 端口: $(state_get '.reality.port')  SNI: $(state_get '.reality.sni')"
    log_info "密钥对将在安装时由 xray x25519 自动生成"
    echo ""
}

# @description 安装向导：询问 SOCKS5 配置（端口/监听/认证）
ask_socks5_mode() {
    echo ""; log_title "SOCKS5 本地代理（可独立使用，与其他协议共存）"
    printf "  ${_C_GRN}1.${_C_RST} 启用 SOCKS5\n"
    printf "  ${_C_GRN}2.${_C_RST} 不启用 ${_C_YLW}[默认]${_C_RST}\n"
    local _c; prompt "请选择 (1-2，回车默认2): " _c
    case "${_c:-2}" in
        1) state_set '.socks5.enabled = true' ;;
        *) state_set '.socks5.enabled = false'; log_info "不启用 SOCKS5"; echo ""; return 0 ;;
    esac

    # 监听端口
    local _default_port; _default_port=$(state_get '.socks5.port')
    local _sp; prompt "监听端口（回车默认 ${_default_port}）: " _sp
    if [ -n "${_sp:-}" ]; then
        case "${_sp}" in
            *[!0-9]*) log_warn "端口格式无效，使用默认值 ${_default_port}" ;;
            *)
                if [ "${_sp}" -ge 1 ] && [ "${_sp}" -le 65535 ]; then
                    state_set '.socks5.port = ($p|tonumber)' --arg p "${_sp}"
                else
                    log_warn "端口超出范围，使用默认值 ${_default_port}"
                fi ;;
        esac
    fi
    port_in_use "$(state_get '.socks5.port')" \
        && log_warn "端口 $(state_get '.socks5.port') 已被占用，可安装后通过 SOCKS5 管理修改"

    # 监听地址
    local _default_listen; _default_listen=$(state_get '.socks5.listen')
    local _sl; prompt "监听地址（回车默认 ${_default_listen}，0.0.0.0=所有接口）: " _sl
    [ -n "${_sl:-}" ] && state_set '.socks5.listen = $l' --arg l "${_sl}"

    # 认证模式
    echo ""
    printf "  ${_C_GRN}1.${_C_RST} 无认证 (noauth) ${_C_YLW}[默认]${_C_RST}\n"
    printf "  ${_C_GRN}2.${_C_RST} 密码认证 (password)\n"
    local _auth_c; prompt "请选择认证模式 (1-2，回车默认1): " _auth_c
    case "${_auth_c:-1}" in
        2)
            state_set '.socks5.auth = "password"'
            local _user _pass
            prompt "用户名: " _user
            [ -z "${_user:-}" ] && { log_error "用户名不能为空"; state_set '.socks5.auth = "noauth"'; }
            prompt "密码: "   _pass
            [ -z "${_pass:-}" ] && { log_error "密码不能为空";   state_set '.socks5.auth = "noauth"'; }
            if [ -n "${_user:-}" ] && [ -n "${_pass:-}" ]; then
                state_set '.socks5.user = $u | .socks5.pass = $p' \
                    --arg u "${_user}" --arg p "${_pass}"
                log_info "已设置密码认证: ${_user}"
            fi ;;
        *) state_set '.socks5.auth = "noauth"'; log_info "已选：无认证模式" ;;
    esac

    log_info "SOCKS5 配置完成 — 端口: $(state_get '.socks5.port')  认证: $(state_get '.socks5.auth')"
    echo ""
}

# --- 管理子菜单 ---

# @description Argo 隧道管理子菜单
manage_argo() {
    [ "$(state_get '.argo.enabled')" = "true" ] || { log_warn "未启用 Argo"; sleep 1; return; }
    [ -f "${ARGO_BIN}" ]                         || { log_warn "Argo 未安装"; sleep 1; return; }

    while true; do
        local _astat _domain _type_disp _proto _port
        _astat=$(check_argo)
        _domain=$(state_get '.argo.domain')
        _proto=$(state_get '.argo.protocol')
        _port=$(state_get '.argo.port')
        is_fixed_tunnel && [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ] \
            && _type_disp="固定 (${_proto}, ${_domain})" \
            || _type_disp="临时 (WS)"

        clear; echo ""; log_title "══ Argo 隧道管理 ══"
        printf "  状态: ${_C_GRN}%s${_C_RST}  协议: ${_C_CYN}%s${_C_RST}  端口: ${_C_YLW}%s${_C_RST}\n" \
            "${_astat}" "${_proto}" "${_port}"
        printf "  类型: %s\n" "${_type_disp}"; _hr
        printf "  ${_C_GRN}1.${_C_RST} 添加/更新固定隧道\n"
        printf "  ${_C_GRN}2.${_C_RST} 切换协议 (WS ↔ XHTTP，仅固定隧道)\n"
        printf "  ${_C_GRN}3.${_C_RST} 切换回临时隧道 (WS)\n"
        printf "  ${_C_GRN}4.${_C_RST} 刷新临时域名\n"
        printf "  ${_C_GRN}5.${_C_RST} 修改回源端口 (当前: ${_C_YLW}${_port}${_C_RST})\n"
        printf "  ${_C_GRN}6.${_C_RST} 启动隧道\n"
        printf "  ${_C_GRN}7.${_C_RST} 停止隧道\n"
        printf "  ${_C_PUR}0.${_C_RST} 返回主菜单\n"; _hr
        local _c; prompt "请输入选择: " _c

        case "${_c:-}" in
            1)
                echo ""
                printf "  ${_C_GRN}1.${_C_RST} WS ${_C_YLW}[默认]${_C_RST}\n"
                printf "  ${_C_GRN}2.${_C_RST} XHTTP (auto)\n"
                local _pp; prompt "协议 (回车维持 ${_proto}): " _pp
                case "${_pp:-}" in
                    2) state_set '.argo.protocol = "xhttp"' ;;
                    1) state_set '.argo.protocol = "ws"'    ;;
                esac
                configure_fixed_tunnel && print_nodes || log_error "固定隧道配置失败" ;;
            2)
                is_fixed_tunnel || { log_warn "当前为临时隧道，请先配置固定隧道"; _pause; continue; }
                local _new_proto
                [ "${_proto}" = "ws" ] && _new_proto="xhttp" || _new_proto="ws"
                state_set '.argo.protocol = $p' --arg p "${_new_proto}" || { _pause; continue; }
                if config_commit && state_persist; then
                    log_ok "协议已切换: ${_new_proto}"; print_nodes
                else
                    log_error "切换失败，回滚"
                    state_set '.argo.protocol = $p' --arg p "${_proto}"
                fi ;;
            3)
                [ "$(state_get '.argo.protocol')" = "xhttp" ] && \
                    { log_error "请先切换协议为 WS 再切回临时隧道"; _pause; continue; }
                reset_temp_tunnel || { _pause; continue; }
                _svc_manager restart tunnel || { _pause; continue; }
                log_step "等待临时域名（最多约 44s）..."
                local _td; _td=$(get_temp_domain) || _td=""
                if [ -n "${_td:-}" ]; then
                    state_set '.argo.domain = $d' --arg d "${_td}" || true
                    state_persist || true
                    log_ok "ArgoDomain: ${_td}"; print_nodes
                else
                    log_warn "未能获取临时域名，可从 [4. 刷新临时域名] 重试"
                fi ;;
            4) refresh_temp_domain ;;
            5) manage_port ;;
            6) _svc_manager start  tunnel && log_ok "隧道已启动" || log_error "启动失败" ;;
            7) _svc_manager stop   tunnel && log_ok "隧道已停止" || log_error "停止失败" ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# @description FreeFlow 管理子菜单
manage_freeflow() {
    while true; do
        local _ff_en _ff_proto _ff_path
        _ff_en=$(   state_get '.ff.enabled')
        _ff_proto=$(state_get '.ff.protocol')
        _ff_path=$( state_get '.ff.path')

        clear; echo ""; log_title "══ FreeFlow 管理 ══"
        if [ "${_ff_en}" = "true" ] && [ "${_ff_proto}" != "none" ]; then
            printf "  状态: ${_C_GRN}已启用${_C_RST}  协议: ${_C_CYN}%s${_C_RST}  path: ${_C_YLW}%s${_C_RST}\n" \
                "${_ff_proto}" "${_ff_path}"
        else
            printf "  状态: ${_C_YLW}未启用${_C_RST}\n"
        fi
        _hr
        printf "  ${_C_GRN}1.${_C_RST} 添加/变更方式\n"
        printf "  ${_C_GRN}2.${_C_RST} 修改 path\n"
        printf "  ${_C_RED}3.${_C_RST} 卸载 FreeFlow\n"
        printf "  ${_C_PUR}0.${_C_RST} 返回主菜单\n"; _hr
        local _c; prompt "请输入选择: " _c

        case "${_c:-}" in
            1)
                ask_freeflow_mode
                config_commit  || { log_error "FreeFlow 配置更新失败"; _pause; continue; }
                state_persist  || log_warn "state.json 写入失败"
                log_ok "FreeFlow 已变更"; print_nodes ;;
            2)
                if [ "${_ff_en}" != "true" ] || [ "${_ff_proto}" = "none" ]; then
                    log_warn "FreeFlow 未启用，请先选择 [1. 添加/变更方式]"; _pause; continue
                fi
                local _p; prompt "新 path（回车保持 ${_ff_path}）: " _p
                if [ -n "${_p:-}" ]; then
                    case "${_p}" in /*) : ;; *) _p="/${_p}" ;; esac
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

# @description Reality 管理子菜单
manage_reality() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先安装 Xray-2go"; sleep 1; return; }

    while true; do
        local _r_en _r_port _r_sni _r_pbk _r_pvk _r_sid _pbk_disp
        _r_en=$(  state_get '.reality.enabled')
        _r_port=$(state_get '.reality.port')
        _r_sni=$( state_get '.reality.sni')
        _r_pbk=$( state_get '.reality.pbk')
        _r_pvk=$( state_get '.reality.pvk')
        _r_sid=$( state_get '.reality.sid')

        # 公钥仅显示前 16 字符
        _pbk_disp="未生成"
        [ -n "${_r_pbk:-}" ] && [ "${_r_pbk}" != "null" ] \
            && _pbk_disp="${_r_pbk:0:16}...（完整见节点链接）"

        clear; echo ""; log_title "══ Reality 管理 (VLESS+TCP+XTLS-Vision) ══"
        [ "${_r_en}" = "true" ] \
            && printf "  状态: ${_C_GRN}已启用${_C_RST}\n" \
            || printf "  状态: ${_C_YLW}未启用${_C_RST}\n"
        printf "  端口: ${_C_YLW}%s${_C_RST}  SNI: ${_C_CYN}%s${_C_RST}\n" "${_r_port}" "${_r_sni}"
        printf "  公钥: %s\n" "${_pbk_disp}"
        [ -n "${_r_sid:-}" ] && [ "${_r_sid}" != "null" ] \
            && printf "  ShortId: ${_C_CYN}%s${_C_RST}\n" "${_r_sid}"
        _hr
        printf "  ${_C_GRN}1.${_C_RST} 启用 Reality\n"
        printf "  ${_C_RED}2.${_C_RST} 禁用 Reality\n"
        printf "  ${_C_GRN}3.${_C_RST} 修改监听端口（当前: ${_C_YLW}${_r_port}${_C_RST}）\n"
        printf "  ${_C_GRN}4.${_C_RST} 修改伪装 SNI（当前: ${_C_CYN}${_r_sni}${_C_RST}）\n"
        printf "  ${_C_GRN}5.${_C_RST} 重新生成密钥对 (x25519 + shortId)\n"
        printf "  ${_C_GRN}6.${_C_RST} 查看节点链接\n"
        printf "  ${_C_PUR}0.${_C_RST} 返回主菜单\n"; _hr
        local _c; prompt "请输入选择: " _c

        case "${_c:-}" in
            1)
                if [ -z "${_r_pvk:-}" ] || [ "${_r_pvk}" = "null" ]; then
                    log_step "首次启用，生成 x25519 密钥对..."
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
                [ -z "${_p:-}" ] && \
                    _p=$(shuf -i 1024-65000 -n 1 2>/dev/null || \
                         awk 'BEGIN{srand();print int(rand()*63976)+1024}')
                case "${_p:-}" in ''|*[!0-9]*) log_error "无效端口"; _pause; continue ;; esac
                { [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]; } \
                    || { log_error "端口须在 1-65535 之间"; _pause; continue; }
                if port_in_use "${_p}"; then
                    log_warn "端口 ${_p} 已被占用"
                    local _ans; prompt "仍然继续？(y/N): " _ans
                    case "${_ans:-n}" in y|Y) : ;; *) _pause; continue ;; esac
                fi
                state_set '.reality.port = ($p|tonumber)' --arg p "${_p}" || { _pause; continue; }
                config_commit  || { _pause; continue; }
                state_persist  || log_warn "state.json 写入失败"
                log_ok "Reality 端口已更新: ${_p}"; print_nodes ;;
            4)
                log_info "建议：addons.mozilla.org / www.microsoft.com / www.apple.com"
                local _sni; prompt "新 SNI（回车保持 ${_r_sni}）: " _sni
                if [ -n "${_sni:-}" ]; then
                    printf '%s' "${_sni}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
                        || { log_error "SNI 格式不合法"; _pause; continue; }
                    state_set '.reality.sni = $s' --arg s "${_sni}" || { _pause; continue; }
                    config_commit  || { _pause; continue; }
                    state_persist  || log_warn "state.json 写入失败"
                    log_ok "SNI 已更新: ${_sni}"; print_nodes
                fi ;;
            5)
                [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪，请先安装"; _pause; continue; }
                log_step "重新生成 x25519 密钥对..."
                _gen_reality_keypair || { _pause; continue; }
                state_set '.reality.sid = $s' --arg s "$(_gen_reality_sid)" || { _pause; continue; }
                [ "$(state_get '.reality.enabled')" = "true" ] && config_commit || true
                state_persist || log_warn "state.json 写入失败"
                log_ok "密钥对已更新"
                [ "$(state_get '.reality.enabled')" = "true" ] && print_nodes ;;
            6) print_nodes ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# @description SOCKS5 管理子菜单
manage_socks5() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先安装 Xray-2go"; sleep 1; return; }

    while true; do
        local _s5_en _s5_port _s5_listen _s5_auth _s5_user
        _s5_en=$(    state_get '.socks5.enabled')
        _s5_port=$(  state_get '.socks5.port')
        _s5_listen=$(state_get '.socks5.listen')
        _s5_auth=$(  state_get '.socks5.auth')
        _s5_user=$(  state_get '.socks5.user')

        clear; echo ""; log_title "══ SOCKS5 管理 ══"
        [ "${_s5_en}" = "true" ] \
            && printf "  状态: ${_C_GRN}已启用${_C_RST}\n" \
            || printf "  状态: ${_C_YLW}未启用${_C_RST}\n"
        printf "  端口: ${_C_YLW}%s${_C_RST}  监听: ${_C_CYN}%s${_C_RST}\n" "${_s5_port}" "${_s5_listen}"
        if [ "${_s5_auth}" = "password" ]; then
            printf "  认证: ${_C_GRN}密码认证${_C_RST}  用户: ${_C_YLW}%s${_C_RST}\n" "${_s5_user}"
        else
            printf "  认证: ${_C_CYN}无认证 (noauth)${_C_RST}\n"
        fi
        _hr
        printf "  ${_C_GRN}1.${_C_RST} 启用 SOCKS5\n"
        printf "  ${_C_RED}2.${_C_RST} 禁用 SOCKS5\n"
        printf "  ${_C_GRN}3.${_C_RST} 修改监听端口（当前: ${_C_YLW}${_s5_port}${_C_RST}）\n"
        printf "  ${_C_GRN}4.${_C_RST} 修改监听地址（当前: ${_C_CYN}${_s5_listen}${_C_RST}）\n"
        printf "  ${_C_GRN}5.${_C_RST} 修改认证模式\n"
        printf "  ${_C_GRN}6.${_C_RST} 查看节点链接\n"
        printf "  ${_C_PUR}0.${_C_RST} 返回主菜单\n"; _hr
        local _c; prompt "请输入选择: " _c

        case "${_c:-}" in
            1)
                state_set '.socks5.enabled = true' || { _pause; continue; }
                config_commit || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                log_ok "SOCKS5 已启用 (端口: ${_s5_port}, 认证: ${_s5_auth})"
                print_nodes ;;
            2)
                state_set '.socks5.enabled = false' || { _pause; continue; }
                config_commit || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                log_ok "SOCKS5 已禁用" ;;
            3)
                local _p; prompt "新端口（回车随机）: " _p
                [ -z "${_p:-}" ] && \
                    _p=$(shuf -i 1024-65000 -n 1 2>/dev/null || \
                         awk 'BEGIN{srand();print int(rand()*63976)+1024}')
                case "${_p:-}" in ''|*[!0-9]*) log_error "无效端口"; _pause; continue ;; esac
                { [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]; } \
                    || { log_error "端口须在 1-65535 之间"; _pause; continue; }
                if port_in_use "${_p}"; then
                    log_warn "端口 ${_p} 已被占用"
                    local _ans; prompt "仍然继续？(y/N): " _ans
                    case "${_ans:-n}" in y|Y) : ;; *) _pause; continue ;; esac
                fi
                state_set '.socks5.port = ($p|tonumber)' --arg p "${_p}" || { _pause; continue; }
                config_commit  || { _pause; continue; }
                state_persist  || log_warn "state.json 写入失败"
                log_ok "SOCKS5 端口已更新: ${_p}"
                [ "${_s5_en}" = "true" ] && print_nodes ;;
            4)
                local _sl; prompt "新监听地址（0.0.0.0=所有，127.0.0.1=仅本地）: " _sl
                if [ -n "${_sl:-}" ]; then
                    state_set '.socks5.listen = $l' --arg l "${_sl}" || { _pause; continue; }
                    config_commit  || { _pause; continue; }
                    state_persist  || log_warn "state.json 写入失败"
                    log_ok "监听地址已更新: ${_sl}"
                    [ "${_s5_en}" = "true" ] && print_nodes
                fi ;;
            5)
                echo ""
                printf "  ${_C_GRN}1.${_C_RST} 无认证 (noauth)\n"
                printf "  ${_C_GRN}2.${_C_RST} 密码认证 (password)\n"
                local _ac; prompt "请选择认证模式: " _ac
                case "${_ac:-}" in
                    2)
                        local _user _pass
                        prompt "用户名: " _user
                        prompt "密码: "   _pass
                        if [ -n "${_user:-}" ] && [ -n "${_pass:-}" ]; then
                            state_set '.socks5.auth = "password" | .socks5.user = $u | .socks5.pass = $p' \
                                --arg u "${_user}" --arg p "${_pass}" || { _pause; continue; }
                            config_commit  || { _pause; continue; }
                            state_persist  || log_warn "state.json 写入失败"
                            log_ok "已切换为密码认证: ${_user}"
                            [ "${_s5_en}" = "true" ] && print_nodes
                        else
                            log_error "用户名和密码不能为空"
                        fi ;;
                    1|*)
                        state_set '.socks5.auth = "noauth" | .socks5.user = "" | .socks5.pass = ""' \
                            || { _pause; continue; }
                        config_commit  || { _pause; continue; }
                        state_persist  || log_warn "state.json 写入失败"
                        log_ok "已切换为无认证模式"
                        [ "${_s5_en}" = "true" ] && print_nodes ;;
                esac ;;
            6) print_nodes ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# @description 自动重启管理子菜单
manage_restart() {
    while true; do
        local _iv; _iv=$(state_get '.cron')
        clear; echo ""; log_title "══ 自动重启管理 ══"
        printf "  当前间隔: ${_C_CYN}%s 分钟${_C_RST}（0 = 关闭）\n" "${_iv}"; _hr
        printf "  ${_C_GRN}1.${_C_RST} 设置间隔\n"
        printf "  ${_C_PUR}0.${_C_RST} 返回主菜单\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)
                local _v; prompt "间隔分钟（0=关闭，推荐 60）: " _v
                case "${_v:-}" in ''|*[!0-9]*) log_error "无效输入"; _pause; continue ;; esac
                state_set '.cron = ($r|tonumber)' --arg r "${_v}" || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                if [ "${_v}" -eq 0 ]; then
                    remove_auto_restart; log_ok "自动重启已关闭"
                else
                    setup_auto_restart
                fi ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ====================== 主流程 ======================

# @description 主菜单（while-true 闭环，所有分支均回到菜单）
menu() {
    while true; do
        # 收集各协议状态信息
        local _xstat _astat _cx _xcolor
        _xstat=$(check_xray); _cx=$?
        _astat=$(check_argo)
        [ "${_cx}" -eq 0 ] && _xcolor="${_C_GRN}" || _xcolor="${_C_RED}"

        local _ff_en _ff_proto _ff_path _ff_disp
        _ff_en=$(   state_get '.ff.enabled')
        _ff_proto=$(state_get '.ff.protocol')
        _ff_path=$( state_get '.ff.path')
        [ "${_ff_en}" = "true" ] && [ "${_ff_proto}" != "none" ] \
            && _ff_disp="${_ff_proto} (path=${_ff_path})" \
            || _ff_disp="未启用"

        local _argo_disp _domain
        _domain=$(state_get '.argo.domain')
        if [ "$(state_get '.argo.enabled')" = "true" ]; then
            [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ] \
                && _argo_disp="${_astat} [$(state_get '.argo.protocol'), 固定: ${_domain}]" \
                || _argo_disp="${_astat} [WS, 临时隧道]"
        else
            _argo_disp="未启用"
        fi

        local _r_en _r_disp
        _r_en=$(state_get '.reality.enabled')
        [ "${_r_en}" = "true" ] \
            && _r_disp="已启用 (port=$(state_get '.reality.port'), sni=$(state_get '.reality.sni'))" \
            || _r_disp="未启用"

        local _s5_en _s5_disp
        _s5_en=$(state_get '.socks5.enabled')
        if [ "${_s5_en}" = "true" ]; then
            _s5_disp="已启用 (port=$(state_get '.socks5.port'), auth=$(state_get '.socks5.auth'))"
        else
            _s5_disp="未启用"
        fi

        # 绘制状态面板
        clear; echo ""
        printf "${_C_BOLD}${_C_PUR}  ╔══════════════════════════════════════════╗${_C_RST}\n"
        printf "${_C_BOLD}${_C_PUR}  ║        Xray-2go  v4.0  SSOT/AC           ║${_C_RST}\n"
        printf "${_C_BOLD}${_C_PUR}  ╠══════════════════════════════════════════╣${_C_RST}\n"
        printf "${_C_BOLD}${_C_PUR}  ║${_C_RST}  Xray    : ${_xcolor}%-30s${_C_RST}${_C_PUR} ${_C_RST}\n"  "${_xstat}"
        printf "${_C_BOLD}${_C_PUR}  ║${_C_RST}  Argo    : %-30s${_C_PUR} ${_C_RST}\n"  "${_argo_disp}"
        printf "${_C_BOLD}${_C_PUR}  ║${_C_RST}  Reality : %-30s${_C_PUR} ${_C_RST}\n"  "${_r_disp}"
        printf "${_C_BOLD}${_C_PUR}  ║${_C_RST}  SOCKS5  : %-30s${_C_PUR} ${_C_RST}\n"  "${_s5_disp}"
        printf "${_C_BOLD}${_C_PUR}  ║${_C_RST}  FF      : %-30s${_C_PUR} ${_C_RST}\n"  "${_ff_disp}"
        printf "${_C_BOLD}${_C_PUR}  ║${_C_RST}  Cron    : ${_C_CYN}%-2s min${_C_RST}                          ${_C_PUR} ${_C_RST}\n" "$(state_get '.cron')"
        printf "${_C_BOLD}${_C_PUR}  ╚══════════════════════════════════════════╝${_C_RST}\n\n"

        # 菜单选项
        printf "  ${_C_GRN}1.${_C_RST} 安装 Xray-2go\n"
        printf "  ${_C_RED}2.${_C_RST} 卸载 Xray-2go\n"; _hr
        printf "  ${_C_GRN}3.${_C_RST} Argo 管理\n"
        printf "  ${_C_GRN}4.${_C_RST} Reality 管理\n"
        printf "  ${_C_GRN}5.${_C_RST} SOCKS5 管理\n"; _hr
        printf "  ${_C_GRN}6.${_C_RST} FreeFlow 管理\n"
        printf "  ${_C_GRN}7.${_C_RST} 查看节点\n"
        printf "  ${_C_GRN}8.${_C_RST} 修改 UUID\n"
        printf "  ${_C_GRN}9.${_C_RST} 自动重启管理\n"
        printf "  ${_C_GRN}s.${_C_RST} 快捷方式/脚本更新\n"; _hr
        printf "  ${_C_RED}0.${_C_RST} 退出\n\n"
        local _c; prompt "请输入选择 (0-9/A): " _c; echo ""

        case "${_c:-}" in
            1)
                if [ "${_cx}" -eq 0 ]; then
                    log_warn "Xray-2go 已安装，如需重装请先卸载 (选项 2)"
                else
                    # 安装向导：收集所有协议配置
                    ask_argo_mode
                    [ "$(state_get '.argo.enabled')" = "true" ] && ask_argo_protocol
                    ask_freeflow_mode
                    ask_reality_mode
                    ask_socks5_mode

                    # 端口冲突前置检测
                    [ "$(state_get '.argo.enabled')" = "true" ] && \
                        port_in_use "$(state_get '.argo.port')" && \
                        log_warn "端口 $(state_get '.argo.port') 已被占用，可安装后修改"
                    [ "$(state_get '.ff.enabled')" = "true" ] && port_in_use 8080 && \
                        log_warn "端口 8080 已被占用，FreeFlow 可能无法启动"
                    if [ "$(state_get '.reality.enabled')" = "true" ]; then
                        local _rport _aport
                        _rport=$(state_get '.reality.port')
                        _aport=$(state_get '.argo.port')
                        [ "${_rport}" = "${_aport}" ] && \
                            log_warn "Reality 端口 (${_rport}) 与 Argo 回源端口相同，请安装后修改其中一个"
                    fi
                    if [ "$(state_get '.socks5.enabled')" = "true" ]; then
                        local _s5port
                        _s5port=$(state_get '.socks5.port')
                        port_in_use "${_s5port}" && \
                            log_warn "SOCKS5 端口 (${_s5port}) 已被占用，可安装后通过 [A. SOCKS5 管理] 修改"
                    fi

                    check_systemd_resolved
                    check_bbr

                    install_core || { log_error "安装失败"; _pause; continue; }

                    # 安装后 Argo 域名获取流程
                    if [ "$(state_get '.argo.protocol')" = "xhttp" ]; then
                        log_warn "XHTTP 仅支持固定隧道，现在进入配置..."
                        configure_fixed_tunnel \
                            || log_error "固定隧道配置失败，请从 [3. Argo 管理] 重新配置"

                    elif [ "$(state_get '.argo.enabled')" = "true" ]; then
                        echo ""
                        printf "  ${_C_GRN}1.${_C_RST} 临时隧道 (WS, 自动生成域名) ${_C_YLW}[默认]${_C_RST}\n"
                        printf "  ${_C_GRN}2.${_C_RST} 固定隧道 (自有 token/json)\n"
                        local _tc; prompt "请选择隧道类型 (回车默认1): " _tc
                        case "${_tc:-1}" in
                            2)
                                if ! configure_fixed_tunnel; then
                                    log_warn "固定隧道配置失败，回退临时隧道"
                                    _svc_manager restart tunnel || true
                                    local _td; _td=$(get_temp_domain) || _td=""
                                    if [ -n "${_td:-}" ]; then
                                        state_set '.argo.domain = $d' --arg d "${_td}" || true
                                        state_persist || true
                                        log_ok "ArgoDomain: ${_td}"
                                    else
                                        log_warn "未能获取临时域名，可从 [3→4] 刷新"
                                    fi
                                fi ;;
                            *)
                                log_step "等待 Argo 临时域名（最多约 44s）..."
                                _svc_manager restart tunnel || true
                                local _td; _td=$(get_temp_domain) || _td=""
                                if [ -n "${_td:-}" ]; then
                                    state_set '.argo.domain = $d' --arg d "${_td}" || true
                                    state_persist || true
                                    log_ok "ArgoDomain: ${_td}"
                                else
                                    log_warn "未能获取临时域名，可从 [3→4] 刷新"
                                fi ;;
                        esac
                    fi
                    print_nodes
                fi ;;
            2) uninstall_all ;;
            3) manage_argo ;;
            4) manage_reality ;;
            5) manage_socks5 ;;
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

# @description 脚本入口：权限检查 → init 检测 → 依赖预检 → 状态引导 → 主菜单
main() {
    check_root       # 权限校验
    _detect_init     # 检测 init 系统（systemd/openrc）
    preflight_check  # 依赖预检（确保 jq 可用，state_init 依赖它）
    state_init       # 引导 SSOT _STATE
    menu             # 进入主菜单
}

main "$@"
