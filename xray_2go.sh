#!/usr/bin/env bash
# ==============================================================================
# xray-2go  r3  —  Clean-Slate Rewrite
# Architecture : Core Engine  +  Protocol Plugin Registry
# Platform     : Debian 12 / Ubuntu (primary) · CentOS/RHEL · Alpine (OpenRC)
# ==============================================================================
set -uo pipefail

# ── §0  SIGNAL / CLEANUP ──────────────────────────────────────────────────────
_SPINNER_PID=0
_TXN_SNAPSHOT=""

trap '_on_exit'   EXIT
trap '_on_int'    INT TERM

_on_exit() {
    [[ $_SPINNER_PID -ne 0 ]] && kill "$_SPINNER_PID" 2>/dev/null || true
    tput cnorm 2>/dev/null || true
}
_on_int() {
    [[ $_SPINNER_PID -ne 0 ]] && kill "$_SPINNER_PID" 2>/dev/null || true
    printf '\n'; err "已中断"; exit 130
}

# ── §1  CONSTANTS ─────────────────────────────────────────────────────────────
readonly DIR="/etc/xray"
readonly XRAY_BIN="$DIR/xray"
readonly ARGO_BIN="$DIR/argo"
readonly CONFIG_FILE="$DIR/config.json"
readonly CLIENT_FILE="$DIR/url.txt"
readonly ARGO_LOG="$DIR/argo.log"
readonly STATE_FILE="$DIR/state.json"     # 单一状态文件，替代原 5 个 .conf
readonly SHORTCUT="/usr/local/bin/s"
readonly SELF_DEST="/usr/local/bin/xray2go"
readonly UPSTREAM="https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh"

# ── §2  RUNTIME STATE  (所有可变全局变量集中声明) ─────────────────────────────
ARGO_MODE="yes"     # yes | no
ARGO_PROTO="ws"     # ws  | xhttp
ARGO_PORT=8080
FF_MODE="none"      # ws | httpupgrade | xhttp | none
FF_PATH="/"
FIXED_DOMAIN=""
RESTART_INTERVAL=0
UUID=""

_INIT_SYS=""        # systemd | openrc
_ARCH_CF=""         # amd64 | arm64 | …
_ARCH_XRAY=""       # 64 | arm64-v8a | …
_UNIT_DIRTY=0       # deferred daemon-reload 标志

# ── §3  UI ENGINE ─────────────────────────────────────────────────────────────
readonly R=$'\033[0m'   B=$'\033[1m'
readonly RED=$'\033[1;91m'  GRN=$'\033[1;32m'  YLW=$'\033[1;33m'
readonly PUR=$'\033[1;35m'  CYN=$'\033[1;36m'

info()  { printf "${CYN}[INFO]${R} %s\n" "$*"; }
ok()    { printf "${GRN}[ OK ]${R} %s\n" "$*"; }
warn()  { printf "${YLW}[WARN]${R} %s\n" "$*" >&2; }
err()   { printf "${RED}[ERR ]${R} %s\n" "$*" >&2; }
step()  { printf "${PUR}[....] %s${R}\n" "$*"; }
title() { printf "\n${B}${PUR}%s${R}\n"  "$*"; }
die()   { err "$1"; exit "${2:-1}"; }
hr()    { printf "${PUR}  %-36s${R}\n" "──────────────────────────────────────"; }

# prompt 走 stderr；read 强制走 /dev/tty（兼容管道重定向场景）
prompt() {
    printf "${RED}%s${R}" "$1" >&2
    read -r "$2" </dev/tty
}

spin_start() {
    printf "${CYN}[....] %s${R}\n" "$1"
    ( local i=0 s='-\|/'
      while true; do
          printf "\r${CYN}[  %s ]${R} %s   " "${s:$((i%4)):1}" "$1" >&2
          sleep 0.1; (( i++ )) || true
      done ) &
    _SPINNER_PID=$!
    disown "$_SPINNER_PID" 2>/dev/null || true
}
spin_stop() {
    [[ $_SPINNER_PID -ne 0 ]] && { kill "$_SPINNER_PID" 2>/dev/null; _SPINNER_PID=0; }
    printf '\r\033[2K' >&2
}

pause() {
    local _; printf "${RED}按回车键继续...${R}" >&2; read -r _ </dev/tty || true
}

# ── §4  PLATFORM LAYER ────────────────────────────────────────────────────────
_detect_init() {
    if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
        _INIT_SYS="systemd"
    elif command -v rc-update >/dev/null 2>&1; then
        _INIT_SYS="openrc"
    else
        die "不支持的 init 系统（需要 systemd 或 OpenRC）"
    fi
}

is_systemd() { [[ $_INIT_SYS == systemd ]]; }
is_openrc()  { [[ $_INIT_SYS == openrc  ]]; }
is_alpine()  { [[ -f /etc/alpine-release ]]; }
is_debian()  { [[ -f /etc/debian_version ]]; }

_detect_arch() {
    [[ -n "$_ARCH_XRAY" ]] && return 0
    case "$(uname -m)" in
        x86_64)        _ARCH_CF="amd64";  _ARCH_XRAY="64"        ;;
        x86|i686|i386) _ARCH_CF="386";    _ARCH_XRAY="32"        ;;
        aarch64|arm64) _ARCH_CF="arm64";  _ARCH_XRAY="arm64-v8a" ;;
        armv7l)        _ARCH_CF="armv7";  _ARCH_XRAY="arm32-v7a" ;;
        s390x)         _ARCH_CF="s390x";  _ARCH_XRAY="s390x"     ;;
        *) die "不支持的架构: $(uname -m)";;
    esac
}

# ── §5  STATE ENGINE ──────────────────────────────────────────────────────────
# 核心改进：用单一 state.json 替代原来 5 个零散 .conf 文件
# 原因：原方案无原子性，多文件部分写入会产生不一致的中间态。
# 新方案：tmp → jq → mv 全程原子，load_state 单次解析，save_state 幂等可重入。

_state_to_json() {
    jq -n \
        --arg   am "$ARGO_MODE"          \
        --arg   ap "$ARGO_PROTO"         \
        --argjson p  "$ARGO_PORT"        \
        --arg   fm "$FF_MODE"            \
        --arg   fp "$FF_PATH"            \
        --arg   fd "$FIXED_DOMAIN"       \
        --argjson ri "$RESTART_INTERVAL" \
        '{argo_mode:$am, argo_proto:$ap, argo_port:$p,
          ff_mode:$fm,   ff_path:$fp,   fixed_domain:$fd,
          restart_interval:$ri}'
}

load_state() {
    # UUID 优先从 config.json 读取（最权威来源），否则生成
    UUID=$(jq -r 'first(.inbounds[]? | select(.protocol=="vless")
                  | .settings.clients[0].id) // empty' \
           "$CONFIG_FILE" 2>/dev/null || true)
    [[ -z "$UUID" ]] && UUID=$(_gen_uuid)
    [[ -f "$STATE_FILE" ]] || return 0

    local s; s=$(cat "$STATE_FILE" 2>/dev/null) || return 0
    local v

    v=$(jq -r '.argo_mode   // empty' <<< "$s" 2>/dev/null || true)
    [[ "$v" =~ ^(yes|no)$                        ]] && ARGO_MODE="$v"

    v=$(jq -r '.argo_proto  // empty' <<< "$s" 2>/dev/null || true)
    [[ "$v" =~ ^(ws|xhttp)$                      ]] && ARGO_PROTO="$v"

    v=$(jq -r '.argo_port   // empty' <<< "$s" 2>/dev/null || true)
    [[ "$v" =~ ^[0-9]+$                          ]] && ARGO_PORT="$v"

    v=$(jq -r '.ff_mode     // empty' <<< "$s" 2>/dev/null || true)
    [[ "$v" =~ ^(ws|httpupgrade|xhttp|none)$     ]] && FF_MODE="$v"

    v=$(jq -r '.ff_path     // empty' <<< "$s" 2>/dev/null || true)
    [[ -n "$v"                                   ]] && FF_PATH="$v"

    v=$(jq -r '.fixed_domain// empty' <<< "$s" 2>/dev/null || true)
    [[ -n "$v"                                   ]] && FIXED_DOMAIN="$v"

    v=$(jq -r '.restart_interval // empty' <<< "$s" 2>/dev/null || true)
    [[ "$v" =~ ^[0-9]+$                          ]] && RESTART_INTERVAL="$v"
}

