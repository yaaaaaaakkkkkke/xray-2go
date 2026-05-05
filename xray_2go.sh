#!/usr/bin/env bash
# ==============================================================================
# xray-2go — 插件化代理管理脚本
# 安全基线：输入校验 · 敏感文件保护 · 原子写入 · 服务互斥 · 可回滚清理
# 协议支持：Argo · FreeFlow · Reality · VLESS-TCP · VLESS-XHTTP-H3（均以插件形式加载）
# 平台支持：Debian/Ubuntu/RHEL系 (systemd) · Alpine (OpenRC；Argo/cloudflared 需用户预装官方 cloudflared)
# ==============================================================================
set -uo pipefail  # 交互菜单使用显式返回值处理，避免 set -e 造成误退出
[ "${BASH_VERSINFO[0]}" -ge 4 ] \
    || { printf '\033[1;91m[ERR ] 需要 bash 4.0 或更高版本\033[0m\n' >&2; exit 1; }

# ==============================================================================
# Global constants
# ==============================================================================
readonly WORK_DIR="/etc/xray2go"
readonly XRAY_BIN="${WORK_DIR}/xray"
readonly ARGO_BIN="${WORK_DIR}/argo"
readonly CONFIG_FILE="${WORK_DIR}/config.json"
readonly STATE_FILE="${WORK_DIR}/state.json"
readonly PLUGIN_DIR="${WORK_DIR}/plugins"
readonly SHORTCUT="/usr/local/bin/s"
readonly SELF_DEST="/usr/local/bin/xray2go"

readonly _LOCK_FILE="${WORK_DIR}/.lock"
readonly _FW_PORTS_FILE="${WORK_DIR}/.fw_ports"
readonly _FW_RULES_FILE="${WORK_DIR}/.fw_rules"
readonly _CONFIG_HASH_FILE="${WORK_DIR}/.config.sha256"
readonly _SYSCTL_FILE="/etc/sysctl.d/99-xray2go.conf"
readonly _HOSTS_BAK="${WORK_DIR}/.hosts.bak"
readonly _ARGO_ENV_FILE="${WORK_DIR}/.argo_env"
readonly _ACME_ENV_FILE="${WORK_DIR}/.acme_env"
readonly _CERT_DIR="${WORK_DIR}/certs"

readonly _SVC_XRAY="xray2go"
readonly _SVC_TUNNEL="tunnel2go"

readonly _XRAY_MIRRORS=(
    "https://github.com/XTLS/Xray-core/releases/download"
)

readonly _XPAD_JSON='{"xPaddingObfsMode":true,"xPaddingMethod":"tokenish","xPaddingPlacement":"queryInHeader","xPaddingHeader":"X-Cache","xPaddingKey":"_Luckylos"}'
readonly _XPAD_QS='%22xPaddingObfsMode%22%3Atrue%2C%22xPaddingMethod%22%3A%22tokenish%22%2C%22xPaddingPlacement%22%3A%22queryInHeader%22%2C%22xPaddingHeader%22%3A%22X-Cache%22%2C%22xPaddingKey%22%3A%22_Luckylos%22'

# 动态插件注册表（由 plugin_load_all 填充，非 readonly）
_PLUGIN_REGISTRY=()

# ==============================================================================
# Temporary workspace
# ==============================================================================
_G_TMP_DIR=""

trap '_trap_exit' EXIT
trap '_trap_int'  INT TERM

_trap_exit() {
    [ -n "${_G_TMP_DIR:-}" ] && rm -rf "${_G_TMP_DIR}" 2>/dev/null || true
    [ -t 1 ] && tput cnorm 2>/dev/null || true
}
_trap_int() {
    printf '\n' >&2
    printf '\033[1;91m[ERR ] 已中断\033[0m\n' >&2
    exit 130
}

_ensure_tmp_dir() {
    if [ -z "${_G_TMP_DIR:-}" ]; then
        mkdir -p "${WORK_DIR}" 2>/dev/null || true
        _G_TMP_DIR=$(mktemp -d "${WORK_DIR}/.tmp_XXXXXX") \
            || { printf '\033[1;91m[ERR ] 无法在 %s 创建临时目录\033[0m\n' "${WORK_DIR}" >&2; exit 1; }
    fi
}

tmp_file() { _ensure_tmp_dir; mktemp "${_G_TMP_DIR}/${1:-tmp_XXXXXX}"; }

# ==============================================================================
# Logging and string utilities
# ==============================================================================
readonly C_RST=$'\033[0m'  C_BOLD=$'\033[1m'
readonly C_RED=$'\033[1;91m'  C_GRN=$'\033[1;32m'  C_YLW=$'\033[1;33m'
readonly C_PUR=$'\033[1;35m'  C_CYN=$'\033[1;36m'

log_info()  { printf '%s[INFO]%s %s\n'  "${C_CYN}" "${C_RST}" "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n'  "${C_GRN}" "${C_RST}" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n'  "${C_YLW}" "${C_RST}" "$*" >&2; }
log_error() { printf '%s[ERR ]%s %s\n'  "${C_RED}" "${C_RST}" "$*" >&2; }
log_step()  { printf '%s[....] %s%s\n'  "${C_PUR}" "$*" "${C_RST}"; }
log_title() { printf '\n%s%s%s\n'       "${C_BOLD}${C_PUR}" "$*" "${C_RST}"; }
die()       { log_error "$1"; exit "${2:-1}"; }

prompt() {
    printf '%s%s%s' "${C_RED}" "$1" "${C_RST}" >&2
    read -r "$2" </dev/tty
}
_pause() {
    local _d
    printf '%s按回车键继续...%s' "${C_RED}" "${C_RST}" >&2
    read -r _d </dev/tty || true
}
_hr() { printf '%s  ──────────────────────────────────%s\n' "${C_PUR}" "${C_RST}"; }

_print_link() {
    local _link="$1"
    [ -n "${_link:-}" ] && printf '%s%s%s\n' "${C_CYN}" "${_link}" "${C_RST}"
}

urlencode_path() {
    printf '%s' "$1" | sed \
        's/%/%25/g;s/ /%20/g;s/!/%21/g;s/"/%22/g;s/#/%23/g;s/\$/%24/g;
         s/&/%26/g;s/'\''/%27/g;s/(/%28/g;s/)/%29/g;s/\*/%2A/g;s/+/%2B/g;
         s/,/%2C/g;s/:/%3A/g;s/;/%3B/g;s/=/%3D/g;s/?/%3F/g;s/@/%40/g;
         s/\[/%5B/g;s/\]/%5D/g'
}

# ==============================================================================
# Platform detection and package helpers
# ==============================================================================
_G_INIT_SYS="" _G_ARCH_CF="" _G_ARCH_XRAY="" _G_CACHED_REALIP=""

platform_detect_init() {
    if [ -f /.dockerenv ] || grep -qE 'docker|lxc|containerd' /proc/1/cgroup 2>/dev/null; then
        log_warn "检测到容器环境，服务管理功能可能受限"
    fi
    local _pid1_comm
    _pid1_comm=$(cat /proc/1/comm 2>/dev/null | tr -d '\n' || printf 'unknown')
    if [ "${_pid1_comm}" = "systemd" ] && command -v systemctl >/dev/null 2>&1; then
        _G_INIT_SYS="systemd"
    elif command -v rc-update >/dev/null 2>&1; then
        _G_INIT_SYS="openrc"
    else
        die "不支持的 init 系统（PID 1: ${_pid1_comm}）"
    fi
}
is_systemd() { [ "${_G_INIT_SYS}" = "systemd" ]; }
is_openrc()  { [ "${_G_INIT_SYS}" = "openrc"  ]; }

platform_detect_arch() {
    [ -n "${_G_ARCH_XRAY:-}" ] && return 0
    case "$(uname -m)" in
        x86_64)        _G_ARCH_CF="amd64";  _G_ARCH_XRAY="64"        ;;
        x86|i686|i386) _G_ARCH_CF="386";    _G_ARCH_XRAY="32"        ;;
        aarch64|arm64) _G_ARCH_CF="arm64";  _G_ARCH_XRAY="arm64-v8a" ;;
        armv7l)        _G_ARCH_CF="armv7";  _G_ARCH_XRAY="arm32-v7a" ;;
        s390x)         _G_ARCH_CF="s390x";  _G_ARCH_XRAY="s390x"     ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

platform_pkg_require() {
    local _pkg="$1" _bin="${2:-$1}"
    command -v "${_bin}" >/dev/null 2>&1 && return 0
    log_step "安装依赖: ${_pkg}"
    local _rc=0
    if   command -v apt-get >/dev/null 2>&1; then
        if ! find /var/cache/apt/pkgcache.bin -mtime -1 >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${_pkg}" >/dev/null 2>&1; _rc=$?
    elif command -v dnf  >/dev/null 2>&1; then dnf install -y "${_pkg}" >/dev/null 2>&1; _rc=$?
    elif command -v yum  >/dev/null 2>&1; then yum install -y "${_pkg}" >/dev/null 2>&1; _rc=$?
    elif command -v apk  >/dev/null 2>&1; then apk add       "${_pkg}" >/dev/null 2>&1; _rc=$?
    else die "未找到包管理器"; fi
    hash -r 2>/dev/null || true
    [ "${_rc}" -ne 0 ] && die "${_pkg} 安装失败"
    command -v "${_bin}" >/dev/null 2>&1 || die "${_bin} 安装后仍不可用"
    log_ok "${_pkg} 已就绪"
}

platform_preflight() {
    log_step "依赖预检..."
    for _d in curl unzip jq; do platform_pkg_require "${_d}"; done
    command -v xxd    >/dev/null 2>&1 || platform_pkg_require "xxd" "xxd" 2>/dev/null \
        || log_info "xxd 未安装，shortId 将使用内置随机源"
    command -v openssl >/dev/null 2>&1 || log_info "openssl 未安装，shortId 将使用内置随机源"
    if [ -f "${XRAY_BIN}" ]; then
        [ -x "${XRAY_BIN}" ] || { chmod +x "${XRAY_BIN}"; log_warn "已设置 xray 可执行权限"; }
        "${XRAY_BIN}" version >/dev/null 2>&1 || log_warn "xray 二进制可能损坏"
    fi
    [ -f "${ARGO_BIN}" ] && ! [ -x "${ARGO_BIN}" ] \
        && { chmod +x "${ARGO_BIN}"; log_warn "已设置 cloudflared 可执行权限"; }
    log_ok "依赖预检通过"
}

platform_get_realip() {
    [ -n "${_G_CACHED_REALIP:-}" ] && { printf '%s' "${_G_CACHED_REALIP}"; return 0; }
    local _ip _org _v6 _result=""
    _ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null) || true
    if [ -z "${_ip:-}" ]; then
        _v6=$(curl -sf --max-time 5 https://api6.ipify.org 2>/dev/null) || true
        [ -n "${_v6:-}" ] && _result="[${_v6}]"
    else
        _org=$(curl -sf --max-time 5 "https://ipinfo.io/${_ip}/org" 2>/dev/null) || true
        if printf '%s' "${_org:-}" | grep -qiE 'Cloudflare|UnReal|AEZA|Andrei'; then
            _v6=$(curl -sf --max-time 5 https://api6.ipify.org 2>/dev/null) || true
            [ -n "${_v6:-}" ] && _result="[${_v6}]" || _result="${_ip}"
        else
            _result="${_ip}"
        fi
    fi
    _G_CACHED_REALIP="${_result}"
    printf '%s' "${_G_CACHED_REALIP}"
}

platform_fix_time_sync() {
    [ -f /etc/redhat-release ] || [ -f /etc/centos-release ] || return 0
    local _pm; command -v dnf >/dev/null 2>&1 && _pm="dnf" || _pm="yum"
    log_step "RHEL 系：修正时间同步..."
    ${_pm} install -y chrony >/dev/null 2>&1 || true
    systemctl enable --now chronyd >/dev/null 2>&1 || true
    chronyc -a makestep >/dev/null 2>&1 || true
    ${_pm} update -y ca-certificates >/dev/null 2>&1 || true
    log_ok "时间同步已修正"
}

check_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || die "请在 root 下运行脚本"; }

# ==============================================================================
# §L_PORT  Port Manager — 精确端口检测唯一入口
# ==============================================================================
port_mgr_in_use() {
    local _p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null | awk -v p="${_p}" \
            'BEGIN{r=0}{split($4,a,":");if(a[length(a)]==p){r=1;exit}}END{exit !r}'
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | awk -v p="${_p}" \
            'BEGIN{r=0}{split($4,a,":");if(a[length(a)]==p){r=1;exit}}END{exit !r}'
        return $?
    fi
    local _hex; _hex=$(printf '%04X' "${_p}")
    awk -v h="${_hex}" \
        'NR>1{n=split($2,a,":");if(a[n]==h){found=1;exit}}END{exit !found}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

port_mgr_in_use_udp() {
    local _p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ulnH 2>/dev/null | awk -v p="${_p}" \
            'BEGIN{r=0}{split($4,a,":");if(a[length(a)]==p){r=1;exit}}END{exit !r}'
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ulnp 2>/dev/null | awk -v p="${_p}" \
            'BEGIN{r=0}{split($4,a,":");if(a[length(a)]==p){r=1;exit}}END{exit !r}'
        return $?
    fi
    local _hex; _hex=$(printf '%04X' "${_p}")
    awk -v h="${_hex}" \
        'NR>1{n=split($2,a,":");if(a[n]==h){found=1;exit}}END{exit !found}' \
        /proc/net/udp /proc/net/udp6 2>/dev/null
}

port_mgr_random() {
    local _i=0 _p
    while true; do
        _p=$(shuf -i 10000-60000 -n 1 2>/dev/null \
             || awk 'BEGIN{srand();print int(rand()*50000)+10000}')
        _i=$(( _i + 1 ))
        port_mgr_in_use "${_p}" || { printf '%s' "${_p}"; return 0; }
        [ "${_i}" -gt 30 ] && { log_error "无法找到空闲端口"; return 1; }
    done
}

# ==============================================================================
# State management
# ==============================================================================
_G_STATE=""

# 当前 state schema：端口和协议状态集中管理
# 加载 state 时自动规范化 schema
readonly _STATE_DEFAULT='{
  "uuid": "",
  "ports": {
    "argo":    18888,
    "ff":      8080,
    "reality": 443,
    "vltcp":   1234,
    "vlquic":  443
  },
  "argo": {
    "enabled":  true,
    "protocol": "ws",
    "mode":     "fixed",
    "domain":   null,
    "token":    null
  },
  "ff": {
    "enabled":  false,
    "protocol": "none",
    "path":     "/",
    "host":     ""
  },
  "reality": {
    "enabled": false,
    "sni":     "addons.mozilla.org",
    "network": "tcp",
    "pbk":     null,
    "pvk":     null,
    "sid":     null
  },
  "vltcp": {
    "enabled": false,
    "listen":  "0.0.0.0"
  },
  "vlquic": {
    "enabled": false,
    "listen":  "0.0.0.0",
    "domain":  "",
    "cert":    "",
    "key":     "",
    "acme_method": "manual"
  },
  "xpad": {
    "argo":    true,
    "ff":      true,
    "reality": true
  },
  "cfip":   "cf.tencentapp.cn",
  "cfport": "443"
}'

# ── 原子写入（同 FS tmp → rename）─────────────────────────────────────────────
atomic_write() {
    local _dest="$1" _content="$2"
    mkdir -p "$(dirname "${_dest}")" 2>/dev/null || true
    local _t; _t=$(tmp_file "aw_XXXXXX") || return 1
    printf '%s' "${_content}" > "${_t}" || { rm -f "${_t}"; return 1; }
    mv "${_t}" "${_dest}"              || { rm -f "${_t}"; return 1; }
}

atomic_write_with_backup() {
    local _dest="$1" _content="$2" _keep="${3:-3}"
    if [ -f "${_dest}" ]; then
        local _ts; _ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || printf 'bak')
        cp -f "${_dest}" "${_dest}.${_ts}.bak" 2>/dev/null || true
        ls -t "${_dest}".*.bak 2>/dev/null \
            | tail -n "+$(( _keep + 1 ))" | xargs rm -f 2>/dev/null || true
    fi
    atomic_write "${_dest}" "${_content}"
}

# 写入敏感文件：同 FS 原子替换 + 强制 0600，避免 state/token/凭证泄露。
atomic_write_secret() {
    local _dest="$1" _content="$2"
    local _old_umask _rc
    _old_umask=$(umask)
    umask 077
    atomic_write "${_dest}" "${_content}"
    _rc=$?
    umask "${_old_umask}"
    [ "${_rc}" -eq 0 ] || return "${_rc}"
    chmod 600 "${_dest}" 2>/dev/null || true
}

atomic_write_secret_with_backup() {
    local _dest="$1" _content="$2" _keep="${3:-3}"
    if [ -f "${_dest}" ]; then
        local _ts; _ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || printf 'bak')
        cp -f "${_dest}" "${_dest}.${_ts}.bak" 2>/dev/null || true
        chmod 600 "${_dest}.${_ts}.bak" 2>/dev/null || true
        ls -t "${_dest}".*.bak 2>/dev/null \
            | tail -n "+$(( _keep + 1 ))" | xargs rm -f 2>/dev/null || true
    fi
    atomic_write_secret "${_dest}" "${_content}"
}

# ── 文件锁（串行化所有 read-modify-write）────────────────────────────────────
with_lock() {
    local _fn="$1"; shift
    mkdir -p "${WORK_DIR}" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        ( flock -x 9 || { log_error "获取文件锁失败"; exit 1; }; "${_fn}" "$@" ) \
            9>"${_LOCK_FILE}"
    else
        log_warn "flock 不可用，并发写入无保护"
        "${_fn}" "$@"
    fi
}


# 修改端口后需要统一提交配置、持久化、同步防火墙，并回显 state 实际值。
_commit_port_change() {
    local _proto="$1" _new_port="$2"
    _commit || return 1
    log_ok "${_proto} 端口已更新: ${_new_port}（当前: $(port_of "${_proto}")）"
    config_print_nodes
}

# ── State 读/写 ───────────────────────────────────────────────────────────────
st_get() {
    local _v
    _v=$(printf '%s' "${_G_STATE}" | jq -r "${1} // empty" 2>/dev/null) || true
    printf '%s' "${_v}"
}

st_set() {
    local _f="$1"; shift
    local _n
    _n=$(printf '%s' "${_G_STATE}" | jq "$@" "${_f}" 2>/dev/null) \
        || { log_error "st_set 失败: ${_f}"; return 1; }
    [ -n "${_n:-}" ] && _G_STATE="${_n}" \
        || { log_error "st_set 返回空 JSON"; return 1; }
}

xpad_of() {
    case "${1:-}" in
        argo|ff|reality) : ;;
        *) log_error "未知 xPadding 目标: ${1:-}"; return 1 ;;
    esac
    local _v
    _v=$(printf '%s' "${_G_STATE}" | jq -r --arg k "${1}" '
        if .xpad[$k] == true then "true"
        elif .xpad[$k] == false then "false"
        else empty end
    ' 2>/dev/null) || true
    [ -n "${_v:-}" ] && printf '%s' "${_v}" || printf 'true'
}

# 统一端口读取接口（单一数据源）
# 所有模块禁止硬编码端口，必须调用此函数
port_of() {
    # 用法：port_of argo / ff / reality / vltcp / vlquic
    local _v; _v=$(st_get ".ports.${1}")
    [ -n "${_v:-}" ] && [ "${_v}" != "null" ] && printf '%s' "${_v}" || printf '0'
}

