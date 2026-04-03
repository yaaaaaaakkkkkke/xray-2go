#!/usr/bin/env bash
# ==============================================================================
# xray-2go v3.0 — SSOT · Declarative Engine · Atomic Commit
# 架构原则：
#   · 单一事实来源 (SSOT)     — _STATE JSON 是唯一权威，所有读写经 state_* 接口
#   · 声明式配置引擎          — jq 驱动的 _gen_inbound_snippet() 插件体系
#   · 原子化提交与验证        — config_commit(): 合成 → xray-test → mv → 重启
#   · 统一服务管理接口        — _svc_manager() 屏蔽 systemd / OpenRC 差异
#   · 零持久化节点解析        — _get_share_links() 实时从 _STATE 生成链接
#   · 临时文件沙箱            — _TMP_DIR 统一追踪，EXIT trap 整体清理
# 支持协议：Argo WS/XHTTP · FreeFlow WS/HTTPUpgrade/XHTTP · Reality Vision
# 目标平台：Debian 12/Ubuntu (systemd) · Alpine (OpenRC)
# ==============================================================================
set -uo pipefail

# ==============================================================================
# §0  临时文件沙箱 + 全局 trap
#     所有 mktemp 调用须经 _tmp_file() — EXIT 时整体清理，无泄漏
# ==============================================================================
_TMP_DIR=""
_SPINNER_PID=0

trap '_global_cleanup' EXIT
trap '_int_handler'    INT TERM

_global_cleanup() {
    [ "${_SPINNER_PID}" -ne 0 ]  && kill "${_SPINNER_PID}" 2>/dev/null || true
    [ -n "${_TMP_DIR:-}" ]       && rm -rf "${_TMP_DIR}"   2>/dev/null || true
    tput cnorm 2>/dev/null || true
}

_int_handler() {
    printf '\n' >&2
    # log_error 在此处可能未定义（极早中断），安全降级
    printf '\033[1;91m[ERR ] 已中断\033[0m\n' >&2
    exit 130
}

# 懒初始化 —— 首次调用时创建，后续复用
_tmp_dir() {
    if [ -z "${_TMP_DIR:-}" ]; then
        _TMP_DIR=$(mktemp -d /tmp/xray2go_XXXXXX) \
            || { printf '\033[1;91m[ERR ] 无法创建临时目录\033[0m\n' >&2; exit 1; }
    fi
    printf '%s' "${_TMP_DIR}"
}

# 在沙箱中创建临时文件；$1 为 mktemp 模板（如 "next_cfg_XXXXXX.json"）
_tmp_file() { mktemp "$(_tmp_dir)/${1:-tmp_XXXXXX}"; }

# ==============================================================================
# §1  FHS 路径常量（唯一声明点）
# ==============================================================================
readonly WORK_DIR="/etc/xray"
readonly XRAY_BIN="${WORK_DIR}/xray"
readonly ARGO_BIN="${WORK_DIR}/argo"
readonly CONFIG_FILE="${WORK_DIR}/config.json"
readonly STATE_FILE="${WORK_DIR}/state.json"          # v3 SSOT 持久化文件
readonly ARGO_LOG="${WORK_DIR}/argo.log"
readonly SHORTCUT="/usr/local/bin/s"
readonly SELF_DEST="/usr/local/bin/xray2go"
readonly UPSTREAM_URL="https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh"

# ==============================================================================
# §2  ANSI UI 层（五级日志 + Spinner + prompt）
# ==============================================================================
readonly _C_RST=$'\033[0m'
readonly _C_BOLD=$'\033[1m'
readonly _C_RED=$'\033[1;91m'    # ERROR / 危险操作
readonly _C_GRN=$'\033[1;32m'   # OK / 成功
readonly _C_YLW=$'\033[1;33m'   # WARN
readonly _C_PUR=$'\033[1;35m'   # 标题 / 步骤
readonly _C_CYN=$'\033[1;36m'   # INFO / 节点链接

log_info()  { printf "${_C_CYN}[INFO]${_C_RST} %s\n"      "$*"; }
log_ok()    { printf "${_C_GRN}[ OK ]${_C_RST} %s\n"      "$*"; }
log_warn()  { printf "${_C_YLW}[WARN]${_C_RST} %s\n"      "$*" >&2; }
log_error() { printf "${_C_RED}[ERR ]${_C_RST} %s\n"      "$*" >&2; }
log_step()  { printf "${_C_PUR}[....] %s${_C_RST}\n"      "$*"; }
log_title() { printf "\n${_C_BOLD}${_C_PUR}%s${_C_RST}\n" "$*"; }
die()       { log_error "$1"; exit "${2:-1}"; }

# prompt：提示走 stderr，read 强制绑定 /dev/tty（兼容管道/重定向场景）
prompt() {
    local _msg="$1" _var="$2"
    printf "${_C_RED}%s${_C_RST}" "${_msg}" >&2
    read -r "${_var}" </dev/tty
}

_pause() {
    local _dummy
    printf "${_C_RED}按回车键继续...${_C_RST}" >&2
    read -r _dummy </dev/tty || true
}

_hr()     { printf "${_C_PUR}  ──────────────────────────────────${_C_RST}\n"; }
_hr_dbl() { printf "${_C_PUR}  ══════════════════════════════════${_C_RST}\n"; }