save_state() {
    mkdir -p "$DIR"
    local tmp; tmp=$(mktemp "$STATE_FILE.XXXXXX") || return 1
    _state_to_json > "$tmp" && mv "$tmp" "$STATE_FILE" || { rm -f "$tmp"; return 1; }
}

# ── §5a  TRANSACTION PRIMITIVES ───────────────────────────────────────────────
# 改进：每个修改系统状态的操作必须是完整事务。
# _txn_begin  → 快照当前状态（JSON 字符串）
# _txn_rollback → 恢复快照并重新同步内存状态
# _txn_commit   → 将内存状态持久化

_txn_begin() {
    _TXN_SNAPSHOT=$(_state_to_json 2>/dev/null || true)
}

_txn_rollback() {
    [[ -z "${_TXN_SNAPSHOT:-}" ]] && return
    mkdir -p "$DIR"
    # 原子性恢复状态文件
    local tmp; tmp=$(mktemp "$STATE_FILE.XXXXXX") || true
    [[ -n "${tmp:-}" ]] && printf '%s\n' "$_TXN_SNAPSHOT" > "$tmp" && mv "$tmp" "$STATE_FILE"
    # 重新加载内存变量
    load_state
    _TXN_SNAPSHOT=""
}

_txn_commit() { save_state; _TXN_SNAPSHOT=""; }

# ── §6  PREFLIGHT ENGINE  (先校验、后执行) ────────────────────────────────────
# 改进：把所有预检逻辑从安装流程中提取为独立函数，确保
#       "预检通过才进入写入阶段"的先验约束。

_port_in_use() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null | awk -v p=":$p" '$4~p"$"||$4~p" "{f=1}END{exit !f}'
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | awk -v p=":$p" '$4~p"$"||$4~p" "{f=1}END{exit !f}'
        return
    fi
    local hex; hex=$(printf '%04X' "$p")
    awk -v h="$hex" 'NR>1&&substr($2,index($2,":")+1,4)==h{f=1}END{exit !f}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

preflight_install() {
    # 仅输出告警，不阻断安装（端口占用为非致命场景）
    [[ "$ARGO_MODE" == "yes" ]] && _port_in_use "$ARGO_PORT" && \
        warn "端口 $ARGO_PORT 已被占用，安装后可在 Argo 管理中修改"
    [[ "$FF_MODE" != "none" ]] && _port_in_use 80 && \
        warn "端口 80 已被占用，FreeFlow 可能无法启动"
    local avail; avail=$(df -k /etc 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
    [[ "$avail" -lt 51200 ]] && warn "磁盘剩余空间不足 50MB，可能影响安装"
    return 0
}

# ── §7  NETWORK PRIMITIVES ────────────────────────────────────────────────────
_get_realip() {
    local ip org ipv6
    ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null) || true
    if [[ -z "${ip:-}" ]]; then
        ipv6=$(curl -sf --max-time 5 https://api6.ipify.org 2>/dev/null) || true
        [[ -n "${ipv6:-}" ]] && printf '[%s]' "$ipv6" || printf ''
        return
    fi
    org=$(curl -sf --max-time 5 "https://ipinfo.io/$ip/org" 2>/dev/null) || true
    if grep -qiE 'Cloudflare|UnReal|AEZA|Andrei' <<< "${org:-}"; then
        ipv6=$(curl -sf --max-time 5 https://api6.ipify.org 2>/dev/null) || true
        [[ -n "${ipv6:-}" ]] && printf '[%s]' "$ipv6" || printf '%s' "$ip"
    else
        printf '%s' "$ip"
    fi
}

# 指数退避轮询 Argo 临时域名：3→6→8→8→8→8 s，总计最多约 44s
_get_temp_domain() {
    local domain delay=3 i=1
    sleep 3
    while [[ $i -le 6 ]]; do
        domain=$(grep -o 'https://[^[:space:]]*trycloudflare\.com' \
                 "$ARGO_LOG" 2>/dev/null | head -1 | sed 's|https://||') || true
        [[ -n "${domain:-}" ]] && { printf '%s' "$domain"; return 0; }
        sleep "$delay"
        (( i++, delay = delay < 8 ? delay * 2 : 8 )) || true
    done
    return 1
}

# URL path 编码：纯 awk 实现，无需 python/perl 依赖
# 改进：原实现用多行 sed 替换，字符集不完整且不可读。awk 版覆盖全 ASCII。
_urlencode() {
    printf '%s' "$1" | awk '
    BEGIN { for(i=0;i<=255;i++) h[sprintf("%c",i)]=sprintf("%%%02X",i) }
    { n=split($0,c,"")
      for(i=1;i<=n;i++){
          ch=c[i]
          if(ch~/[A-Za-z0-9\/:@._~!$&()*+,;=\-]/) printf "%s",ch
          else printf "%s",h[ch]
      }
    } END{printf "\n"}'
}

# ── §8  PROTOCOL PLUGIN REGISTRY ──────────────────────────────────────────────
# 接口契约：
#   _ib_<scope>_<proto>()  → 向 stdout 输出 inbound JSON
#   _lk_<scope>_<proto>()  → 向 stdout 输出 vless:// 链接
# 新增协议只需新增函数，dispatch 层和 config 引擎无需改动。

_sniff() {
    printf '{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}'
}

# ── Argo inbound plugins ──────────────────────────────────────────────────────
_ib_argo_ws() {
    local u; u=$(_get_uuid)
    jq -n --argjson port "$ARGO_PORT" --arg u "$u" --argjson s "$(_sniff)" '{
        port:$port, listen:"127.0.0.1", protocol:"vless",
        settings:{clients:[{id:$u}], decryption:"none"},
        streamSettings:{network:"ws", security:"none", wsSettings:{path:"/argo"}},
        sniffing:$s }'
}

_ib_argo_xhttp() {
    local u; u=$(_get_uuid)
    jq -n --argjson port "$ARGO_PORT" --arg u "$u" --argjson s "$(_sniff)" '{
        port:$port, listen:"127.0.0.1", protocol:"vless",
        settings:{clients:[{id:$u}], decryption:"none"},
        streamSettings:{network:"xhttp", security:"none",
            xhttpSettings:{host:"", path:"/argo", mode:"auto"}},
        sniffing:$s }'
}

# ── FreeFlow inbound plugins ──────────────────────────────────────────────────
_ib_ff_ws() {
    local u; u=$(_get_uuid)
    jq -n --arg u "$u" --arg p "$FF_PATH" --argjson s "$(_sniff)" '{
        port:80, listen:"::", protocol:"vless",
        settings:{clients:[{id:$u}], decryption:"none"},
        streamSettings:{network:"ws", security:"none", wsSettings:{path:$p}},
        sniffing:$s }'
}

_ib_ff_httpupgrade() {
    local u; u=$(_get_uuid)
    jq -n --arg u "$u" --arg p "$FF_PATH" --argjson s "$(_sniff)" '{
        port:80, listen:"::", protocol:"vless",
        settings:{clients:[{id:$u}], decryption:"none"},
        streamSettings:{network:"httpupgrade", security:"none",
            httpupgradeSettings:{path:$p}},
        sniffing:$s }'
}

