# Xray-2go

Xray-2go 是一个面向 Linux VPS 的交互式 Xray 安装与管理脚本，支持通过菜单部署、更新和卸载多种入站协议，并自动生成客户端分享链接。

## 功能特性

- 默认无参数运行进入交互式自定义选项搭建菜单
- 支持 `reality` 非交互一键安装（默认参数 + 443 冲突自动随机端口）
- 交互式安装后管理菜单
- 支持 systemd 与 OpenRC
- 支持 Debian / Ubuntu / RHEL 系 / Alpine
- 内置协议：
  - Argo：VLESS + WS / XHTTP + TLS，或 Trojan + WS + TLS，通过 Cloudflare Tunnel 转发
  - FreeFlow：VLESS + WS / HTTPUpgrade / XHTTP / TCP HTTP 伪装
  - Reality：VLESS + Reality TCP Vision / XHTTP Reality
  - VLESS-TCP：明文落地，可配置监听地址
  - SOCKS5：账号密码认证，可配置监听端口与地址
  - HTTP 代理：账号密码认证，可配置监听端口与地址；协议本身为明文 TCP，公开监听前请确认防火墙与网络边界
- 自动生成并打印分享链接
- 支持修改 UUID、端口、路径、域名、Reality 目标站点等常用参数
- xPadding 支持按协议独立开关，可实现 Argo 开启、Reality 关闭等组合
- 防火墙规则采用托管标记文件记录，只删除脚本实际创建的规则，避免误删其它服务或管理员手动规则
- 完整卸载会清理服务、配置、状态、插件、Tunnel 文件、锁文件、PID、快捷命令和脚本托管防火墙规则

### Argo 入站认证：VLESS / Trojan

Argo 工作台的“修改入站认证”可在 VLESS 与 Trojan 之间切换：

- Trojan 仅支持 WS 传输。当入站认证为 Trojan 时，脚本会拒绝把传输协议切换为 XHTTP；同样地，传输协议不是 WS 时也拒绝切换为 Trojan
- 切换到 Trojan 会自动生成一个独立的随机 Trojan 密码，与 VLESS 使用的 UUID 无关
- 可通过 Argo 工作台的“修改 Trojan 密码”单独设置或重新生成密码；输入时不回显
- 密码限制为 8-128 位 URL-safe 字符（`A-Z a-z 0-9 . _ ~ -`），避免 `#`、`?`、`@` 等字符破坏 `trojan://` 分享链接结构
- 若状态中的 Trojan 密码为空，则回退使用 UUID 作为密码；载入状态时检测到非法存量密码会清空并回退为使用 UUID
- 关闭或卸载 Argo 会把入站认证重置为 VLESS、传输重置为 WS，并清空 Trojan 密码

## 安全与实现原则

- Xray 下载只使用官方 GitHub Release，并校验官方 SHA256 摘要；校验失败或无法获取摘要时拒绝继续
- Cloudflare Tunnel 遵循官方运行方式：
  - Token / remote-managed：`cloudflared tunnel --no-autoupdate run --token ...`
  - Credentials / local-managed：`cloudflared tunnel --no-autoupdate --config tunnel.yml run`
- 敏感文件使用原子写入并限制权限为 `0600`，包括 `state.json`、Tunnel env、Tunnel credentials 等
- 服务状态变更通过统一互斥接口执行，避免并发操作造成状态竞争
- 配置生成前校验端口、UUID、域名、路径、监听地址等输入，降低配置注入风险
- 不内置执行第三方 root 网络调优脚本
- 内置自更新已禁用，请通过 GitHub 仓库或其它可校验渠道更新脚本

## 支持系统

- Debian / Ubuntu
- RHEL 系发行版
- Alpine Linux

说明：Alpine / OpenRC 环境下，Argo / Cloudflare Tunnel 需要用户按 Cloudflare 官方文档预先安装 `cloudflared`。

## 快速使用

### 首次部署：快速向导

无参数运行时，首次部署会先进入快速向导，可选择推荐的 Reality、Argo Tunnel，或进入高级自定义部署。需要多入口或逐项调整时选择高级自定义部署即可。

请在 root 用户下执行；如果当前不是 root，请先切换到 root，或使用下面的“下载后运行”方式配合 `sudo`。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh)
```

### 非交互一键安装：Reality

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh) reality
```

### 非交互一键安装：Reality + 自定义监听端口

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh) reality -p 2443
```

说明：
- 仅 `reality` 会直接触发非交互安装
- `reality`：默认优先尝试 `443`，若 `443` 已被占用，则自动切换到随机高位 TCP 端口
- `reality -p <port>`：使用你指定的 Reality TCP 监听端口，不再自动优先尝试 `443`
- `-p` 后必须显式传入合法端口号，例如 `2443`、`8443`

### 下载后运行

```bash
curl -Lo xray_2go.sh https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh
chmod +x xray_2go.sh
sudo ./xray_2go.sh
```

## 安装后的主要路径

- 工作目录：`/etc/xray2go`
- Xray 二进制：`/etc/xray2go/xray`
- Cloudflared 二进制：`/etc/xray2go/argo`
- Xray 配置：`/etc/xray2go/config.json`
- 状态文件：`/etc/xray2go/state.json`
- 插件目录：`/etc/xray2go/plugins`
- 快捷命令：`/usr/local/bin/s`
- 主脚本安装位置：`/usr/local/bin/xray2go`

## 服务名称

- Xray 服务：`xray2go`
- Cloudflare Tunnel 服务：`tunnel2go`

systemd 系统可使用：

```bash
systemctl status xray2go
systemctl status tunnel2go
```

OpenRC 系统可使用：

```bash
rc-service xray2go status
rc-service tunnel2go status
```

## 卸载说明

在交互菜单中选择卸载即可执行完整清理。脚本会尝试：

- 停止并禁用 `xray2go` / `tunnel2go` 服务
- 删除 systemd 或 OpenRC 服务文件
- 删除 `/etc/xray2go` 工作目录
- 删除配置、状态、备份、Tunnel env、Tunnel credentials、PID、锁文件、配置 hash
- 删除快捷命令和已安装脚本
- 删除脚本托管防火墙规则
- 回滚脚本写入的 sysctl / hosts 相关文件

防火墙清理只针对脚本记录为“已托管”的规则，不会盲目按端口删除系统中已有的其它规则。

## 免责声明

本项目仅供学习研究使用。使用者应遵守服务器所在地及用户所在国家和地区的相关法律法规。因使用本项目造成的任何后果由使用者自行承担，项目作者不对使用者的不当行为承担责任。