spinner_start() {
    local _msg="$1"
    printf "${_C_CYN}[....] %s${_C_RST}\n" "${_msg}"
    ( local i=0 chars='-\|/'
      while true; do
          printf "\r${_C_CYN}[ %s  ]${_C_RST} %s  " "${chars:$(( i % 4 )):1}" "${_msg}" >&2
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
# §3  平台检测层（业务代码仅调用 is_systemd / is_openrc / is_alpine / is_debian）
# ==============================================================================
_INIT_SYS=""      # systemd | openrc
_ARCH_CF=""       # cloudflared 架构标识
_ARCH_XRAY=""     # xray 架构标识

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
    [ -n "${_ARCH_XRAY:-}" ] && return 0    # 幂等
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
# §4  依赖预检层
#     强制依赖：curl / unzip / jq（核心运行时）
#     可选依赖：column（节点格式化）· openssl（备用随机源）
#     二进制完整性：xray / cloudflared 可执行位与基本自检
# ==============================================================================
check_root() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || die "请在 root 下运行脚本"
}

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

preflight_check() {
    log_step "依赖预检..."

    # ── 强制核心依赖
    for _d in curl unzip jq; do pkg_require "${_d}"; done

    # ── column：节点展示格式化（Alpine 需 util-linux-misc，其他系统通常内置）
    if ! command -v column >/dev/null 2>&1; then
        log_warn "column 未找到，节点展示将降级为纯文本"
        if is_alpine; then
            pkg_require util-linux-misc column 2>/dev/null || true
        else
            pkg_require bsdmainutils column 2>/dev/null || true
        fi
    fi

    # ── openssl：Reality shortId 备用随机源（非强制，/dev/urandom 为主路径）
    if ! command -v openssl >/dev/null 2>&1; then
        log_info "openssl 未安装 — Reality shortId 将由 /dev/urandom 生成（无影响）"
    fi

    # ── 二进制完整性检查（若已安装）
    if [ -f "${XRAY_BIN}" ]; then
        [ -x "${XRAY_BIN}" ] || { chmod +x "${XRAY_BIN}"; log_warn "已修复 xray 可执行位"; }
        "${XRAY_BIN}" version >/dev/null 2>&1 \
            || log_warn "xray 二进制可能损坏，建议通过菜单重新安装"
    fi
    if [ -f "${ARGO_BIN}" ]; then
        [ -x "${ARGO_BIN}" ] || { chmod +x "${ARGO_BIN}"; log_warn "已修复 cloudflared 可执行位"; }
    fi

    log_ok "依赖预检通过"
}

# ==============================================================================
# §5  SSOT 状态层
#
#  _STATE         — 内存中的 JSON 字符串，程序运行期间的唯一权威数据源
#  STATE_FILE     — _STATE 的磁盘持久化文件（/etc/xray/state.json）
#
#  数据 Schema（默认值）：
#  {
#    "uuid":    "<自动生成>",
#    "argo":   { "enabled": true,  "protocol": "ws",   "port": 8888,
#                "mode": "temp",   "domain": null,     "token": null },
#    "ff":     { "enabled": false, "protocol": "none", "path": "/" },
#    "reality":{ "enabled": false, "port": 443, "sni": "www.microsoft.com",
#                "pbk": null, "pvk": null, "sid": null },
#    "cron":   0,
#    "cfip":   "cf.tencentapp.cn",
#    "cfport": "443"
#  }
#
#  接口约定：
#    state_get  <jq_path>             → stdout（-r 原始字符串）
#    state_set  <jq_filter> [args...] → 更新 _STATE（in-place）
#    state_init                       → 从 STATE_FILE / config.json / v2 conf 文件引导
#    state_persist                    → 原子写入 STATE_FILE
# ==============================================================================
_STATE=""

# 默认状态模板（jq -n 生成，保证合法 JSON）
readonly _STATE_DEFAULT='{
  "uuid":    "",
  "argo":    {"enabled":true,  "protocol":"ws",   "port":8888,
              "mode":"temp",   "domain":null,      "token":null},
  "ff":      {"enabled":false, "protocol":"none", "path":"/"},
  "reality": {"enabled":false, "port":443, "sni":"www.microsoft.com",
              "pbk":null, "pvk":null, "sid":null},
  "cron":    0,
  "cfip":    "cf.tencentapp.cn",
  "cfport":  "443"
}'

# state_get <jq_path> → stdout（空/null 时输出空字符串）
state_get() {
    local _val
    _val=$(printf '%s' "${_STATE}" | jq -r "${1} // empty" 2>/dev/null) || true
    printf '%s' "${_val}"
}

# state_set <jq_filter> [--arg/--argjson ...] → 原地更新 _STATE
state_set() {
    local _filter="$1"; shift
    local _new
    _new=$(printf '%s' "${_STATE}" | jq "$@" "${_filter}" 2>/dev/null) \
        || { log_error "state_set 失败: ${_filter}"; return 1; }
    [ -n "${_new:-}" ] && _STATE="${_new}" || { log_error "state_set 返回空 JSON"; return 1; }
}