_ib_ff_xhttp() {
    local u; u=$(_get_uuid)
    jq -n --arg u "$u" --arg p "$FF_PATH" --argjson s "$(_sniff)" '{
        port:80, listen:"::", protocol:"vless",
        settings:{clients:[{id:$u}], decryption:"none"},
        streamSettings:{network:"xhttp", security:"none",
            xhttpSettings:{host:"", path:$p, mode:"stream-one"}},
        sniffing:$s }'
}

# ── Link plugins ──────────────────────────────────────────────────────────────
_lk_argo_ws() {
    local u="$1" d="$2" ci="${3:-cf.tencentapp.cn}" cp="${4:-443}"
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=ws&host=%s&path=%%2Fargo%%3Fed%%3D2560#Argo-WS\n' \
        "$u" "$ci" "$cp" "$d" "$d"
}

_lk_argo_xhttp() {
    local u="$1" d="$2" ci="${3:-cf.tencentapp.cn}" cp="${4:-443}"
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=xhttp&host=%s&path=%%2Fargo&mode=auto#Argo-XHTTP\n' \
        "$u" "$ci" "$cp" "$d" "$d"
}

_lk_ff() {
    local u="$1" ip="$2" pe; pe=$(_urlencode "$FF_PATH")
    case "$FF_MODE" in
        ws)
            printf 'vless://%s@%s:80?encryption=none&security=none&type=ws&host=%s&path=%s#FreeFlow-WS\n' \
                "$u" "$ip" "$ip" "$pe" ;;
        httpupgrade)
            printf 'vless://%s@%s:80?encryption=none&security=none&type=httpupgrade&host=%s&path=%s#FreeFlow-HTTPUpgrade\n' \
                "$u" "$ip" "$ip" "$pe" ;;
        xhttp)
            printf 'vless://%s@%s:80?encryption=none&security=none&type=xhttp&host=%s&path=%s&mode=stream-one#FreeFlow-XHTTP\n' \
                "$u" "$ip" "$ip" "$pe" ;;
    esac
}

# ── Plugin dispatch ───────────────────────────────────────────────────────────
_dispatch_ib_argo() { case "$ARGO_PROTO" in xhttp) _ib_argo_xhttp;; *) _ib_argo_ws;; esac; }

_dispatch_ib_ff() {
    case "$FF_MODE" in
        ws)          _ib_ff_ws;;
        httpupgrade) _ib_ff_httpupgrade;;
        xhttp)       _ib_ff_xhttp;;
        *) return 1;;
    esac
}

# ── §9  CONFIG ENGINE ─────────────────────────────────────────────────────────
_gen_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
        awk '{h=$0; printf "%s-%s-4%s-%s%s-%s\n",
            substr(h,1,8),substr(h,9,4),substr(h,14,3),
            substr("89ab",int(rand()*4)+1,1),substr(h,18,3),substr(h,21,12)}'
    fi
}

_get_uuid() {
    local id
    id=$(jq -r 'first(.inbounds[]? | select(.protocol=="vless")
                | .settings.clients[0].id) // empty' \
         "$CONFIG_FILE" 2>/dev/null || true)
    printf '%s' "${id:-$UUID}"
}

# 原子 jq 补丁：tmp → 验证 → mv，杜绝脏写
_jq_patch() {
    local file="$1" filter="$2"; shift 2
    local tmp; tmp=$(mktemp "$file.XXXXXX") || { err "无法创建临时文件"; return 1; }
    if jq "$@" "$filter" "$file" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
        mv "$tmp" "$file"; return 0
    fi
    rm -f "$tmp"; err "jq 操作失败: $filter"; return 1
}

write_config() {
    mkdir -p "$DIR"
    local inbounds="[]" argo_ib ff_ib

    if [[ "$ARGO_MODE" == "yes" ]]; then
        argo_ib=$(_dispatch_ib_argo) || return 1
        inbounds="[$argo_ib]"
    fi

    if [[ "$FF_MODE" != "none" ]]; then
        ff_ib=$(_dispatch_ib_ff) || return 1
        if [[ "$ARGO_MODE" == "yes" ]]; then
            inbounds=$(jq --argjson ib "$ff_ib" '. + [$ib]' <<< "$inbounds")
        else
            inbounds="[$ff_ib]"
        fi
    fi

    local tmp; tmp=$(mktemp "$CONFIG_FILE.XXXXXX") || { err "无法创建临时文件"; return 1; }
    jq -n --argjson inbounds "$inbounds" '{
        log:{access:"/dev/null", error:"/dev/null", loglevel:"none"},
        inbounds:$inbounds,
        dns:{servers:["https+local://1.1.1.1/dns-query"]},
        outbounds:[
            {protocol:"freedom",   tag:"direct"},
            {protocol:"blackhole", tag:"block"}
        ]
    }' > "$tmp" || { rm -f "$tmp"; err "生成 config.json 失败"; return 1; }

    # 改进：commit 前用 xray -test 二次验证，确保语法正确再落盘
    if [[ -x "$XRAY_BIN" ]]; then
        "$XRAY_BIN" -test -c "$tmp" >/dev/null 2>&1 || {
            rm -f "$tmp"; err "config.json 语法验证失败"; return 1
        }
    fi

    mv "$tmp" "$CONFIG_FILE"
    ok "config.json 已写入并验证"
}

apply_argo_inbound() {
    local ib; ib=$(_dispatch_ib_argo) || return 1
    _jq_patch "$CONFIG_FILE" '
        if ([.inbounds[]? | select(.listen=="127.0.0.1")] | length) > 0
        then .inbounds = [.inbounds[] | if .listen=="127.0.0.1" then $ib else . end]
        else .inbounds = [$ib] + .inbounds
        end
    ' --argjson ib "$ib"
}

apply_ff_inbound() {
    _jq_patch "$CONFIG_FILE" 'del(.inbounds[]? | select(.port == 80))' || return 1
    [[ "$FF_MODE" == "none" ]] && return 0
    local ib; ib=$(_dispatch_ib_ff) || return 1
    _jq_patch "$CONFIG_FILE" '.inbounds += [$ib]' --argjson ib "$ib"
}

build_links() {
    local argo_domain="${1:-}"
    local u ip cfip="${CFIP:-cf.tencentapp.cn}" cfport="${CFPORT:-443}"
    u=$(_get_uuid); ip=$(_get_realip)
    {
        if [[ "$ARGO_MODE" == "yes" && -n "${argo_domain:-}" ]]; then
            case "$ARGO_PROTO" in
                xhttp) _lk_argo_xhttp "$u" "$argo_domain" "$cfip" "$cfport";;
                *)     _lk_argo_ws    "$u" "$argo_domain" "$cfip" "$cfport";;
            esac
        fi
        if [[ "$FF_MODE" != "none" ]]; then
            if [[ -n "${ip:-}" ]]; then
                _lk_ff "$u" "$ip"
            else
                warn "无法获取服务器 IP，FreeFlow 节点已跳过（可从 FreeFlow 管理重新生成）"
            fi
        fi
    } > "$CLIENT_FILE"
}

print_links() {
    echo ""
    if [[ ! -s "$CLIENT_FILE" ]]; then
        warn "节点文件为空，请先安装或重新生成"; return 1
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] && printf "${CYN}%s${R}\n" "$line"
    done < "$CLIENT_FILE"
    echo ""
}

# ── §10  SERVICE ENGINE ───────────────────────────────────────────────────────
# 核心改进：所有单元文件从模板全量生成（替代原来用 sed -i 打补丁的方式）。
# 原因：sed 补丁依赖文件当前内容格式，脆弱且不幂等。
#       模板生成天然幂等，端口/路径变更只需重调 register_*_unit()。

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
ExecStart=$XRAY_BIN run -c $CONFIG_FILE
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
}

