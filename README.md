<p align="center">
  <img src="./assets/icon.png" width="200" alt="RealityChecker 标志">
</p>

<h1 align="center">RealityChecker</h1>

<p align="center">面向 REALITY SNI 伪装目标的检测与选型工具链，附带一键部署与运维脚本。</p>

<p align="center">
  <a href="./README.md">English</a> | <a href="./README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/G1oow/RC/actions/workflows/build.yml"><img src="https://github.com/G1oow/RC/actions/workflows/build.yml/badge.svg" alt="Build and Release 工作流状态"></a>
  <img src="https://img.shields.io/badge/Go-1.26.0-3776AB?style=flat-square&logo=go" alt="Go 1.26.0">
  <img src="https://img.shields.io/badge/platform-linux--amd64%20%7C%20linux--arm64%20%7C%20windows--amd64-4B5563?style=flat-square" alt="Linux amd64、Linux arm64、Windows amd64 构建">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-22C55E?style=flat-square" alt="MIT 许可"></a>
</p>

RealityChecker 只回答一个问题：某段网络里，哪些公开站点还能通过真实的 REALITY 握手检验。它把 VPS 的 IP 展开成该 ASN 已宣告的网段，扫描这些网段，只保留真正协商到 TLS 1.3 + X25519 + HTTP/2 的主机，并把每条判定写进本地资产库。结果按协议支持、证书与 CDN 特征打 1-5 星，让你从证据里挑伪装域名，而不是靠猜。

## 亮点

| 能力 | 价值 |
|---|---|
| Linux 一键部署 | `install.sh` 下载发布产物、`config.yaml` 与 `data/` 数据文件，探测本机出口 IPv4/IPv6，并直接打印该跑的 `auto` 命令 |
| Windows 一键部署 | `install.ps1` 在 `%USERPROFILE%\reality-checker` 建立同样的目录结构 |
| 以服务方式常驻 | `src/deploy/systemd/reasni-daemon.service` 配合 `reasni.env`，用 systemd 托管 24h 扫描守护进程 |
| VPS 开荒面板 | `rc.sh` 安装为 `rc`，带新机器依次走 SSH 加固（备份 + `sshd -t` 校验 + 失败自动回滚）、TCP 质量检测、NQ 评分、TCP 调优，最后做 REALITY 目标筛选 |
| 协议层过滤 | 候选站点必须支持 TLS 1.3、X25519、HTTP/2；命中 CDN 节点、热门站点名单、nginx 默认页、跳转、被封域名或国内站点即淘汰 |
| 缓存优先 + 星级排序 | `get` 直接从本地 SQLite 资产库返回 1-5 星目标，不重复扫描（`--fresh` 强制重扫）；`serve` 用 REST 与 SSE 暴露同一份数据 |

## 架构

```text
┌────────────────────────────────────────────────────────────────────┐
│ cmd (src/main.go)                                                  │
│ get  auto  serve  daemon  patrol  asn  pipe  check  batch          │
└────────────────────────────────────────────────────────────────────┘
                                   │
┌──────────────────────────────────▼─────────────────────────────────┐
│ core.Engine  -  internal/core                                      │
│ auto_scanner  pipeline  filter  patrol  daemon                     │
└──────────┬───────────────────────┬───────────────────────┬─────────┘
           │                       │                       │
┌──────────▼─────────┐  ┌──────────▼─────────┐  ┌──────────▼─────────┐
│ internal/asn       │  │ internal/detectors │  │ internal/storage   │
│ RIPEstat prefixes  │  │ TLS1.3, X25519, h2 │  │ SQLite/PostgreSQL  │
│ country lookup     │  │ CDN/302/hot site   │  │ ASN + target store │
└────────────────────┘  └──────────┬─────────┘  └────────────────────┘
                                   │
                        ┌──────────▼─────────┐
                        │ target websites    │
                        └────────────────────┘

HTTP surface
┌──────────────────┐     ┌──────────────────────────────┐     ┌──────────────────┐
│ serve / daemon   │ ──▶ │ internal/server: REST + SSE  │ ──▶ │ embedded web UI  │
└──────────────────┘     └──────────────────────────────┘     └──────────────────┘
```

前端构建产物（`src/web`）被编译进 Go 二进制，`serve` 与 `daemon` 因此能在同一个进程里同时提供控制台页面与 `/api/*` 接口。

## 用法示例

`get` 先从资产库取结果，`auto` 把周边网段扫进库，`serve` 把结果集发布出去。

```bash
./reality-checker-main get 203.0.113.10 -n 5 -s 4
./reality-checker-main get 203.0.113.10 --json
./reality-checker-main auto 203.0.113.10 --limit 5
./reality-checker-main serve --port 8881
```