# state_persist → 原子写入 STATE_FILE（tmp → mv）
state_persist() {
    mkdir -p "${WORK_DIR}"
    local _tmp; _tmp=$(_tmp_file "state_XXXXXX.json") || return 1
    printf '%s\n' "${_STATE}" | jq . > "${_tmp}" \
        || { log_error "state 序列化失败"; return 1; }
    mv "${_tmp}" "${STATE_FILE}"
}

# state_init → 按优先级引导 _STATE
#   1. STATE_FILE（v3 原生，最权威）
#   2. 从 config.json + v2 散落 conf 文件迁移
#   3. 纯默认值（全新安装）
state_init() {
    # 尝试加载 STATE_FILE
    if [ -f "${STATE_FILE}" ]; then
        local _raw; _raw=$(cat "${STATE_FILE}" 2>/dev/null || true)
        if printf '%s' "${_raw}" | jq -e . >/dev/null 2>&1; then
            _STATE="${_raw}"
            _state_ensure_uuid
            return 0
        fi
        log_warn "state.json 损坏，尝试迁移..."
    fi

    # 初始化为默认值后迁移 v2 数据
    _STATE="${_STATE_DEFAULT}"
    _state_migrate_v2
    _state_ensure_uuid

    # 写入 STATE_FILE，后续以此为准
    if [ -d "${WORK_DIR}" ]; then
        state_persist 2>/dev/null || true
        log_info "状态已初始化并持久化"
    fi
}

# 确保 UUID 非空
_state_ensure_uuid() {
    local _u; _u=$(state_get '.uuid')
    if [ -z "${_u:-}" ]; then
        state_set '.uuid = $u' --arg u "$(_gen_uuid)"
    fi
}

# 从 v2 散落配置文件迁移到 _STATE（一次性，无副作用）
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

# ==============================================================================
# §6  工具函数（UUID · 内核版本 · 端口检测 · IP · Argo 域名）
# ==============================================================================
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

# 内核版本比较：_kernel_ge MAJOR MINOR（剥离 4.9-generic 等非数字后缀）
_kernel_ge() {
    local cur; cur=$(uname -r)
    local cm="${cur%%.*}"
    local cr="${cur#*.}"; cr="${cr%%.*}"; cr="${cr%%[^0-9]*}"
    [ "${cm}" -gt "$1" ] || { [ "${cm}" -eq "$1" ] && [ "${cr:-0}" -ge "$2" ]; }
}

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

# 指数退避轮询 Argo 日志：3s + 3→6→8→8→8→8，最多约 44s
get_temp_domain() {
    local _d _delay=3 _i=1
    sleep 3
    while [ "${_i}" -le 6 ]; do
        _d=$(grep -o 'https://[^[:space:]]*trycloudflare\.com' \
             "${ARGO_LOG}" 2>/dev/null | head -1 | sed 's|https://||') || true
        [ -n "${_d:-}" ] && printf '%s' "${_d}" && return 0
        sleep "${_delay}"; _i=$(( _i + 1 ))
        _delay=$(( _delay < 8 ? _delay * 2 : 8 ))
    done
    return 1
}

_urlencode_path() {
    printf '%s' "$1" | sed \
        's/%/%25/g;s/ /%20/g;s/!/%21/g;s/"/%22/g;s/#/%23/g;
         s/\$/%24/g;s/&/%26/g;s/'\''/%27/g;s/(/%28/g;s/)/%29/g;
         s/\*/%2A/g;s/+/%2B/g;s/,/%2C/g;s/:/%3A/g;s/;/%3B/g;
         s/=/%3D/g;s/?/%3F/g;s/@/%40/g;s/\[/%5B/g;s/\]/%5D/g'
}

# Reality x25519 密钥对（依赖已下载的 xray 二进制）
_gen_reality_keypair() {
    [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪，无法生成密钥对"; return 1; }
    local _out; _out=$("${XRAY_BIN}" x25519 2>/dev/null) \
        || { log_error "xray x25519 执行失败"; return 1; }
    local _pvk _pbk
    _pvk=$(printf '%s' "${_out}" | awk '/Private key:/{print $NF}')
    _pbk=$(printf '%s' "${_out}" | awk '/Public key:/{print $NF}')
    [ -n "${_pvk:-}" ] && [ -n "${_pbk:-}" ] || { log_error "密钥解析失败"; return 1; }
    state_set '.reality.pvk = $v | .reality.pbk = $b' --arg v "${_pvk}" --arg b "${_pbk}"
    log_ok "x25519 密钥对已生成"
}

# Reality shortId：优先 openssl，降级 /dev/urandom + od
_gen_reality_sid() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 8 2>/dev/null
    else
        od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

# ==============================================================================
# §7  声明式配置合成引擎
#
#  _gen_inbound_snippet <type> → stdout（jq 生成的 JSON 片段，所有值经 --arg 序列化）
#    type: argo | ff | reality
#
#  config_synthesize <outfile>  → 从 _STATE 合成完整 config.json 到 outfile
#
#  config_commit               → 原子化提交：
#    1. config_synthesize(tmp) 2. xray -test 3. mv → CONFIG_FILE 4. _svc_manager restart xray
# ==============================================================================
readonly _SNIFF_JSON='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}'

# ── Inbound 协议插件 ────────────────────────────────────────────────────────
# 命名约定：_gen_inbound_snippet <scope> → JSON object
# 新增协议：在此处增加 case 分支，config_synthesize 无需修改
_gen_inbound_snippet() {
    local _type="$1"
    local _uuid; _uuid=$(state_get '.uuid')

    case "${_type}" in
        # ──────────────────────────── Argo ──────────────────────────────────
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

        # ─────────────────────────── FreeFlow ───────────────────────────────
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

        # ─────────────────────────── Reality ────────────────────────────────
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

        *) log_error "_gen_inbound_snippet: 未知类型 '${_type}'"; return 1 ;;
    esac
}