_tpl_tunnel_systemd() {
    cat <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/sh -c '${1} >> $ARGO_LOG 2>&1'
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
command="$XRAY_BIN"
command_args="run -c $CONFIG_FILE"
command_background=true
pidfile="/var/run/xray.pid"
EOF
}

_tpl_tunnel_openrc() {
    cat <<EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '${1} >> $ARGO_LOG 2>&1'"
command_background=true
pidfile="/var/run/tunnel.pid"
EOF
}

_tunnel_cmd_temp() {
    printf '%s tunnel --url http://localhost:%s --no-autoupdate --edge-ip-version auto --protocol http2' \
        "$ARGO_BIN" "$ARGO_PORT"
}

# 写入单元文件：内容无变化则跳过，有变化则置脏标志（deferred daemon-reload）
_sync_unit() {
    local dest="$1" content="$2"
    local cur; cur=$(cat "$dest" 2>/dev/null || true)
    [[ "$cur" == "$content" ]] && return 0
    printf '%s' "$content" > "$dest"
    _UNIT_DIRTY=1
}

register_xray_unit() {
    if is_systemd; then
        _sync_unit "/etc/systemd/system/xray.service" "$(_tpl_xray_systemd)"
    else
        _sync_unit "/etc/init.d/xray" "$(_tpl_xray_openrc)"
        chmod +x /etc/init.d/xray
    fi
}

register_tunnel_unit() {
    local cmd="${1:-$(_tunnel_cmd_temp)}"
    if is_systemd; then
        _sync_unit "/etc/systemd/system/tunnel.service" "$(_tpl_tunnel_systemd "$cmd")"
    else
        _sync_unit "/etc/init.d/tunnel" "$(_tpl_tunnel_openrc "$cmd")"
        chmod +x /etc/init.d/tunnel
    fi
}

# 端口变更时重新生成隧道单元（从模板，无 sed 打补丁）
# 覆盖三种场景：① tunnel.yml（JSON 凭证）② token 字符串 ③ 临时隧道
_regen_tunnel_unit() {
    local old_port="${1:-}"
    if [[ -f "$DIR/tunnel.yml" ]]; then
        [[ -n "$old_port" ]] && \
            sed -i "s|localhost:${old_port}|localhost:${ARGO_PORT}|g" \
                "$DIR/tunnel.yml" 2>/dev/null || true
        register_tunnel_unit "$ARGO_BIN tunnel --edge-ip-version auto --config $DIR/tunnel.yml run"
        return
    fi
    local unit_f token
    is_systemd && unit_f="/etc/systemd/system/tunnel.service" || unit_f="/etc/init.d/tunnel"
    token=$(grep -oE -- '--token [A-Za-z0-9=_-]+' "${unit_f}" 2>/dev/null | awk '{print $2}' || true)
    if [[ -n "${token:-}" ]]; then
        register_tunnel_unit \
            "$ARGO_BIN tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $token"
    else
        register_tunnel_unit "$(_tunnel_cmd_temp)"
    fi
}

_daemon_reload() {
    is_systemd                   || return 0
    [[ $_UNIT_DIRTY -eq 1 ]]     || return 0
    systemctl daemon-reload 2>/dev/null || true
    _UNIT_DIRTY=0
}

svc() {
    local act="$1" name="$2"
    if is_systemd; then
        case "$act" in
            enable)  systemctl enable  "$name" 2>/dev/null;;
            disable) systemctl disable "$name" 2>/dev/null;;
            *)       systemctl "$act"  "$name" 2>/dev/null;;
        esac
    else
        case "$act" in
            enable)  rc-update add "$name" default 2>/dev/null;;
            disable) rc-update del "$name" default 2>/dev/null;;
            *)       rc-service  "$name" "$act"    2>/dev/null;;
        esac
    fi
}

restart_xray() {
    step "重启 xray..."
    _daemon_reload
    svc restart xray || { err "xray 重启失败"; return 1; }
    ok "xray 已重启"
}

restart_argo() {
    rm -f "$ARGO_LOG"
    step "重启 Argo 隧道..."
    _daemon_reload
    svc restart tunnel || { err "tunnel 重启失败"; return 1; }
    ok "Argo 隧道已重启"
}

# ── §11  DOWNLOAD ENGINE ──────────────────────────────────────────────────────
_curl_dl() { curl -sfL --connect-timeout 15 --max-time 120 -o "$2" "$1"; }

download_xray() {
    _detect_arch
    if [[ -f "$XRAY_BIN" ]]; then info "xray 已存在，跳过下载"; return 0; fi
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${_ARCH_XRAY}.zip"
    local zip="$DIR/xray.zip"
    spin_start "下载 Xray ($_ARCH_XRAY)"
    _curl_dl "$url" "$zip"; local rc=$?; spin_stop
    [[ $rc -ne 0 ]] && { rm -f "$zip"; err "Xray 下载失败，请检查网络"; return 1; }
    unzip -t "$zip" >/dev/null 2>&1 || { rm -f "$zip"; err "Xray zip 损坏"; return 1; }
    unzip -o "$zip" xray -d "$DIR/" >/dev/null 2>&1 || { rm -f "$zip"; err "解压失败"; return 1; }
    rm -f "$zip"
    [[ -f "$XRAY_BIN" ]] || { err "解压后未找到 xray 二进制"; return 1; }
    chmod +x "$XRAY_BIN"
    ok "Xray 下载完成 ($("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}'))"
}

download_cloudflared() {
    _detect_arch
    if [[ -f "$ARGO_BIN" ]]; then info "cloudflared 已存在，跳过下载"; return 0; fi
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${_ARCH_CF}"
    spin_start "下载 cloudflared ($_ARCH_CF)"
    _curl_dl "$url" "$ARGO_BIN"; local rc=$?; spin_stop
    [[ $rc -ne 0 ]] && { rm -f "$ARGO_BIN"; err "cloudflared 下载失败"; return 1; }
    [[ -s "$ARGO_BIN" ]]  || { rm -f "$ARGO_BIN"; err "cloudflared 文件为空"; return 1; }
    chmod +x "$ARGO_BIN"
    ok "cloudflared 下载完成"
}

# ── §12  ENVIRONMENT SETUP ────────────────────────────────────────────────────
_check_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请在 root 下运行脚本"; }

_pkg_install() {
    local pkg="$1" bin="${2:-$1}"
    command -v "$bin" >/dev/null 2>&1 && return 0
    step "安装依赖: $pkg"
    if   command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1
    elif command -v dnf     >/dev/null 2>&1; then dnf  install -y "$pkg" >/dev/null 2>&1
    elif command -v yum     >/dev/null 2>&1; then yum  install -y "$pkg" >/dev/null 2>&1
    elif command -v apk     >/dev/null 2>&1; then apk  add       "$pkg" >/dev/null 2>&1
    else die "未找到包管理器，无法安装 $pkg"
    fi
    hash -r 2>/dev/null || true
    command -v "$bin" >/dev/null 2>&1 || die "$pkg 安装失败，请手动安装后重试"
    ok "$pkg 已就绪"
}

check_deps() {
    step "检查依赖 (curl / unzip / jq)..."
    for d in curl unzip jq; do _pkg_install "$d"; done
    ok "依赖检查通过"
}

_kernel_ge() {
    local cur; cur=$(uname -r)
    local cm="${cur%%.*}" cr="${cur#*.}"; cr="${cr%%.*}"; cr="${cr%%[^0-9]*}"
    [[ $cm -gt $1 ]] || { [[ $cm -eq $1 ]] && [[ ${cr:-0} -ge $2 ]]; }
}