# ── 输入校验层 ───────────────────────────────────────────────────────────────
# val_port: 限制端口为纯数字 1-65535，防止配置注入
val_port() {
    local _p="$1"
    case "${_p}" in
        ''|*[!0-9]*) log_error "非法端口值: ${_p}"; return 1 ;;
    esac
    [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]         || { log_error "端口超出范围: ${_p}"; return 1; }
    printf '%s' "${_p}"
}

# val_uuid: 严格匹配 UUID v4 格式，防止 JSON 注入
val_uuid() {
    printf '%s' "${1:-}" | grep -qiE         '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'         || { log_error "非法 UUID 格式: ${1:-}"; return 1; }
    printf '%s' "${1}"
}

# val_domain: 防止域名字段注入 YAML 特殊字符
val_domain() {
    printf '%s' "${1:-}" | grep -qE         '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$'         || { log_error "非法域名格式: ${1:-}"; return 1; }
    printf '%s' "${1}"
}

# val_path: 路径只允许 / 开头的 URL-safe 字符串
val_path() {
    local _p="${1:-/}"
    case "${_p}" in /*) : ;; *) _p="/${_p}" ;; esac
    printf '%s' "${_p}" | grep -qE '^[/a-zA-Z0-9_.~-]+$'         || { log_error "非法 path 格式: ${_p}"; return 1; }
    printf '%s' "${_p}"
}

# val_listen_addr: 限制 Xray listen 为明确的 IP 监听地址，避免坏 state 导致配置失败
val_listen_addr() {
    local _a="${1:-}"
    case "${_a}" in
        0.0.0.0|127.0.0.1|::|::1) printf '%s' "${_a}"; return 0 ;;
    esac
    if printf '%s' "${_a}" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        local IFS=. _o
        for _o in ${_a}; do
            [ "${_o}" -ge 0 ] 2>/dev/null && [ "${_o}" -le 255 ] 2>/dev/null || { log_error "非法监听地址: ${_a}"; return 1; }
        done
        printf '%s' "${_a}"; return 0
    fi
    if printf '%s' "${_a}" | grep -qE '^[0-9A-Fa-f:]+$' && printf '%s' "${_a}" | grep -q ':'; then
        printf '%s' "${_a}"; return 0
    fi
    log_error "非法监听地址: ${_a}"
    return 1
}

_st_persist_inner() {
    local _json
    _json=$(printf '%s\n' "${_G_STATE}" | jq . 2>/dev/null) \
        || { log_error "state 序列化失败"; return 1; }
    atomic_write_secret_with_backup "${STATE_FILE}" "${_json}" 3 || return 1
    # state.json 含 token 等敏感数据，严格限制权限
    chmod 600 "${STATE_FILE}" 2>/dev/null || true
}

st_persist() { with_lock _st_persist_inner; }

# State schema 规范化
# 将可识别的既有字段归一到当前 schema，并补齐缺失默认值
_st_normalize_schema() {

    # 规范化端口字段到顶层 ports
    local _ap _rp _vp _qp _fp
    _ap=$(st_get '.argo.port    // empty')
    _rp=$(st_get '.reality.port // empty')
    _vp=$(st_get '.vltcp.port   // empty')
    _qp=$(st_get '.vlquic.port  // empty')
    _fp=$(st_get '.ff.port      // empty')

    # 若 .ports 不存在则初始化
    local _ports; _ports=$(st_get '.ports')
    if [ -z "${_ports:-}" ] || [ "${_ports}" = "null" ]; then
        st_set '.ports = {"argo":18888,"ff":8080,"reality":443,"vltcp":1234,"vlquic":443}'
    fi

    # 将分散端口字段归一到 .ports（仅当字段存在且非默认值时）
    [ -n "${_ap:-}" ] && [ "${_ap}" != "null" ] && {
        st_set '.ports.argo = ($p|tonumber)' --arg p "${_ap}"
        st_set 'del(.argo.port)' 2>/dev/null || true; }
    [ -n "${_rp:-}" ] && [ "${_rp}" != "null" ] && {
        st_set '.ports.reality = ($p|tonumber)' --arg p "${_rp}"
        st_set 'del(.reality.port)' 2>/dev/null || true; }
    [ -n "${_vp:-}" ] && [ "${_vp}" != "null" ] && {
        st_set '.ports.vltcp = ($p|tonumber)' --arg p "${_vp}"
        st_set 'del(.vltcp.port)' 2>/dev/null || true; }
    [ -n "${_qp:-}" ] && [ "${_qp}" != "null" ] && {
        st_set '.ports.vlquic = ($p|tonumber)' --arg p "${_qp}"
        st_set 'del(.vlquic.port)' 2>/dev/null || true; }
    [ -n "${_fp:-}" ] && [ "${_fp}" != "null" ] && {
        st_set '.ports.ff = ($p|tonumber)' --arg p "${_fp}"
        st_set 'del(.ff.port)' 2>/dev/null || true; }

    # 补全缺失/损坏端口字段，避免菜单显示 0 或修改端口后写入无效路径
    local _c
    _c=$(st_get '.ports.argo')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ] || [ "${_c}" = "0" ]; } && st_set '.ports.argo = 18888'
    _c=$(st_get '.ports.ff')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ] || [ "${_c}" = "0" ]; } && st_set '.ports.ff = 8080'
    _c=$(st_get '.ports.reality')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ] || [ "${_c}" = "0" ]; } && st_set '.ports.reality = 443'
    _c=$(st_get '.ports.vltcp')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ] || [ "${_c}" = "0" ]; } && st_set '.ports.vltcp = 1234'
    _c=$(st_get '.ports.vlquic')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ] || [ "${_c}" = "0" ]; } && st_set '.ports.vlquic = 443'

    _c=$(st_get '.reality.network')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.reality.network = "tcp"'
    _c=$(st_get '.cfip')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.cfip = "cf.tencentapp.cn"'
    _c=$(st_get '.cfport')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.cfport = "443"'
    _c=$(st_get '.ff.host')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.ff.host = ""'
    # 规范化 xPadding 开关结构。
    local _global_xpad
    _global_xpad=$(printf '%s' "${_G_STATE}" | jq -r '
        if .xpad.enabled == true then "true"
        elif .xpad.enabled == false then "false"
        else empty end
    ' 2>/dev/null) || true
    case "${_global_xpad}" in
        true|false)
            st_set '.xpad.argo = $v | .xpad.ff = $v | .xpad.reality = $v | del(.xpad.enabled)' --argjson v "${_global_xpad}" ;;
    esac
    printf '%s' "${_G_STATE}" | jq -e '.xpad.argo == null' >/dev/null 2>&1 && \
        st_set '.xpad.argo = true'
    printf '%s' "${_G_STATE}" | jq -e '.xpad.ff == null' >/dev/null 2>&1 && \
        st_set '.xpad.ff = true'
    printf '%s' "${_G_STATE}" | jq -e '.xpad.reality == null' >/dev/null 2>&1 && \
        st_set '.xpad.reality = true'
    _c=$(st_get '.vltcp.listen')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.vltcp.listen = "0.0.0.0"'
    _c=$(st_get '.vlquic.listen')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.vlquic.listen = "0.0.0.0"'
    _c=$(st_get '.vlquic.domain')
    { [ "${_c}" = "null" ]; } && st_set '.vlquic.domain = ""'
    _c=$(st_get '.vlquic.cert')
    { [ "${_c}" = "null" ]; } && st_set '.vlquic.cert = ""'
    _c=$(st_get '.vlquic.key')
    { [ "${_c}" = "null" ]; } && st_set '.vlquic.key = ""'
    _c=$(st_get '.vlquic.acme_method')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.vlquic.acme_method = "manual"'
    _c=$(st_get '.ff.path')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.ff.path = "/"'
    _c=$(st_get '.ff.protocol')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.ff.protocol = "none"'

    return 0
}

st_init() {
    if [ -f "${STATE_FILE}" ]; then
        local _raw; _raw=$(cat "${STATE_FILE}" 2>/dev/null || true)
        if printf '%s' "${_raw}" | jq -e . >/dev/null 2>&1; then
            _G_STATE="${_raw}"
            _st_normalize_schema
            local _u; _u=$(st_get '.uuid')
            [ -z "${_u:-}" ] && st_set '.uuid = $u' --arg u "$(crypto_gen_uuid)"
            return 0
        fi
        log_warn "state.json 损坏，重置为默认值..."
    fi
    _G_STATE="${_STATE_DEFAULT}"
    _st_normalize_schema
    local _u; _u=$(st_get '.uuid')
    [ -z "${_u:-}" ] && st_set '.uuid = $u' --arg u "$(crypto_gen_uuid)"
    [ -d "${WORK_DIR}" ] && { st_persist 2>/dev/null || true; log_info "状态已初始化"; }
}

# ==============================================================================
# Plugin runtime
# ==============================================================================
# 插件接口契约（每个插件文件必须实现）：
#   plugin_inbound  — 输出单个 inbound JSON（或空字符串表示禁用）
#   plugin_link     — 输出分享链接字符串（或空）
#   plugin_ports    — 每行输出一个端口号（当前协议占用的端口）
#   plugin_enabled  — 返回 0=启用 / 1=禁用
#
# 插件文件约定：
#   PLUGIN_DIR/<name>.sh
#   所有函数以 _plg_<name>_<method> 命名，避免全局污染
#   注册后通过 plugin_call <name> <method> [args] 调用

# 加载所有插件并注册到 _PLUGIN_REGISTRY
plugin_load_all() {
    _PLUGIN_REGISTRY=()
    mkdir -p "${PLUGIN_DIR}"
    local _f _name
    for _f in "${PLUGIN_DIR}"/*.sh; do
        [ -f "${_f}" ] || continue
        _name=$(basename "${_f}" .sh)
        # source 插件（在当前 shell 中定义函数）
        # shellcheck source=/dev/null
        . "${_f}" || { log_warn "插件加载失败: ${_f}"; continue; }
        # 验证必须实现的接口
        if ! declare -f "_plg_${_name}_inbound" >/dev/null 2>&1 \
            || ! declare -f "_plg_${_name}_link"    >/dev/null 2>&1 \
            || ! declare -f "_plg_${_name}_ports"   >/dev/null 2>&1 \
            || ! declare -f "_plg_${_name}_enabled" >/dev/null 2>&1; then
            log_warn "插件 ${_name} 接口不完整，已跳过"
            continue
        fi
        _PLUGIN_REGISTRY+=( "${_name}" )
        log_info "插件已加载: ${_name}"
    done
}

# 调用插件方法
plugin_call() {
    local _name="$1" _method="$2"; shift 2
    local _fn="_plg_${_name}_${_method}"
    declare -f "${_fn}" >/dev/null 2>&1 \
        || { log_error "插件方法未找到: ${_fn}"; return 1; }
    "${_fn}" "$@"
}

# 将所有内置协议插件写入 PLUGIN_DIR（首次运行或插件缺失时调用）
plugin_install_builtins() {
    mkdir -p "${PLUGIN_DIR}"
    # 内置插件属于脚本本体的一部分：每次运行刷新，确保主脚本更新能同步下发。
    # 用户自定义插件请使用其它文件名，避免与 argo/ff/reality/vltcp 重名。
    _plugin_write_argo
    _plugin_write_ff
    _plugin_write_reality
    _plugin_write_vltcp
    _plugin_write_vlquic
}

# ==============================================================================
# Built-in protocol plugins
# ==============================================================================
# 设计原则：
#   - 插件只读 state，不写 state
#   - 插件不调用 svc_* 或 fw_*（由主程序调度）
#   - 端口全部通过 port_of <name> 读取，不硬编码

_plugin_write_argo() {
cat > "${PLUGIN_DIR}/argo.sh" << 'PLUGIN_EOF'
# xray-2go plugin: argo
# 接口：_plg_argo_inbound / _plg_argo_link / _plg_argo_ports / _plg_argo_enabled

_plg_argo_enabled() {
    [ "$(st_get '.argo.enabled')" = "true" ]
}

_plg_argo_ports() {
    _plg_argo_enabled || return 0
    port_of argo
}

_plg_argo_inbound() {
    _plg_argo_enabled || return 0
    local _port _proto _uuid
    _port=$(port_of argo)
    _proto=$(st_get '.argo.protocol')
    _uuid=$(st_get '.uuid')
    local _xpad
    if [ "$(xpad_of argo)" = "true" ]; then
        _xpad=$(printf '%s' "${_XPAD_JSON}" | jq -c .)
    else
        _xpad='{}'
    fi
    case "${_proto}" in
        xhttp)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                   --arg mode "auto" --argjson x "${_xpad}" '{
                port:$port, listen:"127.0.0.1", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp",
                    xhttpSettings:({path:"/argo", mode:$mode} + $x)}}' ;;
        *)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" '{
                port:$port, listen:"127.0.0.1", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"ws", wsSettings:{path:"/argo"}}}' ;;
    esac
}

_plg_argo_link() {
    _plg_argo_enabled || return 0
    local _domain _proto _uuid _cfip _cfport _xqs
    _domain=$(st_get '.argo.domain')
    [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ] || return 0
    _proto=$(st_get '.argo.protocol')
    _uuid=$(st_get '.uuid')
    _cfip=$(st_get '.cfip')
    _cfport=$(st_get '.cfport')
    [ "$(xpad_of argo)" = "true" ] && _xqs="${_XPAD_QS}" || _xqs=""
    case "${_proto}" in
        xhttp)
            if [ -n "${_xqs}" ]; then
                printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=xhttp&host=%s&path=%%2Fargo&mode=auto&extra=%%7B%s%%7D#Argo-XHTTP\n' \
                    "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" "${_xqs}"
            else
                printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=xhttp&host=%s&path=%%2Fargo&mode=auto#Argo-XHTTP\n' \
                    "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}"
            fi ;;
        *)
            printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%%2Fargo%%3Fed%%3D2560#Argo-WS\n' \
                "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" ;;
    esac
}
PLUGIN_EOF
    chmod 644 "${PLUGIN_DIR}/argo.sh"
}

_plugin_write_ff() {
cat > "${PLUGIN_DIR}/ff.sh" << 'PLUGIN_EOF'
# xray-2go plugin: ff (FreeFlow)

_plg_ff_enabled() {
    [ "$(st_get '.ff.enabled')" = "true" ] && \
    [ "$(st_get '.ff.protocol')" != "none" ]
}

_plg_ff_ports() {
    _plg_ff_enabled || return 0
    port_of ff
}

_plg_ff_inbound() {
    _plg_ff_enabled || return 0
    local _proto _path _uuid _port
    _proto=$(st_get '.ff.protocol')
    _path=$(st_get '.ff.path')
    _uuid=$(st_get '.uuid')
    _port=$(port_of ff)
    local _xpad
    if [ "$(xpad_of ff)" = "true" ]; then
        _xpad=$(printf '%s' "${_XPAD_JSON}" | jq -c .)
    else
        _xpad='{}'
    fi
    case "${_proto}" in
        ws)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" --arg path "${_path}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"ws", wsSettings:{path:$path}}}' ;;
        httpupgrade)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" --arg path "${_path}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"httpupgrade",
                    httpupgradeSettings:{path:$path}}}' ;;
        xhttp)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" --arg path "${_path}" \
                   --arg mode "stream-one" --argjson x "${_xpad}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp",
                    xhttpSettings:({path:$path, mode:$mode} + $x)}}' ;;
        tcphttp)
            local _host; _host=$(st_get '.ff.host')
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" --arg host "${_host}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"tcp",
                    tcpSettings:{header:{type:"http",request:{
                        version:"1.1", method:"GET", path:["/"],
                        headers:{
                            Host:[$host],
                            "User-Agent":["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"],
                            "Accept-Encoding":["gzip, deflate"],
                            Connection:["keep-alive"], Pragma:["no-cache"]
                        }}}}}}' ;;
        *) log_error "_plg_ff_inbound: 未知协议 ${_proto}"; return 1 ;;
    esac
}

_plg_ff_link() {
    _plg_ff_enabled || return 0
    local _proto _uuid _ip _penc _port _xqs
    _proto=$(st_get '.ff.protocol')
    _uuid=$(st_get '.uuid')
    _port=$(port_of ff)
    _ip=$(platform_get_realip)
    [ -z "${_ip:-}" ] && { log_warn "无法获取服务器 IP，FreeFlow 节点已跳过"; return 0; }
    _penc=$(urlencode_path "$(st_get '.ff.path')")
    [ "$(xpad_of ff)" = "true" ] && _xqs="${_XPAD_QS}" || _xqs=""
    case "${_proto}" in
        ws)
            printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&host=%s&path=%s#FreeFlow-WS\n' \
                "${_uuid}" "${_ip}" "${_port}" "${_ip}" "${_penc}" ;;
        httpupgrade)
            printf 'vless://%s@%s:%s?encryption=none&security=none&type=httpupgrade&host=%s&path=%s#FreeFlow-HTTPUpgrade\n' \
                "${_uuid}" "${_ip}" "${_port}" "${_ip}" "${_penc}" ;;
        xhttp)
            if [ -n "${_xqs}" ]; then
                printf 'vless://%s@%s:%s?encryption=none&security=none&type=xhttp&host=%s&path=%s&mode=stream-one&extra=%%7B%s%%7D#FreeFlow-XHTTP\n' \
                    "${_uuid}" "${_ip}" "${_port}" "${_ip}" "${_penc}" "${_xqs}"
            else
                printf 'vless://%s@%s:%s?encryption=none&security=none&type=xhttp&host=%s&path=%s&mode=stream-one#FreeFlow-XHTTP\n' \
                    "${_uuid}" "${_ip}" "${_port}" "${_ip}" "${_penc}"
            fi ;;
        tcphttp)
            local _host _henc
            _host=$(st_get '.ff.host')
            _henc=$(urlencode_path "${_host}")
            printf 'vless://%s@%s:%s?encryption=none&security=none&type=tcp&headerType=http&host=%s&path=%%2F#FreeFlow-TCP-HTTP\n' \
                "${_uuid}" "${_ip}" "${_port}" "${_henc}" ;;
    esac
}
PLUGIN_EOF
    chmod 644 "${PLUGIN_DIR}/ff.sh"
}

_plugin_write_reality() {
cat > "${PLUGIN_DIR}/reality.sh" << 'PLUGIN_EOF'
# xray-2go plugin: reality

_plg_reality_enabled() {
    [ "$(st_get '.reality.enabled')" = "true" ]
}

_plg_reality_ports() {
    _plg_reality_enabled || return 0
    port_of reality
}

_plg_reality_inbound() {
    _plg_reality_enabled || return 0
    local _pvk; _pvk=$(st_get '.reality.pvk')
    if [ -z "${_pvk:-}" ] || [ "${_pvk}" = "null" ]; then
        log_warn "Reality 密钥未就绪，已跳过"; return 0
    fi
    local _port _sni _sid _net _uuid _port
    _port=$(port_of reality)
    _sni=$(st_get '.reality.sni')
    _sid=$(st_get '.reality.sid')
    _net=$(st_get '.reality.network'); _net="${_net:-tcp}"
    _uuid=$(st_get '.uuid')
    local _xpad
    if [ "$(xpad_of reality)" = "true" ]; then
        _xpad=$(printf '%s' "${_XPAD_JSON}" | jq -c .)
    else
        _xpad='{}'
    fi
    case "${_net}" in
        xhttp)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                   --arg sni "${_sni}" --arg pvk "${_pvk}" --arg sid "${_sid}" \
                   --arg mode "stream-one" --argjson x "${_xpad}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp", security:"reality",
                    realitySettings:{dest:($sni+":443"),
                        serverNames:[$sni], privateKey:$pvk, shortIds:[$sid]},
                    xhttpSettings:({path:"/", mode:$mode} + $x)}}' ;;
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

_plg_reality_link() {
    _plg_reality_enabled || return 0
    local _rpbk; _rpbk=$(st_get '.reality.pbk')
    [ -n "${_rpbk:-}" ] && [ "${_rpbk}" != "null" ] || return 0
    local _ip; _ip=$(platform_get_realip)
    [ -z "${_ip:-}" ] && { log_warn "无法获取服务器 IP，Reality 节点已跳过"; return 0; }
    local _port _rnet _uuid _xqs
    _port=$(port_of reality)
    _rnet=$(st_get '.reality.network'); _rnet="${_rnet:-tcp}"
    _uuid=$(st_get '.uuid')
    [ "$(xpad_of reality)" = "true" ] && _xqs="${_XPAD_QS}" || _xqs=""
    case "${_rnet}" in
        xhttp)
            if [ -n "${_xqs}" ]; then
                printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%%2F&mode=stream-one&extra=%%7B%s%%7D#Reality-XHTTP\n' \
                    "${_uuid}" "${_ip}" "${_port}" \
                    "$(st_get '.reality.sni')" "${_rpbk}" "$(st_get '.reality.sid')" "${_xqs}"
            else
                printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%%2F&mode=stream-one#Reality-XHTTP\n' \
                    "${_uuid}" "${_ip}" "${_port}" \
                    "$(st_get '.reality.sni')" "${_rpbk}" "$(st_get '.reality.sid')"
            fi ;;
        *)
            printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#Reality-Vision\n' \
                "${_uuid}" "${_ip}" "${_port}" \
                "$(st_get '.reality.sni')" "${_rpbk}" "$(st_get '.reality.sid')" ;;
    esac
}
PLUGIN_EOF
    chmod 644 "${PLUGIN_DIR}/reality.sh"
}

_plugin_write_vltcp() {
cat > "${PLUGIN_DIR}/vltcp.sh" << 'PLUGIN_EOF'
# xray-2go plugin: vltcp

_plg_vltcp_enabled() {
    [ "$(st_get '.vltcp.enabled')" = "true" ]
}

_plg_vltcp_ports() {
    _plg_vltcp_enabled || return 0
    port_of vltcp
}

_plg_vltcp_inbound() {
    _plg_vltcp_enabled || return 0
    local _port _listen _uuid
    _port=$(port_of vltcp)
    _listen=$(st_get '.vltcp.listen')
    _uuid=$(st_get '.uuid')
    jq -n --argjson port "${_port}" --arg listen "${_listen}" --arg uuid "${_uuid}" '{
        port:$port, listen:$listen, protocol:"vless",
        settings:{clients:[{id:$uuid}], decryption:"none"}}'
}

_plg_vltcp_link() {
    _plg_vltcp_enabled || return 0
    local _listen _vhost _uuid _port
    _listen=$(st_get '.vltcp.listen')
    _uuid=$(st_get '.uuid')
    _port=$(port_of vltcp)
    [ "${_listen}" = "0.0.0.0" ] || [ "${_listen}" = "::" ] \
        && _vhost=$(platform_get_realip) || _vhost="${_listen}"
    [ -z "${_vhost:-}" ] && { log_warn "无法获取服务器 IP，VLESS-TCP 节点已跳过"; return 0; }
    printf 'vless://%s@%s:%s?type=tcp&security=none#VLESS-TCP\n' \
        "${_uuid}" "${_vhost}" "${_port}"
}
PLUGIN_EOF
    chmod 644 "${PLUGIN_DIR}/vltcp.sh"
}

_plugin_write_vlquic() {
cat > "${PLUGIN_DIR}/vlquic.sh" << 'PLUGIN_EOF'
# xray-2go plugin: vlquic (VLESS + XHTTP stream-one H3)

_plg_vlquic_enabled() {
    [ "$(st_get '.vlquic.enabled')" = "true" ]
}

_plg_vlquic_ports() {
    _plg_vlquic_enabled || return 0
    printf '%s/udp\n' "$(port_of vlquic)"
}

_plg_vlquic_inbound() {
    _plg_vlquic_enabled || return 0
    local _port _listen _uuid _domain _cert _key
    _port=$(port_of vlquic)
    _listen=$(st_get '.vlquic.listen')
    _uuid=$(st_get '.uuid')
    _domain=$(st_get '.vlquic.domain')
    _cert=$(st_get '.vlquic.cert')
    _key=$(st_get '.vlquic.key')
    [ -n "${_domain:-}" ] && [ -n "${_cert:-}" ] && [ -n "${_key:-}" ] || {
        log_error "VLESS-XHTTP-H3 缺少域名或证书路径"; return 1; }
    jq -n --argjson port "${_port}" --arg listen "${_listen}" --arg uuid "${_uuid}" \
          --arg domain "${_domain}" --arg cert "${_cert}" --arg key "${_key}" '{
        port:$port, listen:$listen, protocol:"vless",
        settings:{clients:[{id:$uuid}], decryption:"none"},
        streamSettings:{
            network:"xhttp",
            security:"tls",
            tlsSettings:{serverName:$domain, alpn:["h3"], certificates:[{certificateFile:$cert, keyFile:$key}]},
            xhttpSettings:{path:"/", mode:"stream-one", extra:{xhttpModeH3:true}}
        }}'
}

_plg_vlquic_link() {
    _plg_vlquic_enabled || return 0
    local _domain _uuid _port
    _domain=$(st_get '.vlquic.domain')
    _uuid=$(st_get '.uuid')
    _port=$(port_of vlquic)
    [ -n "${_domain:-}" ] || return 0
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=xhttp&host=%s&path=%%2F&mode=stream-one&xhttpModeH3=true#VLESS-XHTTP-H3\n' \
        "${_uuid}" "${_domain}" "${_port}" "${_domain}" "${_domain}"
}
PLUGIN_EOF
    chmod 644 "${PLUGIN_DIR}/vlquic.sh"
}

# ==============================================================================
# Firewall reconciliation
# ==============================================================================

# 汇总所有插件的期望防火墙规则（格式：port/proto）
fw_desired_rules() {
    local _name _p _port _proto
    for _name in "${_PLUGIN_REGISTRY[@]}"; do
        _p=$(plugin_call "${_name}" ports 2>/dev/null) || true
        [ -n "${_p:-}" ] || continue
        while IFS= read -r _p; do
            [ -n "${_p:-}" ] || continue
            case "${_p}" in
                */udp) _port=${_p%/*}; _proto=udp ;;
                */tcp) _port=${_p%/*}; _proto=tcp ;;
                *)     _port=${_p};    _proto=tcp ;;
            esac
            printf '%s' "${_port}" | grep -qE '^[0-9]+$' || continue
            printf '%s/%s\n' "${_port}" "${_proto}"
        done <<EOF
${_p}
EOF
    done | sort -u
}

fw_desired_ports() { fw_desired_rules | cut -d/ -f1 | sort -un; }

_fw_read_managed() {
    grep -E '^[0-9]+$' "${_FW_PORTS_FILE}" 2>/dev/null | sort -un || true
}

_fw_read_managed_rules() {
    grep -E '^[a-z0-9_]+:[0-9]+/(tcp|udp)$' "${_FW_RULES_FILE}" 2>/dev/null | sort -u || true
}

_fw_mark_rule() {
    local _backend="$1" _port="$2" _proto="${3:-tcp}"
    mkdir -p "${WORK_DIR}" 2>/dev/null || true
    if ! grep -qx "${_backend}:${_port}/${_proto}" "${_FW_RULES_FILE}" 2>/dev/null; then
        printf '%s:%s/%s\n' "${_backend}" "${_port}" "${_proto}" >> "${_FW_RULES_FILE}" 2>/dev/null || true
    fi
}

_fw_unmark_rule() {
    local _backend="$1" _port="$2" _proto="${3:-tcp}" _tmp
    [ -f "${_FW_RULES_FILE}" ] || return 0
    _tmp=$(tmp_file "fw_rules_XXXXXX") || return 0
    grep -vx "${_backend}:${_port}/${_proto}" "${_FW_RULES_FILE}" > "${_tmp}" 2>/dev/null || true
    mv "${_tmp}" "${_FW_RULES_FILE}" 2>/dev/null || true
}

_fw_has_nftables() {
    command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1
}
_fw_nft_table_exists() { nft list table inet xray2go >/dev/null 2>&1; }
_fw_nft_ensure_table() {
    _fw_nft_table_exists && return 0
    nft add table inet xray2go 2>/dev/null || return 1
    nft add chain inet xray2go input '{ type filter hook input priority 0; policy accept; }' \
        2>/dev/null || return 1
}

_fw_open_port() {
    local _port="$1" _proto="${2:-tcp}" _any=0
    if _fw_has_nftables; then
        _fw_nft_ensure_table 2>/dev/null || true
        if ! nft list chain inet xray2go input 2>/dev/null \
             | grep -q "${_proto} dport ${_port} accept"; then
            nft add rule inet xray2go input "${_proto}" dport "${_port}" accept 2>/dev/null \
                && { _fw_mark_rule nft "${_port}" "${_proto}"; _any=1; }
        else
            _fw_mark_rule nft "${_port}" "${_proto}"
        fi
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        if ! ufw status numbered 2>/dev/null | grep -qE "^[[:space:]]*[0-9]+.*${_port}/${_proto}"; then
            ufw allow "${_port}/${_proto}" >/dev/null 2>&1 && { _fw_mark_rule ufw "${_port}" "${_proto}"; _any=1; }
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        if ! firewall-cmd --query-port="${_port}/${_proto}" --permanent >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port="${_port}/${_proto}" >/dev/null 2>&1 && \
                firewall-cmd --reload >/dev/null 2>&1 && { _fw_mark_rule firewalld "${_port}" "${_proto}"; _any=1; }
        fi
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null || {
            iptables -I INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null && { _fw_mark_rule iptables "${_port}" "${_proto}"; _any=1; }; }
        ip6tables -C INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null || {
            ip6tables -I INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null && _fw_mark_rule ip6tables6 "${_port}" "${_proto}" || true; }
    fi
    [ "${_any}" -eq 1 ] \
        && log_ok  "防火墙已开放: ${_port}/${_proto}" \
        || log_info "防火墙端口已存在: ${_port}/${_proto}"
}

_fw_close_port() {
    local _port="$1" _proto="${2:-tcp}" _backend="${3:-all}"
    if { [ "${_backend}" = "all" ] || [ "${_backend}" = "nft" ]; } && _fw_has_nftables && _fw_nft_table_exists; then
        local _handle
        _handle=$(nft -a list chain inet xray2go input 2>/dev/null \
            | grep "${_proto} dport ${_port} accept" \
            | grep -oE 'handle [0-9]+' | awk '{print $2}' | head -1)
        [ -n "${_handle:-}" ] && \
            nft delete rule inet xray2go input handle "${_handle}" 2>/dev/null || true
        _fw_unmark_rule nft "${_port}" "${_proto}"
    fi
    if { [ "${_backend}" = "all" ] || [ "${_backend}" = "ufw" ]; } && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw delete allow "${_port}/${_proto}" >/dev/null 2>&1 || true
        _fw_unmark_rule ufw "${_port}" "${_proto}"
    fi
    if { [ "${_backend}" = "all" ] || [ "${_backend}" = "firewalld" ]; } && command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${_port}/${_proto}" >/dev/null 2>&1 && \
            firewall-cmd --reload >/dev/null 2>&1 || true
        _fw_unmark_rule firewalld "${_port}" "${_proto}"
    fi
    if command -v iptables >/dev/null 2>&1; then
        if [ "${_backend}" = "all" ] || [ "${_backend}" = "iptables" ]; then
            local _n=0
            while iptables -C INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null; do
                iptables -D INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null || break
                _n=$(( _n + 1 )); [ "${_n}" -gt 20 ] && break
            done
            _fw_unmark_rule iptables "${_port}" "${_proto}"
        fi
        if [ "${_backend}" = "all" ] || [ "${_backend}" = "ip6tables6" ]; then
            local _n=0
            while ip6tables -C INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null; do
                ip6tables -D INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null || break
                _n=$(( _n + 1 )); [ "${_n}" -gt 20 ] && break
            done
            _fw_unmark_rule ip6tables6 "${_port}" "${_proto}"
        fi
    fi
    log_info "防火墙规则已删除: ${_port}/${_proto}"
}

fw_reconcile() {
    log_step "同步防火墙规则..."
    mkdir -p "${WORK_DIR}"
    local _expected_rules _expected_ports _rule _rp _rb _rproto _want
    _expected_rules=$(fw_desired_rules)
    _expected_ports=$(printf '%s\n' ${_expected_rules} | cut -d/ -f1 | grep -E '^[0-9]+$' | sort -un || true)

    for _rule in $(_fw_read_managed_rules); do
        _rb=${_rule%%:*}
        _rp=${_rule#*:}; _rproto=${_rp#*/}; _rp=${_rp%/*}
        _want="${_rp}/${_rproto}"
        printf '%s\n' ${_expected_rules} | grep -qx "${_want}" || \
            _fw_close_port "${_rp}" "${_rproto}" "${_rb}"
    done

    for _rule in ${_expected_rules}; do
        _rp=${_rule%/*}; _rproto=${_rule#*/}
        _fw_open_port "${_rp}" "${_rproto}"
    done

    if [ -n "${_expected_ports:-}" ]; then
        printf '%s\n' ${_expected_ports} > "${_FW_PORTS_FILE}" 2>/dev/null || true
    else
        rm -f "${_FW_PORTS_FILE}" "${_FW_RULES_FILE}" 2>/dev/null || true
    fi
}