# ── 从 _STATE 合成完整 config.json 到 <outfile> ──────────────────────────────
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

    # 两者均禁用时给出警告（不阻断，允许生成零入站配置）
    if [ "$(printf '%s' "${_ibs}" | jq 'length')" -eq 0 ]; then
        log_warn "所有入站均已禁用，xray 将以零入站模式运行（无可用节点）"
    fi

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

# ── 原子化提交：合成 → 预检 → mv → 重启 ──────────────────────────────────────
# 若任一步骤失败：临时文件由 _TMP_DIR EXIT trap 清理，原配置保持不变
config_commit() {
    local _tmp; _tmp=$(_tmp_file "xray_next_XXXXXX.json") || return 1

    log_step "合成配置..."
    config_synthesize "${_tmp}" || return 1

    # xray -test 预检（二进制就绪后强制执行）
    if [ -x "${XRAY_BIN}" ]; then
        log_step "验证配置 (xray -test)..."
        if ! "${XRAY_BIN}" -test -c "${_tmp}" >/dev/null 2>&1; then
            log_error "config 验证失败！现场已保留于 ${_tmp}（不会自动删除，可供排查）"
            # 保留临时文件：从 _TMP_DIR 移出，避免 EXIT trap 清理
            mv "${_tmp}" "${WORK_DIR}/config_failed.json" 2>/dev/null || true
            return 1
        fi
        log_ok "config 验证通过"
    else
        log_warn "xray 二进制未就绪，跳过预检（安装阶段正常）"
    fi

    # 原子覆盖：mv 在同一文件系统内是原子操作
    mkdir -p "${WORK_DIR}"
    mv "${_tmp}" "${CONFIG_FILE}" || { log_error "config 写入失败"; return 1; }
    log_ok "config.json 已原子更新"

    # 重启 xray（仅当服务已注册）
    if _svc_manager status xray >/dev/null 2>&1; then
        _svc_manager restart xray || { log_error "xray 重启失败"; return 1; }
        log_ok "xray 已重启"
    fi
}

# ==============================================================================
# §8  Argo 配置引擎
#     _gen_argo_config  — 从 _STATE 动态构建 tunnel.yml（ingress 规则遍历所有 argo 入站）
#     _build_tunnel_cmd — 从 _STATE 派生 cloudflared 启动命令（mode: temp | fixed）
# ==============================================================================
# _gen_argo_config <domain> <tunnel_id> <cred_file>
# 遍历 _STATE 中所有 argo 入站端口，动态生成 ingress 规则
# （当前单 Argo 入站；未来扩展多入站只需修改此函数）
_gen_argo_config() {
    local _domain="$1" _tid="$2" _cred_file="$3"

    # 从 _STATE 收集所有需要内网转发的端口（扩展点：未来可存 argo.ports 数组）
    local _port; _port=$(state_get '.argo.port')

    # 构建 ingress 块（每个入站生成一条规则）
    local _ingress
    _ingress=$(printf '  - hostname: %s\n    service: http://localhost:%s\n    originRequest:\n      noTLSVerify: true\n' \
        "${_domain}" "${_port}")

    printf 'tunnel: %s\ncredentials-file: %s\nprotocol: http2\n\ningress:\n%s  - service: http_status:404\n' \
        "${_tid}" "${_cred_file}" "${_ingress}" > "${WORK_DIR}/tunnel.yml" \
        || { log_error "tunnel.yml 写入失败"; return 1; }
    log_ok "tunnel.yml 已生成 (hostname=${_domain} → localhost:${_port})"
}

# 根据 _STATE.argo.mode 派生 cloudflared 启动命令（无需读取服务文件）
_build_tunnel_cmd() {
    local _mode; _mode=$(state_get '.argo.mode')
    local _port; _port=$(state_get '.argo.port')

    case "${_mode}" in
        fixed)
            if [ -f "${WORK_DIR}/tunnel.yml" ]; then
                printf '%s tunnel --edge-ip-version auto --config %s run' \
                    "${ARGO_BIN}" "${WORK_DIR}/tunnel.yml"
            else
                # token 模式（tunnel.yml 不存在时从 state 读取 token）
                local _tok; _tok=$(state_get '.argo.token')
                printf '%s tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token %s' \
                    "${ARGO_BIN}" "${_tok}"
            fi ;;
        *)  # temp
            printf '%s tunnel --url http://localhost:%s --no-autoupdate --edge-ip-version auto --protocol http2' \
                "${ARGO_BIN}" "${_port}" ;;
    esac
}

# ==============================================================================
# §9  统一服务管理接口
#     _svc_manager <action> <name>
#     业务代码中严禁出现 systemctl / rc-service 的直接调用
#
#     action: start | stop | restart | enable | disable | status
#     name:   xray  | tunnel
# ==============================================================================
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