check_bbr() {
    local algo; algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$algo" == "bbr" ]]; then ok "TCP BBR 已启用"; return 0; fi
    warn "当前 TCP 拥塞控制: $algo（推荐 BBR）"
    _kernel_ge 4 9 || { warn "内核 < 4.9，不支持 BBR，跳过"; return 0; }
    is_systemd || return 0
    local ans; prompt "是否启用 BBR？(y/N): " ans
    [[ "${ans:-n}" =~ ^[Yy]$ ]] || return 0
    modprobe tcp_bbr 2>/dev/null || true
    mkdir -p /etc/modules-load.d /etc/sysctl.d
    printf 'tcp_bbr\n' > /etc/modules-load.d/xray2go-bbr.conf
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' \
        > /etc/sysctl.d/88-xray2go-bbr.conf
    sysctl -p /etc/sysctl.d/88-xray2go-bbr.conf >/dev/null 2>&1
    ok "BBR 已启用（重启后仍生效）"
}

fix_time_sync() {
    [[ -f /etc/redhat-release || -f /etc/centos-release ]] || return 0
    local pm; command -v dnf >/dev/null 2>&1 && pm="dnf" || pm="yum"
    step "RHEL 系：修正时间同步..."
    $pm install -y chrony >/dev/null 2>&1 || true
    systemctl enable --now chronyd >/dev/null 2>&1 || true
    chronyc -a makestep >/dev/null 2>&1 || true
    $pm update -y ca-certificates >/dev/null 2>&1 || true
    ok "时间同步已修正"
}

check_resolved() {
    is_debian && is_systemd || return 0
    systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0
    local stub; stub=$(awk -F= '/^DNSStubListener/{print $2}' \
                       /etc/systemd/resolved.conf 2>/dev/null | tr -d ' ')
    [[ "${stub:-yes}" != "no" ]] && \
        info "检测到 systemd-resolved stub (127.0.0.53:53) — xray 使用 DoH，无端口冲突"
}

# ── §13  INSTALL / UNINSTALL  (事务化，失败原子回滚) ─────────────────────────
# 核心改进：原方案无回滚，安装失败后系统处于不确定状态。
# 新方案：txn_begin 快照状态 → 逐步执行 → 失败则 txn_rollback 恢复。

install_all() {
    clear; title "══════════ 安装 Xray-2go r3 ══════════"
    check_deps
    mkdir -p "$DIR" && chmod 750 "$DIR"
    _txn_begin

    download_xray || { _txn_rollback; return 1; }
    [[ "$ARGO_MODE" == "yes" ]] && { download_cloudflared || { _txn_rollback; return 1; }; }

    write_config || { _txn_rollback; return 1; }

    [[ "$ARGO_MODE" == "no" && "$FF_MODE" == "none" ]] && \
        warn "Argo 与 FreeFlow 均未启用，xray 以零入站模式运行（无可用节点）"

    register_xray_unit
    [[ "$ARGO_MODE" == "yes" ]] && register_tunnel_unit
    _daemon_reload

    if is_openrc; then
        printf '0 0\n' > /proc/sys/net/ipv4/ping_group_range 2>/dev/null || true
        sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts 2>/dev/null || true
        sed -i '2s/.*/::1         localhost/'  /etc/hosts 2>/dev/null || true
    fi

    fix_time_sync

    step "启动服务..."
    svc enable xray
    svc start  xray || { err "xray 启动失败"; _txn_rollback; return 1; }
    ok "xray 已启动"

    if [[ "$ARGO_MODE" == "yes" ]]; then
        svc enable tunnel
        svc start  tunnel || { err "tunnel 启动失败"; _txn_rollback; return 1; }
        ok "tunnel 已启动"
    fi

    _txn_commit
    ok "══ 安装完成 ══"
}

uninstall_all() {
    local ans; prompt "确定要卸载 xray-2go？(y/N): " ans
    [[ "${ans:-n}" =~ ^[Yy]$ ]] || { info "已取消"; return; }
    step "卸载中..."
    _remove_crontab
    for s in xray tunnel; do
        svc stop    "$s" 2>/dev/null || true
        svc disable "$s" 2>/dev/null || true
    done
    if is_systemd; then
        rm -f /etc/systemd/system/{xray,tunnel}.service
        systemctl daemon-reload 2>/dev/null || true
    else
        rm -f /etc/init.d/{xray,tunnel}
    fi
    rm -rf "$DIR"
    rm -f  "$SHORTCUT" "$SELF_DEST" "$SELF_DEST.bak"
    ok "Xray-2go 卸载完成"
}

# ── §14  TUNNEL OPERATIONS ────────────────────────────────────────────────────
_validate_domain() {
    local d="$1"
    [[ -z "$d" ]] && return 1
    [[ "$d" =~ [[:space:]/] ]] && return 1
    printf '%s' "$d" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$'
}

configure_fixed_tunnel() {
    info "固定隧道 — 协议: $ARGO_PROTO  回源端口: $ARGO_PORT"
    info "请确认 CF 后台 ingress 已指向 http://localhost:$ARGO_PORT"
    echo ""

    local domain auth
    prompt "请输入 Argo 域名: " domain
    _validate_domain "$domain" || { err "域名格式不合法"; return 1; }

    prompt "请输入 Argo 密钥 (token 或 JSON 内容): " auth
    [[ -z "${auth:-}" ]] && { err "密钥不能为空"; return 1; }

    local exec_cmd
    if grep -q "TunnelSecret" <<< "$auth"; then
        jq . <<< "$auth" >/dev/null 2>&1 || { err "JSON 凭证格式不合法"; return 1; }
        local tid
        tid=$(jq -r '(.TunnelID // .AccountTag) // empty' <<< "$auth" 2>/dev/null || true)
        [[ -z "${tid:-}" ]] && { err "无法从 JSON 提取 TunnelID/AccountTag"; return 1; }
        [[ "$tid" =~ $'\n'|'"'|"'"| ]] && { err "TunnelID 含非法字符"; return 1; }
        printf '%s' "$auth" > "$DIR/tunnel.json"
        cat > "$DIR/tunnel.yml" <<EOF
tunnel: $tid
credentials-file: $DIR/tunnel.json
protocol: http2

ingress:
  - hostname: $domain
    service: http://localhost:$ARGO_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
        exec_cmd="$ARGO_BIN tunnel --edge-ip-version auto --config $DIR/tunnel.yml run"

    elif [[ "$auth" =~ ^[A-Za-z0-9=_-]{120,250}$ ]]; then
        exec_cmd="$ARGO_BIN tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $auth"
    else
        err "密钥格式无法识别（JSON 需含 TunnelSecret；Token 为 120-250 位字母数字串）"
        return 1
    fi

    _txn_begin
    register_tunnel_unit "$exec_cmd"
    _daemon_reload
    svc enable tunnel 2>/dev/null || true

    if ! apply_argo_inbound; then
        err "更新 xray inbound 失败"; _txn_rollback; return 1
    fi
    FIXED_DOMAIN="$domain"

    if ! restart_xray || ! restart_argo; then
        _txn_rollback; return 1
    fi

    _txn_commit
    ok "固定隧道 ($ARGO_PROTO, path=/argo) 已配置，域名: $domain"
}

reset_temp_tunnel() {
    register_tunnel_unit "$(_tunnel_cmd_temp)"
    _daemon_reload
    rm -f "$DIR/tunnel.yml" "$DIR/tunnel.json"
    ARGO_PROTO="ws"; FIXED_DOMAIN=""
    apply_argo_inbound || warn "更新 xray inbound 失败（可手动重启 xray 恢复）"
    save_state
}