fw_force_cleanup() {
    log_step "清理 xray2go 托管防火墙规则..."
    local _ports="" _p
    [ -f "${_FW_PORTS_FILE}" ] && \
        _ports=$(grep -E '^[0-9]+$' "${_FW_PORTS_FILE}" 2>/dev/null || true)
    # 正常情况下只依赖 .fw_ports 删除脚本曾托管的端口；同时合并当前 state 中
    # 仍处于启用状态的端口，覆盖 .fw_ports 损坏/未写入但本次运行 state 仍可证明
    # 该端口属于 xray2go 的场景。避免盲删默认 443/8080 等可能由其它服务使用的端口。
    if [ "$(st_get '.argo.enabled')" = "true" ]; then
        _ports="${_ports}
$(port_of argo)"
    fi
    if [ "$(st_get '.ff.enabled')" = "true" ] && [ "$(st_get '.ff.protocol')" != "none" ]; then
        _ports="${_ports}
$(port_of ff)"
    fi
    if [ "$(st_get '.reality.enabled')" = "true" ]; then
        _ports="${_ports}
$(port_of reality)"
    fi
    if [ "$(st_get '.vltcp.enabled')" = "true" ]; then
        _ports="${_ports}
$(port_of vltcp)"
    fi
    if [ "$(st_get '.vlquic.enabled')" = "true" ]; then
        _ports="${_ports}
$(port_of vlquic)"
    fi
    local _uniq _rule _rp _rb _rproto
    _uniq=$(printf '%s\n' ${_ports} | grep -E '^[0-9]+$' | sort -un)
    for _rule in $(_fw_read_managed_rules); do
        _rb=${_rule%%:*}
        _rp=${_rule#*:}; _rproto=${_rp#*/}; _rp=${_rp%/*}
        if printf '%s\n' ${_uniq} | grep -qx "${_rp}" || [ ! -f "${_FW_PORTS_FILE}" ]; then
            _fw_close_port "${_rp}" "${_rproto}" "${_rb}" 2>/dev/null || true
        fi
    done
    if _fw_has_nftables && _fw_nft_table_exists; then
        nft delete table inet xray2go 2>/dev/null || true
    fi
    rm -f "${_FW_PORTS_FILE}" "${_FW_RULES_FILE}" 2>/dev/null || true
    log_ok "防火墙规则清理完成"
}

# ==============================================================================
# §L_LIFECYCLE  系统变更生命周期（可追踪、可回滚）
# ==============================================================================
lifecycle_apply_sysctl() {
    is_openrc || return 0
    log_step "持久化内核参数..."
    local _content
    _content=$(printf '# xray2go managed - do not edit manually\nnet.ipv4.ping_group_range = 0 0\n')
    atomic_write "${_SYSCTL_FILE}" "${_content}" || {
        log_warn "sysctl drop-in 写入失败"; return 0; }
    sysctl -p "${_SYSCTL_FILE}" >/dev/null 2>&1 || true
    log_ok "sysctl 已持久化: ${_SYSCTL_FILE}"
}
lifecycle_rollback_sysctl() {
    [ -f "${_SYSCTL_FILE}" ] || return 0
    rm -f "${_SYSCTL_FILE}" 2>/dev/null || true
    log_info "sysctl drop-in 已清除"
}
lifecycle_apply_hosts_patch() {
    is_openrc || return 0
    [ -f "${_HOSTS_BAK}" ] || cp -f /etc/hosts "${_HOSTS_BAK}" 2>/dev/null || {
        log_warn "/etc/hosts 备份失败，跳过"; return 0; }
    log_step "修补 /etc/hosts..."
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts 2>/dev/null || true
    sed -i '2s/.*/::1         localhost/'  /etc/hosts 2>/dev/null || true
    log_ok "/etc/hosts 已修补"
}
lifecycle_rollback_hosts() {
    [ -f "${_HOSTS_BAK}" ] || return 0
    cp -f "${_HOSTS_BAK}" /etc/hosts 2>/dev/null && {
        rm -f "${_HOSTS_BAK}" 2>/dev/null || true
        log_ok "/etc/hosts 已从备份恢复"
    } || log_warn "/etc/hosts 恢复失败，请手动恢复: ${_HOSTS_BAK}"
}
lifecycle_cleanup_cloudflared() {
    local _cf_dir="${HOME}/.cloudflared"
    [ -d "${_cf_dir}" ] && rm -rf "${_cf_dir}" 2>/dev/null && \
        log_info "已清理 cloudflared 用户目录" || true
}

# ==============================================================================
# Service adapter
# ==============================================================================
_G_SYSD_DIRTY=0

svc_exec() {
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

svc_reload_daemon() {
    is_systemd && [ "${_G_SYSD_DIRTY}" -eq 1 ] || return 0
    systemctl daemon-reload >/dev/null 2>&1 || true
    _G_SYSD_DIRTY=0
}

# 服务状态变更互斥锁：start/stop/restart/enable/disable 统一通过此接口
# 只读状态查询不加锁，避免死锁
_SVC_LOCK_FILE="${WORK_DIR}/.svc_lock"
svc_exec_mut() {
    # 用法同 svc_exec，但对 mutating 操作加独立锁
    local _act="$1"
    case "${_act}" in
        status) svc_exec "$@"; return $? ;;  # 只读不加锁
    esac
    mkdir -p "${WORK_DIR}" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        ( flock -x 9 || { log_error "获取 svc 锁失败"; exit 1; }
          svc_exec "$@"
        ) 9>"${_SVC_LOCK_FILE}"
    else
        svc_exec "$@"
    fi
}

_svc_write_file() {
    local _dest="$1" _content="$2"
    local _cur; _cur=$(cat "${_dest}" 2>/dev/null || printf '')
    if [ "${_cur}" != "${_content}" ]; then
        atomic_write "${_dest}" "${_content}" || return 1
        is_systemd && _G_SYSD_DIRTY=1
    fi
    return 0
}

# ── 配置重载策略 ──────────────────────────────────────────────────────────────
# 遵循保守、可验证的服务管理路径：不依赖未确认的信号重载契约，统一通过 init 系统 restart。
svc_reload_xray() {
    [ -f "${CONFIG_FILE}" ] || { log_error "配置文件不存在"; return 1; }

    local _new_hash
    _new_hash=$(sha256sum "${CONFIG_FILE}" 2>/dev/null | awk '{print $1}') || \
        _new_hash=$(md5sum  "${CONFIG_FILE}" 2>/dev/null | awk '{print $1}') || \
        _new_hash="unknown"

    local _old_hash=""
    [ -f "${_CONFIG_HASH_FILE}" ] && _old_hash=$(cat "${_CONFIG_HASH_FILE}" 2>/dev/null || true)

    if [ "${_new_hash}" = "${_old_hash}" ] && [ "${_new_hash}" != "unknown" ]; then
        log_info "config.json 未变化，跳过 restart"
        return 0
    fi

    log_step "重启 xray2go 以加载新配置..."
    # 兼容旧版本/异常中断造成的 systemd active(not-found) 状态：
    # 进程仍在运行，但 unit 文件不存在时，systemctl restart 会直接失败。
    # 因此每次重载配置前都先确保托管服务单元存在并刷新 daemon。
    svc_apply_xray || { log_error "xray2go 服务单元写入失败"; return 1; }
    svc_reload_daemon
    svc_exec_mut restart "${_SVC_XRAY}" || { log_error "xray restart 失败"; return 1; }
    printf '%s' "${_new_hash}" > "${_CONFIG_HASH_FILE}" 2>/dev/null || true
    log_ok "xray 已重启并加载新配置"
}

# ── 服务单元模板 ──────────────────────────────────────────────────────────────

_svc_tpl_xray_systemd() {
    printf '[Unit]\nDescription=Xray2go Service\nDocumentation=https://github.com/XTLS/Xray-core\nAfter=network.target nss-lookup.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nExecStart=%s run -c %s\nRestart=always\nRestartSec=3\nRestartPreventExitStatus=23\nLimitNOFILE=1048576\nStandardOutput=null\nStandardError=null\n\n[Install]\nWantedBy=multi-user.target\n' \
        "${XRAY_BIN}" "${CONFIG_FILE}"
}

_svc_tpl_xray_openrc() {
    printf '#!/sbin/openrc-run\ndescription="Xray2go service"\ncommand="%s"\ncommand_args="run -c %s"\ncommand_background=true\noutput_log="/dev/null"\nerror_log="/dev/null"\npidfile="/var/run/xray2go.pid"\n' \
        "${XRAY_BIN}" "${CONFIG_FILE}"
}

# tunnel 服务：按 Cloudflare 官方两类运行方式区分：
#   - token/remote-managed tunnel：cloudflared tunnel run --token <token>
#   - credentials/local-managed tunnel：cloudflared tunnel --config <config.yml> run
_svc_tpl_tunnel_systemd() {
    local _token; _token=$(st_get '.argo.token')
    if [ -n "${_token:-}" ] && [ "${_token}" != "null" ] && [ ! -f "${WORK_DIR}/tunnel.json" ]; then
        # token 模式采用 Cloudflare 官方 --token 参数；token 通过 0600 EnvironmentFile 注入，避免写入 unit 和 tunnel.yml。
        # 注意：官方 token CLI 模式会把 token 展开到进程 argv；若本机多用户不可信，请优先使用 credentials/local-managed 模式或加固 /proc 可见性。
        printf '[Unit]\nDescription=Cloudflare Tunnel2go (token mode)\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nTimeoutStartSec=0\nEnvironmentFile=%s\nExecStart=%s tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}\nRestart=on-failure\nRestartSec=5\nStandardOutput=null\nStandardError=null\n\n[Install]\nWantedBy=multi-user.target\n' \
            "${_ARGO_ENV_FILE}" "${ARGO_BIN}"
    else
        printf '[Unit]\nDescription=Cloudflare Tunnel2go (credentials mode)\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nTimeoutStartSec=0\nEnvironmentFile=-%s\nExecStart=%s tunnel --no-autoupdate --config %s run\nRestart=on-failure\nRestartSec=5\nStandardOutput=null\nStandardError=null\n\n[Install]\nWantedBy=multi-user.target\n' \
            "${_ARGO_ENV_FILE}" "${ARGO_BIN}" "${WORK_DIR}/tunnel.yml"
    fi
}

_svc_tpl_tunnel_openrc() {
    local _token; _token=$(st_get '.argo.token')
    if [ -n "${_token:-}" ] && [ "${_token}" != "null" ] && [ ! -f "${WORK_DIR}/tunnel.json" ]; then
        # 不 source env 文件，避免把动态文件作为 shell 代码执行；只解析固定 TUNNEL_TOKEN 键。
        printf '#!/sbin/openrc-run\ndescription="Cloudflare Tunnel2go (token mode)"\ndepend() { need net; }\nstart() {\n    if [ -f %s ]; then\n        TUNNEL_TOKEN=$(grep -m1 "^TUNNEL_TOKEN=" %s | cut -d= -f2-)\n        export TUNNEL_TOKEN\n    fi\n    ebegin "Starting tunnel2go"\n    start-stop-daemon --start --background \\\n        --make-pidfile --pidfile /var/run/tunnel2go.pid \\\n        --exec %s -- tunnel --no-autoupdate run --token "${TUNNEL_TOKEN}"\n    eend $?\n}\nstop() { start-stop-daemon --stop --pidfile /var/run/tunnel2go.pid; }\n' \
            "${_ARGO_ENV_FILE}" "${_ARGO_ENV_FILE}" "${ARGO_BIN}"
    else
        printf '#!/sbin/openrc-run\ndescription="Cloudflare Tunnel2go (credentials mode)"\ndepend() { need net; }\nstart() {\n    ebegin "Starting tunnel2go"\n    start-stop-daemon --start --background \\\n        --make-pidfile --pidfile /var/run/tunnel2go.pid \\\n        --exec %s -- tunnel --no-autoupdate --config %s run\n    eend $?\n}\nstop() { start-stop-daemon --stop --pidfile /var/run/tunnel2go.pid; }\n' \
            "${ARGO_BIN}" "${WORK_DIR}/tunnel.yml"
    fi
}

_svc_write_argo_env() {
    local _token; _token=$(st_get '.argo.token')
    # token 写入 env file 前做格式净化
    # credentials 模式下 token 为空，写入空 env 值即可
    # token 模式下已通过 grep -qE '^[A-Za-z0-9=_-]{20,}$' 校验过格式
    # env file 格式：KEY=VALUE（不加引号，cloudflared 直接读）
    # 防止 token 含换行导致 env file 解析错误
    local _safe_token="${_token:-}"
    _safe_token=$(printf '%s' "${_safe_token}" | tr -d '\n\r')
    atomic_write_secret "${_ARGO_ENV_FILE}" "$(printf 'ARGO_TOKEN=%s\nTUNNEL_TOKEN=%s\n' "${_safe_token}" "${_safe_token}")" \
        || { log_error "Argo env 写入失败"; return 1; }
    chmod 600 "${_ARGO_ENV_FILE}" 2>/dev/null || true
}

svc_apply_xray() {
    if is_systemd; then
        _svc_write_file "/etc/systemd/system/${_SVC_XRAY}.service" "$(_svc_tpl_xray_systemd)" || return 1
    else
        local _f="/etc/init.d/${_SVC_XRAY}"
        _svc_write_file "${_f}" "$(_svc_tpl_xray_openrc)" || return 1
        chmod +x "${_f}" 2>/dev/null || true
    fi
}

svc_apply_tunnel() {
    _svc_write_argo_env || return 1
    if is_systemd; then
        _svc_write_file "/etc/systemd/system/${_SVC_TUNNEL}.service" "$(_svc_tpl_tunnel_systemd)" || return 1
    else
        local _f="/etc/init.d/${_SVC_TUNNEL}"
        _svc_write_file "${_f}" "$(_svc_tpl_tunnel_openrc)" || return 1
        chmod +x "${_f}" 2>/dev/null || true
    fi
}

svc_restart_xray() {
    [ -f "${CONFIG_FILE}" ] || { log_error "配置文件不存在"; return 1; }
    svc_apply_xray || { log_error "xray2go 服务单元写入失败"; return 1; }
    svc_reload_daemon
    svc_exec_mut restart "${_SVC_XRAY}" \
        && { log_ok "${_SVC_XRAY} 已重启"; svc_verify_health "${_SVC_XRAY}" 6; } \
        || { log_error "${_SVC_XRAY} 重启失败"; return 1; }
}

svc_verify_health() {
    local _svc="${1:-${_SVC_XRAY}}" _max="${2:-8}"
    log_step "验证服务 ${_svc} 就绪（最长 ${_max}s）..."
    local _i=0
    while [ "${_i}" -lt "${_max}" ]; do
        sleep 1; _i=$(( _i + 1 ))
        svc_exec status "${_svc}" >/dev/null 2>&1 && {
            log_ok "${_svc} 运行正常 (${_i}s 内就绪)"; return 0; }
    done
    log_error "${_svc} 启动失败"
    if is_systemd; then
        journalctl -u "${_svc}" --no-pager -n 20 2>/dev/null >&2 || true
        systemctl status "${_svc}" --no-pager -l 2>/dev/null >&2 || true
    fi
    return 1
}

# ==============================================================================
# Crypto helpers
# ==============================================================================
crypto_gen_uuid() {
    [ -r /proc/sys/kernel/random/uuid ] && { cat /proc/sys/kernel/random/uuid; return; }
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
    awk 'BEGIN{srand()}{h=$0;printf "%s-%s-4%s-%s%s-%s\n",
        substr(h,1,8),substr(h,9,4),substr(h,14,3),
        substr("89ab",int(rand()*4)+1,1),substr(h,18,3),substr(h,21,12)}'
}