# deferred daemon-reload：仅 systemd 且服务文件有变更时执行
_SYSD_DIRTY=0
_svc_daemon_reload() {
    is_systemd                  || return 0
    [ "${_SYSD_DIRTY}" -eq 1 ] || return 0
    systemctl daemon-reload >/dev/null 2>&1 || true
    _SYSD_DIRTY=0
}

# ── 服务文件幂等写入（内容无变化则跳过，避免不必要的 daemon-reload）
_svc_write_file() {
    local _dest="$1" _content="$2"
    local _cur; _cur=$(cat "${_dest}" 2>/dev/null || printf '')
    [ "${_cur}" = "${_content}" ] && return 0
    printf '%s' "${_content}" > "${_dest}"
    return 1    # 1 = 内容已变更，调用方决定是否 daemon-reload
}

# ── 服务单元模板（使用 printf 替代 heredoc，避免 IFS 意外截断）
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

# ── 注册 xray 服务（幂等）
_register_xray_service() {
    if is_systemd; then
        _svc_write_file "/etc/systemd/system/xray.service" "$(_svc_content_xray_systemd)" \
            || _SYSD_DIRTY=1
    else
        if _svc_write_file "/etc/init.d/xray" "$(_svc_content_xray_openrc)"; then :
        else chmod +x /etc/init.d/xray; fi
    fi
}

# ── 注册 tunnel 服务（幂等；命令来自 _build_tunnel_cmd）
_register_tunnel_service() {
    local _cmd; _cmd=$(_build_tunnel_cmd)
    if is_systemd; then
        _svc_write_file "/etc/systemd/system/tunnel.service" \
            "$(_svc_content_tunnel_systemd "${_cmd}")" || _SYSD_DIRTY=1
    else
        if _svc_write_file "/etc/init.d/tunnel" "$(_svc_content_tunnel_openrc "${_cmd}")"; then :
        else chmod +x /etc/init.d/tunnel; fi
    fi
}

# ==============================================================================
# §10 零持久化节点解析引擎
#     _get_share_links → 实时从 _STATE 生成所有 VLESS 链接，无文件 I/O
#     print_nodes      → 彩色打印，支持 column 格式化
# ==============================================================================
_get_share_links() {
    local _uuid _cfip _cfport
    _uuid=$(state_get '.uuid')
    _cfip=$(state_get '.cfip')
    _cfport=$(state_get '.cfport')

    # ── Argo 链接
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

    # ── FreeFlow 链接
    local _ff_proto; _ff_proto=$(state_get '.ff.protocol')
    if [ "$(state_get '.ff.enabled')" = "true" ] && [ "${_ff_proto}" != "none" ]; then
        local _ip; _ip=$(get_realip)
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

    # ── Reality 链接
    if [ "$(state_get '.reality.enabled')" = "true" ]; then
        local _r_port _r_sni _r_pbk _r_sid _ip2
        _r_port=$(state_get '.reality.port')
        _r_sni=$( state_get '.reality.sni')
        _r_pbk=$( state_get '.reality.pbk')
        _r_sid=$( state_get '.reality.sid')
        if [ -n "${_r_pbk:-}" ] && [ "${_r_pbk}" != "null" ]; then
            _ip2=$(get_realip)
            if [ -n "${_ip2:-}" ]; then
                printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#Reality-Vision\n' \
                    "${_uuid}" "${_ip2}" "${_r_port}" "${_r_sni}" "${_r_pbk}" "${_r_sid}"
            else
                log_warn "无法获取服务器 IP，Reality 节点已跳过"
            fi
        fi
    fi
}

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

# ==============================================================================
# §11 下载层（带 spinner / 完整性校验 / 幂等跳过）
# ==============================================================================
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

# ==============================================================================
# §12 环境自愈（BBR · systemd-resolved · 时间同步）
# ==============================================================================
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