refresh_temp_domain() {
    [[ "$ARGO_MODE" == "yes"  ]] || { warn "未启用 Argo"; return 1; }
    [[ "$ARGO_PROTO" == "ws"  ]] || { err "XHTTP 不支持临时隧道，请先切换协议"; return 1; }
    [[ -s "$CLIENT_FILE"      ]] || { warn "节点文件为空，请先安装"; return 1; }

    step "重启隧道并等待新域名..."
    restart_argo || return 1
    local domain
    domain=$(_get_temp_domain) || { warn "未能获取临时域名，请检查网络"; return 1; }
    ok "ArgoDomain: $domain"

    awk -v d="$domain" '
        /#Argo-WS$/ { sub(/sni=[^&]*/, "sni="d); sub(/host=[^&]*/, "host="d) }
        { print }
    ' "$CLIENT_FILE" > "$CLIENT_FILE.tmp" \
        && mv "$CLIENT_FILE.tmp" "$CLIENT_FILE" \
        || { rm -f "$CLIENT_FILE.tmp"; err "节点文件更新失败"; return 1; }

    print_links; ok "节点已更新"
}

# ── §15  CRON ENGINE ──────────────────────────────────────────────────────────
_cron_running() {
    command -v crontab >/dev/null 2>&1 || return 1
    if is_openrc; then
        rc-service dcron status >/dev/null 2>&1 || rc-service crond status >/dev/null 2>&1
    else
        systemctl is-active --quiet cron  2>/dev/null || \
        systemctl is-active --quiet crond 2>/dev/null
    fi
}

_ensure_cron() {
    _cron_running && return 0
    warn "cron 未运行"
    local ans; prompt "是否安装 cron？(Y/n): " ans
    [[ "${ans:-y}" =~ ^[Nn]$ ]] && { err "cron 不可用，自动重启无法配置"; return 1; }
    if   command -v apt-get >/dev/null 2>&1; then
        _pkg_install cron crontab; systemctl enable --now cron  2>/dev/null || true
    elif command -v dnf     >/dev/null 2>&1; then
        _pkg_install cronie crontab; systemctl enable --now crond 2>/dev/null || true
    elif command -v yum     >/dev/null 2>&1; then
        _pkg_install cronie crontab; systemctl enable --now crond 2>/dev/null || true
    elif command -v apk     >/dev/null 2>&1; then
        _pkg_install dcron crontab
        rc-service dcron start 2>/dev/null; rc-update add dcron default 2>/dev/null || true
    else
        die "无法安装 cron，请手动安装"
    fi
}

setup_cron_restart() {
    _ensure_cron || return 1
    local cmd; is_openrc && cmd="rc-service xray restart" || cmd="systemctl restart xray"
    local tmp; tmp=$(mktemp) || { err "无法创建临时文件"; return 1; }
    { crontab -l 2>/dev/null | grep -v '#xray-restart'
      printf '*/%s * * * * %s >/dev/null 2>&1 #xray-restart\n' "$RESTART_INTERVAL" "$cmd"
    } > "$tmp"
    crontab "$tmp" || { rm -f "$tmp"; err "crontab 写入失败"; return 1; }
    rm -f "$tmp"
    ok "已设置每 $RESTART_INTERVAL 分钟自动重启 xray"
}

_remove_crontab() {
    command -v crontab >/dev/null 2>&1 || return 0
    local tmp; tmp=$(mktemp) || return 0
    crontab -l 2>/dev/null | grep -v '#xray-restart' > "$tmp" || true
    crontab "$tmp" 2>/dev/null || true; rm -f "$tmp"
}

# ── §16  SHORTCUT / SELF-UPDATE ───────────────────────────────────────────────
install_shortcut() {
    step "拉取最新脚本..."
    local tmp="$SELF_DEST.tmp"
    _curl_dl "$UPSTREAM" "$tmp" || { rm -f "$tmp"; err "拉取失败，请检查网络"; return 1; }
    bash -n "$tmp" 2>/dev/null  || { rm -f "$tmp"; err "脚本语法验证失败，已中止"; return 1; }
    [[ -f "$SELF_DEST" ]] && cp -f "$SELF_DEST" "$SELF_DEST.bak" 2>/dev/null || true
    mv "$tmp" "$SELF_DEST" && chmod +x "$SELF_DEST"
    printf '#!/bin/bash\nexec %s "$@"\n' "$SELF_DEST" > "$SHORTCUT"
    chmod +x "$SHORTCUT"
    ok "脚本已更新！输入 ${GRN}s${R} 快速启动"
}

# ── §17  STATUS QUERIES ───────────────────────────────────────────────────────
status_xray() {
    [[ -f "$XRAY_BIN" ]] || { printf 'not installed'; return 2; }
    if is_openrc; then
        rc-service xray status 2>/dev/null | grep -q "started" \
            && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
    else
        [[ "$(systemctl is-active xray 2>/dev/null)" == "active" ]] \
            && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
    fi
}

status_argo() {
    [[ "$ARGO_MODE" == "no" ]] && { printf 'disabled';      return 3; }
    [[ -f "$ARGO_BIN"       ]] || { printf 'not installed'; return 2; }
    if is_openrc; then
        rc-service tunnel status 2>/dev/null | grep -q "started" \
            && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
    else
        [[ "$(systemctl is-active tunnel 2>/dev/null)" == "active" ]] \
            && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
    fi
}

is_fixed_tunnel() {
    local f
    is_systemd && f="/etc/systemd/system/tunnel.service" || f="/etc/init.d/tunnel"
    [[ -f "$f" ]] || return 1
    ! grep -Fq -- "--url http://localhost:$ARGO_PORT" "$f" 2>/dev/null
}

# ── §18  INTERACTION HELPERS  (纯输入收集，不含业务逻辑) ─────────────────────
ask_argo_mode() {
    echo ""; title "Argo 隧道"
    printf "  ${GRN}1.${R} VLESS+WS/XHTTP+TLS via Cloudflare  ${YLW}[默认]${R}\n"
    printf "  ${GRN}2.${R} 不安装 Argo\n"
    local c; prompt "请选择 (1-2，回车默认1): " c
    case "${c:-1}" in
        2) ARGO_MODE="no";  info "已选：不安装 Argo";;
        *) ARGO_MODE="yes"; info "已选：安装 Argo"  ;;
    esac
}

ask_argo_proto() {
    echo ""; title "Argo 传输协议"
    printf "  ${GRN}1.${R} WS（临时+固定均支持）  ${YLW}[默认]${R}\n"
    printf "  ${GRN}2.${R} XHTTP auto（仅支持固定隧道）\n"
    local c; prompt "请选择 (1-2，回车默认1): " c
    case "${c:-1}" in
        2) ARGO_PROTO="xhttp"; warn "XHTTP 不支持临时隧道！安装后将进入固定隧道配置。";;
        *) ARGO_PROTO="ws";;
    esac
    info "已选协议: $ARGO_PROTO"; echo ""
}