crypto_gen_reality_keypair() {
    [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪"; return 1; }
    local _out; _out=$("${XRAY_BIN}" x25519 2>&1) || { log_error "xray x25519 失败"; return 1; }
    local _pvk _pbk
    _pvk=$(printf '%s\n' "${_out}" | grep -i 'private' | awk '{print $NF}' | tr -d '\r\n')
    _pbk=$(printf '%s\n' "${_out}" | grep -i 'public'  | awk '{print $NF}' | tr -d '\r\n')
    [ -z "${_pvk:-}" ] || [ -z "${_pbk:-}" ] && { log_error "密钥解析失败"; return 1; }
    printf '%s' "${_pvk}" | grep -qE '^[A-Za-z0-9_=-]{20,}$' || { log_error "私钥格式异常"; return 1; }
    printf '%s' "${_pbk}" | grep -qE '^[A-Za-z0-9_=-]{20,}$' || { log_error "公钥格式异常"; return 1; }
    st_set '.reality.pvk = $v | .reality.pbk = $b' --arg v "${_pvk}" --arg b "${_pbk}"
    log_ok "x25519 密钥对已生成 (pubkey: ${_pbk:0:16}...)"
}

crypto_gen_reality_sid() {
    command -v openssl >/dev/null 2>&1 && { openssl rand -hex 8 2>/dev/null; return; }
    command -v xxd    >/dev/null 2>&1 && { head -c 8 /dev/urandom | xxd -p | tr -d '\n'; return; }
    od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

# ==============================================================================
# Config synthesis and apply
# ==============================================================================

# 遍历插件注册表，收集所有 inbound → JSON 数组
config_build_inbounds() {
    # 在构建 inbound 前校验 UUID，防止配置注入
    local _uuid_check; _uuid_check=$(st_get '.uuid')
    if ! val_uuid "${_uuid_check}" >/dev/null 2>&1; then
        log_error "UUID 格式异常，拒绝生成配置: ${_uuid_check}"
        return 1
    fi
    local _ibs="[]" _ib _name _used_keys=""
    for _name in "${_PLUGIN_REGISTRY[@]}"; do
        _ib=$(plugin_call "${_name}" inbound 2>/dev/null) || {
            log_error "插件 inbound 失败: ${_name}"; return 1; }
        [ -n "${_ib:-}" ] || continue

        local _p _l _key
        _p=$(printf '%s' "${_ib}" | jq -r '.port // empty')
        _l=$(printf '%s' "${_ib}" | jq -r '.listen // "0.0.0.0"')
        _key="${_l}:${_p}"

        # 端口冲突检测（换行分隔精确匹配）
        if [ -n "${_used_keys:-}" ] && \
           printf '%s\n' "${_used_keys}" | grep -qxF "${_key}"; then
            log_error "端口冲突: ${_key}，插件 [${_name}] 与已启用入站冲突"
            return 1
        fi
        _used_keys="${_used_keys:+${_used_keys}
}${_key}"
        _ibs=$(printf '%s' "${_ibs}" | jq --argjson ib "${_ib}" '. + [$ib]') \
            || { log_error "inbounds 组装失败: ${_name}"; return 1; }
    done
    printf '%s' "${_ibs}"
}

config_synthesize() {
    local _ibs
    _ibs=$(config_build_inbounds) || return 1
    [ "$(printf '%s' "${_ibs}" | jq 'length')" -eq 0 ] && \
        log_warn "所有入站均已禁用，xray 将以零入站模式运行"
    jq -n --argjson inbounds "${_ibs}" '{
        log: {loglevel:"none", access:"none", error:"none"},
        inbounds: $inbounds,
        outbounds: [{protocol:"freedom", settings:{domainStrategy:"AsIs"}}],
        policy: {
            levels: {"0": {connIdle:300, uplinkOnly:1, downlinkOnly:1,
                statsUserUplink:false, statsUserDownlink:false}},
            system: {statsInboundUplink:false, statsInboundDownlink:false}
        }
    }' || { log_error "config JSON 合成失败"; return 1; }
}

_config_apply_inner() {
    local _t; _t=$(tmp_file "xray_next_XXXXXX.json") || return 1
    log_step "合成配置..."
    config_synthesize > "${_t}" || return 1

    if [ -x "${XRAY_BIN}" ]; then
        log_step "验证配置 (xray -test)..."
        if ! "${XRAY_BIN}" -test -c "${_t}" >/dev/null 2>&1; then
            log_error "config 验证失败！已保留: ${WORK_DIR}/config_failed.json"
            mv "${_t}" "${WORK_DIR}/config_failed.json" 2>/dev/null || true
            return 1
        fi
        log_ok "config 验证通过"
        rm -f "${WORK_DIR}/config_failed.json" 2>/dev/null || true
    else
        log_warn "xray 未就绪，跳过预检（安装阶段正常）"
    fi

    local _json; _json=$(cat "${_t}")
    atomic_write_with_backup "${CONFIG_FILE}" "${_json}" 3 || {
        log_error "config 写入失败"; return 1; }
    rm -f "${_t}" 2>/dev/null || true
    log_ok "config.json 已原子更新"

    # 服务运行中才执行重启加载
    if svc_exec status "${_SVC_XRAY}" >/dev/null 2>&1; then
        svc_reload_xray || return 1
    fi
}

config_apply() { with_lock _config_apply_inner; }

config_print_nodes() {
    local _links _name
    _links=""
    for _name in "${_PLUGIN_REGISTRY[@]}"; do
        local _l; _l=$(plugin_call "${_name}" link 2>/dev/null) || true
        [ -n "${_l:-}" ] && _links="${_links}${_l}"$'\n'
    done

    if [ -z "${_links:-}" ]; then
        echo ""; log_warn "暂无可用节点"; return 1
    fi
    echo ""
    printf '%s\n' "${_links}" | while IFS= read -r _l; do
        _print_link "${_l}"
    done
    echo ""
}

# 组合提交：config_apply + st_persist + fw_reconcile
_commit() {
    config_apply  || return 1
    st_persist    || log_warn "state.json 写入失败"
    fw_reconcile
}

_module_disable_commit() {
    local _name="$1"
    config_apply || return 1
    st_persist   || log_warn "state.json 写入失败"
    # 模块禁用/卸载后必须删除对应托管防火墙端口，而不是只让服务不再监听。
    # fw_reconcile 根据当前启用插件重新计算期望端口，并删除 .fw_ports 中不再期望的规则。
    fw_reconcile
    log_info "${_name} 防火墙端口已从托管规则中删除"
}


# ==============================================================================
# ACME certificate automation for VLESS-XHTTP-H3
# ==============================================================================
acme_install() {
    local _email="${1:-}"
    [ -n "${_email:-}" ] || { log_error "ACME 邮箱不能为空"; return 1; }
    if [ ! -x "${HOME}/.acme.sh/acme.sh" ]; then
        log_step "安装 acme.sh..."
        curl -fsSL https://get.acme.sh | sh -s email="${_email}" >/dev/null 2>&1 \
            || { log_error "acme.sh 安装失败"; return 1; }
    fi
    acme_update_account_email "${_email}"
}

acme_update_account_email() {
    local _email="$1" _account_conf="${HOME}/.acme.sh/account.conf"
    [ -x "${HOME}/.acme.sh/acme.sh" ] || return 1
    if [ -f "${_account_conf}" ] && grep -q "^ACCOUNT_EMAIL=.*example\.com" "${_account_conf}" 2>/dev/null; then
        log_warn "检测到旧 ACME 账户邮箱为 example.com，正在更新账户邮箱..."
    fi
    "${HOME}/.acme.sh/acme.sh" --update-account --accountemail "${_email}" >/dev/null 2>&1 || true
    if [ -f "${_account_conf}" ]; then
        local _tmp
        _tmp=$(tmp_file "acme_account_XXXXXX") || return 0
        grep -v '^ACCOUNT_EMAIL=' "${_account_conf}" > "${_tmp}" 2>/dev/null || true
        printf "ACCOUNT_EMAIL='%s'\n" "${_email}" >> "${_tmp}"
        mv "${_tmp}" "${_account_conf}" 2>/dev/null || true
        chmod 600 "${_account_conf}" 2>/dev/null || true
    fi
}

acme_issue_cf_token() {
    local _domain="$1" _token="$2" _zone="$3" _email="${4:-}"
    val_domain "${_domain}" >/dev/null || return 1
    [ -n "${_token:-}" ] || { log_error "Cloudflare API Token 不能为空"; return 1; }
    [ -n "${_zone:-}" ]  || { log_error "Cloudflare Zone ID 不能为空"; return 1; }
    [ -n "${_email:-}" ] || { log_error "ACME 邮箱不能为空"; return 1; }
    case "${_token}" in *$'\r'*|*$'\n'*|*"'"*) log_error "Cloudflare API Token 含非法字符"; return 1;; esac
    case "${_zone}" in *[!A-Za-z0-9_-]*) log_error "Cloudflare Zone ID 格式不合法"; return 1;; esac
    acme_install "${_email}" || return 1
    mkdir -p "${_CERT_DIR}/${_domain}"
    atomic_write_secret "${_ACME_ENV_FILE}" "CF_Token='${_token}'
CF_Zone_ID='${_zone}'
export CF_Token CF_Zone_ID
" || { log_error "ACME 凭证写入失败"; return 1; }
    "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    log_step "DNS-01 签发证书（Cloudflare Token）..."
    CF_Token="${_token}" CF_Zone_ID="${_zone}" CF_Account_ID="" CF_Key="" CF_Email="" \
        "${HOME}/.acme.sh/acme.sh" --issue --dns dns_cf -d "${_domain}" --keylength ec-256 --accountemail "${_email}" \
        || { log_error "DNS-01 签发失败"; return 1; }
    acme_install_cert "${_domain}" "dns_cf_token"
}