check_systemd_resolved() {
    is_debian  || return 0
    is_systemd || return 0
    systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0
    local _stub; _stub=$(awk -F= '/^DNSStubListener/{gsub(/ /,"",$2); print $2}' \
                         /etc/systemd/resolved.conf 2>/dev/null || printf '')
    [ "${_stub:-yes}" != "no" ] && \
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
# §13 安装 / 卸载核心
# ==============================================================================
install_core() {
    clear; log_title "══════════ 安装 Xray-2go v3 ══════════"
    preflight_check
    mkdir -p "${WORK_DIR}" && chmod 750 "${WORK_DIR}"

    download_xray || return 1
    [ "$(state_get '.argo.enabled')" = "true" ] && { download_cloudflared || return 1; }

    # Reality 密钥对（依赖 xray 二进制，安装完成后立即生成）
    if [ "$(state_get '.reality.enabled')" = "true" ]; then
        log_step "生成 Reality x25519 密钥对..."
        _gen_reality_keypair || return 1
        state_set '.reality.sid = $s' --arg s "$(_gen_reality_sid)"
    fi

    # 原子化提交配置（synthesize → xray-test → mv）
    config_commit || return 1

    # 注册服务（幂等）
    _register_xray_service
    [ "$(state_get '.argo.enabled')" = "true" ] && _register_tunnel_service
    _svc_daemon_reload

    # Alpine / OpenRC 特殊初始化
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

    # 持久化 SSOT
    state_persist || log_warn "state.json 写入失败（不影响运行）"
    log_ok "══ 安装完成 ══"
}

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

# ==============================================================================
# §14 隧道操作层（固定隧道配置 / 临时隧道重置 / 临时域名刷新）
# ==============================================================================
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
        # JSON 凭证模式
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
        # token 字段清空（已用 tunnel.yml 模式）
        state_set '.argo.token = null | .argo.domain = $d | .argo.mode = "fixed"' \
            --arg d "${_domain}" || return 1

    elif printf '%s' "${_auth}" | grep -qE '^[A-Za-z0-9=_-]{120,250}$'; then
        # Token 模式（token 存入 _STATE，_build_tunnel_cmd 派生命令）
        state_set '.argo.token = $t | .argo.domain = $d | .argo.mode = "fixed"' \
            --arg t "${_auth}" --arg d "${_domain}" || return 1
        rm -f "${WORK_DIR}/tunnel.yml" "${WORK_DIR}/tunnel.json"
    else
        log_error "密钥格式无法识别（JSON 需含 TunnelSecret；Token 为 120-250 位字母数字串）"
        return 1
    fi

    # 更新服务文件（命令由 _build_tunnel_cmd 从 _STATE 派生）
    _register_tunnel_service
    _svc_daemon_reload
    _svc_manager enable tunnel 2>/dev/null || true

    config_commit || return 1
    state_persist || log_warn "state.json 写入失败"

    _svc_manager restart tunnel || { log_error "tunnel 重启失败"; return 1; }
    log_ok "固定隧道已配置 (${_argo_proto}, domain=${_domain})"
}

reset_temp_tunnel() {
    state_set '.argo.mode = "temp" | .argo.domain = null | .argo.token = null' || return 1
    # 清理固定隧道残留文件
    rm -f "${WORK_DIR}/tunnel.yml" "${WORK_DIR}/tunnel.json"
    # 更新服务文件（命令变为 --url 临时模式）
    _register_tunnel_service
    _svc_daemon_reload
    # Argo protocol 强制回 ws（临时隧道不支持 xhttp）
    state_set '.argo.protocol = "ws"' || return 1
    config_commit || return 1
    state_persist || log_warn "state.json 写入失败"
    log_ok "已切换至临时隧道"
}

refresh_temp_domain() {
    [ "$(state_get '.argo.enabled')" = "true" ]    || { log_warn "未启用 Argo"; return 1; }
    [ "$(state_get '.argo.protocol')" = "ws" ]      || { log_error "XHTTP 不支持临时隧道"; return 1; }
    [ "$(state_get '.argo.mode')" = "temp" ]        || { log_warn "当前为固定隧道，无需刷新临时域名"; return 1; }

    rm -f "${ARGO_LOG}"
    log_step "重启隧道并等待新域名（最多约 44s）..."
    _svc_manager restart tunnel || return 1

    local _d
    _d=$(get_temp_domain) || { log_warn "未能获取临时域名，请检查网络"; return 1; }
    log_ok "ArgoDomain: ${_d}"

    # 更新 _STATE 中的 domain 字段
    state_set '.argo.domain = $d' --arg d "${_d}" || return 1
    state_persist || log_warn "state.json 写入失败"
    print_nodes
}

# ==============================================================================
# §15 UUID / 端口管理（遵循 SSOT 修改工作流）
#     工作流：state_set → config_commit → state_persist → print_nodes
# ==============================================================================
manage_uuid() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先安装 Xray-2go"; return 1; }
    local _v; prompt "新 UUID（回车自动生成）: " _v
    if [ -z "${_v:-}" ]; then
        _v=$(_gen_uuid) || { log_error "UUID 生成失败"; return 1; }
        log_info "已生成 UUID: ${_v}"
    fi
    printf '%s' "${_v}" | grep -qiE \
        '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' \
        || { log_error "UUID 格式不合法"; return 1; }

    # 1. 修改 _STATE
    state_set '.uuid = $u' --arg u "${_v}" || return 1

    # 2. 原子提交（合成 → xray-test → mv → 重启）
    config_commit || return 1

    # 3. 持久化 SSOT
    state_persist || log_warn "state.json 写入失败"

    # 4. 实时输出节点（直接从 _STATE 生成，零文件 I/O）
    log_ok "UUID 已更新: ${_v}"
    print_nodes
}

manage_port() {
    local _p; prompt "新回源端口（回车随机）: " _p
    if [ -z "${_p:-}" ]; then
        _p=$(shuf -i 2000-65000 -n 1 2>/dev/null || \
             awk 'BEGIN{srand();print int(rand()*63000)+2000}')
    fi
    case "${_p:-}" in ''|*[!0-9]*) log_error "无效端口"; return 1 ;; esac
    { [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]; } \
        || { log_error "端口须在 1-65535 之间"; return 1; }

    if port_in_use "${_p}"; then
        log_warn "端口 ${_p} 已被占用"
        local _ans; prompt "仍然继续？(y/N): " _ans
        case "${_ans:-n}" in y|Y) : ;; *) return 1 ;; esac
    fi

    # 1. 修改 _STATE
    state_set '.argo.port = ($p|tonumber)' --arg p "${_p}" || return 1

    # 2. 原子提交（更新 config.json）
    config_commit || return 1

    # 3. 更新 tunnel 服务文件（端口变化，命令行参数需重新生成）
    _register_tunnel_service     # 命令由 _build_tunnel_cmd 从 _STATE 派生
    _svc_daemon_reload
    _svc_manager restart tunnel || log_warn "tunnel 重启失败，请手动重启"

    # 4. 持久化 SSOT
    state_persist || log_warn "state.json 写入失败"

    log_ok "回源端口已更新: ${_p}"
    print_nodes
}

