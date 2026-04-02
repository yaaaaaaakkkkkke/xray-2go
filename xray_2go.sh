#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  xray-next  ·  现代节点部署引擎
#  协议矩阵  ┌ VLESS + Reality + xHTTP  (直连·抗检测)
#            ├ VLESS + Argo   + WS      (CDN穿透)
#            └ FreeFlow       + HTTPUpgrade (定向免流)
#  平台要求  Debian 12 · systemd
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

# ──────────────────────────────────────────────────────────────────────
# §0  中断 / 退出清理
# ──────────────────────────────────────────────────────────────────────
_SPINNER_PID=0
trap '_on_exit'  EXIT
trap '_on_int'   INT TERM

_on_exit() {
    [ "${_SPINNER_PID}" -ne 0 ] && kill "${_SPINNER_PID}" 2>/dev/null || true
    tput cnorm 2>/dev/null || true
}
_on_int() {
    [ "${_SPINNER_PID}" -ne 0 ] && kill "${_SPINNER_PID}" 2>/dev/null || true
    printf '\n'; _e "已中断"; exit 130
}

# ──────────────────────────────────────────────────────────────────────
# §1  路径常量（FHS 规范，唯一声明点）
# ──────────────────────────────────────────────────────────────────────
readonly D="/etc/xray"                          # 工作目录
readonly XRAY_BIN="${D}/xray"                   # xray 二进制
readonly ARGO_BIN="${D}/argo"                   # cloudflared 二进制
readonly CONFIG_FILE="${D}/config.json"         # xray 配置
readonly URL_FILE="${D}/url.txt"                # 节点链接
readonly SUB_FILE="${D}/sub.txt"                # base64 订阅
readonly ARGO_LOG="${D}/argo.log"               # argo 日志
readonly RT_FILE="${D}/runtime.env"             # 运行时状态持久化
readonly DOMAIN_FIXED_FILE="${D}/domain_fixed.txt"
readonly TUNNEL_YML="${D}/tunnel.yml"
readonly TUNNEL_JSON="${D}/tunnel.json"
readonly SHORTCUT="/usr/local/bin/x"            # 快捷入口

readonly UPSTREAM="https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_next.sh"
readonly XRAY_DL_BASE="https://github.com/XTLS/Xray-core/releases/latest/download"
readonly CF_DL_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"

# ──────────────────────────────────────────────────────────────────────
# §2  运行时全局状态（所有可变量集中声明）
# ──────────────────────────────────────────────────────────────────────
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
REALITY_PORT="0"        # 0 = 未初始化，首次安装随机分配
REALITY_SNI="www.nazhumi.com"
ARGO_ENABLED="yes"
ARGO_PORT="8080"
FF_ENABLED="no"
FF_HOST="h.ime.qq.com"  # HTTPUpgrade Host 伪装域（运营商免流特征域）
FF_PATH="/"
_ARCH_XRAY=""
_ARCH_CF=""

# ──────────────────────────────────────────────────────────────────────
# §3  UI 层 ── 现代柔和调色板 + 信息等级原语
# ──────────────────────────────────────────────────────────────────────
# 调色板：青色主色 · 柔绿成功 · 琥珀警告 · 玫红错误 · 灰色辅助
readonly _R=$'\033[0m'        # reset
readonly _C=$'\033[38;5;73m'  # 主色  ──  steel-blue cyan（柔和不刺眼）
readonly _G=$'\033[38;5;114m' # 成功  ──  soft sage green
readonly _Y=$'\033[38;5;179m' # 警告  ──  warm amber
readonly _E=$'\033[38;5;203m' # 错误  ──  muted rose-red
readonly _M=$'\033[38;5;141m' # 节点  ──  soft lavender
readonly _S=$'\033[38;5;242m' # 辅助  ──  mid grey
readonly _B=$'\033[1m'        # bold

_i()  { printf "${_C}  •  ${_R}%s\n"   "$*"; }          # INFO
_ok() { printf "${_G}  ✓  ${_R}%s\n"   "$*"; }          # OK
_w()  { printf "${_Y}  ⚠  ${_R}%s\n"   "$*" >&2; }      # WARN
_e()  { printf "${_E}  ✗  ${_R}%s\n"   "$*" >&2; }      # ERROR
_h()  { printf "\n${_B}${_C}  %s${_R}\n\n" "$*"; }      # 标题
_die(){ _e "$1"; exit "${2:-1}"; }

# 分割线
_hr()  { printf "${_S}  %s${_R}\n" "────────────────────────────────────────"; }
_hr2() { printf "${_S}  %s${_R}\n" "════════════════════════════════════════"; }

# 交互提示（stderr + /dev/tty，兼容管道环境）
prompt() {
    local _var="$2"
    printf "${_C}  ›  ${_R}%s" "$1" >&2
    read -r "${_var}" </dev/tty
}

# 旋转进度（后台子 shell，spinner_stop 后清行）
spinner_start() {
    printf "${_C}  ○  ${_R}%s\n" "$1"
    ( local i=0 c='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
      while true; do
          printf "\r${_C}  %s  ${_R}%s    " \
              "${c:$(( i % 10 )):1}" "$1" >&2
          sleep 0.1; i=$(( i + 1 ))
      done ) &
    _SPINNER_PID=$!
    disown "${_SPINNER_PID}" 2>/dev/null || true
}
spinner_stop() {
    [ "${_SPINNER_PID}" -ne 0 ] && kill "${_SPINNER_PID}" 2>/dev/null
    _SPINNER_PID=0
    printf '\r\033[2K' >&2
}

_pause() {
    local _d
    printf "\n${_S}  按回车继续…${_R}" >&2
    read -r _d </dev/tty || true
}

# ──────────────────────────────────────────────────────────────────────
# §4  平台层（Debian 12 / systemd 专属）
# ──────────────────────────────────────────────────────────────────────
check_root()   { [ "${EUID:-$(id -u)}" -eq 0 ] || _die "请以 root 身份运行"; }
check_systemd() {
    command -v systemctl >/dev/null 2>&1 \
        || _die "未检测到 systemd，本脚本仅支持 Debian 12"
}

detect_arch() {
    [ -n "${_ARCH_XRAY}" ] && return 0
    case "$(uname -m)" in
        x86_64)        _ARCH_XRAY="64";         _ARCH_CF="amd64"  ;;
        aarch64|arm64) _ARCH_XRAY="arm64-v8a";  _ARCH_CF="arm64"  ;;
        armv7l)        _ARCH_XRAY="arm32-v7a";  _ARCH_CF="armv7"  ;;
        s390x)         _ARCH_XRAY="s390x";      _ARCH_CF="s390x"  ;;
        *)             _die "不支持的架构: $(uname -m)" ;;
    esac
}