acme_issue_cf_key() {
    local _domain="$1" _cf_key="$2" _cf_email="$3" _email="${4:-}"
    val_domain "${_domain}" >/dev/null || return 1
    [ -n "${_cf_key:-}" ]   || { log_error "Cloudflare Global API Key 不能为空"; return 1; }
    [ -n "${_cf_email:-}" ] || { log_error "Cloudflare 账号邮箱不能为空"; return 1; }
    [ -n "${_email:-}" ]    || { log_error "ACME 邮箱不能为空"; return 1; }
    case "${_cf_key}" in *$'\r'*|*$'\n'*|*"'"*) log_error "Cloudflare Global API Key 含非法字符"; return 1;; esac
    case "${_cf_email}" in *' '*|*"'"*|*'"'*|*'`'*|*'\'*) log_error "Cloudflare 账号邮箱不合法"; return 1;; esac
    printf '%s' "${_cf_email}" | grep -qE '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' \
        || { log_error "Cloudflare 账号邮箱格式不合法"; return 1; }
    acme_install "${_email}" || return 1
    mkdir -p "${_CERT_DIR}/${_domain}"
    atomic_write_secret "${_ACME_ENV_FILE}" "CF_Key='${_cf_key}'
CF_Email='${_cf_email}'
export CF_Key CF_Email
" || { log_error "ACME 凭证写入失败"; return 1; }
    "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    log_step "DNS-01 签发证书（Cloudflare Global Key）..."
    CF_Token="" CF_Zone_ID="" CF_Account_ID="" CF_Key="${_cf_key}" CF_Email="${_cf_email}" \
        "${HOME}/.acme.sh/acme.sh" --issue --dns dns_cf -d "${_domain}" --keylength ec-256 --accountemail "${_email}" \
        || { log_error "DNS-01 签发失败"; return 1; }
    acme_install_cert "${_domain}" "dns_cf_key"
}

acme_install_cert() {
    local _domain="$1" _method="${2:-manual}"
    "${HOME}/.acme.sh/acme.sh" --install-cert -d "${_domain}" --ecc \
        --fullchain-file "${_CERT_DIR}/${_domain}/fullchain.pem" \
        --key-file "${_CERT_DIR}/${_domain}/privkey.pem" \
        --reloadcmd "systemctl restart ${_SVC_XRAY} >/dev/null 2>&1 || true" \
        || { log_error "证书安装失败"; return 1; }
    chmod 700 "${_CERT_DIR}/${_domain}" 2>/dev/null || true
    chmod 600 "${_CERT_DIR}/${_domain}/privkey.pem" 2>/dev/null || true
    chmod 644 "${_CERT_DIR}/${_domain}/fullchain.pem" 2>/dev/null || true
    st_set '.vlquic.domain = $d | .vlquic.cert = $c | .vlquic.key = $k | .vlquic.acme_method = $m' \
        --arg d "${_domain}" \
        --arg c "${_CERT_DIR}/${_domain}/fullchain.pem" \
        --arg k "${_CERT_DIR}/${_domain}/privkey.pem" \
        --arg m "${_method}"
}

acme_issue_http01() {
    local _domain="$1" _email="${2:-}"
    val_domain "${_domain}" >/dev/null || return 1
    [ -n "${_email:-}" ] || { log_error "ACME 邮箱不能为空"; return 1; }
    if port_mgr_in_use 80; then
        log_error "80/tcp 已被占用，无法使用 HTTP-01 standalone"
        return 1
    fi
    acme_install "${_email}" || return 1
    mkdir -p "${_CERT_DIR}/${_domain}"
    "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    log_step "HTTP-01 standalone 签发证书..."
    "${HOME}/.acme.sh/acme.sh" --issue -d "${_domain}" --standalone --httpport 80 --keylength ec-256 --accountemail "${_email}" \
        || { log_error "HTTP-01 签发失败"; return 1; }
    "${HOME}/.acme.sh/acme.sh" --install-cert -d "${_domain}" --ecc \
        --fullchain-file "${_CERT_DIR}/${_domain}/fullchain.pem" \
        --key-file "${_CERT_DIR}/${_domain}/privkey.pem" \
        --reloadcmd "systemctl restart ${_SVC_XRAY} >/dev/null 2>&1 || true" \
        || { log_error "证书安装失败"; return 1; }
    chmod 700 "${_CERT_DIR}/${_domain}" 2>/dev/null || true
    chmod 600 "${_CERT_DIR}/${_domain}/privkey.pem" 2>/dev/null || true
    chmod 644 "${_CERT_DIR}/${_domain}/fullchain.pem" 2>/dev/null || true
    st_set '.vlquic.domain = $d | .vlquic.cert = $c | .vlquic.key = $k | .vlquic.acme_method = "http01"' \
        --arg d "${_domain}" \
        --arg c "${_CERT_DIR}/${_domain}/fullchain.pem" \
        --arg k "${_CERT_DIR}/${_domain}/privkey.pem"
}

vlquic_config_cert() {
    echo ""; log_title "VLESS-XHTTP-H3 证书配置"
    local _domain _email; prompt "入口域名（需 DNS only 直连 VPS）: " _domain
    _domain=$(val_domain "${_domain}") || return 1
    echo ""
    printf "  ${C_GRN}1.${C_RST} Cloudflare Global API Key ${C_YLW}[简单]${C_RST}\n"
    printf "  ${C_GRN}2.${C_RST} Cloudflare API Token ${C_YLW}[最小权限推荐]${C_RST}\n"
    printf "  ${C_GRN}3.${C_RST} HTTP-01 standalone ${C_YLW}[需要80端口]${C_RST}\n"
    printf "  ${C_GRN}4.${C_RST} 使用已有证书文件\n"
    local _m; prompt "请选择 (1-4，回车默认1): " _m
    if [ "${_m:-1}" != "4" ]; then
        prompt "ACME 邮箱（用于 Let's Encrypt 账户，不能使用 example.com）: " _email
        case "${_email:-}" in
            *@example.com|*@example.org|*@example.net|''|*' '*|*"'"*|*'"'*|*'`'*|*'\'*) log_error "ACME 邮箱不合法"; return 1 ;;
        esac
        printf '%s' "${_email}" | grep -qE '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'             || { log_error "ACME 邮箱格式不合法"; return 1; }
    fi
    case "${_m:-1}" in
        1)
            local _cf_key _cf_email
            prompt "Cloudflare 账号邮箱: " _cf_email
            prompt "Cloudflare Global API Key（不会显示在节点/日志中）: " _cf_key
            acme_issue_cf_key "${_domain}" "${_cf_key}" "${_cf_email}" "${_email}" || return 1 ;;
        2)
            local _token _zone
            prompt "Cloudflare API Token（不会显示在节点/日志中）: " _token
            prompt "Cloudflare Zone ID: " _zone
            acme_issue_cf_token "${_domain}" "${_token}" "${_zone}" "${_email}" || return 1 ;;
        3)
            log_warn "HTTP-01 需要域名 A 记录指向本机且 80/tcp 开放/空闲"
            acme_issue_http01 "${_domain}" "${_email}" || return 1 ;;
        4)
            local _cert _key
            prompt "fullchain.pem 路径: " _cert
            prompt "privkey.pem 路径: " _key
            [ -f "${_cert}" ] || { log_error "证书文件不存在: ${_cert}"; return 1; }
            [ -f "${_key}" ]  || { log_error "私钥文件不存在: ${_key}"; return 1; }
            st_set '.vlquic.domain = $d | .vlquic.cert = $c | .vlquic.key = $k | .vlquic.acme_method = "manual"' \
                --arg d "${_domain}" --arg c "${_cert}" --arg k "${_key}" ;;
        *) log_error "无效选项"; return 1 ;;
    esac
    log_ok "证书配置完成: ${_domain}"
}

# ==============================================================================
# Argo tunnel integration
# ==============================================================================
# 核心设计：
#   - token/remote-managed tunnel：官方命令 cloudflared tunnel run --token <token>
#     token 仅存入 0600 env 文件；ingress 由 Cloudflare Zero Trust 远端配置管理。
#   - credentials/local-managed tunnel：官方命令 cloudflared tunnel --config tunnel.yml run
#     tunnel.yml 包含 tunnel ID、credentials-file 与本地 ingress。