# ==============================================================================
# §16 Cron 自动重启
# ==============================================================================
_cron_available() {
    command -v crontab >/dev/null 2>&1 || return 1
    if is_openrc; then
        rc-service dcron status >/dev/null 2>&1 || rc-service crond status >/dev/null 2>&1
    else
        systemctl is-active --quiet cron 2>/dev/null || \
        systemctl is-active --quiet crond 2>/dev/null
    fi
}

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

remove_auto_restart() {
    command -v crontab >/dev/null 2>&1 || return 0
    local _tmp; _tmp=$(_tmp_file "cron_XXXXXX") || return 0
    crontab -l 2>/dev/null | grep -v '#xray-restart' > "${_tmp}" || true
    crontab "${_tmp}" 2>/dev/null || true
}

# ==============================================================================
# §17 快捷方式 / 脚本更新
# ==============================================================================
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

is_fixed_tunnel() {
    [ "$(state_get '.argo.mode')" = "fixed" ]
}

# ==============================================================================
# §19 交互询问函数（纯输入收集，不含业务逻辑）
# ==============================================================================
ask_argo_mode() {
    echo ""; log_title "Argo 隧道选项"
    printf "  ${_C_GRN}1.${_C_RST} 安装 Argo (VLESS+WS/XHTTP+TLS) ${_C_YLW}[默认]${_C_RST}\n"
    printf "  ${_C_GRN}2.${_C_RST} 不安装 Argo（仅 FreeFlow 节点）\n"
    local _c; prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2) state_set '.argo.enabled = false'; log_info "已选：不安装 Argo" ;;
        *) state_set '.argo.enabled = true';  log_info "已选：安装 Argo" ;;
    esac; echo ""
}

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

# ==============================================================================
# §20 管理子菜单
# ==============================================================================
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
                if configure_fixed_tunnel; then
                    print_nodes
                else
                    log_error "固定隧道配置失败"
                fi ;;
            2)
                is_fixed_tunnel || { log_warn "当前为临时隧道，请先配置固定隧道"; _pause; continue; }
                local _new_proto
                if [ "${_proto}" = "ws" ]; then _new_proto="xhttp"; else _new_proto="ws"; fi
                state_set '.argo.protocol = $p' --arg p "${_new_proto}" || { _pause; continue; }
                if config_commit && state_persist; then
                    log_ok "协议已切换: ${_new_proto}"
                    print_nodes
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
            6)
                _svc_manager start tunnel \
                    && log_ok "隧道已启动" \
                    || log_error "隧道启动失败，请检查日志" ;;
            7)
                _svc_manager stop tunnel \
                    && log_ok "隧道已停止" \
                    || log_error "隧道停止失败" ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