pkg_need() {
    local pkg="$1" bin="${2:-$1}"
    command -v "${bin}" >/dev/null 2>&1 && return 0
    _i "安装依赖: ${pkg}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}" >/dev/null 2>&1 \
        || _die "${pkg} 安装失败"
    command -v "${bin}" >/dev/null 2>&1 || _die "${pkg} 安装后仍未找到"
}
check_deps() {
    _i "检查运行时依赖…"
    for _p in curl unzip jq; do pkg_need "${_p}"; done
    _ok "依赖就绪"
}

# ──────────────────────────────────────────────────────────────────────
# §5  状态 I/O 层（单一 runtime.env，source 加载，printf 持久化）
# ──────────────────────────────────────────────────────────────────────
load_runtime() {
    # 先设默认值，再 source 文件覆盖
    UUID=""; PRIVATE_KEY=""; PUBLIC_KEY=""
    REALITY_PORT="0"; REALITY_SNI="www.nazhumi.com"
    ARGO_ENABLED="yes"; ARGO_PORT="8080"
    FF_ENABLED="no"; FF_HOST="h.ime.qq.com"; FF_PATH="/"

    # shellcheck source=/dev/null
    [ -f "${RT_FILE}" ] && . "${RT_FILE}" 2>/dev/null || true

    # UUID 兜底（首次运行）
    [ -z "${UUID}" ] && UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || _gen_uuid)

    # 端口兜底
    [ "${REALITY_PORT}" -eq 0 ] 2>/dev/null && \
        REALITY_PORT=$(shuf -i 10000-60000 -n 1 2>/dev/null \
            || awk 'BEGIN{srand();print int(rand()*50000)+10000}')
}

save_runtime() {
    mkdir -p "${D}"
    # 使用 %s 逐字段写入，避免特殊字符污染 source 环境
    printf 'UUID=%s\nPRIVATE_KEY=%s\nPUBLIC_KEY=%s\n'  \
        "${UUID}" "${PRIVATE_KEY}" "${PUBLIC_KEY}"       > "${RT_FILE}"
    printf 'REALITY_PORT=%s\nREALITY_SNI=%s\n'          \
        "${REALITY_PORT}" "${REALITY_SNI}"               >> "${RT_FILE}"
    printf 'ARGO_ENABLED=%s\nARGO_PORT=%s\n'             \
        "${ARGO_ENABLED}" "${ARGO_PORT}"                 >> "${RT_FILE}"
    printf 'FF_ENABLED=%s\nFF_HOST=%s\nFF_PATH=%s\n'     \
        "${FF_ENABLED}" "${FF_HOST}" "${FF_PATH}"        >> "${RT_FILE}"
}

# 原子 jq 编辑（mktemp → jq → mv）
jq_edit() {
    local f="$1" flt="$2"; shift 2
    local tmp; tmp=$(mktemp "${f}.XXXXXX") || { _e "无法创建临时文件"; return 1; }
    jq "$@" "${flt}" "${f}" > "${tmp}" 2>/dev/null && [ -s "${tmp}" ] \
        && mv "${tmp}" "${f}" \
        || { rm -f "${tmp}"; _e "jq 操作失败: ${flt}"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────
# §6  工具函数（网络 · UUID · 端口）
# ──────────────────────────────────────────────────────────────────────
_gen_uuid() {
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
    awk 'BEGIN{srand()} {h=$0; printf "%s-%s-4%s-%s%s-%s\n",
        substr(h,1,8),substr(h,9,4),substr(h,14,3),
        substr("89ab",int(rand()*4)+1,1),substr(h,18,3),substr(h,21,12)}'
}

get_realip() {
    local ip org ipv6
    ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null) || true
    if [ -z "${ip:-}" ]; then
        ipv6=$(curl -sf --max-time 5 https://api6.ipify.org 2>/dev/null) || true
        [ -n "${ipv6:-}" ] && printf '[%s]' "${ipv6}" || printf ''
        return
    fi
    org=$(curl -sf --max-time 5 "https://ipinfo.io/${ip}/org" 2>/dev/null) || true
    if printf '%s' "${org:-}" | grep -qiE 'Cloudflare|UnReal|AEZA|Andrei'; then
        ipv6=$(curl -sf --max-time 5 https://api6.ipify.org 2>/dev/null) || true
        [ -n "${ipv6:-}" ] && printf '[%s]' "${ipv6}" || printf '%s' "${ip}"
    else
        printf '%s' "${ip}"
    fi
}

port_used() {
    local p="$1"
    command -v ss >/dev/null 2>&1 && {
        ss -tlnH 2>/dev/null | awk -v p=":${p}" '$4~p"$"||$4~p" "{f=1}END{exit !f}'
        return
    }
    local h; h=$(printf '%04X' "${p}")
    awk -v h="${h}" 'NR>1&&substr($2,index($2,":")+1,4)==h{f=1}END{exit !f}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# 从 argo.log 轮询临时域名（指数退避，最长约 44 s）
get_temp_domain() {
    local d delay=3 i=1
    sleep 3
    while [ "${i}" -le 6 ]; do
        d=$(grep -o 'https://[^[:space:]]*trycloudflare\.com' \
            "${ARGO_LOG}" 2>/dev/null | head -1 | sed 's|https://||') || true
        [ -n "${d:-}" ] && printf '%s' "${d}" && return 0
        sleep "${delay}"; i=$(( i+1 ))
        delay=$(( delay < 8 ? delay*2 : 8 ))
    done
    return 1
}

# ──────────────────────────────────────────────────────────────────────
# §7  密钥管理
# ──────────────────────────────────────────────────────────────────────
gen_reality_keys() {
    [ -x "${XRAY_BIN}" ] || { _e "xray 二进制不存在，无法生成密钥"; return 1; }
    local out; out=$("${XRAY_BIN}" x25519 2>/dev/null) \
        || { _e "x25519 密钥生成失败"; return 1; }
    PRIVATE_KEY=$(printf '%s' "${out}" | awk '/Private key:/{print $3}')
    PUBLIC_KEY=$(printf '%s' "${out}"  | awk '/Public key:/{print $3}')
    [ -n "${PRIVATE_KEY}" ] && [ -n "${PUBLIC_KEY}" ] \
        || { _e "密钥解析失败，请检查 xray 版本"; return 1; }
    _ok "Reality 密钥对已生成"
}

# ──────────────────────────────────────────────────────────────────────
# §8  JSON 构建层（协议插件）
# ──────────────────────────────────────────────────────────────────────
#
# 命名约定：_ib_<协议>()  → stdout 输出合法 JSON inbound 对象
#
# ─── 公共 sniffing 片段 ─────────────────────────────────────────────
_sniff='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}'

# ─── 8-A  VLESS + Reality + xHTTP ────────────────────────────────────
#   特性：TLS 指纹混淆至目标 SNI、xHTTP auto 模式流量无特征
_ib_reality_xhttp() {
    jq -n \
        --argjson port    "${REALITY_PORT}" \
        --arg     uuid    "${UUID}"         \
        --arg     sni     "${REALITY_SNI}"  \
        --arg     priv    "${PRIVATE_KEY}"  \
        --argjson sniff   "${_sniff}"       \
    '{
        port: $port, listen: "::", protocol: "vless",
        settings: {
            clients: [{id: $uuid}],
            decryption: "none"
        },
        streamSettings: {
            network: "xhttp",
            security: "reality",
            realitySettings: {
                dest:        ($sni + ":443"),
                serverNames: [$sni],
                privateKey:  $priv,
                shortIds:    [""]
            },
            xhttpSettings: {
                path: "/xhttp",
                mode: "auto"
            }
        },
        sniffing: $sniff
    }'
}

# ─── 8-B  VLESS + Argo + WS（监听 127.0.0.1，由 cloudflared 反代）──
_ib_argo_ws() {
    jq -n \
        --argjson port  "${ARGO_PORT}" \
        --arg     uuid  "${UUID}"      \
        --argjson sniff "${_sniff}"    \
    '{
        port: $port, listen: "127.0.0.1", protocol: "vless",
        settings: {
            clients: [{id: $uuid}],
            decryption: "none"
        },
        streamSettings: {
            network: "ws",
            security: "none",
            wsSettings: {path: "/vless-argo"}
        },
        sniffing: $sniff
    }'
}

# ─── 8-C  FreeFlow + HTTPUpgrade ────────────────────────────────────
#   免流原理：HTTPUpgrade 握手时将 Host 头设为运营商白名单域名，
#   DPI 识别为合法流量 → 不计费/不限速。
#   path 可任意设置以匹配运营商规则，host 须为运营商已免流域名。
_ib_freeflow_httpupgrade() {
    jq -n \
        --arg  uuid   "${UUID}"    \
        --arg  host   "${FF_HOST}" \
        --arg  path   "${FF_PATH}" \
        --argjson sniff "${_sniff}" \
    '{
        port: 80, listen: "::", protocol: "vless",
        settings: {
            clients: [{id: $uuid}],
            decryption: "none"
        },
        streamSettings: {
            network: "httpupgrade",
            security: "none",
            httpupgradeSettings: {
                path: $path,
                host: $host
            }
        },
        sniffing: $sniff
    }'
}

