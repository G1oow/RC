<p align="center">
  <img src="./assets/icon.png" width="200" alt="RC 标志">
</p>

<h1 align="center">RC</h1>

<p align="center">VPS 聚合运维面板：SSH 加固、连通体检与调优、REALITY 伪装目标筛选，收在一个 <code>rc</code> 里。</p>

<p align="center">
  <a href="./README.en.md">English</a> | <a href="./README.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/G1oow/RC/actions/workflows/build.yml"><img src="https://github.com/G1oow/RC/actions/workflows/build.yml/badge.svg" alt="Build and Release 工作流状态"></a>
  <img src="https://img.shields.io/badge/Go-1.26.0-3776AB?style=flat-square&logo=go" alt="Go 1.26.0">
  <img src="https://img.shields.io/badge/platform-linux--amd64%20%7C%20linux--arm64%20%7C%20windows--amd64-4B5563?style=flat-square" alt="Linux amd64、Linux arm64、Windows amd64 构建">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-22C55E?style=flat-square" alt="MIT 许可"></a>
</p>

RC 是一台新 VPS 从开荒到可用的统一入口。装好面板后输入 `rc` 进菜单：先把 SSH 收干净（公钥、端口、关闭密码登录，改错可以回滚），再体检与调优 TCP（TcpQuality / NodeQuality / tcpfit）、顺手把 sing-box 面板（singbox-lite，命令名 `sb`）装起来，最后在同一台机器上筛出适合做 REALITY 伪装的域名。所有阶段都在一个菜单里，不用再记一堆一次性脚本的 URL。

面板本身不含扫描逻辑：选目标这一步交给随附的扫描引擎。引擎由面板自动安装并调用，也可以独立以 CLI 或 systemd 守护进程运行。

## 面板长这样

装好后输入 `rc`，看到的就是这一屏：横幅下面三行环境摘要（系统、SSH 端口、密码登录、公钥条数、ufw、TCP 拥塞控制算法、引擎 / tcpfit / sb 状态），再按五个分区列出 16 个入口。

```text
  ____   ____
 |  _ \ / ___|
 | |_) | |
 |  _ <| |___
 |_| \_\____|  VPS 聚合面板

  rc v1.5.0   (实机执行)

  系统: Debian GNU/Linux 13  |  SSH 端口: 30000  |  密码登录: no
  公钥: 1 条  |  ufw: 已启用  |  拥塞控制: BBRv3
  引擎: 已安装  |  tcpfit: 已安装  |  sb: 已安装

【SSH 加固】
    1) 写入公钥+改端口      2) 只改端口
    3) 关闭密码登录         4) 回滚 SSH 配置

【体检与调优】
    5) TCP 质量检测         6) NQ 测试
    7) TCP 调优(tcpfit)
    8) sing-box 面板(sb)

【目标筛选】
    9) Reality 目标扫描     10) 重装扫描引擎

【维护】
   11) 默认设置            12) 更新 rc
   13) 查看执行日志

【危险】
   14) 卸载 rc（含引擎/tcpfit）
   15) 模块单独卸载
   16) 查看当前 SSH 端口

  ─────────────────────────────────────────
    0) 退出

  请选择 [0-16]:
```

## 面板能力