# 生成 tunnel.yml（cred 模式：含 credentials-file）
_argo_gen_yml_cred() {
    local _domain="$1" _tid="$2" _cred="$3"
    # 校验所有字段，防止 YAML 注入
    local _port; _port=$(val_port "$(port_of argo)") || return 1
    val_domain "${_domain}" >/dev/null || return 1
    # tid 只允许 hex UUID 或 AccountTag（字母数字连字符）
    printf '%s' "${_tid}" | grep -qE '^[a-zA-Z0-9_-]{8,}$'         || { log_error "TunnelID 格式非法"; return 1; }
    local _new
    _new=$(printf 'tunnel: %s
credentials-file: %s

ingress:
  - hostname: %s
    service: http://localhost:%s
    originRequest:
      connectTimeout: 30s
      noTLSVerify: true
  - service: http_status:404
'         "${_tid}" "${_cred}" "${_domain}" "${_port}")
    local _cur; _cur=$(cat "${WORK_DIR}/tunnel.yml" 2>/dev/null || true)
    [ "${_cur}" = "${_new}" ] && return 0
    atomic_write_secret "${WORK_DIR}/tunnel.yml" "${_new}"         || { log_error "tunnel.yml 写入失败"; return 1; }
    log_ok "tunnel.yml 已更新 [cred] (${_domain} → localhost:${_port})"
}

# token 模式：不生成 tunnel.yml；采用 Cloudflare 官方 remote-managed tunnel token 运行方式。
# 本地脚本只能保存 token 和域名状态；ingress 应在 Cloudflare Zero Trust 远端配置为 http://localhost:<argo-port>。
_argo_gen_yml_token() {
    local _domain="$1" _token="$2"
    # token/remote-managed tunnel：不把 token 写入 tunnel.yml；token 仅写入 0600 env file。
    # 注意：cloudflared token 模式的 ingress 通常由 Cloudflare 远端配置管理；本地无法可靠覆盖 ingress。
    local _port; _port=$(val_port "$(port_of argo)") || return 1
    val_domain "${_domain}" >/dev/null || return 1
    printf '%s' "${_token}" | grep -qE '^[A-Za-z0-9=_-]{20,}$'         || { log_error "token 格式非法"; return 1; }
    rm -f "${WORK_DIR}/tunnel.yml" 2>/dev/null || true
    log_ok "token 模式已配置：token 保存于 ${_ARGO_ENV_FILE}；请在 Cloudflare Zero Trust 远端将 Public Hostname 服务指向 http://localhost:${_port}"
}

# 统一同步入口：cred 模式重建 tunnel.yml；token/remote-managed 模式仅校验并提示远端 ingress。
# 调用方：exec_update_argo_port / svc_apply_tunnel / _commit 后的端口变更
argo_sync_tunnel_yml() {
    [ "$(st_get '.argo.enabled')" = "true" ] || return 0
    local _domain; _domain=$(st_get '.argo.domain')
    [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ] || {
        log_warn "tunnel.yml 同步跳过：domain 未配置"; return 0; }

    if [ -f "${WORK_DIR}/tunnel.json" ]; then
        # cred 模式
        local _tid
        _tid=$(jq -r 'if (.TunnelID? // "") != "" then .TunnelID
                      elif (.AccountTag? // "") != "" then .AccountTag
                      else empty end' "${WORK_DIR}/tunnel.json" 2>/dev/null) || true
        [ -n "${_tid:-}" ] || { log_warn "tunnel.yml 同步跳过：无法提取 TunnelID"; return 0; }
        _argo_gen_yml_cred "${_domain}" "${_tid}" "${WORK_DIR}/tunnel.json"
    else
        # token 模式
        local _token; _token=$(st_get '.argo.token')
        [ -n "${_token:-}" ] && [ "${_token}" != "null" ] || {
            log_warn "tunnel.yml 同步跳过：token 未配置"; return 0; }
        _argo_gen_yml_token "${_domain}" "${_token}"
    fi
}

argo_apply_fixed_tunnel() {
    log_info "固定隧道 — 协议: $(st_get '.argo.protocol')  回源端口: $(port_of argo)"
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
            log_error "TunnelID 含非法字符"; return 1;; esac
        local _cred="${WORK_DIR}/tunnel.json"
        atomic_write_secret "${_cred}" "${_auth}" || { log_error "凭证写入失败"; return 1; }
        # 凭证文件含敏感字段，严格限制权限
        chmod 600 "${_cred}" 2>/dev/null || true
        _argo_gen_yml_cred "${_domain}" "${_tid}" "${_cred}" || return 1
        st_set '.argo.token = null | .argo.domain = $d | .argo.mode = "fixed"' \
            --arg d "${_domain}" || return 1
    elif printf '%s' "${_auth}" | grep -qE '^[A-Za-z0-9=_-]{120,250}$'; then
        st_set '.argo.token = $t | .argo.domain = $d | .argo.mode = "fixed"' \
            --arg t "${_auth}" --arg d "${_domain}" || return 1
        rm -f "${WORK_DIR}/tunnel.json" 2>/dev/null || true
        _argo_gen_yml_token "${_domain}" "${_auth}" || return 1
    else
        log_error "密钥格式无法识别"
        return 1
    fi

    _svc_write_argo_env || return 1
    svc_apply_tunnel || return 1
    svc_reload_daemon
    svc_exec_mut enable "${_SVC_TUNNEL}" 2>/dev/null || true
    config_apply  || return 1
    st_persist    || log_warn "state.json 写入失败"
    # tunnel restart 通过服务互斥接口执行
    svc_exec_mut restart "${_SVC_TUNNEL}" || { log_error "tunnel 重启失败"; return 1; }
    log_ok "固定隧道已配置 (domain=${_domain})"
    argo_check_health || true
}

argo_check_health() {
    local _domain; _domain=$(st_get '.argo.domain')
    [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ] || return 0
    log_step "Argo 健康检查（最长 15s）..."
    local _i
    for _i in 3 6 9 12 15; do
        sleep "${_i}" 2>/dev/null || sleep 3
        local _code
        _code=$(curl -sfL --max-time 5 --connect-timeout 3 \
            -o /dev/null -w '%{http_code}' "https://${_domain}/" 2>/dev/null) || true
        case "${_code:-000}" in
            [2345]??) log_ok "Argo 隧道连通 (HTTP ${_code})"; return 0 ;;
        esac
        [ "${_i}" -lt 15 ] && printf '\r  等待中... (%ss)' "${_i}" >&2
    done
    printf '\n' >&2
    log_warn "Argo 健康检查超时"
    return 1
}

# 修改 Argo 端口：同步 xray inbound；cred/local-managed 模式同步 tunnel.yml；token/remote-managed 模式提示远端同步
exec_update_argo_port() {
    local _p; _menu_input_port '.ports.argo' _p || return 1
    # 1. cred/local-managed 模式同步 tunnel.yml；token/remote-managed 模式仅校验并提示 Cloudflare 远端 ingress
    argo_sync_tunnel_yml || return 1
    # 2. 重建 xray config（插件读取新端口）并持久化 state
    config_apply || return 1
    st_persist || log_warn "state.json 写入失败"
    # 3. 更新 tunnel 服务单元（命令不变，但 env 可能变）
    svc_apply_tunnel || return 1
    svc_reload_daemon
    # 4. 重启 tunnel 使 cred/local-managed tunnel.yml 生效；token/remote-managed 需远端同步 ingress
    svc_exec_mut restart "${_SVC_TUNNEL}" || log_warn "tunnel 重启失败，请手动重启"
    fw_reconcile
    log_ok "Argo 端口已更新: ${_p}（当前: $(port_of argo)；xray inbound 已同步；cred/local-managed tunnel.yml 已同步，token/remote-managed 模式需在 Cloudflare Zero Trust 远端确认 Public Hostname 指向 http://localhost:${_p}）"
    config_print_nodes
}

# ==============================================================================
# Downloads and verification
# ==============================================================================
_xray_health_check() {
    local _bin="${1:-${XRAY_BIN}}"
    [ -f "${_bin}" ] && [ -x "${_bin}" ] || return 1
    "${_bin}" version >/dev/null 2>&1 || return 1
    local _tc; _tc=$(tmp_file "xray_hc_XXXXXX.json") || return 1
    printf '{"log":{"loglevel":"none"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}\n' \
        > "${_tc}"
    "${_bin}" -test -c "${_tc}" >/dev/null 2>&1; local _rc=$?
    rm -f "${_tc}" 2>/dev/null || true
    return "${_rc}"
}

_xray_latest_tag() {
    local _tag _i
    for _i in 1 2; do
        _tag=$(curl -sfL --max-time 10 \
            "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
            2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null) || true
        [ -n "${_tag:-}" ] && { printf '%s' "${_tag}"; return 0; }
        [ "${_i}" -lt 2 ] && sleep 2
    done
    return 1
}

_xray_download_from_mirrors() {
    local _filename="$1" _dest="$2" _tag="$3"
    for _mirror in "${_XRAY_MIRRORS[@]}"; do
        log_step "下载 ${_filename} ..."
        curl -sfL --connect-timeout 15 --max-time 120 \
            -o "${_dest}" "${_mirror}/${_tag}/${_filename}"
        [ $? -eq 0 ] && [ -s "${_dest}" ] && return 0
        log_warn "镜像失败，尝试下一个..."
        rm -f "${_dest}" 2>/dev/null || true
    done
    log_error "所有镜像均下载失败: ${_filename}"; return 1
}

download_xray() {
    platform_detect_arch
    if _xray_health_check "${XRAY_BIN}" 2>/dev/null; then
        local _cur
        _cur=$("${XRAY_BIN}" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_info "xray 已存在且健康 (v${_cur:-unknown})，跳过下载"; return 0
    fi
    log_info "xray 健康检查未通过，重新下载..."
    rm -f "${XRAY_BIN}" 2>/dev/null || true
    local _tag; _tag=$(_xray_latest_tag) || true
    [ -z "${_tag:-}" ] && { log_error "无法获取 Xray 最新版本号，拒绝使用未校验 latest 下载"; return 1; }
    local _zip_name="Xray-linux-${_G_ARCH_XRAY}.zip"
    local _z; _z=$(tmp_file "xray_XXXXXX.zip") || return 1
    _xray_download_from_mirrors "${_zip_name}" "${_z}" "${_tag}" || return 1
    command -v sha256sum >/dev/null 2>&1 || { log_error "缺少 sha256sum，拒绝安装未校验 Xray 二进制"; rm -f "${_z}"; return 1; }
    log_step "校验 SHA256..."
    local _dgst _expected _actual
    _dgst=$(curl -sfL --max-time 15 \
        "https://github.com/XTLS/Xray-core/releases/download/${_tag}/${_zip_name}.dgst" \
        2>/dev/null) || true
    _expected=$(printf '%s' "${_dgst:-}" | grep -i 'SHA2-256' | awk '{print $NF}' | head -1 | tr -d '[:space:]')
    [ -n "${_expected:-}" ] || { log_error "未获取到 Xray SHA256 摘要，拒绝继续"; rm -f "${_z}"; return 1; }
    _actual=$(sha256sum "${_z}" | awk '{print $1}')
    if [ "${_actual}" != "${_expected}" ]; then
        log_error "SHA256 校验失败"; rm -f "${_z}"; return 1
    fi
    log_ok "SHA256 校验通过"
    unzip -t "${_z}" >/dev/null 2>&1 || { log_error "zip 文件损坏"; rm -f "${_z}"; return 1; }
    unzip -o "${_z}" xray -d "${WORK_DIR}/" >/dev/null 2>&1 || { log_error "解压失败"; return 1; }
    [ -f "${XRAY_BIN}" ] || { log_error "解压后未找到 xray 二进制"; return 1; }
    chmod +x "${XRAY_BIN}"
    _xray_health_check "${XRAY_BIN}" || { log_error "xray 健康检查失败"; rm -f "${XRAY_BIN}"; return 1; }
    log_ok "Xray 安装完成 ($("${XRAY_BIN}" version 2>/dev/null | head -1 | awk '{print $2}'))"
}

download_cloudflared() {
    platform_detect_arch
    if [ -f "${ARGO_BIN}" ] && [ -x "${ARGO_BIN}" ]; then
        log_info "cloudflared 已存在，跳过下载"; return 0
    fi
    local _existing_cf; _existing_cf=$(command -v cloudflared 2>/dev/null || true)
    if [ -n "${_existing_cf:-}" ]; then
        cp -f "${_existing_cf}" "${ARGO_BIN}" || { log_error "复制 cloudflared 到 ${ARGO_BIN} 失败"; return 1; }
        chmod +x "${ARGO_BIN}"
        "${ARGO_BIN}" --version >/dev/null 2>&1 || { log_error "cloudflared --version 验证失败"; return 1; }
        log_ok "使用系统已安装的 cloudflared: ${_existing_cf}"
        return 0
    fi
    rm -f "${ARGO_BIN}" 2>/dev/null || true

    # 官方最佳实践优先：使用 Cloudflare 软件仓库/系统包管理器安装 cloudflared，避免脚本自管裸二进制校验链。
    log_step "通过系统包管理器安装 cloudflared..."
    if command -v apt-get >/dev/null 2>&1; then
        platform_pkg_require ca-certificates update-ca-certificates
        platform_pkg_require curl curl
        mkdir -p /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            -o /usr/share/keyrings/cloudflare-main.gpg \
            || { log_error "Cloudflare GPG key 下载失败"; return 1; }
        printf 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main\n' \
            > /etc/apt/sources.list.d/cloudflared.list
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 \
            || { log_error "cloudflared 官方仓库 apt update 失败"; return 1; }
        DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared >/dev/null 2>&1 \
            || { log_error "cloudflared 包安装失败"; return 1; }
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        local _pm; command -v dnf >/dev/null 2>&1 && _pm="dnf" || _pm="yum"
        cat > /etc/yum.repos.d/cloudflared.repo <<'EOF'
[cloudflared]
name=cloudflared
baseurl=https://pkg.cloudflare.com/cloudflared/rpm
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflare.com/cloudflare-main.gpg
EOF
        ${_pm} install -y cloudflared >/dev/null 2>&1 \
            || { log_error "cloudflared 包安装失败"; return 1; }
    else
        log_error "当前系统无 Cloudflare 官方包仓库自动安装路径；请先按 Cloudflare 官方文档安装 cloudflared 后重试，或先在菜单中关闭 Argo"
        return 1
    fi

    local _cf_bin; _cf_bin=$(command -v cloudflared 2>/dev/null || true)
    [ -n "${_cf_bin:-}" ] || { log_error "cloudflared 安装后不可用"; return 1; }
    cp -f "${_cf_bin}" "${ARGO_BIN}" || { log_error "复制 cloudflared 到 ${ARGO_BIN} 失败"; return 1; }
    chmod +x "${ARGO_BIN}"
    "${ARGO_BIN}" --version >/dev/null 2>&1 || { log_error "cloudflared --version 验证失败"; return 1; }
    log_ok "cloudflared 已通过官方包仓库安装"
}

# ==============================================================================
# Install and uninstall
# ==============================================================================
_install_detect_existing_xray() {
    command -v systemctl >/dev/null 2>&1 && \
        systemctl list-unit-files 2>/dev/null | grep -qiE '^xray[^2]' && return 0
    [ -f /etc/init.d/xray ] && return 0
    command -v rc-service >/dev/null 2>&1 && rc-service xray status >/dev/null 2>&1 && return 0
    command -v rc-update  >/dev/null 2>&1 && rc-update show 2>/dev/null | grep -q '\bxray\b' && return 0
    local _wx; _wx=$(command -v xray 2>/dev/null || true)
    [ -n "${_wx:-}" ] && [ "${_wx}" != "${XRAY_BIN}" ] && return 0
    pgrep -x xray >/dev/null 2>&1 && return 0
    return 1
}

_install_check_port_conflicts() {
    log_step "检测端口冲突..."
    local _proto _port _new
    for _proto in argo reality vltcp; do
        # 读取启用状态
        local _en; _en=$(st_get ".${_proto}.enabled")
        [ "${_en}" = "true" ] || continue
        _port=$(port_of "${_proto}")
        if port_mgr_in_use "${_port}"; then
            _new=$(port_mgr_random) || return 1
            st_set ".ports.${_proto} = (\$p|tonumber)" --arg p "${_new}" || return 1
            log_ok "端口 ${_port} 已占用，自动分配: ${_new}"
        fi
    done
    # ff 端口冲突仅 warn（非独占端口）
    if [ "$(st_get '.ff.enabled')" = "true" ] && \
       [ "$(st_get '.ff.protocol')" != "none" ]; then
        _port=$(port_of ff)
        port_mgr_in_use "${_port}" && \
            log_warn "FreeFlow 端口 ${_port} 已被占用，可能无法启动"
    fi
    return 0
}

_install_rollback() {
    local _xray_was="${1:-0}" _argo_was="${2:-0}"
    log_warn "安装中断，回滚..."
    fw_force_cleanup
    [ "${_xray_was}" -eq 0 ] && rm -f "${XRAY_BIN}" 2>/dev/null || true
    [ "${_argo_was}" -eq 0 ] && rm -f "${ARGO_BIN}" 2>/dev/null || true
    rm -f "${CONFIG_FILE}" "${CONFIG_FILE}".*.bak "${STATE_FILE}".*.bak \
          "${_CONFIG_HASH_FILE}" "${_FW_RULES_FILE}" "${_ARGO_ENV_FILE}" "${WORK_DIR}/tunnel.yml" \
          "${WORK_DIR}/tunnel.json" "${WORK_DIR}/xray.pid" \
          /var/run/xray2go.pid /var/run/tunnel2go.pid 2>/dev/null || true
    for _s in "${_SVC_XRAY}" "${_SVC_TUNNEL}"; do
        svc_exec_mut stop    "${_s}" 2>/dev/null || true
        svc_exec_mut disable "${_s}" 2>/dev/null || true
    done
    if is_systemd; then
        rm -f /etc/systemd/system/${_SVC_XRAY}.service \
              /etc/systemd/system/${_SVC_TUNNEL}.service 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rm -f /etc/init.d/${_SVC_XRAY} /etc/init.d/${_SVC_TUNNEL} 2>/dev/null || true
    fi
    lifecycle_rollback_sysctl
    lifecycle_rollback_hosts
}

exec_install() {
    clear; log_title "══════════ 安装 Xray-2go ══════════"
    platform_preflight
    mkdir -p "${WORK_DIR}" && chmod 750 "${WORK_DIR}"
    # 确保现有敏感文件权限正确
    [ -f "${STATE_FILE}" ]    && chmod 600 "${STATE_FILE}"    2>/dev/null || true
    [ -f "${_ARGO_ENV_FILE}" ] && chmod 600 "${_ARGO_ENV_FILE}" 2>/dev/null || true
    [ -f "${WORK_DIR}/tunnel.json" ] && chmod 600 "${WORK_DIR}/tunnel.json" 2>/dev/null || true

    # 安装内置插件文件
    plugin_install_builtins
    plugin_load_all

    _install_detect_existing_xray && {
        log_warn "检测到系统已存在 xray 相关组件"
        log_warn "将以隔离模式运行（服务名: ${_SVC_XRAY}）"
    }

    _install_check_port_conflicts || { log_error "端口冲突无法解决"; return 1; }

    local _xray_was=0 _argo_was=0
    [ -f "${XRAY_BIN}" ] && [ -x "${XRAY_BIN}" ] && _xray_was=1
    [ -f "${ARGO_BIN}" ] && [ -x "${ARGO_BIN}" ] && _argo_was=1

    download_xray || { _install_rollback "${_xray_was}" "${_argo_was}"; return 1; }
    [ "$(st_get '.argo.enabled')" = "true" ] && {
        download_cloudflared || { _install_rollback "${_xray_was}" "${_argo_was}"; return 1; }
    }

    if [ "$(st_get '.reality.enabled')" = "true" ]; then
        log_step "生成 Reality x25519 密钥对..."
        crypto_gen_reality_keypair || { _install_rollback "${_xray_was}" "${_argo_was}"; return 1; }
        st_set '.reality.sid = $s' --arg s "$(crypto_gen_reality_sid)"
    fi

    config_apply || { _install_rollback "${_xray_was}" "${_argo_was}"; return 1; }

    svc_apply_xray || { _install_rollback "${_xray_was}" "${_argo_was}"; return 1; }
    if [ "$(st_get '.argo.enabled')" = "true" ]; then
        svc_apply_tunnel || { _install_rollback "${_xray_was}" "${_argo_was}"; return 1; }
    fi
    svc_reload_daemon

    is_openrc && { lifecycle_apply_sysctl; lifecycle_apply_hosts_patch; }

    platform_fix_time_sync
    fw_reconcile

    log_step "启动服务..."
    svc_exec_mut enable "${_SVC_XRAY}"
    svc_exec_mut start  "${_SVC_XRAY}" || {
        log_error "启动命令失败"; _install_rollback "${_xray_was}" "${_argo_was}"; return 1; }

    if ! svc_verify_health "${_SVC_XRAY}" 8; then
        log_error "${_SVC_XRAY} 未正常运行，回滚"
        svc_exec_mut stop "${_SVC_XRAY}" 2>/dev/null || true
        _install_rollback "${_xray_was}" "${_argo_was}"
        return 1
    fi

    if [ "$(st_get '.argo.enabled')" = "true" ]; then
        svc_exec_mut enable "${_SVC_TUNNEL}"
        svc_exec_mut start  "${_SVC_TUNNEL}" || log_error "tunnel 启动失败（不影响 xray）"
        log_ok "${_SVC_TUNNEL} 已启动"
    fi

    log_info "网络调优未内置执行：为避免运行未签名第三方 root 脚本，请按需参考可信来源手动配置。"

    st_persist || log_warn "state.json 写入失败（不影响运行）"
    log_ok "══ 安装完成 ══"
}

exec_uninstall() {
    local _a; prompt "确定要卸载 xray2go？(y/N): " _a
    case "${_a:-n}" in y|Y) :;; *) log_info "已取消"; return;; esac
    log_step "卸载中..."
    for _s in "${_SVC_XRAY}" "${_SVC_TUNNEL}"; do
        svc_exec_mut stop    "${_s}" 2>/dev/null || true
        svc_exec_mut disable "${_s}" 2>/dev/null || true
    done
    fw_force_cleanup
    rm -f "${WORK_DIR}/xray.pid" /var/run/xray2go.pid /var/run/tunnel2go.pid 2>/dev/null || true
    rm -f "${CONFIG_FILE}" "${CONFIG_FILE}".*.bak "${STATE_FILE}" "${STATE_FILE}".*.bak \
          "${_CONFIG_HASH_FILE}" "${_FW_RULES_FILE}" "${_ARGO_ENV_FILE}" "${WORK_DIR}/tunnel.yml" \
          "${WORK_DIR}/tunnel.json" "${_SVC_LOCK_FILE}" "${_LOCK_FILE}" 2>/dev/null || true
    if is_systemd; then
        rm -f /etc/systemd/system/${_SVC_XRAY}.service \
              /etc/systemd/system/${_SVC_TUNNEL}.service 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rm -f /etc/init.d/${_SVC_XRAY} /etc/init.d/${_SVC_TUNNEL} 2>/dev/null || true
    fi
    lifecycle_rollback_sysctl
    lifecycle_rollback_hosts
    lifecycle_cleanup_cloudflared
    if [ -d "${WORK_DIR}" ]; then
        rm -rf "${WORK_DIR}" 2>/dev/null || true
        [ -d "${WORK_DIR}" ] \
            && log_warn "${WORK_DIR} 未能完全删除，请手动: rm -rf ${WORK_DIR}" \
            || log_ok "${WORK_DIR} 已清除"
    fi
    rm -f "${SHORTCUT}" "${SELF_DEST}" "${SELF_DEST}.bak" 2>/dev/null || true
    log_ok "xray2go 卸载完成"
}

exec_update_shortcut() {
    log_warn "已禁用内置自更新：为避免未签名 root 脚本覆盖，请通过 GitHub Release/包管理器等可校验渠道手动更新。"
    return 1
}

exec_update_uuid() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先安装 Xray-2go"; return 1; }
    local _v; prompt "新 UUID（回车自动生成）: " _v
    if [ -z "${_v:-}" ]; then
        _v=$(crypto_gen_uuid) || { log_error "UUID 生成失败"; return 1; }
        log_info "已生成 UUID: ${_v}"
    fi
    # 通过 val_uuid 统一校验，防止配置注入
    val_uuid "${_v}" >/dev/null || return 1
    st_set '.uuid = $u' --arg u "${_v}" || return 1
    _commit || return 1
    log_ok "UUID 已更新: ${_v}"; config_print_nodes
}

# ==============================================================================
# Interactive menus
# ==============================================================================

# ── 安装向导 ──────────────────────────────────────────────────────────────────

ask_argo_mode() {
    echo ""; log_title "Argo 固定隧道"
    printf "  ${C_GRN}1.${C_RST} 安装 Argo (VLESS+WS/XHTTP+TLS) ${C_YLW}[默认]${C_RST}\n"
    printf "  ${C_GRN}2.${C_RST} 不安装 Argo\n"
    local _c; prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2) st_set '.argo.enabled = false'; log_info "已选：不安装 Argo";;
        *) st_set '.argo.enabled = true';  log_info "已选：安装 Argo";;
    esac; echo ""
}

ask_argo_protocol() {
    echo ""; log_title "Argo 传输协议"
    printf "  ${C_GRN}1.${C_RST} WS ${C_YLW}[默认]${C_RST}\n"
    printf "  ${C_GRN}2.${C_RST} XHTTP (auto)\n"
    local _c; prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2) st_set '.argo.protocol = "xhttp"';;
        *) st_set '.argo.protocol = "ws"';;
    esac
    log_info "已选协议: $(st_get '.argo.protocol')"; echo ""
}