`get` 输出带星级的表格（加 `--json` 输出 JSON），只有加 `--fresh` 才会重扫。`auto` 并发扫描，最多保留 `--limit` 个合适目标。`serve` 监听 `:8881`，在 `/` 提供内嵌控制台，仅在配置了 token 时才要求鉴权。

## 快速安装

Linux：需要 bash、curl，且仓库已发布 release（脚本默认 `REF_TAG=latest`）。

```bash
curl -LfsS https://raw.githubusercontent.com/G1oow/RC/main/install.sh -o install.sh
bash install.sh            # 可选第一个参数：安装目录，默认 /root/rc-new
```

Windows PowerShell：

```powershell
.\install.ps1              # 可选第一个参数：安装目录，默认 %USERPROFILE%\reality-checker
```

从源码构建。需要 Go 1.26、Node 22 与 pnpm 9，前端必须先构建并嵌入，否则 `go build` 会失败：

```bash
cd src && ./build.sh
```

Windows 下改用 `.\src\build.ps1`，两个脚本产物相同：`dist/reality-checker-linux-amd64`、`dist/reality-checker-linux-arm64`、`dist/reality-checker-windows-amd64.exe`。

## 快速开始

```bash
cd /root/rc-new
./reality-checker-main auto 203.0.113.10 --limit 5
```

只填 IPv4 会展开成该地址的 `/24`，只填 IPv6 展开成 `/64`，填 CIDR 则按原样扫描。启动时会先探测公网出口 IP，探测失败（离线主机、探测端点不可达）需追加 `-f`。判定结果写入 `data/reality_targets.db`。

## 命令

| 命令 | 作用 |
|---|---|
| `get <ip> [-n 5] [-s 3] [--fresh] [--json]` | 按 IP 取星级目标，缓存优先 |
| `auto <ip/cidr> [--limit 5] [-v]` | 查输入的 ASN 网段并并发扫描入库 |
| `serve [--port 8881] [--host 0.0.0.0] [--token TOKEN]` | 启动 REST/SSE 服务与内嵌控制台 |
| `daemon [-t 500] [--interval 10] [--country US]` | 启动 24h 全网 ASN 扫描守护进程 |
| `patrol [--daemon]` | 对库内资产复测并做生命周期维护 |
| `asn <ASN> <国家> [--stats] [--seed]` | 查询 ASN 已宣告网段并按国家过滤 |
| `pipe` | 从标准输入流式读取目标 |
| `check <domain>` | 检测单个域名 |
| `batch <d1> <d2> ...` | 批量检测多个域名 |
| `migrate [--from ...] [--to ...]` | 在 SQLite 与 PostgreSQL 之间迁移资产库 |
| `version` | 输出版本、提交与构建时间 |

全局选项：`-c, --config FILE`、`-f, --force`。

## HTTP 接口

`serve` 与 `daemon` 提供 `/api/health`、`/api/stats`、`/api/filter/default`、`/api/targets/smart`、`/api/targets/stream`（SSE）、`/api/targets/check`、`/api/targets`、`/api/targets/{domain}`、`/api/asns`。默认不鉴权，可用 `--token`、`RC_API_TOKEN` 或配置里的 `server.api_token` 开启。

## 配置

`config.yaml` 的查找顺序为 `-c/--config`、环境变量、当前目录、二进制所在目录。

| 配置项 | 作用 |
|---|---|
| `database.driver` | `sqlite`（代码内置默认）或 `postgres`；仓库内的配置文件当前选了 `postgres`，`host: 127.0.0.1` |
| `database.sqlite.path` | 资产库路径，默认 `data/reality_targets.db` |
| `reality_filter.scan_threads` | 扫描并发，默认 `200` |
| `reality_filter.scan_timeout` | 单 IP 握手超时秒数，默认 `3` |
| `reality_filter.require_no_cdn` / `require_no_cn` | 剔除 CDN 节点与国内站点 |
| `reality_filter.check_gfw` | 静态 GFW 名单开关（仓库配置中为关闭） |
| `reality_filter.use_cache` / `cache_max_days` | 缓存优先与缓存有效天数，默认 7 天 |

## 文档

| 主题 | 内容 | 链接 |
|---|---|---|
| 以服务运行 | systemd 单元与环境变量模板 | [src/deploy/systemd/README.md](./src/deploy/systemd/README.md) |
| 构建与发布 | 交叉编译、内嵌资源、CI 入口 | [src/build.sh](./src/build.sh) |
| 开发文档 | 架构、数据库生命周期、扫描器设计 | [src/doc/dev](./src/doc/dev) |
| 文档站源码 | VitePress 首页与导航 | [src/doc/index.md](./src/doc/index.md) |
| 全部选项 | 每个配置项的注释说明 | [config.yaml](./config.yaml) |

## 许可

本项目使用 [MIT 许可证](./LICENSE)。