# ─── 组装完整 config.json ────────────────────────────────────────────
build_xray_config() {
    mkdir -p "${D}"
    local inbounds="[]" ib

    # Reality xHTTP（核心，始终存在）
    ib=$(_ib_reality_xhttp) || return 1
    inbounds=$(printf '%s' "${inbounds}" | jq --argjson x "${ib}" '. + [$x]')

    # Argo WS
    if [ "${ARGO_ENABLED}" = "yes" ]; then
        ib=$(_ib_argo_ws) || return 1
        inbounds=$(printf '%s' "${inbounds}" | jq --argjson x "${ib}" '. + [$x]')
    fi

    # FreeFlow HTTPUpgrade
    if [ "${FF_ENABLED}" = "yes" ]; then
        ib=$(_ib_freeflow_httpupgrade) || return 1
        inbounds=$(printf '%s' "${inbounds}" | jq --argjson x "${ib}" '. + [$x]')
    fi

    jq -n --argjson inbounds "${inbounds}" '{
        log: {access: "/dev/null", error: "/dev/null", loglevel: "none"},
        inbounds: $inbounds,
        dns: {servers: ["https+local://1.1.1.1/dns-query"]},
        outbounds: [
            {protocol: "freedom",   tag: "direct"},
            {protocol: "blackhole", tag: "block"}
        ]
    }' > "${CONFIG_FILE}" || { _e "生成 config.json 失败"; return 1; }

    "${XRAY_BIN}" -test -c "${CONFIG_FILE}" >/dev/null 2>&1 \
        || { _e "config.json 验证失败，请检查协议参数"; return 1; }
    _ok "config.json 已写入并验证"
}

# ──────────────────────────────────────────────────────────────────────
# §9  链接构建层
# ──────────────────────────────────────────────────────────────────────
_urlencode() { printf '%s' "$1" | \
    sed 's/%/%25/g;s/ /%20/g;s/#/%23/g;s/\?/%3F/g;s/=/%3D/g;s/&/%26/g;s|/|%2F|g'; }

# 9-A  Reality xHTTP 直连链接
_link_reality_xhttp() {
    local ip="$1" isp="${2:-xray-next}"
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&type=xhttp&path=%%2Fxhttp&mode=auto#%s-Reality\n' \
        "${UUID}" "${ip}" "${REALITY_PORT}" "${REALITY_SNI}" "${PUBLIC_KEY}" "${isp}"
}

# 9-B  Argo WS 链接（走 Cloudflare CDN）
_link_argo_ws() {
    local domain="$1" isp="${2:-xray-next}"
    local cfip="${CFIP:-cdns.doon.eu.org}" cfport="${CFPORT:-443}"
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%%2Fvless-argo%%3Fed%%3D2560#%s-Argo\n' \
        "${UUID}" "${cfip}" "${cfport}" "${domain}" "${domain}" "${isp}"
}

# 9-C  FreeFlow HTTPUpgrade 链接
_link_freeflow() {
    local ip="$1" isp="${2:-xray-next}"
    local pe; pe=$(_urlencode "${FF_PATH}")
    printf 'vless://%s@%s:80?encryption=none&security=none&type=httpupgrade&host=%s&path=%s#%s-FreeFlow\n' \
        "${UUID}" "${ip}" "${FF_HOST}" "${pe}" "${isp}"
}

# 获取 ISP 标签（用于节点备注）
_get_isp() {
    local raw
    raw=$(curl -sf --max-time 4 \
        -H 'User-Agent: Mozilla/5.0' \
        "https://api.ip.sb/geoip" 2>/dev/null) || true
    if [ -n "${raw:-}" ]; then
        printf '%s' "${raw}" | jq -r '"\(.country_code)-\(.isp)"' 2>/dev/null \
            | sed 's/ /_/g' || printf 'vps'
    else
        printf 'vps'
    fi
}