| 分区 | 入口 | 做什么 |
|---|---|---|
| SSH 加固 | `1` 写入公钥 + 改端口 | 追加公钥、改 SSH 端口、放行防火墙；切换成功后只保留新端口，旧端口（含默认 22）停止监听；改前备份到 `/root/vps-init-backup`，改后 `sshd -t` 校验并复核监听，失败自动回滚 |
| SSH 加固 | `2` 只改端口 / `3` 关闭密码登录 / `4` 回滚 | 分步收紧；关闭密码登录会先确认新端口可登录；回滚可还原到任一份备份。旧 ufw 规则不会自动删除 |
| 体检与调优 | `5` TCP 质量检测 / `6` NQ 测试 / `7` TCP 调优 | 依次拉起 TcpQuality、NodeQuality、tcpfit，测完再按面板提示调整内核参数 |
| 体检与调优 | `8` sing-box 面板（sb） | 一键安装 [singbox-lite](https://github.com/G1oow/singbox-lite)：下载 `singbox.sh` 到 `/usr/local/bin/sb`、校验后直接进入它的菜单；已装过则跳过下载直接进菜单。sing-box / Xray 核心由 `sb` 菜单按需安装 |
| 目标筛选 | `9` Reality 目标扫描 | 每次都重新询问扫描 IPv4 / IPv6 / 双栈（不记忆上次选择），再调用引擎按 ASN 网段扫描；同 ASN 找不到合适目标时自动回退同地区（同国家）继续找 |
| 目标筛选 | `10` 重装扫描引擎 | 引擎缺失或损坏时按需重装到 `RC_DIR` |
| 维护 | `11` 默认设置 / `12` 更新 rc / `13` 查看执行日志 | 改 SSH 端口、公钥、扫描目录与条数上限、备份保留份数、SSH 自动回滚；自更新面板，更新完直接载入新版本（不再回到旧面板）；查看 `/var/log/rc-manager.log` |
| 危险 | `14` 卸载 rc | 删除 `rc`、`RC` 软链接、引擎目录、tcpfit（含 iperf3）、`/etc/rc-manager` 与日志；保留 SSH 改动、备份目录、资产库备份与 `/usr/local/bin/sb`（由 `sb` 菜单的卸载项自行清理）。tcpfit 卸载前会问是否回滚内核调优，默认**不回滚**（选择保留调优时 tcpfit 与 iperf3 都不动） |
| 危险 | `15` 模块单独卸载 | 只卸某一个模块：扫描引擎 / tcpfit / iperf3 / rc 配置与日志 |
| 危险 | `16` 端口开关 | 列出配置中的 SSH 端口与监听状态，可开启已关闭端口或关闭其中一个，唯一 SSH 端口禁止关闭 |

面板对系统是有副作用的：`DRY_RUN=1` 下所有改动只打印不执行，第一次使用建议先试跑一遍。

## 安装

Debian / Ubuntu，root 权限，一行装完直接进面板：

```bash
curl -fsSL https://raw.githubusercontent.com/G1oow/RC/main/rc.sh | bash
```

脚本会把自己装到 `/usr/local/bin/rc`，创建 `/usr/local/bin/RC` 软链接，然后直接打开菜单；非 root 用 `| sudo bash`，只想安装不启动用 `| bash -s -- install-self`。扫描引擎不需要手动装：执行 `9) Reality 目标扫描` 时面板会把它下载到 `RC_DIR`（默认 `/root/rc-new`）。sing-box 面板同样不用手动装：执行 `8) sing-box 面板(sb)` 会把它装到 `/usr/local/bin/sb` 并直接进菜单。

## 子命令

菜单之外每个动作都有对应的非交互子命令，方便脚本化：

| 命令 | 作用 |
|---|---|
| `rc` | 进入交互菜单（默认行为） |
| `rc ssh` | 写入公钥 + 改 SSH 端口 + 放行防火墙 |
| `rc ssh-close` | 确认新端口可登录后关闭密码登录 |
| `rc ssh-ports` | 查看 SSH 端口并交互开启/关闭；唯一 SSH 端口禁止关闭 |
| `rc tcpq` | TCP 质量检测（TcpQuality） |
| `rc score` | NQ 测试（NodeQuality） |
| `rc tune` | TCP 调优（tcpfit） |
| `rc sb` | 一键安装 sing-box 面板（singbox-lite）并进入其菜单 |
| `rc reality` | REALITY 伪装目标筛选 |
| `rc status` | 查看系统、SSH 端口、ufw、TCP 拥塞控制算法、引擎、tcpfit 与 sb 状态 |
| `rc rollback` | 回滚 SSH 配置（`--yes` 跳过确认；默认同时还原 `/etc/ssh` 与 socket drop-in） |
| `rc rollback-cancel` | 取消排定的 SSH 自动回滚 |
| `rc install-self` | 把面板安装/修复到 `/usr/local/bin/rc` |
| `rc update` | 更新面板自身（非交互更新，更新后重新输入 `rc` 进入新版本） |
| `rc uninstall` | 卸载面板 + 已装引擎 + tcpfit + iperf3 |
| `rc uninstall engine\|tcpfit\|iperf3\|conf` | 只卸载指定模块 |
| `rc help` | 显示帮助 |

旧参数 `0` / `0b` / `1` / `2` / `3` / `4` 仍然可用，等同于对应子命令（`5` 等价 `rc sb`）。`rc ssh` 和 `rc ssh-ports` 修改端口前会备份 `/etc/ssh`（socket 模式另存 drop-in），校验失败、重载失败或端口复核不一致都会恢复本次快照。仓库根目录的 `vps-init.sh` 只是转发到 `rc.sh` 的兼容壳，不含逻辑。

## 面板与引擎

`rc reality` 会先确保引擎就绪，然后**每次都询问**本次扫描的协议族（IPv4 / IPv6 / 双栈，不记忆上一次的选择），再调用引擎扫描并打印结果。目标域名的选型标准由引擎负责：同 ASN / 同机房、非公共 CDN、非热门大站、TLS 1.3 + X25519 + HTTP/2 握手真实可用、证书剩余有效期足够、握手延迟低；同 ASN 命中不足时回退到同国家（同地区）的其它 ASN 与本地历史资产。默认保留 10 个目标。

引擎独立运行时保留完整 CLI 能力，面板只是它的一个调用方：

| 引擎命令 | 作用 |
|---|---|
| `get <ip> [-n 5] [-s 3] [--fresh] [--json]` | 按 IP 取星级目标，缓存优先 |
| `auto <ip/cidr> [--limit 10] [--ipv4-only\|--ipv6-only] [-v]` | 查输入的 ASN 网段并并发扫描入库；同 ASN 不足时回退同国家 |
| `daemon [-t 500] [--interval 10] [--country US]` | 24 小时全网 ASN 扫描守护进程 |
| `patrol [--daemon]` | 对库内资产复测并做生命周期维护 |
| `asn <ASN> <国家> [--stats] [--seed]` | 查询 ASN 已宣告网段并按国家过滤 |
| `pipe` | 从标准输入流式读取目标 |
| `check <domain>` | 检测单个域名 |
| `batch <d1> <d2> ...` | 批量检测多个域名 |
| `migrate [--from ...] [--to ...]` | 在 SQLite 与 PostgreSQL 之间迁移资产库 |
| `version` | 输出版本、提交与构建时间 |

引擎的安装脚本 `install.sh` 把它装进 `/root/rc-new`，同时带上 `config.yaml` 与 `data/` 数据文件；判定结果写入 `data/reality_targets.db`。

## 架构

```text
          ┌─────────────────────────────────────────────────────┐
   你 ──▶ │ rc 面板（rc.sh → /usr/local/bin/rc）                 │
          │ ① SSH 加固  ② 体检与调优  ③ 目标筛选  ④ 维护         │
          └───────────────┬─────────────────────────────────────┘
                          │ rc reality：探出口 IP + 调引擎
          ┌───────────────▼─────────────────────────────────────┐
          │ 扫描引擎（/root/rc-new）                             │
          │ ASN 网段展开 → 并发 TLS 握手 → 协议/伪装过滤 → 入库   │
          └───────────────┬─────────────────────────────────────┘
                          │
          ┌───────────────▼─────────────────────────────────────┐
          │ reasni-daemon.service：24h ASN 轮转扫描与资产巡检     │
          └─────────────────────────────────────────────────────┘
```

面板与引擎都是纯 Go / Bash 产物，不依赖 Node 与前端构建；引擎二进制由 CI 交叉编译发布。

## 配置

面板设置持久化在 `/etc/rc-manager/rc.conf`（0600），同名环境变量优先级更高：

| 键 | 默认值 | 作用 |
|---|---|---|
| `SSH_PORT` | `30000` | 目标 SSH 端口 |
| `SSH_PUBKEY` / `SSH_PUBKEY_FILE` | 空 | 要写入的公钥内容或公钥文件路径 |
| `RC_DIR` | `/root/rc-new` | 扫描引擎安装目录 |
| `SCAN_LIMIT` | `10` | `rc reality` 保留的目标条数上限 |
| `DRY_RUN` | `0` | `1` 时所有改动只打印不执行 |
| `BACKUP_ROOT` | `/root/vps-init-backup` | SSH 配置备份目录 |
| `RC_BACKUP_KEEP` | `10` | 备份目录里每类备份保留的份数 |
| `RC_SSH_AUTO_ROLLBACK_MIN` | `0` | 改完 SSH 后 N 分钟自动回滚（0 = 关闭，需要 `systemd-run` 或 `at`） |

引擎侧的 `config.yaml` 与面板解耦，主要配置项：

| 配置项 | 作用 |
|---|---|
| `database.driver` | `sqlite`（内置默认）或 `postgres` |
| `database.sqlite.path` | 资产库路径，默认 `data/reality_targets.db` |
| `reality_filter.scan_threads` | 扫描并发，默认 `200` |
| `reality_filter.scan_timeout` | 单 IP 握手超时秒数，默认 `3` |
| `reality_filter.ipv6_budget` | IPv6 单网段探针预算，默认 `4096`（IPv6 主机位按伪随机 IID 稀疏采样） |
| `reality_filter.require_no_cdn` / `require_no_cn` | 剔除 CDN 节点与国内站点 |
| `reality_filter.check_gfw` | 静态 GFW 名单开关 |
| `reality_filter.use_cache` / `cache_max_days` | 缓存优先与缓存有效天数，默认 7 天 |
| `proxy.url` / `proxy.scanner` | 引擎下载与扫描的出站代理 |

## 升级提示

早期版本内置过 HTTP API 与 Web 控制台，现已整体移除：面板、CLI 与 systemd 守护进程不再监听任何端口。若 `/etc/default/reasni` 的 `DAEMON_OPTS` 里还留着 `--port` / `--host` / `--token` / `--no-http`，引擎会打印提示并忽略这些参数，建议直接删掉，只保留 `-t` 与 `--interval`。

## 文档

| 主题 | 内容 | 链接 |
|---|---|---|
| 以服务运行 | systemd 服务单元、`/etc/default/reasni` 与运维命令 | [src/deploy/systemd/README.md](./src/deploy/systemd/README.md) |
| 构建与发布 | 交叉编译、内嵌资源、CI 入口 | [src/build.sh](./src/build.sh) |
| 开发文档 | 架构、数据库生命周期、扫描器设计 | [src/doc/dev](./src/doc/dev) |
| 文档站源码 | VitePress 首页与导航 | [src/doc/index.md](./src/doc/index.md) |
| 全部选项 | 每个配置项的注释说明 | [config.yaml](./config.yaml) |

## 许可

本项目使用 [MIT 许可证](./LICENSE)。

仅用于网络技术研究与学习，请遵守当地法律法规并合理使用网络资源。
