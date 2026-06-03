# Xray-2go

Xray-2go 是一个面向 Linux VPS 的交互式 Xray 安装与管理脚本，支持通过菜单部署、更新和卸载多种入站协议，并自动生成客户端分享链接。

## 功能特性

- 交互式安装和管理菜单
- 支持 systemd 与 OpenRC
- 支持 Debian / Ubuntu / RHEL 系 / Alpine
- 内置协议：
  - Argo：VLESS + WS / XHTTP + TLS，通过 Cloudflare Tunnel 转发
  - FreeFlow：VLESS + WS / HTTPUpgrade / XHTTP / TCP HTTP 伪装
  - Reality：VLESS + Reality TCP Vision / XHTTP Reality
  - VLESS-TCP：明文落地，可配置监听地址
- 自动生成并打印分享链接
- 支持修改 UUID、端口、路径、域名、Reality 目标站点等常用参数
- xPadding 支持按协议独立开关，可实现 Argo 开启、Reality 关闭等组合
- 防火墙规则采用托管标记文件记录，只删除脚本实际创建的规则，避免误删其它服务或管理员手动规则
- 完整卸载会清理服务、配置、状态、插件、Tunnel 文件、锁文件、PID、快捷命令和脚本托管防火墙规则

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

### 一键运行交互菜单

请在 root 用户下执行；如果当前不是 root，请先切换到 root，或使用下面的“下载后运行”方式配合 `sudo`。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh)
```

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