ask_ff_mode() {
    echo ""; title "FreeFlow（明文 port 80）"
    printf "  ${GRN}1.${R} VLESS + WS\n"
    printf "  ${GRN}2.${R} VLESS + HTTPUpgrade\n"
    printf "  ${GRN}3.${R} VLESS + XHTTP (stream-one)\n"
    printf "  ${GRN}4.${R} 不启用  ${YLW}[默认]${R}\n"
    local c; prompt "请选择 (1-4，回车默认4): " c
    case "${c:-4}" in
        1) FF_MODE="ws";;          2) FF_MODE="httpupgrade";;
        3) FF_MODE="xhttp";;       *) FF_MODE="none";;
    esac

    if [[ "$FF_MODE" != "none" ]]; then
        _port_in_use 80 && warn "端口 80 已被占用，FreeFlow 可能无法启动"
        local p; prompt "FreeFlow path（回车默认 /）: " p
        [[ "${p:-/}" == /* ]] && FF_PATH="${p:-/}" || FF_PATH="/${p}"
        info "已选: $FF_MODE（path=$FF_PATH）"
    else
        FF_PATH="/"; info "不启用 FreeFlow"
    fi
    echo ""
}

# ── §19  SUBMENUS ─────────────────────────────────────────────────────────────
manage_argo() {
    [[ "$ARGO_MODE" == "yes" && -f "$ARGO_BIN" ]] || { warn "Argo 未启用或未安装"; sleep 1; return; }

    while true; do
        local astat type_disp
        astat=$(status_argo)
        if is_fixed_tunnel && [[ -n "$FIXED_DOMAIN" ]]; then
            type_disp="固定 ($ARGO_PROTO · $FIXED_DOMAIN)"
        else
            type_disp="临时 (WS)"
        fi

        clear; echo ""; title "══ Argo 隧道管理 ══"
        printf "  状态: ${GRN}%s${R}  协议: ${CYN}%s${R}  端口: ${YLW}%s${R}\n" \
            "$astat" "$ARGO_PROTO" "$ARGO_PORT"
        printf "  类型: %s\n" "$type_disp"
        hr
        printf "  ${GRN}1.${R} 添加/更新固定隧道\n"
        printf "  ${GRN}2.${R} 切换协议 (WS ↔ XHTTP，仅固定隧道)\n"
        printf "  ${GRN}3.${R} 切换回临时隧道 (WS)\n"
        printf "  ${GRN}4.${R} 刷新临时域名\n"
        printf "  ${GRN}5.${R} 修改回源端口（当前: ${YLW}${ARGO_PORT}${R}）\n"
        printf "  ${GRN}6.${R} 启动隧道\n"
        printf "  ${GRN}7.${R} 停止隧道\n"
        printf "  ${PUR}0.${R} 返回主菜单\n"
        hr
        local c; prompt "请输入选择: " c

        case "${c:-}" in
            1)
                echo ""
                printf "  ${GRN}1.${R} WS  ${YLW}[默认]${R}\n"
                printf "  ${GRN}2.${R} XHTTP (auto)\n"
                local p; prompt "协议 (1-2，回车维持 $ARGO_PROTO): " p
                case "${p:-}" in 2) ARGO_PROTO="xhttp";; 1) ARGO_PROTO="ws";; esac
                if configure_fixed_tunnel; then
                    build_links "$FIXED_DOMAIN"; print_links
                else
                    err "固定隧道配置失败"
                fi
                ;;
            2)
                is_fixed_tunnel || { warn "当前为临时隧道，请先配置固定隧道"; pause; continue; }
                local prev="$ARGO_PROTO"
                if [[ "$ARGO_PROTO" == "ws" ]]; then ARGO_PROTO="xhttp"; else ARGO_PROTO="ws"; fi
                save_state
                if apply_argo_inbound && restart_xray; then
                    ok "协议已切换: $ARGO_PROTO"
                    build_links "$FIXED_DOMAIN"; print_links
                else
                    err "协议切换失败，已回滚"
                    ARGO_PROTO="$prev"; save_state
                fi
                ;;
            3)
                [[ "$ARGO_PROTO" == "xhttp" ]] && \
                    { err "请先切换协议为 WS 再切回临时隧道"; pause; continue; }
                reset_temp_tunnel || { pause; continue; }
                restart_xray && restart_argo || { pause; continue; }
                step "等待临时域名（最多约 44s）..."
                local td; td=$(_get_temp_domain) || td=""
                if [[ -n "$td" ]]; then
                    ok "ArgoDomain: $td"
                else
                    warn "未能获取临时域名，可从 [4. 刷新临时域名] 重试"
                fi
                build_links "$td"; print_links
                ;;
            4) refresh_temp_domain;;
            5)
                local p_; prompt "请输入新端口（回车随机）: " p_
                [[ -z "${p_:-}" ]] && \
                    p_=$(shuf -i 2000-65000 -n 1 2>/dev/null || \
                         awk 'BEGIN{srand();print int(rand()*63000)+2000}')
                [[ "$p_" =~ ^[0-9]+$ && $p_ -ge 1 && $p_ -le 65535 ]] || \
                    { err "无效端口（范围 1-65535）"; pause; continue; }
                if _port_in_use "$p_"; then
                    warn "端口 $p_ 已被占用"
                    local ans_; prompt "仍然继续？(y/N): " ans_
                    [[ "${ans_:-n}" =~ ^[Yy]$ ]] || { pause; continue; }
                fi
                local old="$ARGO_PORT"
                _jq_patch "$CONFIG_FILE" \
                    '(.inbounds[]? | select(.port == $op) | .port) |= $np' \
                    --argjson op "$ARGO_PORT" --argjson np "$p_" \
                    || { err "端口修改失败"; pause; continue; }
                ARGO_PORT="$p_"
                # 改进：通过模板重新生成单元，替代原方案的 sed -i 打补丁
                _regen_tunnel_unit "$old"
                _daemon_reload; save_state
                restart_xray && restart_argo && ok "回源端口已修改: $p_"
                ;;
            6) svc start  tunnel && ok "隧道已启动" || err "隧道启动失败";;
            7) svc stop   tunnel && ok "隧道已停止" || err "隧道停止失败";;
            0) return;;
            *) err "无效选项";;
        esac
        pause
    done
}

manage_freeflow() {
    while true; do
        clear; echo ""; title "══ FreeFlow 管理 ══"
        if [[ "$FF_MODE" == "none" ]]; then
            printf "  当前状态: ${YLW}未启用${R}\n"
        else
            printf "  当前状态: ${GRN}%s${R}  path: ${CYN}%s${R}\n" "$FF_MODE" "$FF_PATH"
        fi
        hr
        printf "  ${GRN}1.${R} 添加/变更方式\n"
        printf "  ${GRN}2.${R} 修改 path\n"
        printf "  ${RED}3.${R} 卸载 FreeFlow\n"
        printf "  ${PUR}0.${R} 返回主菜单\n"
        hr
        local c; prompt "请输入选择: " c

        case "${c:-}" in
            1)
                ask_ff_mode
                apply_ff_inbound || { err "FreeFlow 配置更新失败"; pause; continue; }
                save_state
                local ip; ip=$(_get_realip)
                { grep '#Argo' "$CLIENT_FILE" 2>/dev/null || true
                  [[ "$FF_MODE" != "none" && -n "${ip:-}" ]] && \
                      _lk_ff "$(_get_uuid)" "$ip"
                } > "$CLIENT_FILE.new" && mv "$CLIENT_FILE.new" "$CLIENT_FILE"
                restart_xray; ok "FreeFlow 已变更"; print_links
                ;;
            2)
                [[ "$FF_MODE" == "none" ]] && { warn "FreeFlow 未启用，请先选 [1]"; pause; continue; }
                local p; prompt "新 path（回车保持 $FF_PATH）: " p
                if [[ -n "${p:-}" ]]; then
                    [[ "$p" == /* ]] && FF_PATH="$p" || FF_PATH="/$p"
                    apply_ff_inbound || { err "更新失败"; pause; continue; }
                    save_state
                    local ip; ip=$(_get_realip)
                    if [[ -n "${ip:-}" ]]; then
                        local nl; nl=$(_lk_ff "$(_get_uuid)" "$ip")
                        awk -v nl="$nl" '/#FreeFlow/{print nl; next}{print}' \
                            "$CLIENT_FILE" > "$CLIENT_FILE.tmp" \
                            && mv "$CLIENT_FILE.tmp" "$CLIENT_FILE" \
                            || rm -f "$CLIENT_FILE.tmp"
                    fi
                    restart_xray; ok "path 已修改: $FF_PATH"; print_links
                fi
                ;;
            3)
                FF_MODE="none"
                apply_ff_inbound || { err "卸载失败"; pause; continue; }
                save_state
                grep -v '#FreeFlow' "$CLIENT_FILE" 2>/dev/null > "$CLIENT_FILE.tmp" \
                    && mv "$CLIENT_FILE.tmp" "$CLIENT_FILE" || rm -f "$CLIENT_FILE.tmp"
                restart_xray; ok "FreeFlow 已卸载"
                ;;
            0) return;;
            *) err "无效选项";;
        esac
        pause
    done
}

manage_restart() {
    while true; do
        clear; echo ""; title "══ 自动重启管理 ══"
        printf "  当前间隔: ${CYN}%s 分钟${R}（0 = 关闭）\n" "$RESTART_INTERVAL"
        hr
        printf "  ${GRN}1.${R} 设置间隔\n"
        printf "  ${PUR}0.${R} 返回\n"
        hr
        local c; prompt "请输入选择: " c
        case "${c:-}" in
            1)
                local v; prompt "间隔分钟（0=关闭，推荐 60）: " v
                [[ "$v" =~ ^[0-9]+$ ]] || { err "无效输入"; pause; continue; }
                RESTART_INTERVAL="$v"; save_state
                if [[ "$RESTART_INTERVAL" -eq 0 ]]; then
                    _remove_crontab; ok "自动重启已关闭"
                else
                    setup_cron_restart
                fi
                ;;
            0) return;;
            *) err "无效选项";;
        esac
        pause
    done
}

# ── §20  MAIN MENU ────────────────────────────────────────────────────────────
menu() {
    while true; do
        local xstat astat xc ff_disp argo_disp xcolor
        xstat=$(status_xray); xc=$?
        astat=$(status_argo)

        [[ $xc -eq 0 ]] && xcolor="$GRN" || xcolor="$RED"

        case "$FF_MODE" in
            ws)          ff_disp="WS (path=$FF_PATH)"          ;;
            httpupgrade) ff_disp="HTTPUpgrade (path=$FF_PATH)" ;;
            xhttp)       ff_disp="XHTTP (path=$FF_PATH)"       ;;
            *)           ff_disp="未启用"                        ;;
        esac

        if [[ "$ARGO_MODE" == "yes" ]]; then
            [[ -n "$FIXED_DOMAIN" ]] \
                && argo_disp="$astat [$ARGO_PROTO · 固定: $FIXED_DOMAIN]" \
                || argo_disp="$astat [WS · 临时隧道]"
        else
            argo_disp="未启用"
        fi

        clear; echo ""
        printf "${B}${PUR}  ╔══════════════════════════════════════╗${R}\n"
        printf "${B}${PUR}  ║          Xray-2go  r3                ║${R}\n"
        printf "${B}${PUR}  ╠══════════════════════════════════════╣${R}\n"
        printf "${B}${PUR}  ║${R}  Xray   ${xcolor}%-10s${R}                     ${B}${PUR}║${R}\n" "$xstat"
        printf "${B}${PUR}  ║${R}  Argo   %-32s${B}${PUR}║${R}\n" "$argo_disp"
        printf "${B}${PUR}  ║${R}  FF     %-32s${B}${PUR}║${R}\n" "$ff_disp"
        printf "${B}${PUR}  ║${R}  重启   ${CYN}%-2s min${R}                          ${B}${PUR}║${R}\n" "$RESTART_INTERVAL"
        printf "${B}${PUR}  ╚══════════════════════════════════════╝${R}\n"
        echo ""
        printf "  ${GRN}1.${R} 安装 Xray-2go\n"
        printf "  ${RED}2.${R} 卸载 Xray-2go\n"
        hr
        printf "  ${GRN}3.${R} Argo 管理\n"
        printf "  ${GRN}4.${R} FreeFlow 管理\n"
        hr
        printf "  ${GRN}5.${R} 查看节点\n"
        printf "  ${GRN}6.${R} 修改 UUID\n"
        printf "  ${GRN}7.${R} 自动重启管理\n"
        printf "  ${GRN}8.${R} 快捷方式/脚本更新\n"
        hr
        printf "  ${RED}0.${R} 退出\n"
        echo ""
        local c; prompt "请输入选择 (0-8): " c
        echo ""

        case "${c:-}" in
            1)
                if [[ $xc -eq 0 ]]; then
                    warn "Xray-2go 已安装（请先执行选项 2 卸载）"
                else
                    ask_argo_mode
                    [[ "$ARGO_MODE" == "yes" ]] && ask_argo_proto
                    ask_ff_mode
                    check_resolved; check_bbr; preflight_install
                    save_state

                    install_all || { err "安装失败，请查看以上错误信息"; pause; continue; }

                    # 安装后节点获取流程
                    if [[ "$ARGO_MODE" == "yes" && "$ARGO_PROTO" == "xhttp" ]]; then
                        warn "XHTTP 仅支持固定隧道，现在进入配置..."
                        configure_fixed_tunnel && build_links "$FIXED_DOMAIN" || \
                            err "固定隧道配置失败，请从 [3. Argo 管理] 重新配置"

                    elif [[ "$ARGO_MODE" == "yes" ]]; then
                        echo ""
                        printf "  ${GRN}1.${R} 临时隧道（自动生成域名）  ${YLW}[默认]${R}\n"
                        printf "  ${GRN}2.${R} 固定隧道（使用自有 token/json）\n"
                        local tc; prompt "请选择隧道类型 (1-2，回车默认1): " tc
                        if [[ "${tc:-1}" == "2" ]]; then
                            if configure_fixed_tunnel; then
                                build_links "$FIXED_DOMAIN"
                            else
                                warn "固定隧道配置失败，回退临时隧道"
                                restart_argo
                                local td; td=$(_get_temp_domain) || td=""
                                build_links "$td"
                            fi
                        else
                            step "等待 Argo 临时域名（最多约 44s）..."
                            restart_argo
                            local td; td=$(_get_temp_domain) || td=""
                            [[ -n "$td" ]] && ok "ArgoDomain: $td" || \
                                warn "未能获取临时域名，可从 [3. Argo 管理→4] 刷新"
                            build_links "$td"
                        fi
                    else
                        build_links ""
                    fi
                    print_links
                fi
                ;;
            2) uninstall_all;;
            3) manage_argo;;
            4) manage_freeflow;;
            5) [[ $xc -eq 0 ]] && print_links || warn "Xray-2go 未安装或未运行";;
            6)
                [[ -f "$CONFIG_FILE" ]] || { warn "请先安装 Xray-2go"; pause; continue; }
                local v; prompt "新 UUID（回车自动生成）: " v
                if [[ -z "${v:-}" ]]; then
                    v=$(_gen_uuid) || { err "无法生成 UUID"; pause; continue; }
                    info "生成 UUID: $v"
                fi
                [[ "$v" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
                    || { err "UUID 格式不合法"; pause; continue; }
                _jq_patch "$CONFIG_FILE" \
                    '(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) = $u' \
                    --arg u "$v" || { err "UUID 更新失败"; pause; continue; }
                UUID="$v"
                [[ -s "$CLIENT_FILE" ]] && \
                    awk -v u="$v" '{gsub(/vless:\/\/[^@]*@/, "vless://"u"@"); print}' \
                        "$CLIENT_FILE" > "$CLIENT_FILE.tmp" \
                        && mv "$CLIENT_FILE.tmp" "$CLIENT_FILE"
                restart_xray && ok "UUID 已修改: $v"
                print_links
                ;;
            7) manage_restart;;
            8) install_shortcut;;
            0) info "已退出"; exit 0;;
            *) err "无效选项，请输入 0-8";;
        esac
        pause
    done
}

# ── §21  ENTRY POINT ──────────────────────────────────────────────────────────
main() {
    _check_root
    _detect_init
    load_state
    menu
}

main "$@"