manage_freeflow() {
    while true; do
        local _ff_proto _ff_path _ff_en
        _ff_en=$(state_get '.ff.enabled')
        _ff_proto=$(state_get '.ff.protocol')
        _ff_path=$(state_get '.ff.path')

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
                _svc_manager restart xray || log_warn "xray 重启失败"
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
                    _svc_manager restart xray || log_warn "xray 重启失败"
                    log_ok "path 已修改: ${_p}"; print_nodes
                fi ;;
            3)
                state_set '.ff.enabled = false | .ff.protocol = "none"' || { _pause; continue; }
                config_commit || { log_error "卸载失败"; _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                _svc_manager restart xray || log_warn "xray 重启失败"
                log_ok "FreeFlow 已卸载" ;;
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

# ==============================================================================
# §21 主菜单（while-true 闭环）
# ==============================================================================
menu() {
    while true; do
        local _xstat _astat _cx _ff_disp _argo_disp _xcolor
        _xstat=$(check_xray); _cx=$?
        _astat=$(check_argo)
        [ "${_cx}" -eq 0 ] && _xcolor="${_C_GRN}" || _xcolor="${_C_RED}"

        local _ff_proto _ff_path _ff_en
        _ff_en=$(state_get '.ff.enabled')
        _ff_proto=$(state_get '.ff.protocol')
        _ff_path=$(state_get '.ff.path')
        if [ "${_ff_en}" = "true" ] && [ "${_ff_proto}" != "none" ]; then
            _ff_disp="${_ff_proto} (path=${_ff_path})"
        else
            _ff_disp="未启用"
        fi

        local _domain; _domain=$(state_get '.argo.domain')
        if [ "$(state_get '.argo.enabled')" = "true" ]; then
            [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ] \
                && _argo_disp="${_astat} [$(state_get '.argo.protocol'), 固定: ${_domain}]" \
                || _argo_disp="${_astat} [WS, 临时隧道]"
        else
            _argo_disp="未启用"
        fi

        clear; echo ""
        printf "${_C_BOLD}${_C_PUR}  ╔═══════════════════════════════╗${_C_RST}\n"
        printf "${_C_BOLD}${_C_PUR}  ║   Xray-2go  v3.0  SSOT/AC     ║${_C_RST}\n"
        printf "${_C_BOLD}${_C_PUR}  ╠═══════════════════════════════╣${_C_RST}\n"
        printf "${_C_BOLD}${_C_PUR}  ║${_C_RST}  Xray : ${_xcolor}%-22s${_C_RST}${_C_PUR} ${_C_RST}\n"  "${_xstat}"
        printf "${_C_BOLD}${_C_PUR}  ║${_C_RST}  Argo : %-22s${_C_PUR} ${_C_RST}\n"  "${_argo_disp}"
        printf "${_C_BOLD}${_C_PUR}  ║${_C_RST}  FF   : %-22s${_C_PUR} ${_C_RST}\n"  "${_ff_disp}"
        printf "${_C_BOLD}${_C_PUR}  ║${_C_RST}  Cron : ${_C_CYN}%-2s min${_C_RST}                  ${_C_PUR} ${_C_RST}\n" "$(state_get '.cron')"
        printf "${_C_BOLD}${_C_PUR}  ╚═══════════════════════════════╝${_C_RST}\n\n"

        printf "  ${_C_GRN}1.${_C_RST} 安装 Xray-2go\n"
        printf "  ${_C_RED}2.${_C_RST} 卸载 Xray-2go\n"; _hr
        printf "  ${_C_GRN}3.${_C_RST} Argo 管理\n"
        printf "  ${_C_GRN}4.${_C_RST} FreeFlow 管理\n"; _hr
        printf "  ${_C_GRN}5.${_C_RST} 查看节点\n"
        printf "  ${_C_GRN}6.${_C_RST} 修改 UUID\n"
        printf "  ${_C_GRN}7.${_C_RST} 自动重启管理\n"
        printf "  ${_C_GRN}8.${_C_RST} 快捷方式/脚本更新\n"; _hr
        printf "  ${_C_RED}0.${_C_RST} 退出\n\n"
        local _c; prompt "请输入选择 (0-8): " _c; echo ""

        case "${_c:-}" in
            1)
                if [ "${_cx}" -eq 0 ]; then
                    log_warn "Xray-2go 已安装，如需重装请先卸载 (选项 2)"
                else
                    ask_argo_mode
                    [ "$(state_get '.argo.enabled')" = "true" ] && ask_argo_protocol
                    ask_freeflow_mode

                    [ "$(state_get '.argo.enabled')" = "true" ] && \
                        port_in_use "$(state_get '.argo.port')" && \
                        log_warn "端口 $(state_get '.argo.port') 已被占用，可安装后修改"
                    [ "$(state_get '.ff.enabled')" = "true" ] && port_in_use 8080 && \
                        log_warn "端口 8080 已被占用，FreeFlow 可能无法启动"

                    check_systemd_resolved
                    check_bbr

                    install_core || { log_error "安装失败"; _pause; continue; }

                    # 节点获取流程
                    if [ "$(state_get '.argo.protocol')" = "xhttp" ]; then
                        log_warn "XHTTP 仅支持固定隧道，现在进入配置..."
                        configure_fixed_tunnel || log_error "固定隧道配置失败，请从 [3. Argo 管理] 重新配置"

                    elif [ "$(state_get '.argo.enabled')" = "true" ]; then
                        echo ""
                        printf "  ${_C_GRN}1.${_C_RST} 临时隧道 (WS, 自动生成域名) ${_C_YLW}[默认]${_C_RST}\n"
                        printf "  ${_C_GRN}2.${_C_RST} 固定隧道 (自有 token/json)\n"
                        local _tc; prompt "请选择隧道类型 (回车默认1): " _tc
                        case "${_tc:-1}" in
                            2)
                                if configure_fixed_tunnel; then : ; else
                                    log_warn "固定隧道配置失败，回退临时隧道"
                                    _svc_manager restart tunnel || true
                                    local _td; _td=$(get_temp_domain) || _td=""
                                    [ -n "${_td:-}" ] && {
                                        state_set '.argo.domain = $d' --arg d "${_td}" || true
                                        state_persist || true
                                        log_ok "ArgoDomain: ${_td}"
                                    } || log_warn "未能获取临时域名，可从 [3→4] 刷新"
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
            4) manage_freeflow ;;
            5) [ "${_cx}" -eq 0 ] && print_nodes || log_warn "Xray-2go 未安装或未运行" ;;
            6) [ -f "${CONFIG_FILE}" ] \
                && manage_uuid \
                || { log_warn "请先安装 Xray-2go"; } ;;
            7) manage_restart ;;
            8) install_shortcut ;;
            0) log_info "已退出"; exit 0 ;;
            *) log_error "无效选项，请输入 0-8" ;;
        esac
        _pause
    done
}

# ==============================================================================
# §22 入口点 main()
# ==============================================================================
main() {
    check_root          # §4:  权限检查
    _detect_init        # §3:  检测 init 系统
    preflight_check     # §4:  依赖预检（确保 jq 可用，state_init 依赖它）
    state_init          # §5:  引导 SSOT _STATE
    menu                # §21: 主菜单
}

main "$@"