# 构建全部节点链接并写入 url.txt + sub.txt
build_all_links() {
    local argo_domain="${1:-}"
    local ip isp
    ip=$(get_realip)
    isp=$(_get_isp)

    {
        # Reality xHTTP（依赖服务器公网 IP）
        [ -n "${ip:-}" ] && _link_reality_xhttp "${ip}" "${isp}"

        # Argo WS（依赖 Argo 域名）
        [ "${ARGO_ENABLED}" = "yes" ] && [ -n "${argo_domain:-}" ] && \
            _link_argo_ws "${argo_domain}" "${isp}"

        # FreeFlow HTTPUpgrade
        [ "${FF_ENABLED}" = "yes" ] && [ -n "${ip:-}" ] && \
            _link_freeflow "${ip}" "${isp}"
    } > "${URL_FILE}"

    base64 -w0 "${URL_FILE}" > "${SUB_FILE}" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────
# §10  服务管理层（systemd 专属，幂等写入）
# ──────────────────────────────────────────────────────────────────────
_SYSTEMD_DIRTY=0

# 内容不变则跳过写文件（幂等），有变化则置 dirty flag
_write_unit() {
    local dest="$1" content="$2"
    local cur; cur=$(cat "${dest}" 2>/dev/null || printf '')
    [ "${cur}" = "${content}" ] && return 0
    printf '%s' "${content}" > "${dest}"
    _SYSTEMD_DIRTY=1
}

_daemon_reload() {
    [ "${_SYSTEMD_DIRTY}" -eq 1 ] || return 0
    systemctl daemon-reload 2>/dev/null || true
    _SYSTEMD_DIRTY=0
}

_tpl_xray() {
    cat <<EOF
[Unit]
Description=Xray Service (xray-next)
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

_tpl_tunnel() {
    local cmd="$1"
    cat <<EOF
[Unit]
Description=Cloudflare Tunnel (xray-next)
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/sh -c '${cmd} >> ${ARGO_LOG} 2>&1'
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}

_tunnel_cmd_temp() {
    printf '%s tunnel --url http://localhost:%s --no-autoupdate --edge-ip-version auto --protocol http2' \
        "${ARGO_BIN}" "${ARGO_PORT}"
}

register_xray_unit()   { _write_unit "/etc/systemd/system/xray.service"   "$(_tpl_xray)"; }
register_tunnel_unit() { _write_unit "/etc/systemd/system/tunnel.service" "$(_tpl_tunnel "${1:-$(_tunnel_cmd_temp)}")"; }

svc() {
    local act="$1" name="$2"
    systemctl "${act}" "${name}" 2>/dev/null; return $?
}

restart_xray() {
    _daemon_reload
    svc restart xray && _ok "xray 已重启" || { _e "xray 重启失败"; return 1; }
}
restart_argo() {
    rm -f "${ARGO_LOG}"
    _daemon_reload
    svc restart tunnel && _ok "Argo 隧道已重启" || { _e "Argo 重启失败"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────
# §11  下载层（带进度 · 完整性校验 · 幂等跳过）
# ──────────────────────────────────────────────────────────────────────
_dl() {
    local url="$1" dest="$2" label="$3"
    spinner_start "${label}"
    curl -sfL --connect-timeout 15 --max-time 120 -o "${dest}" "${url}"
    local rc=$?; spinner_stop
    [ "${rc}" -eq 0 ] && [ -s "${dest}" ] || { rm -f "${dest}"; _e "${label} 下载失败"; return 1; }
}

download_xray() {
    detect_arch
    if [ -f "${XRAY_BIN}" ]; then _i "xray 已存在，跳过下载"; return 0; fi
    local zip="${D}/xray.zip"
    _dl "${XRAY_DL_BASE}/Xray-linux-${_ARCH_XRAY}.zip" "${zip}" "下载 Xray (${_ARCH_XRAY})" || return 1
    unzip -t "${zip}" >/dev/null 2>&1 || { rm -f "${zip}"; _e "zip 文件损坏"; return 1; }
    unzip -o "${zip}" xray -d "${D}/" >/dev/null 2>&1 || { rm -f "${zip}"; _e "解压失败"; return 1; }
    rm -f "${zip}"
    [ -f "${XRAY_BIN}" ] || { _e "未找到 xray 二进制"; return 1; }
    chmod +x "${XRAY_BIN}"
    _ok "Xray $(${XRAY_BIN} version 2>/dev/null | head -1 | awk '{print $2}') 已就绪"
}

download_argo() {
    detect_arch
    if [ -f "${ARGO_BIN}" ]; then _i "cloudflared 已存在，跳过下载"; return 0; fi
    _dl "${CF_DL_BASE}/cloudflared-linux-${_ARCH_CF}" "${ARGO_BIN}" "下载 cloudflared (${_ARCH_CF})" || return 1
    chmod +x "${ARGO_BIN}"
    _ok "cloudflared 已就绪"
}

# ──────────────────────────────────────────────────────────────────────
# §12  安装 / 卸载核心
# ──────────────────────────────────────────────────────────────────────
install_core() {
    clear
    _h "安装 xray-next"
    check_deps
    mkdir -p "${D}" && chmod 750 "${D}"

    download_xray                                || return 1
    [ "${ARGO_ENABLED}" = "yes" ] && { download_argo || return 1; }

    # 生成 Reality 密钥（安装时必须，密钥对持久化到 runtime.env）
    gen_reality_keys                             || return 1

    build_xray_config                            || return 1
    save_runtime

    # 服务注册（幂等）
    register_xray_unit
    [ "${ARGO_ENABLED}" = "yes" ] && register_tunnel_unit
    _daemon_reload

    svc enable xray; svc start xray \
        || { _e "xray 启动失败"; return 1; }
    _ok "xray 已启动"

    if [ "${ARGO_ENABLED}" = "yes" ]; then
        svc enable tunnel; svc start tunnel \
            || { _e "tunnel 启动失败"; return 1; }
        _ok "Argo 隧道已启动"
    fi

    # 快捷指令
    printf '#!/usr/bin/env bash\nbash %s "$@"\n' "$0" > "${SHORTCUT}"
    chmod +x "${SHORTCUT}"

    _ok "安装完成"
}

uninstall_all() {
    prompt "确定卸载 xray-next？[y/N]: " _c
    case "${_c:-n}" in y|Y) : ;; *) _i "已取消"; return ;; esac
    _i "卸载中…"
    for _s in xray tunnel; do
        svc stop    "${_s}" 2>/dev/null || true
        svc disable "${_s}" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/xray.service \
          /etc/systemd/system/tunnel.service
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "${D}"
    rm -f  "${SHORTCUT}"
    _ok "xray-next 已卸载"
}

# ──────────────────────────────────────────────────────────────────────
# §13  隧道操作层
# ──────────────────────────────────────────────────────────────────────
# 13-A  判断当前是否为固定隧道（--url 是临时隧道的特征命令）
is_fixed_tunnel() {
    local f="/etc/systemd/system/tunnel.service"
    [ -f "${f}" ] || return 1
    ! grep -Fq -- "--url http://localhost:${ARGO_PORT}" "${f}" 2>/dev/null
}

# 13-B  配置固定隧道
configure_fixed_tunnel() {
    _i "固定隧道  ·  协议: WS  ·  回源端口: ${ARGO_PORT}"
    echo ""
    prompt "Argo 域名: " domain
    case "${domain:-}" in ''|*' '*|*'/'*) _e "域名格式不合法"; return 1 ;; esac
    printf '%s' "${domain}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
        || { _e "域名包含非法字符"; return 1; }

    prompt "Argo 密钥 (Token 或 JSON): " auth
    [ -z "${auth:-}" ] && { _e "密钥不能为空"; return 1; }

    local cmd
    if printf '%s' "${auth}" | grep -q "TunnelSecret"; then
        printf '%s' "${auth}" | jq . >/dev/null 2>&1 \
            || { _e "JSON 格式不合法"; return 1; }
        local tid; tid=$(printf '%s' "${auth}" | jq -r '
            if (.TunnelID?  // "") != "" then .TunnelID
            elif (.AccountTag? // "") != "" then .AccountTag
            else empty end' 2>/dev/null)
        [ -z "${tid:-}" ] && { _e "无法从 JSON 提取 TunnelID"; return 1; }
        case "${tid}" in *$'\n'*|*'"'*|*':'*) _e "TunnelID 含非法字符"; return 1 ;; esac

        printf '%s' "${auth}" > "${TUNNEL_JSON}"
        cat > "${TUNNEL_YML}" <<EOF
tunnel: ${tid}
credentials-file: ${TUNNEL_JSON}
protocol: http2

ingress:
  - hostname: ${domain}
    service: http://localhost:${ARGO_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
        cmd="${ARGO_BIN} tunnel --edge-ip-version auto --config ${TUNNEL_YML} run"

    elif printf '%s' "${auth}" | grep -qE '^[A-Za-z0-9=_-]{120,250}$'; then
        cmd="${ARGO_BIN} tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${auth}"
    else
        _e "密钥格式无法识别（JSON 须含 TunnelSecret；Token 为 120-250 位字母数字串）"
        return 1
    fi

    register_tunnel_unit "${cmd}"
    _daemon_reload
    svc enable tunnel 2>/dev/null || true
    printf '%s\n' "${domain}" > "${DOMAIN_FIXED_FILE}"

    restart_xray || return 1
    restart_argo  || return 1
    _ok "固定隧道已配置 · 域名: ${domain}"
    printf '%s' "${domain}"   # 返回域名供调用方使用
}

# 13-C  切换回临时隧道
reset_temp_tunnel() {
    register_tunnel_unit "$(_tunnel_cmd_temp)"
    _daemon_reload
    rm -f "${DOMAIN_FIXED_FILE}" "${TUNNEL_YML}" "${TUNNEL_JSON}"
    _ok "已切换回临时隧道配置"
}

# 13-D  刷新临时域名并更新 url.txt
refresh_temp_domain() {
    _i "重启隧道，等待新临时域名（最长约 44s）…"
    restart_argo || return 1
    local d; d=$(get_temp_domain) || { _w "未能获取临时域名，请稍后手动刷新"; return 1; }
    _ok "ArgoDomain: ${d}"

    # 原子更新 url.txt 中 Argo-WS 行的 sni/host 字段
    awk -v D="${d}" '
        /-Argo$/ {
            sub(/sni=[^&]*/, "sni="D)
            sub(/host=[^&]*/, "host="D)
        }
        { print }
    ' "${URL_FILE}" > "${URL_FILE}.tmp" \
        && mv "${URL_FILE}.tmp" "${URL_FILE}" \
        || rm -f "${URL_FILE}.tmp"

    base64 -w0 "${URL_FILE}" > "${SUB_FILE}" 2>/dev/null || true
    _ok "节点链接已更新"
}

# ──────────────────────────────────────────────────────────────────────
# §14  节点信息展示（UI 焦点面板）
# ──────────────────────────────────────────────────────────────────────
print_node_panel() {
    [ -s "${URL_FILE}" ] || { _w "节点文件为空，请先完成安装或刷新"; return 1; }

    echo ""
    _hr2
    printf "${_B}${_C}  %-6s  节点链接${_R}\n" "›"
    _hr2
    echo ""

    local line label
    while IFS= read -r line; do
        [ -z "${line:-}" ] && continue
        # 提取 # 后的标签作为前缀
        label="${line##*#}"
        printf "${_S}  ┌ ${_C}%s${_R}\n" "${label}"
        printf "${_M}  │ %s${_R}\n" "${line}"
        printf "${_S}  └────${_R}\n\n"
    done < "${URL_FILE}"

    _hr2
    printf "${_S}  快捷启动  ${_B}${_G}x${_R}   "
    printf "${_S}  订阅文件  ${_B}${_G}%s${_R}\n" "${SUB_FILE}"
    _hr2
    echo ""
}

# ──────────────────────────────────────────────────────────────────────
# §15  状态检测层
# ──────────────────────────────────────────────────────────────────────
# 返回 0=running 1=stopped 2=not-installed 3=disabled
xray_status()   {
    [ -f "${XRAY_BIN}" ] || { printf 'not installed'; return 2; }
    [ "$(systemctl is-active xray   2>/dev/null)" = "active" ] \
        && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
}
argo_status()   {
    [ "${ARGO_ENABLED}" = "no"  ] && { printf 'disabled';      return 3; }
    [ -f "${ARGO_BIN}"          ] || { printf 'not installed'; return 2; }
    [ "$(systemctl is-active tunnel 2>/dev/null)" = "active" ] \
        && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
}
xray_installed() { [ -f "${XRAY_BIN}" ] && [ -f "${CONFIG_FILE}" ]; }

# ──────────────────────────────────────────────────────────────────────
# §16  状态面板渲染
# ──────────────────────────────────────────────────────────────────────
_dot_color() {
    # $1 = 状态字符串
    case "${1:-}" in
        running)       printf "${_G}●${_R}" ;;
        stopped)       printf "${_Y}○${_R}" ;;
        disabled)      printf "${_S}○${_R}" ;;
        'not installed') printf "${_E}✗${_R}" ;;
        *)             printf "${_S}?${_R}"  ;;
    esac
}

