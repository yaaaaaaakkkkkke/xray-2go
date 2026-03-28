# Xray-Argo 精简版一键脚本

精简高效的 Xray-Argo 一键安装脚本，无交互全自动部署。

## 支持系统

Debian / Ubuntu / CentOS / Alpine / Fedora / AlmaLinux / Rocky Linux / Amazon Linux

## 使用方法

**一键安装（交互菜单）**
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh)
```

## 可用环境变量

| 变量 | 说明 | 默认值 |
|---|---|---|
| `UUID` | 节点身份标识 | 随机生成 |
| `ARGO_PORT` | Xray WS 本地监听端口（cloudflared 回源端口） | `8080` |
| `CFIP` | Cloudflare 优选 IP | `cdns.doon.eu.org` |
| `CFPORT` | Cloudflare 优选端口 | `443` |

## 菜单功能

```
1. 安装 Xray-2go
2. 卸载 Xray-2go
3. Argo 隧道管理（启动/停止/固定隧道/临时隧道切换）
4. 查看节点信息
5. 修改节点配置（UUID / Argo 端口 / 免流 Path[WS]）
```

## 免责声明

本程序仅供学习研究使用，非盈利目的，请于下载后 24 小时内删除，不得用作任何商业用途。使用本程序须遵守部署服务器所在地及用户所在国家和地区的相关法律法规，程序作者不对使用者任何不当行为承担责任。