ask_freeflow_mode() {
    echo ""; log_title "FreeFlow（明文端口: $(port_of ff)）"
    printf "  ${C_GRN}1.${C_RST} VLESS + WS\n"
    printf "  ${C_GRN}2.${C_RST} VLESS + HTTPUpgrade\n"
    printf "  ${C_GRN}3.${C_RST} VLESS + XHTTP (stream-one)\n"
    printf "  ${C_GRN}4.${C_RST} VLESS + TCP + HTTP 伪装（免流）\n"
    printf "  ${C_GRN}5.${C_RST} 不启用 ${C_YLW}[默认]${C_RST}\n"
    local _c; prompt "请选择 (1-5，回车默认5): " _c
    case "${_c:-5}" in
        1) st_set '.ff.enabled = true | .ff.protocol = "ws"';;
        2) st_set '.ff.enabled = true | .ff.protocol = "httpupgrade"';;
        3) st_set '.ff.enabled = true | .ff.protocol = "xhttp"';;
        4)
            st_set '.ff.enabled = true | .ff.protocol = "tcphttp"'
            local _host; prompt "免流 Host（如 realname.1888.com.mo）: " _host
            if [ -z "${_host:-}" ]; then
                log_error "Host 不能为空"
                st_set '.ff.enabled = false | .ff.protocol = "none"'
                echo ""; return 0
            fi
            st_set '.ff.host = $h' --arg h "${_host}"
            log_info "已选: TCP + HTTP 伪装（host=${_host}）"; echo ""; return 0 ;;
        *) st_set '.ff.enabled = false | .ff.protocol = "none"'
           log_info "不启用 FreeFlow"; echo ""; return 0;;
    esac
    port_mgr_in_use "$(port_of ff)" && log_warn "端口 $(port_of ff) 已被占用"
    local _p _vp; prompt "FreeFlow path（回车默认 /）: " _p
    case "${_p:-/}" in /*) :;; *) _p="/${_p}";; esac
    # path 通过 val_path 校验，防止配置注入
    if _vp=$(val_path "${_p:-/}" 2>/dev/null); then
        st_set '.ff.path = $p' --arg p "${_vp}"
    else
        log_warn "path 格式不合法，使用默认值 /"
        st_set '.ff.path = $p' --arg p "/"
    fi
    log_info "已选: $(st_get '.ff.protocol')（path=${_p:-/}）"; echo ""
}

ask_reality_mode() {
    echo ""; log_title "VLESS + Reality（TCP 直连，独立端口）"
    printf "  ${C_GRN}1.${C_RST} 启用 Reality\n"
    printf "  ${C_GRN}2.${C_RST} 不启用 ${C_YLW}[默认]${C_RST}\n"
    local _c; prompt "请选择 (1-2，回车默认2): " _c
    case "${_c:-2}" in
        1) st_set '.reality.enabled = true';;
        *) st_set '.reality.enabled = false'; log_info "不启用 Reality"; echo ""; return 0;;
    esac

    local _dp; _dp=$(port_of reality)
    local _rp; prompt "监听端口（回车默认 ${_dp}）: " _rp
    if [ -n "${_rp:-}" ]; then
        if val_port "${_rp}" >/dev/null 2>&1; then
            st_set '.ports.reality = ($p|tonumber)' --arg p "${_rp}"
        else
            log_warn "端口无效，使用默认值 ${_dp}"
        fi
    fi
    port_mgr_in_use "$(port_of reality)" && \
        log_warn "端口 $(port_of reality) 已被占用，安装时将自动更换"

    local _ds; _ds=$(st_get '.reality.sni')
    log_info "SNI 建议：addons.mozilla.org / www.microsoft.com / www.apple.com"
    local _sni; prompt "伪装 SNI（回车默认 ${_ds}）: " _sni
    if [ -n "${_sni:-}" ]; then
        printf '%s' "${_sni}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
            && st_set '.reality.sni = $s' --arg s "${_sni}" \
            || log_warn "SNI 格式不合法，使用默认值 ${_ds}"
    fi

    echo ""
    printf "  ${C_GRN}1.${C_RST} TCP + XTLS-Vision ${C_YLW}[默认]${C_RST}\n"
    printf "  ${C_GRN}2.${C_RST} XHTTP + Reality (auto)\n"
    local _nc; prompt "传输方式 (1-2，回车默认1): " _nc
    case "${_nc:-1}" in
        2) st_set '.reality.network = "xhttp"'; log_info "已选：XHTTP + Reality";;
        *) st_set '.reality.network = "tcp"';   log_info "已选：TCP + XTLS-Vision";;
    esac
    log_info "Reality 配置完成 — 端口:$(port_of reality) SNI:$(st_get '.reality.sni') 传输:$(st_get '.reality.network')"
    echo ""
}

ask_vltcp_mode() {
    echo ""; log_title "VLESS-TCP 明文落地（无加密）"
    printf "  ${C_GRN}1.${C_RST} 启用 VLESS-TCP\n"
    printf "  ${C_GRN}2.${C_RST} 不启用 ${C_YLW}[默认]${C_RST}\n"
    local _c; prompt "请选择 (1-2，回车默认2): " _c
    case "${_c:-2}" in
        1) st_set '.vltcp.enabled = true';;
        *) st_set '.vltcp.enabled = false'; log_info "不启用 VLESS-TCP"; echo ""; return 0;;
    esac

    local _dp; _dp=$(port_of vltcp)
    local _vp; prompt "监听端口（回车默认 ${_dp}）: " _vp
    if [ -n "${_vp:-}" ]; then
        if val_port "${_vp}" >/dev/null 2>&1; then
            st_set '.ports.vltcp = ($p|tonumber)' --arg p "${_vp}"
        else
            log_warn "端口无效，使用默认值 ${_dp}"
        fi
    fi
    port_mgr_in_use "$(port_of vltcp)" && log_warn "端口 $(port_of vltcp) 已被占用"

    local _dl; _dl=$(st_get '.vltcp.listen')
    local _vl; prompt "监听地址（回车默认 ${_dl}，0.0.0.0=所有接口）: " _vl
    [ -n "${_vl:-}" ] && { _vl=$(val_listen_addr "${_vl}") || { log_warn "监听地址不合法，使用默认值 ${_dl}"; _vl="${_dl}"; }; st_set '.vltcp.listen = $l' --arg l "${_vl}"; }
    log_info "VLESS-TCP 配置完成 — 端口:$(port_of vltcp) 监听:$(st_get '.vltcp.listen')"
    echo ""
}


ask_vlquic_mode() {
    echo ""; log_title "VLESS-XHTTP-H3（UDP/QUIC）"
    printf "  ${C_GRN}1.${C_RST} 启用 VLESS-XHTTP-H3\n"
    printf "  ${C_GRN}2.${C_RST} 不启用 ${C_YLW}[默认]${C_RST}\n"
    local _c; prompt "请选择 (1-2，回车默认2): " _c
    case "${_c:-2}" in
        1) st_set '.vlquic.enabled = true';;
        *) st_set '.vlquic.enabled = false'; log_info "不启用 VLESS-XHTTP-H3"; echo ""; return 0;;
    esac

    local _dp; _dp=$(port_of vlquic)
    local _vp; prompt "UDP 监听端口（回车默认 ${_dp}）: " _vp
    if [ -n "${_vp:-}" ]; then
        if val_port "${_vp}" >/dev/null 2>&1; then
            st_set '.ports.vlquic = ($p|tonumber)' --arg p "${_vp}"
        else
            log_warn "端口无效，使用默认值 ${_dp}"
        fi
    fi
    port_mgr_in_use_udp "$(port_of vlquic)" && log_warn "UDP/$(port_of vlquic) 已被占用"

    local _dl; _dl=$(st_get '.vlquic.listen')
    local _vl; prompt "监听地址（回车默认 ${_dl}，0.0.0.0=所有接口）: " _vl
    [ -n "${_vl:-}" ] && { _vl=$(val_listen_addr "${_vl}") || { log_warn "监听地址不合法，使用默认值 ${_dl}"; _vl="${_dl}"; }; st_set '.vlquic.listen = $l' --arg l "${_vl}"; }
    vlquic_config_cert || { st_set '.vlquic.enabled = false'; return 1; }
    log_info "VLESS-XHTTP-H3 配置完成 — UDP端口:$(port_of vlquic) 域名:$(st_get '.vlquic.domain')"
    echo ""
}

ask_xpad_mode() {
    local _target="${1:-all}" _label="${2:-全部 XHTTP}"
    echo ""; log_title "${_label} xPadding 混淆"
    printf "  ${C_GRN}1.${C_RST} 开启 xPadding（更强流量伪装） ${C_YLW}[默认]${C_RST}\n"
    printf "  ${C_GRN}2.${C_RST} 关闭 xPadding（纯 XHTTP）\n"
    local _c _v; prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2) _v=false; log_info "已选：${_label} 关闭 xPadding";;
        *) _v=true;  log_info "已选：${_label} 开启 xPadding";;
    esac
    case "${_target}" in
        argo|ff|reality) st_set ".xpad.${_target} = \$v" --argjson v "${_v}" ;;
        all) st_set '.xpad.argo = $v | .xpad.ff = $v | .xpad.reality = $v' --argjson v "${_v}" ;;
        *) log_error "未知 xPadding 目标: ${_target}"; return 1 ;;
    esac
    echo ""
}

# ── 管理子菜单辅助 ────────────────────────────────────────────────────────────

# 交互输入端口并写入 .ports.<proto>
_menu_input_port() {
    local _jq_path="$1" _outvar="${2:-}" _port_input
    prompt "新端口（回车随机）: " _port_input
    [ -z "${_port_input:-}" ] && _port_input=$(shuf -i 1024-65000 -n 1 2>/dev/null || \
                              awk 'BEGIN{srand();print int(rand()*63976)+1024}')
    # 统一通过 val_port 校验，防止配置注入
    val_port "${_port_input}" >/dev/null || return 1
    if port_mgr_in_use "${_port_input}"; then
        log_warn "端口 ${_port_input} 已被占用"
        local _a; prompt "仍然继续？(y/N): " _a
        case "${_a:-n}" in y|Y) :;; *) return 1;; esac
    fi
    st_set "${_jq_path} = (\$p|tonumber)" --arg p "${_port_input}" || return 1
    if [ -n "${_outvar:-}" ]; then
        printf '%s' "${_outvar}" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' \
            || { log_error "内部错误：非法输出变量名 ${_outvar}"; return 1; }
        printf -v "${_outvar}" '%s' "${_port_input}"
    else
        printf '%s' "${_port_input}"
    fi
}

_menu_confirm_uninstall() {
    local _name="$1" _a
    prompt "确定要卸载 ${_name}？(y/N): " _a
    case "${_a:-n}" in y|Y) return 0;; *) return 1;; esac
}

_menu_toggle_xpad() {
    local _target="$1" _label="$2" _nxp
    case "${_target}" in
        argo|ff|reality) : ;;
        *) log_error "未知 xPadding 目标: ${_target}"; return 1 ;;
    esac
    [ "$(xpad_of "${_target}")" = "true" ] && _nxp="false" || _nxp="true"
    st_set ".xpad.${_target} = \$v" --argjson v "${_nxp}" || return 1
    config_apply || return 1
    st_persist || log_warn "state.json 写入失败"
    log_ok "${_label} xPadding 已${_nxp}"; config_print_nodes
}

check_xray() {
    [ -f "${XRAY_BIN}" ] || { printf 'not installed'; return 2; }
    svc_exec status "${_SVC_XRAY}" \
        && { printf 'running'; return 0; } \
        || { printf 'stopped'; return 1; }
}

check_argo() {
    [ "$(st_get '.argo.enabled')" = "true" ] || { printf 'disabled'; return 3; }
    [ -f "${ARGO_BIN}" ]                      || { printf 'not installed'; return 2; }
    svc_exec status "${_SVC_TUNNEL}" \
        && { printf 'running'; return 0; } \
        || { printf 'stopped'; return 1; }
}

# ── Argo 管理 ─────────────────────────────────────────────────────────────────

manage_argo() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先完成 Xray-2go 安装"; sleep 1; return; }
    while true; do
        local _en _astat _domain _proto _port _xpad
        _en=$(    st_get '.argo.enabled')
        _astat=$( check_argo)
        _domain=$(st_get '.argo.domain')
        _proto=$( st_get '.argo.protocol')
        _port=$(  port_of argo)
        _xpad=$(  xpad_of argo)

        clear; echo ""; log_title "══ Argo 固定隧道管理 ══"
        if [ "${_en}" = "true" ]; then
            printf "  模块: ${C_GRN}已启用${C_RST}  服务: ${C_GRN}%s${C_RST}\n" "${_astat}"
            printf "  协议: ${C_CYN}%s${C_RST}  回源端口: ${C_YLW}%s${C_RST}\n" "${_proto}" "${_port}"
            if [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ]; then
                printf "  域名: ${C_GRN}%s${C_RST}\n" "${_domain}"
            else
                printf "  域名: ${C_YLW}未配置（请选项 4 配置）${C_RST}\n"
            fi
        else
            printf "  模块: ${C_YLW}未启用${C_RST}\n"
        fi
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用 Argo\n"
        printf "  ${C_RED}2.${C_RST} 禁用 Argo\n"
        printf "  ${C_GRN}3.${C_RST} 重启隧道服务\n"
        printf "  ${C_RED}9.${C_RST} 卸载 Argo\n"
        _hr
        printf "  ${C_GRN}4.${C_RST} 配置/更新固定隧道域名\n"
        printf "  ${C_GRN}5.${C_RST} 切换协议 (WS ↔ XHTTP)\n"
        printf "  ${C_GRN}6.${C_RST} 修改回源端口 (当前: ${C_YLW}${_port}${C_RST})\n"
        printf "  ${C_GRN}7.${C_RST} 切换 xPadding (当前: ${C_YLW}${_xpad}${C_RST}，仅 XHTTP 生效)\n"
        printf "  ${C_GRN}8.${C_RST} 查看节点链接\n"
        printf "  ${C_GRN}a.${C_RST} 健康检查\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)
                [ "${_en}" = "true" ] && { log_info "Argo 已启用"; _pause; continue; }
                if [ ! -f "${ARGO_BIN}" ] || [ ! -x "${ARGO_BIN}" ]; then
                    download_cloudflared || { _pause; continue; }
                fi
                st_set '.argo.enabled = true' || { _pause; continue; }
                config_apply || { st_set '.argo.enabled = false'; _pause; continue; }
                svc_apply_tunnel || return 1; svc_reload_daemon
                svc_exec_mut enable "${_SVC_TUNNEL}"
                svc_exec_mut start  "${_SVC_TUNNEL}" \
                    && log_ok "Argo 已启用并启动" \
                    || log_warn "启动失败，请检查域名配置"
                st_persist || log_warn "state.json 写入失败" ;;
            2)
                [ "${_en}" != "true" ] && { log_info "Argo 已禁用"; _pause; continue; }
                svc_exec_mut stop    "${_SVC_TUNNEL}" 2>/dev/null || true
                svc_exec_mut disable "${_SVC_TUNNEL}" 2>/dev/null || true
                st_set '.argo.enabled = false' || { _pause; continue; }
                _module_disable_commit Argo || { _pause; continue; }
                log_ok "Argo 已禁用" ;;
            3)
                [ "${_en}" != "true" ] && { log_warn "Argo 未启用"; _pause; continue; }
                svc_exec_mut restart "${_SVC_TUNNEL}" \
                    && { log_ok "${_SVC_TUNNEL} 已重启"; svc_verify_health "${_SVC_TUNNEL}" 6; } \
                    || log_error "${_SVC_TUNNEL} 重启失败" ;;
            9)
                _menu_confirm_uninstall "Argo" || { _pause; continue; }
                svc_exec_mut stop    "${_SVC_TUNNEL}" 2>/dev/null || true
                svc_exec_mut disable "${_SVC_TUNNEL}" 2>/dev/null || true
                if is_systemd; then
                    rm -f "/etc/systemd/system/${_SVC_TUNNEL}.service" 2>/dev/null || true
                    systemctl daemon-reload >/dev/null 2>&1 || true
                else
                    rm -f "/etc/init.d/${_SVC_TUNNEL}" 2>/dev/null || true
                fi
                rm -f "${ARGO_BIN}" "${WORK_DIR}/tunnel.yml" \
                      "${WORK_DIR}/tunnel.json" "${_ARGO_ENV_FILE}" 2>/dev/null || true
                st_set '.argo.enabled = false | .argo.domain = null | .argo.token = null | .argo.mode = "fixed"' \
                    || true
                _module_disable_commit Argo || { _pause; continue; }
                log_ok "Argo 已完全卸载"; _pause; return ;;
            4)
                [ "${_en}" != "true" ] && { log_warn "请先选项 1 启用 Argo"; _pause; continue; }
                echo ""
                printf "  ${C_GRN}1.${C_RST} WS ${C_YLW}[默认]${C_RST}\n"
                printf "  ${C_GRN}2.${C_RST} XHTTP\n"
                local _pp; prompt "协议 (回车维持 ${_proto}): " _pp
                case "${_pp:-}" in
                    2) st_set '.argo.protocol = "xhttp"';;
                    1) st_set '.argo.protocol = "ws"';;
                esac
                argo_apply_fixed_tunnel && config_print_nodes || log_error "固定隧道配置失败" ;;
            5)
                [ "${_en}" != "true" ] && { log_warn "请先选项 1 启用 Argo"; _pause; continue; }
                local _np; [ "${_proto}" = "ws" ] && _np="xhttp" || _np="ws"
                st_set '.argo.protocol = $p' --arg p "${_np}" || { _pause; continue; }
                if config_apply && st_persist; then
                    log_ok "协议已切换: ${_np}"; config_print_nodes
                else
                    log_error "切换失败，回滚"
                    st_set '.argo.protocol = $p' --arg p "${_proto}"
                fi ;;
            6) exec_update_argo_port ;;
            7) _menu_toggle_xpad argo Argo ;;
            8) config_print_nodes ;;
            a) argo_check_health || true ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ── FreeFlow 管理 ─────────────────────────────────────────────────────────────

manage_freeflow() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先完成 Xray-2go 安装"; sleep 1; return; }
    while true; do
        local _en _proto _path _host _xpad _xstat _port
        _en=$(   st_get '.ff.enabled')
        _proto=$(st_get '.ff.protocol')
        _path=$( st_get '.ff.path')
        _host=$( st_get '.ff.host')
        _xpad=$( xpad_of ff)
        _port=$( port_of ff)
        svc_exec status "${_SVC_XRAY}" >/dev/null 2>&1 && _xstat="running" || _xstat="stopped"

        clear; echo ""; log_title "══ FreeFlow 管理 ══"
        if [ "${_en}" = "true" ] && [ "${_proto}" != "none" ]; then
            printf "  模块: ${C_GRN}已启用${C_RST}  服务: ${C_GRN}%s${C_RST}\n" "${_xstat}"
            if [ "${_proto}" = "tcphttp" ]; then
                printf "  协议: ${C_CYN}%s${C_RST}  host: ${C_YLW}%s${C_RST}  端口: %s\n" "${_proto}" "${_host}" "${_port}"
            else
                printf "  协议: ${C_CYN}%s${C_RST}  path: ${C_YLW}%s${C_RST}  端口: %s\n" "${_proto}" "${_path}" "${_port}"
            fi
        else
            printf "  模块: ${C_YLW}未启用${C_RST}\n"
        fi
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用 FreeFlow\n"
        printf "  ${C_RED}2.${C_RST} 禁用 FreeFlow\n"
        printf "  ${C_GRN}3.${C_RST} 重启 xray2go 服务\n"
        printf "  ${C_RED}9.${C_RST} 卸载 FreeFlow\n"
        _hr
        printf "  ${C_GRN}4.${C_RST} 变更传输协议\n"
        printf "  ${C_GRN}5.${C_RST} 修改端口（当前: ${C_YLW}${_port}${C_RST}）\n"
        if [ "${_proto}" = "tcphttp" ]; then
            printf "  ${C_GRN}6.${C_RST} 修改免流 Host（当前: ${C_YLW}${_host}${C_RST}）\n"
        else
            printf "  ${C_GRN}6.${C_RST} 修改 path（当前: ${C_YLW}${_path}${C_RST}）\n"
        fi
        printf "  ${C_GRN}7.${C_RST} 切换 xPadding (当前: ${C_YLW}${_xpad}${C_RST}，仅 XHTTP 生效)\n"
        printf "  ${C_GRN}8.${C_RST} 查看节点链接\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)
                [ "${_en}" = "true" ] && [ "${_proto}" != "none" ] && { log_info "FreeFlow 已启用"; _pause; continue; }
                ask_freeflow_mode
                [ "$(st_get '.ff.enabled')" = "true" ] || { _pause; continue; }
                _commit || { _pause; continue; }
                log_ok "FreeFlow 已启用"; config_print_nodes ;;
            2)
                { [ "${_en}" != "true" ] || [ "${_proto}" = "none" ]; } && { log_info "FreeFlow 已禁用"; _pause; continue; }
                st_set '.ff.enabled = false | .ff.protocol = "none"' || { _pause; continue; }
                _module_disable_commit FreeFlow || { _pause; continue; }
                log_ok "FreeFlow 已禁用" ;;
            3) svc_restart_xray || true ;;
            9)
                _menu_confirm_uninstall "FreeFlow" || { _pause; continue; }
                st_set '.ff.enabled = false | .ff.protocol = "none" | .ff.path = "/" | .ff.host = ""' \
                    || { _pause; continue; }
                _module_disable_commit FreeFlow || { _pause; continue; }
                log_ok "FreeFlow 已卸载"; _pause; return ;;
            4)
                ask_freeflow_mode
                [ "$(st_get '.ff.enabled')" = "true" ] || { _pause; continue; }
                _commit || { _pause; continue; }
                log_ok "FreeFlow 协议已变更"; config_print_nodes ;;
            5)
                local _np; _menu_input_port '.ports.ff' _np || { _pause; continue; }
                _commit_port_change ff "${_np}" || { _pause; continue; } ;;
            6)
                { [ "${_en}" != "true" ] || [ "${_proto}" = "none" ]; } && { log_warn "请先启用 FreeFlow"; _pause; continue; }
                if [ "${_proto}" = "tcphttp" ]; then
                    local _h; prompt "新免流 Host（回车保持 ${_host}）: " _h
                    if [ -n "${_h:-}" ]; then
                        st_set '.ff.host = $h' --arg h "${_h}" || { _pause; continue; }
                        config_apply && st_persist || true
                        log_ok "Host 已更新: ${_h}"; config_print_nodes
                    fi
                else
                    local _p; prompt "新 path（回车保持 ${_path}）: " _p
                    if [ -n "${_p:-}" ]; then
                        case "${_p}" in /*) :;; *) _p="/${_p}";; esac
                        # path 格式校验
                        local _vp2
                        if ! _vp2=$(val_path "${_p}" 2>/dev/null); then
                            log_error "path 格式不合法"; _pause; continue
                        fi
                        st_set '.ff.path = $p' --arg p "${_vp2}" || { _pause; continue; }
                        config_apply && st_persist || true
                        log_ok "path 已更新: ${_p}"; config_print_nodes
                    fi
                fi ;;
            7) _menu_toggle_xpad ff FreeFlow ;;
            8) config_print_nodes ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ── Reality 管理 ──────────────────────────────────────────────────────────────

manage_reality() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先完成 Xray-2go 安装"; sleep 1; return; }
    while true; do
        local _en _port _sni _pbk _pvk _sid _net _pbk_disp _xpad _xstat
        _en=$(  st_get '.reality.enabled')
        _port=$(port_of reality)
        _sni=$( st_get '.reality.sni')
        _pbk=$( st_get '.reality.pbk')
        _pvk=$( st_get '.reality.pvk')
        _sid=$( st_get '.reality.sid')
        _net=$( st_get '.reality.network'); _net="${_net:-tcp}"
        _xpad=$(xpad_of reality)
        _pbk_disp="未生成"
        [ -n "${_pbk:-}" ] && [ "${_pbk}" != "null" ] && _pbk_disp="${_pbk:0:16}..."
        svc_exec status "${_SVC_XRAY}" >/dev/null 2>&1 && _xstat="running" || _xstat="stopped"

        clear; echo ""; log_title "══ Reality 管理 ══"
        [ "${_en}" = "true" ] \
            && printf "  模块: ${C_GRN}已启用${C_RST}  服务: ${C_GRN}%s${C_RST}\n" "${_xstat}" \
            || printf "  模块: ${C_YLW}未启用${C_RST}\n"
        printf "  端口: ${C_YLW}%s${C_RST}  SNI: ${C_CYN}%s${C_RST}  传输: ${C_GRN}%s${C_RST}\n" \
            "${_port}" "${_sni}" "${_net}"
        printf "  公钥: %s\n" "${_pbk_disp}"
        [ -n "${_sid:-}" ] && [ "${_sid}" != "null" ] \
            && printf "  ShortId: ${C_CYN}%s${C_RST}\n" "${_sid}"
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用 Reality\n"
        printf "  ${C_RED}2.${C_RST} 禁用 Reality\n"
        printf "  ${C_GRN}3.${C_RST} 重启 xray2go 服务\n"
        printf "  ${C_RED}9.${C_RST} 卸载 Reality（禁用 + 清除密钥）\n"
        _hr
        printf "  ${C_GRN}4.${C_RST} 修改端口（当前: ${C_YLW}${_port}${C_RST}）\n"
        printf "  ${C_GRN}5.${C_RST} 修改 SNI（当前: ${C_CYN}${_sni}${C_RST}）\n"
        printf "  ${C_GRN}6.${C_RST} 切换传输方式（当前: ${C_GRN}${_net}${C_RST}）\n"
        printf "  ${C_GRN}7.${C_RST} 切换 xPadding (当前: ${C_YLW}${_xpad}${C_RST}，仅 XHTTP 生效)\n"
        printf "  ${C_GRN}8.${C_RST} 重新生成密钥对\n"
        printf "  ${C_GRN}a.${C_RST} 查看节点链接\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)
                [ "${_en}" = "true" ] && { log_info "Reality 已启用"; _pause; continue; }
                [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪"; _pause; continue; }
                if [ -z "${_pvk:-}" ] || [ "${_pvk}" = "null" ]; then
                    log_step "生成 x25519 密钥对..."
                    crypto_gen_reality_keypair || { _pause; continue; }
                    st_set '.reality.sid = $s' --arg s "$(crypto_gen_reality_sid)" || true
                fi
                st_set '.reality.enabled = true' || { _pause; continue; }
                config_apply || { st_set '.reality.enabled = false'; _pause; continue; }
                st_persist || log_warn "state.json 写入失败"
                fw_reconcile
                log_ok "Reality 已启用"; config_print_nodes ;;
            2)
                [ "${_en}" != "true" ] && { log_info "Reality 已禁用"; _pause; continue; }
                st_set '.reality.enabled = false' || { _pause; continue; }
                _module_disable_commit Reality || { _pause; continue; }
                log_ok "Reality 已禁用" ;;
            3) svc_restart_xray || true ;;
            9)
                _menu_confirm_uninstall "Reality" || { _pause; continue; }
                st_set '.reality.enabled = false | .reality.pbk = null | .reality.pvk = null | .reality.sid = null' \
                    || { _pause; continue; }
                _module_disable_commit Reality || { _pause; continue; }
                log_ok "Reality 已卸载"; _pause; return ;;
            4)
                local _np; _menu_input_port '.ports.reality' _np || { _pause; continue; }
                _commit_port_change reality "${_np}" || { _pause; continue; } ;;
            5)
                log_info "建议：addons.mozilla.org / www.microsoft.com / www.apple.com"
                local _s; prompt "新 SNI（回车保持 ${_sni}）: " _s
                if [ -n "${_s:-}" ]; then
                    printf '%s' "${_s}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
                        || { log_error "SNI 格式不合法"; _pause; continue; }
                    st_set '.reality.sni = $s' --arg s "${_s}" || { _pause; continue; }
                    [ "${_en}" = "true" ] && { config_apply || { _pause; continue; }; }
                    st_persist || log_warn "state.json 写入失败"
                    log_ok "SNI 已更新: ${_s}"
                    [ "${_en}" = "true" ] && config_print_nodes
                fi ;;
            6)
                local _nn; [ "${_net}" = "tcp" ] && _nn="xhttp" || _nn="tcp"
                st_set '.reality.network = $n' --arg n "${_nn}" || { _pause; continue; }
                [ "${_en}" = "true" ] && { config_apply || { _pause; continue; }; }
                st_persist || log_warn "state.json 写入失败"
                log_ok "传输方式已切换: ${_nn}"
                [ "${_en}" = "true" ] && config_print_nodes ;;
            7) _menu_toggle_xpad reality Reality ;;
            8)
                [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪"; _pause; continue; }
                crypto_gen_reality_keypair || { _pause; continue; }
                st_set '.reality.sid = $s' --arg s "$(crypto_gen_reality_sid)" || { _pause; continue; }
                [ "${_en}" = "true" ] && { config_apply || { _pause; continue; }; }
                st_persist || log_warn "state.json 写入失败"
                log_ok "密钥对已更新"
                [ "${_en}" = "true" ] && config_print_nodes ;;
            a) config_print_nodes ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ── VLESS-TCP 管理 ────────────────────────────────────────────────────────────

manage_vltcp() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先完成 Xray-2go 安装"; sleep 1; return; }
    while true; do
        local _en _port _listen _xstat
        _en=$(    st_get '.vltcp.enabled')
        _port=$(  port_of vltcp)
        _listen=$(st_get '.vltcp.listen')
        svc_exec status "${_SVC_XRAY}" >/dev/null 2>&1 && _xstat="running" || _xstat="stopped"

        clear; echo ""; log_title "══ VLESS-TCP 明文落地管理 ══"
        [ "${_en}" = "true" ] \
            && printf "  模块: ${C_GRN}已启用${C_RST}  服务: ${C_GRN}%s${C_RST}\n" "${_xstat}" \
            || printf "  模块: ${C_YLW}未启用${C_RST}\n"
        printf "  端口: ${C_YLW}%s${C_RST}  监听: ${C_CYN}%s${C_RST}\n" "${_port}" "${_listen}"
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用 VLESS-TCP\n"
        printf "  ${C_RED}2.${C_RST} 禁用 VLESS-TCP\n"
        printf "  ${C_GRN}3.${C_RST} 重启 xray2go 服务\n"
        printf "  ${C_RED}9.${C_RST} 卸载 VLESS-TCP\n"
        _hr
        printf "  ${C_GRN}4.${C_RST} 修改端口（当前: ${C_YLW}${_port}${C_RST}）\n"
        printf "  ${C_GRN}5.${C_RST} 修改监听地址（当前: ${C_CYN}${_listen}${C_RST}）\n"
        printf "  ${C_GRN}6.${C_RST} 查看节点链接\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)
                [ "${_en}" = "true" ] && { log_info "VLESS-TCP 已启用"; _pause; continue; }
                st_set '.vltcp.enabled = true' || { _pause; continue; }
                config_apply || { st_set '.vltcp.enabled = false'; _pause; continue; }
                st_persist || log_warn "state.json 写入失败"
                fw_reconcile
                log_ok "VLESS-TCP 已启用 (端口: ${_port})"; config_print_nodes ;;
            2)
                [ "${_en}" != "true" ] && { log_info "VLESS-TCP 已禁用"; _pause; continue; }
                st_set '.vltcp.enabled = false' || { _pause; continue; }
                _module_disable_commit VLESS-TCP || { _pause; continue; }
                log_ok "VLESS-TCP 已禁用" ;;
            3) svc_restart_xray || true ;;
            9)
                _menu_confirm_uninstall "VLESS-TCP" || { _pause; continue; }
                st_set '.vltcp.enabled = false | .vltcp.listen = "0.0.0.0"' || { _pause; continue; }
                st_set '.ports.vltcp = 1234'
                _module_disable_commit VLESS-TCP || { _pause; continue; }
                log_ok "VLESS-TCP 已卸载"; _pause; return ;;
            4)
                local _np; _menu_input_port '.ports.vltcp' _np || { _pause; continue; }
                _commit_port_change vltcp "${_np}" || { _pause; continue; } ;;
            5)
                local _l; prompt "新监听地址（0.0.0.0=所有，127.0.0.1=仅本地）: " _l
                if [ -n "${_l:-}" ]; then
                    _l=$(val_listen_addr "${_l}") || { _pause; continue; }
                    st_set '.vltcp.listen = $l' --arg l "${_l}" || { _pause; continue; }
                    [ "${_en}" = "true" ] && { config_apply || { _pause; continue; }; }
                    st_persist || log_warn "state.json 写入失败"
                    log_ok "监听地址已更新: ${_l}"
                    [ "${_en}" = "true" ] && config_print_nodes
                fi ;;
            6) config_print_nodes ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}


# ── VLESS-XHTTP-H3 管理 ────────────────────────────────────────────────────────

manage_vlquic() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先完成 Xray-2go 安装"; sleep 1; return; }
    while true; do
        local _en _port _listen _domain _method _xstat
        _en=$(     st_get '.vlquic.enabled')
        _port=$(   port_of vlquic)
        _listen=$( st_get '.vlquic.listen')
        _domain=$( st_get '.vlquic.domain')
        _method=$( st_get '.vlquic.acme_method')
        svc_exec status "${_SVC_XRAY}" >/dev/null 2>&1 && _xstat="running" || _xstat="stopped"

        clear; echo ""; log_title "══ VLESS-XHTTP-H3 / QUIC 管理 ══"
        [ "${_en}" = "true" ] \
            && printf "  模块: ${C_GRN}已启用${C_RST}  服务: ${C_GRN}%s${C_RST}\n" "${_xstat}" \
            || printf "  模块: ${C_YLW}未启用${C_RST}\n"
        printf "  端口: ${C_YLW}%s/udp${C_RST}  监听: ${C_CYN}%s${C_RST}\n" "${_port}" "${_listen}"
        printf "  域名: ${C_CYN}%s${C_RST}  证书: ${C_YLW}%s${C_RST}\n" "${_domain:-未配置}" "${_method:-manual}"
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用 VLESS-XHTTP-H3\n"
        printf "  ${C_RED}2.${C_RST} 禁用 VLESS-XHTTP-H3\n"
        printf "  ${C_GRN}3.${C_RST} 重启 xray2go 服务\n"
        printf "  ${C_RED}9.${C_RST} 卸载 VLESS-XHTTP-H3\n"
        _hr
        printf "  ${C_GRN}4.${C_RST} 修改 UDP 端口（当前: ${C_YLW}${_port}${C_RST}）\n"
        printf "  ${C_GRN}5.${C_RST} 修改监听地址（当前: ${C_CYN}${_listen}${C_RST}）\n"
        printf "  ${C_GRN}6.${C_RST} 配置/重新签发证书\n"
        printf "  ${C_GRN}7.${C_RST} 查看节点链接\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)
                [ "${_en}" = "true" ] && { log_info "VLESS-XHTTP-H3 已启用"; _pause; continue; }
                if [ -z "${_domain:-}" ] || [ "${_domain}" = "null" ] || [ ! -f "$(st_get '.vlquic.cert')" ] || [ ! -f "$(st_get '.vlquic.key')" ]; then
                    vlquic_config_cert || { _pause; continue; }
                fi
                st_set '.vlquic.enabled = true' || { _pause; continue; }
                config_apply || { st_set '.vlquic.enabled = false'; _pause; continue; }
                st_persist || log_warn "state.json 写入失败"
                fw_reconcile
                log_ok "VLESS-XHTTP-H3 已启用 (UDP/${_port})"; config_print_nodes ;;
            2)
                [ "${_en}" != "true" ] && { log_info "VLESS-XHTTP-H3 已禁用"; _pause; continue; }
                st_set '.vlquic.enabled = false' || { _pause; continue; }
                _module_disable_commit VLESS-XHTTP-H3 || { _pause; continue; }
                log_ok "VLESS-XHTTP-H3 已禁用" ;;
            3) svc_restart_xray || true ;;
            9)
                _menu_confirm_uninstall "VLESS-XHTTP-H3" || { _pause; continue; }
                st_set '.vlquic.enabled = false | .vlquic.listen = "0.0.0.0" | .vlquic.domain = "" | .vlquic.cert = "" | .vlquic.key = "" | .vlquic.acme_method = "manual"' || { _pause; continue; }
                st_set '.ports.vlquic = 443'
                _module_disable_commit VLESS-XHTTP-H3 || { _pause; continue; }
                log_ok "VLESS-XHTTP-H3 已卸载"; _pause; return ;;
            4)
                local _np; _menu_input_port '.ports.vlquic' _np || { _pause; continue; }
                _commit_port_change vlquic "${_np}/udp" || { _pause; continue; } ;;
            5)
                local _l; prompt "新监听地址（0.0.0.0=所有，127.0.0.1=仅本地）: " _l
                if [ -n "${_l:-}" ]; then
                    _l=$(val_listen_addr "${_l}") || { _pause; continue; }
                    st_set '.vlquic.listen = $l' --arg l "${_l}" || { _pause; continue; }
                    [ "${_en}" = "true" ] && { config_apply || { _pause; continue; }; }
                    st_persist || log_warn "state.json 写入失败"
                    log_ok "监听地址已更新: ${_l}"
                    [ "${_en}" = "true" ] && config_print_nodes
                fi ;;
            6)
                vlquic_config_cert || { _pause; continue; }
                [ "${_en}" = "true" ] && { config_apply || { _pause; continue; }; }
                st_persist || log_warn "state.json 写入失败"
                [ "${_en}" = "true" ] && config_print_nodes ;;
            7) config_print_nodes ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ── 主菜单 ────────────────────────────────────────────────────────────────────

_menu_collect_status() {
    local _xs _cx
    _xs=$(check_xray); _cx=$?
    [ "${_cx}" -eq 0 ] && _MENU_XC="${C_GRN}" || _MENU_XC="${C_RED}"
    _MENU_XS="${_xs}"; _MENU_CX="${_cx}"

    local _as _dom
    _as=$(check_argo); _dom=$(st_get '.argo.domain')
    if [ "$(st_get '.argo.enabled')" = "true" ]; then
        [ -n "${_dom:-}" ] && [ "${_dom}" != "null" ] \
            && _MENU_AD="${_as} [$(st_get '.argo.protocol'), ${_dom}, port=$(port_of argo)]" \
            || _MENU_AD="${_as} [未配置域名]"
    else
        _MENU_AD="未启用"
    fi

    local _fp _fpa _ffhost
    _fp=$(st_get '.ff.protocol'); _fpa=$(st_get '.ff.path'); _ffhost=$(st_get '.ff.host')
    if [ "$(st_get '.ff.enabled')" = "true" ] && [ "${_fp}" != "none" ]; then
        [ "${_fp}" = "tcphttp" ] \
            && _MENU_FD="${_fp} (host=${_ffhost}, port=$(port_of ff))" \
            || _MENU_FD="${_fp} (path=${_fpa}, port=$(port_of ff))"
    else
        _MENU_FD="未启用"
    fi

    [ "$(st_get '.reality.enabled')" = "true" ] \
        && _MENU_RD="已启用 (port=$(port_of reality), $(st_get '.reality.network'), sni=$(st_get '.reality.sni'))" \
        || _MENU_RD="未启用"

    [ "$(st_get '.vltcp.enabled')" = "true" ] \
        && _MENU_VD="已启用 (port=$(port_of vltcp), listen=$(st_get '.vltcp.listen'))" \
        || _MENU_VD="未启用"

    [ "$(st_get '.vlquic.enabled')" = "true" ] \
        && _MENU_QD="已启用 (udp=$(port_of vlquic), domain=$(st_get '.vlquic.domain'))" \
        || _MENU_QD="未启用"
}

_menu_render() {
    clear; echo ""
    printf "${C_BOLD}${C_PUR}  ╔══════════════════════════════════════════╗${C_RST}\n"
    printf "${C_BOLD}${C_PUR}  ║           Xray-2go Plugin Platform       ║${C_RST}\n"
    printf "${C_BOLD}${C_PUR}  ╠══════════════════════════════════════════╣${C_RST}\n"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  Xray     : ${_MENU_XC}%-29s${C_RST}${C_PUR} ${C_RST}\n" "${_MENU_XS}"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  Argo     : %-29s${C_PUR} ${C_RST}\n" "${_MENU_AD}"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  Reality  : %-29s${C_PUR} ${C_RST}\n" "${_MENU_RD}"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  VLESS-TCP: %-29s${C_PUR} ${C_RST}\n" "${_MENU_VD}"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  XHTTP-H3 : %-29s${C_PUR} ${C_RST}\n" "${_MENU_QD}"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  FF       : %-29s${C_PUR} ${C_RST}\n" "${_MENU_FD}"
    printf "${C_BOLD}${C_PUR}  ╚══════════════════════════════════════════╝${C_RST}\n\n"
    printf "  ${C_GRN}1.${C_RST} 安装 Xray-2go\n"
    printf "  ${C_RED}2.${C_RST} 卸载 Xray-2go\n"; _hr
    printf "  ${C_GRN}3.${C_RST} Argo 管理\n"
    printf "  ${C_GRN}4.${C_RST} Reality 管理\n"
    printf "  ${C_GRN}5.${C_RST} VLESS-TCP 管理\n"
    printf "  ${C_GRN}6.${C_RST} VLESS-XHTTP-H3 管理\n"
    printf "  ${C_GRN}7.${C_RST} FreeFlow 管理\n"; _hr
    printf "  ${C_GRN}8.${C_RST} 查看节点\n"
    printf "  ${C_GRN}9.${C_RST} 修改 UUID\n"
    printf "  ${C_GRN}s.${C_RST} 快捷方式/脚本更新\n"; _hr
    printf "  ${C_RED}0.${C_RST} 退出\n\n"
}

_menu_do_install() {
    if [ "${_MENU_CX}" -eq 0 ]; then
        log_warn "Xray-2go 已安装并运行，如需重装请先卸载 (选项 2)"; return
    fi

    ask_argo_mode
    [ "$(st_get '.argo.enabled')" = "true" ] && ask_argo_protocol
    ask_freeflow_mode
    ask_reality_mode
    ask_vltcp_mode
    ask_vlquic_mode

    if [ "$(st_get '.argo.enabled')" = "true" ] && [ "$(st_get '.argo.protocol')" = "xhttp" ]; then
        ask_xpad_mode argo Argo
    fi
    if [ "$(st_get '.ff.enabled')" = "true" ] && [ "$(st_get '.ff.protocol')" = "xhttp" ]; then
        ask_xpad_mode ff FreeFlow
    fi
    if [ "$(st_get '.reality.enabled')" = "true" ] && [ "$(st_get '.reality.network')" = "xhttp" ]; then
        ask_xpad_mode reality Reality
    fi

    if [ "$(st_get '.reality.enabled')" = "true" ]; then
        [ "$(port_of reality)" = "$(port_of argo)" ] && \
            log_warn "Reality 端口与 Argo 回源端口相同，安装时将自动修正"
    fi
    if [ "$(st_get '.vlquic.enabled')" = "true" ]; then
        port_mgr_in_use_udp "$(port_of vlquic)" && \
            log_warn "VLESS-XHTTP-H3 UDP/$(port_of vlquic) 已被占用"
    fi

    if ! exec_install; then
        log_error "安装失败"; _pause; return
    fi

    st_persist || log_warn "state.json 写入失败"

    [ "$(st_get '.argo.enabled')" = "true" ] && \
        { argo_apply_fixed_tunnel || \
          log_error "固定隧道配置失败，请从 [3. Argo 管理] 重新配置"; }
    config_print_nodes
}

menu() {
    local _MENU_XS="" _MENU_XC="" _MENU_CX=1
    local _MENU_AD="" _MENU_FD="" _MENU_RD="" _MENU_VD="" _MENU_QD=""
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
            6) manage_vlquic ;;
            7) manage_freeflow ;;
            8) [ "${_MENU_CX}" -eq 0 ] && config_print_nodes \
                    || log_warn "Xray-2go 未安装或未运行" ;;
            9) [ -f "${CONFIG_FILE}" ] && exec_update_uuid \
                    || log_warn "请先安装 Xray-2go" ;;
            s) exec_update_shortcut ;;
            0) log_info "已退出"; exit 0 ;;
            *) log_error "无效选项，请输入 0-9 或 s" ;;
        esac
        _pause
    done
}

# ==============================================================================
# Entrypoint
# ==============================================================================
main() {
    check_root
    platform_detect_init
    platform_preflight
    st_init
    # 刷新内置插件
    plugin_install_builtins
    # 加载插件到注册表
    plugin_load_all
    menu
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