render_status_panel() {
    local xs as fx fd
    xs=$(xray_status)
    as=$(argo_status)

    # FreeFlow 状态描述
    [ "${FF_ENABLED}" = "yes" ] \
        && fx="${_G}●${_R} httpupgrade  host=${FF_HOST}" \
        || fx="${_S}○${_R} 未启用"

    # Argo 类型描述
    fd=$(cat "${DOMAIN_FIXED_FILE}" 2>/dev/null || true)
    local argo_type
    is_fixed_tunnel 2>/dev/null && [ -n "${fd:-}" ] \
        && argo_type="固定  ${fd}" \
        || argo_type="临时  *.trycloudflare.com"

    echo ""
    printf "${_S}  ╭──────────────────────────────────────────╮${_R}\n"
    printf "${_S}  │${_R}  ${_B}${_C}xray-next${_R}                                 ${_S}│${_R}\n"
    printf "${_S}  ├──────────────────────────────────────────┤${_R}\n"
    printf "${_S}  │${_R}  Xray        $(_dot_color "${xs}")  %-28s${_S}│${_R}\n"  "${xs}"
    printf "${_S}  │${_R}  Argo        $(_dot_color "${as}")  %-28s${_S}│${_R}\n"  "${as}  (${argo_type})"
    printf "${_S}  │${_R}  FreeFlow    ${fx}${_S}%s│${_R}\n" "$(printf '%*s' $(( 10 - ${#FF_HOST} )) '')"
    printf "${_S}  │${_R}  Reality SNI  ${_C}%-30s${_S}│${_R}\n" "${REALITY_SNI}"
    printf "${_S}  ╰──────────────────────────────────────────╯${_R}\n"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────
# §17  交互询问函数（纯输入收集）
# ──────────────────────────────────────────────────────────────────────
ask_argo_mode() {
    echo ""
    printf "  ${_C}1${_R}  安装 Argo 隧道  ${_S}(Cloudflare CDN 穿透)${_R}  ${_Y}[默认]${_R}\n"
    printf "  ${_C}2${_R}  不安装 Argo\n"
    prompt "选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in 2) ARGO_ENABLED="no" ;; *) ARGO_ENABLED="yes" ;; esac
}

ask_freeflow() {
    echo ""
    printf "  ${_C}1${_R}  启用 FreeFlow  ${_S}(HTTPUpgrade 定向免流)${_R}\n"
    printf "  ${_C}2${_R}  不启用  ${_Y}[默认]${_R}\n"
    prompt "选择 (1-2，回车默认2): " _c
    case "${_c:-2}" in
        1)
            FF_ENABLED="yes"
            echo ""
            printf "${_S}  常见运营商免流域名示例：h.ime.qq.com · msn.com · wifi.weixin.qq.com${_R}\n"
            prompt "免流 Host 域名 (回车默认 ${FF_HOST}): " _h
            [ -n "${_h:-}" ] && FF_HOST="${_h}"
            prompt "Path (回车默认 /): " _p
            case "${_p:-/}" in /*) FF_PATH="${_p:-/}" ;; *) FF_PATH="/${_p}" ;; esac
            port_used 80 && _w "端口 80 已被占用，FreeFlow 可能无法启动"
            ;;
        *) FF_ENABLED="no" ;;
    esac
}

ask_reality_sni() {
    echo ""
    printf "  Reality 伪装 SNI（须为支持 TLSv1.3 的目标站点）\n\n"
    printf "  ${_C}1${_R}  www.nazhumi.com   ${_S}[默认]${_R}\n"
    printf "  ${_C}2${_R}  www.iij.ad.jp\n"
    printf "  ${_C}3${_R}  bgk.jp\n"
    printf "  ${_C}4${_R}  addons.mozilla.org\n"
    printf "  ${_C}5${_R}  自定义\n"
    prompt "选择 (1-5，回车默认1): " _c
    case "${_c:-1}" in
        2) REALITY_SNI="www.iij.ad.jp"      ;;
        3) REALITY_SNI="bgk.jp"             ;;
        4) REALITY_SNI="addons.mozilla.org" ;;
        5) prompt "输入自定义域名: " _s
           [ -n "${_s:-}" ] && REALITY_SNI="${_s}" ;;
        *) REALITY_SNI="www.nazhumi.com"    ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# §18  子菜单
# ──────────────────────────────────────────────────────────────────────

# ── Argo 管理 ──────────────────────────────────────────────────────────
menu_argo() {
    [ "${ARGO_ENABLED}" = "yes" ] || { _w "Argo 未启用"; _pause; return; }
    [ -f "${ARGO_BIN}"          ] || { _w "Argo 未安装"; _pause; return; }

    while true; do
        clear
        local as fd type_disp
        as=$(argo_status)
        fd=$(cat "${DOMAIN_FIXED_FILE}" 2>/dev/null || true)
        is_fixed_tunnel && [ -n "${fd:-}" ] \
            && type_disp="固定 · ${fd}" || type_disp="临时"

        _h "Argo 隧道管理"
        printf "  状态: $(_dot_color "${as}") ${as}   类型: ${_C}%s${_R}   端口: ${_C}%s${_R}\n\n" \
            "${type_disp}" "${ARGO_PORT}"
        _hr
        printf "  ${_C}1${_R}  添加 / 更新固定隧道\n"
        printf "  ${_C}2${_R}  切换回临时隧道\n"
        printf "  ${_C}3${_R}  刷新临时域名\n"
        printf "  ${_C}4${_R}  修改回源端口  ${_S}(当前: ${ARGO_PORT})${_R}\n"
        printf "  ${_C}5${_R}  启动隧道\n"
        printf "  ${_C}6${_R}  停止隧道\n"
        _hr
        printf "  ${_S}0${_R}  返回\n\n"
        prompt "选择: " _c

        case "${_c:-}" in
            1)
                local _d; _d=$(configure_fixed_tunnel)
                if [ $? -eq 0 ] && [ -n "${_d:-}" ]; then
                    build_all_links "${_d}"; print_node_panel
                fi
                ;;
            2)
                is_fixed_tunnel || { _w "当前已是临时隧道"; _pause; continue; }
                reset_temp_tunnel && restart_xray && restart_argo
                local _nd; _nd=$(get_temp_domain) || _nd=""
                [ -n "${_nd}" ] && _ok "ArgoDomain: ${_nd}"
                build_all_links "${_nd}"; print_node_panel
                ;;
            3) refresh_temp_domain; print_node_panel ;;
            4)
                prompt "新回源端口 (回车随机): " _p
                [ -z "${_p:-}" ] && _p=$(shuf -i 2000-65000 -n 1 2>/dev/null \
                    || awk 'BEGIN{srand();print int(rand()*63000)+2000}')
                case "${_p:-}" in ''|*[!0-9]*) _e "无效端口"; _pause; continue ;; esac
                [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ] \
                    || { _e "端口须在 1-65535"; _pause; continue; }
                port_used "${_p}" && {
                    _w "端口 ${_p} 已被占用"
                    prompt "仍然继续？[y/N]: " _ans
                    case "${_ans:-n}" in y|Y) : ;; *) _pause; continue ;; esac
                }
                jq_edit "${CONFIG_FILE}" \
                    '(.inbounds[]? | select(.port == $old) | .port) |= $new' \
                    --argjson old "${ARGO_PORT}" --argjson new "${_p}" \
                    || { _pause; continue; }
                sed -i "s|localhost:${ARGO_PORT}|localhost:${_p}|g" \
                    /etc/systemd/system/tunnel.service 2>/dev/null
                ARGO_PORT="${_p}"; save_runtime
                _SYSTEMD_DIRTY=1
                restart_xray && restart_argo
                _ok "回源端口已改为 ${_p}"
                ;;
            5) svc start  tunnel && _ok "隧道已启动" || _e "启动失败" ;;
            6) svc stop   tunnel && _ok "隧道已停止" || _e "停止失败" ;;
            0) return ;;
            *) _e "无效选项" ;;
        esac
        _pause
    done
}

# ── FreeFlow 管理 ──────────────────────────────────────────────────────
menu_freeflow() {
    while true; do
        clear
        _h "FreeFlow 免流管理"
        if [ "${FF_ENABLED}" = "yes" ]; then
            printf "  状态: ${_G}● 已启用${_R}   Host: ${_C}%s${_R}   Path: ${_C}%s${_R}\n\n" \
                "${FF_HOST}" "${FF_PATH}"
        else
            printf "  状态: ${_S}○ 未启用${_R}\n\n"
        fi
        _hr
        printf "  ${_C}1${_R}  启用 / 变更免流参数\n"
        printf "  ${_C}2${_R}  修改免流 Host\n"
        printf "  ${_C}3${_R}  修改免流 Path\n"
        printf "  ${_E}4${_R}  禁用 FreeFlow\n"
        _hr
        printf "  ${_S}0${_R}  返回\n\n"
        prompt "选择: " _c

        case "${_c:-}" in
            1)
                ask_freeflow
                save_runtime
                jq_edit "${CONFIG_FILE}" 'del(.inbounds[]? | select(.port == 80))' || \
                    { _pause; continue; }
                if [ "${FF_ENABLED}" = "yes" ]; then
                    local ib; ib=$(_ib_freeflow_httpupgrade) || { _pause; continue; }
                    jq_edit "${CONFIG_FILE}" '.inbounds += [$x]' --argjson x "${ib}" || \
                        { _pause; continue; }
                fi
                restart_xray
                local _ip; _ip=$(get_realip)
                [ -n "${_ip:-}" ] && {
                    awk -v ip="${_ip}" -v h="${FF_HOST}" -v p="${FF_PATH}" \
                        '/-FreeFlow$/{
                            sub(/vless:\/\/[^@]*@[^:]*:[0-9]*/, "vless://"uuid"@"ip":80")
                            sub(/host=[^&]*/, "host="h)
                            sub(/path=[^#]*/, "path="p)
                        }{print}' "${URL_FILE}" > "${URL_FILE}.tmp" \
                        && mv "${URL_FILE}.tmp" "${URL_FILE}" \
                        || rm -f "${URL_FILE}.tmp"
                }
                print_node_panel
                ;;
            2)
                [ "${FF_ENABLED}" = "yes" ] || { _w "FreeFlow 未启用"; _pause; continue; }
                prompt "新 Host 域名 (当前: ${FF_HOST}): " _h
                [ -n "${_h:-}" ] && {
                    FF_HOST="${_h}"; save_runtime
                    jq_edit "${CONFIG_FILE}" \
                        '(.inbounds[]? | select(.port==80) | .streamSettings.httpupgradeSettings.host) |= $h' \
                        --arg h "${FF_HOST}" || { _pause; continue; }
                    restart_xray; _ok "Host 已更新为 ${FF_HOST}"
                }
                ;;
            3)
                [ "${FF_ENABLED}" = "yes" ] || { _w "FreeFlow 未启用"; _pause; continue; }
                prompt "新 Path (当前: ${FF_PATH}): " _p
                [ -n "${_p:-}" ] && {
                    case "${_p}" in /*) FF_PATH="${_p}" ;; *) FF_PATH="/${_p}" ;; esac
                    save_runtime
                    jq_edit "${CONFIG_FILE}" \
                        '(.inbounds[]? | select(.port==80) | .streamSettings.httpupgradeSettings.path) |= $p' \
                        --arg p "${FF_PATH}" || { _pause; continue; }
                    restart_xray; _ok "Path 已更新为 ${FF_PATH}"
                }
                ;;
            4)
                FF_ENABLED="no"; save_runtime
                jq_edit "${CONFIG_FILE}" 'del(.inbounds[]? | select(.port == 80))' \
                    && restart_xray && _ok "FreeFlow 已禁用"
                ;;
            0) return ;;
            *) _e "无效选项" ;;
        esac
        _pause
    done
}

# ── 配置管理 ───────────────────────────────────────────────────────────
menu_config() {
    while true; do
        clear
        _h "配置管理"
        printf "  UUID       ${_S}%s${_R}\n"   "${UUID}"
        printf "  Reality SNI ${_C}%s${_R}\n"  "${REALITY_SNI}"
        printf "  Reality 端口 ${_C}%s${_R}\n" "${REALITY_PORT}"
        printf "  公钥       ${_S}%.44s…${_R}\n" "${PUBLIC_KEY:-未生成}"
        echo ""
        _hr
        printf "  ${_C}1${_R}  修改 UUID\n"
        printf "  ${_C}2${_R}  修改 Reality SNI\n"
        printf "  ${_C}3${_R}  修改 Reality 端口\n"
        printf "  ${_C}4${_R}  重新生成 Reality 密钥对\n"
        _hr
        printf "  ${_S}0${_R}  返回\n\n"
        prompt "选择: " _c

        case "${_c:-}" in
            1)
                prompt "新 UUID (回车自动生成): " _v
                [ -z "${_v:-}" ] && { _v=$(_gen_uuid); _i "已生成: ${_v}"; }
                printf '%s' "${_v}" | grep -qiE \
                    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
                    || { _e "UUID 格式不合法"; _pause; continue; }
                UUID="${_v}"; save_runtime
                # 同步 config.json（所有 inbound）
                jq_edit "${CONFIG_FILE}" \
                    '(.inbounds[].settings.clients[0].id) = $u' --arg u "${UUID}" \
                    || { _pause; continue; }
                # 同步 url.txt
                [ -s "${URL_FILE}" ] && awk -v u="${UUID}" \
                    '{gsub(/vless:\/\/[^@]*@/, "vless://"u"@"); print}' \
                    "${URL_FILE}" > "${URL_FILE}.tmp" \
                    && mv "${URL_FILE}.tmp" "${URL_FILE}" || rm -f "${URL_FILE}.tmp"
                base64 -w0 "${URL_FILE}" > "${SUB_FILE}" 2>/dev/null || true
                restart_xray && _ok "UUID 已更新: ${UUID}"
                print_node_panel
                ;;
            2)
                ask_reality_sni; save_runtime
                jq_edit "${CONFIG_FILE}" '
                    (.inbounds[]? | select(.streamSettings.security=="reality")
                    | .streamSettings.realitySettings)
                    |= (.dest = ($s+":443") | .serverNames = [$s])
                ' --arg s "${REALITY_SNI}" || { _pause; continue; }
                # 同步 url.txt
                [ -s "${URL_FILE}" ] && sed -i \
                    "s/sni=[^&]*/sni=${REALITY_SNI}/g; s/authority=[^&]*/authority=${REALITY_SNI}/g" \
                    "${URL_FILE}"
                base64 -w0 "${URL_FILE}" > "${SUB_FILE}" 2>/dev/null || true
                restart_xray && _ok "SNI 已更新: ${REALITY_SNI}"
                ;;
            3)
                prompt "新 Reality 端口 (回车随机): " _p
                [ -z "${_p:-}" ] && _p=$(shuf -i 10000-60000 -n 1 2>/dev/null \
                    || awk 'BEGIN{srand();print int(rand()*50000)+10000}')
                case "${_p:-}" in ''|*[!0-9]*) _e "无效端口"; _pause; continue ;; esac
                [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ] \
                    || { _e "端口须在 1-65535"; _pause; continue; }
                port_used "${_p}" && _w "端口 ${_p} 已被占用，请注意"
                jq_edit "${CONFIG_FILE}" \
                    '(.inbounds[]? | select(.streamSettings.network == "xhttp") | .port) |= $n' \
                    --argjson n "${_p}" || { _pause; continue; }
                local old="${REALITY_PORT}"; REALITY_PORT="${_p}"; save_runtime
                [ -s "${URL_FILE}" ] && sed -i \
                    "s|@\([^:]*\):${old}?|@\1:${_p}?|g" "${URL_FILE}"
                base64 -w0 "${URL_FILE}" > "${SUB_FILE}" 2>/dev/null || true
                restart_xray && _ok "Reality 端口已改为 ${_p}"
                ;;
            4)
                gen_reality_keys || { _pause; continue; }
                save_runtime
                jq_edit "${CONFIG_FILE}" '
                    (.inbounds[]? | select(.streamSettings.security=="reality")
                    | .streamSettings.realitySettings.privateKey) = $pk
                ' --arg pk "${PRIVATE_KEY}" || { _pause; continue; }
                # url.txt 中公钥同步
                [ -s "${URL_FILE}" ] && sed -i \
                    "s/pbk=[^&]*/pbk=${PUBLIC_KEY}/g" "${URL_FILE}"
                base64 -w0 "${URL_FILE}" > "${SUB_FILE}" 2>/dev/null || true
                restart_xray
                _ok "密钥对已重新生成"
                printf "  ${_S}公钥: ${_C}%s${_R}\n" "${PUBLIC_KEY}"
                ;;
            0) return ;;
            *) _e "无效选项" ;;
        esac
        _pause
    done
}

# ──────────────────────────────────────────────────────────────────────
# §19  主菜单（完全状态感应）
# ──────────────────────────────────────────────────────────────────────
menu() {
    while true; do
        clear

        if ! xray_installed; then
            # ── 未安装状态：极简入口 ──────────────────────────────
            echo ""
            printf "${_S}  ╭──────────────────────────╮${_R}\n"
            printf "${_S}  │${_R}  ${_B}${_C}xray-next${_R}  ${_E}未安装${_R}        ${_S}│${_R}\n"
            printf "${_S}  ╰──────────────────────────╯${_R}\n\n"
            _hr
            printf "  ${_C}1${_R}  安装 xray-next\n"
            _hr
            printf "  ${_S}0${_R}  退出\n\n"
            prompt "选择: " _c

            case "${_c:-}" in
                1)
                    # 安装向导
                    clear; _h "安装向导"
                    ask_argo_mode
                    ask_reality_sni
                    ask_freeflow
                    echo ""

                    # 端口前置告警（不阻断）
                    port_used "${REALITY_PORT}" && \
                        _w "端口 ${REALITY_PORT} 已被占用，安装后可在配置管理中修改"
                    [ "${FF_ENABLED}" = "yes" ] && port_used 80 && \
                        _w "端口 80 已被占用，FreeFlow 可能无法启动"

                    install_core || { _e "安装失败，请查看以上错误信息"; _pause; continue; }
                    save_runtime

                    # 节点获取流程
                    if [ "${ARGO_ENABLED}" = "yes" ]; then
                        echo ""
                        printf "  ${_C}1${_R}  临时隧道  ${_S}(自动生成域名)${_R}  ${_Y}[默认]${_R}\n"
                        printf "  ${_C}2${_R}  固定隧道  ${_S}(使用自有 Token/JSON)${_R}\n"
                        prompt "隧道类型 (1-2，回车默认1): " _tc
                        case "${_tc:-1}" in
                            2)
                                local _fd; _fd=$(configure_fixed_tunnel) || _fd=""
                                if [ -n "${_fd:-}" ]; then
                                    build_all_links "${_fd}"
                                else
                                    _w "固定隧道配置失败，尝试临时隧道"
                                    local _td; _td=$(get_temp_domain 2>/dev/null) || _td=""
                                    build_all_links "${_td}"
                                fi
                                ;;
                            *)
                                _i "等待临时域名（最长约 44s）…"
                                local _td; _td=$(get_temp_domain 2>/dev/null) || _td=""
                                [ -n "${_td}" ] && _ok "ArgoDomain: ${_td}" \
                                    || _w "未能获取临时域名，可后续从 Argo 管理中刷新"
                                build_all_links "${_td}"
                                ;;
                        esac
                    else
                        build_all_links ""
                    fi

                    print_node_panel
                    ;;
                0) exit 0 ;;
                *) _e "无效选项" ;;
            esac

        else
            # ── 已安装状态：完整管理面板 ─────────────────────────
            render_status_panel
            _hr
            printf "  ${_C}1${_R}  查看节点 / 订阅\n"
            printf "  ${_C}2${_R}  Argo 隧道管理\n"
            printf "  ${_C}3${_R}  FreeFlow 管理\n"
            printf "  ${_C}4${_R}  配置管理  ${_S}(UUID · SNI · 端口 · 密钥)${_R}\n"
            printf "  ${_C}5${_R}  重启所有服务\n"
            printf "  ${_C}6${_R}  脚本更新\n"
            _hr
            printf "  ${_E}9${_R}  卸载\n"
            printf "  ${_S}0${_R}  退出\n\n"
            prompt "选择 (0-9): " _c

            case "${_c:-}" in
                1) print_node_panel ;;
                2) menu_argo ;;
                3) menu_freeflow ;;
                4) menu_config ;;
                5)
                    restart_xray
                    [ "${ARGO_ENABLED}" = "yes" ] && restart_argo
                    ;;
                6)
                    _i "拉取最新脚本…"
                    local _tmp="${SHORTCUT}.tmp"
                    curl -sfL --connect-timeout 15 --max-time 60 \
                        -o "${_tmp}" "${UPSTREAM}" \
                        || { rm -f "${_tmp}"; _e "拉取失败"; _pause; continue; }
                    bash -n "${_tmp}" 2>/dev/null \
                        || { rm -f "${_tmp}"; _e "脚本语法校验失败"; _pause; continue; }
                    [ -f "$0" ] && cp -f "$0" "$0.bak" 2>/dev/null || true
                    mv "${_tmp}" "$0" && chmod +x "$0"
                    _ok "脚本已更新，请重新运行"
                    exit 0
                    ;;
                9) uninstall_all ;;
                0) exit 0 ;;
                *) _e "无效选项，请输入 0-9" ;;
            esac
        fi

        _pause
    done
}

# ──────────────────────────────────────────────────────────────────────
# §20  入口点
# ──────────────────────────────────────────────────────────────────────
main() {
    check_root
    check_systemd
    load_runtime
    menu
}

main "$@"
