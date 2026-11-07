# Reality 目标检测 reality-checker

自动扫描并筛选适合做 **Xray / sing-box REALITY 伪装目标（fallback SNI）** 的真实网站域名。

程序会硬性校验 TLS 1.3、X25519、HTTP/2、证书有效性、SNI 匹配、非国内站点，并按是否 CDN、是否热门大站、握手延迟、证书剩余天数、页面状态综合打星，只输出真正可用的目标。

> 配套程序由 **GitHub Actions 从 `main` 构建并发布到 Releases**。上游流传的 `v2.2.3`（csv 命令只取第 3 列）与 `v1.1.2` release（证书校验 bug，结果恒为 0）**均不可用**，请只使用本仓库的 release。

---

## 一键指令

装完会自动探测本机出口 IP：检测到双栈时会让你选 IPv4 还是 IPv6，选完回车即可开始扫描。

### Linux（VPS / Debian / Ubuntu）

```bash
curl -fsSL https://raw.githubusercontent.com/G1oow/RC/main/install.sh | bash
```

默认安装到 `/root/rc-new`，完成后直接跑：

```bash
cd /root/rc-new && ./reality-checker-main auto <你的VPS_IP> --limit 5
```

自定义目录：

```bash
curl -fsSL https://raw.githubusercontent.com/G1oow/RC/main/install.sh | bash -s -- /opt/rc
```

### Windows（PowerShell）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/G1oow/RC/main/install.ps1 | iex"
```

默认安装到 `%USERPROFILE%\reality-checker`，完成后直接跑：

```powershell
cd "$env:USERPROFILE\reality-checker"; .\reality-checker-main.exe auto <你的VPS_IP> --limit 5
```

自定义目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $env:REF='main'; irm https://raw.githubusercontent.com/G1oow/RC/main/install.ps1 -OutFile $env:TEMP\rc-install.ps1; & $env:TEMP\rc-install.ps1 'D:\rc' }"
```

### 一键指令做了什么

1. 下载对应平台的主程序（`reality-checker-main` / `reality-checker-main.exe`）；
2. 解除执行限制（Linux `chmod +x`，Windows `Unblock-File`）；
3. 拉取 `config.yaml` 与 `data/` 下的离线规则库（国家 IP 库、GFW 列表、CDN 特征、热门站点特征、排除规则）；
4. 自动探测本机出口 IP：只有 IPv4 或只有 IPv6 就直接采用；**双栈时让你选 1) IPv4 / 2) IPv6**（选 IPv6 会附加 `-6`）；都探测不到则提示手动输入；
5. 打印完整运行命令，问一句「现在开始扫描？」，回车即开始（默认不跑）。

全程只往指定目录写文件，不改动系统配置。全自动场景（无终端、`curl | bash` 到 CI）会自动降级为默认值，不会卡住。装完后可执行 [`rc`](#rc-面板vps-开荒向导) 进面板做 SSH 加固与目标扫描。

> 探测走 `api4.ipify.org` / `api6.ipify.org`，失败时回退 `icanhazip.com`。入口 IP 只用于反查 ASN 网段，不会外传。

---

## rc 面板（VPS 开荒向导）

> 标签：`#面板` `#启动方式`

`rc` 是配套的单文件管理面板：一条命令装到 `/usr/local/bin/rc` 并直接进面板，之后输入 `rc`（或大写 `RC`）即可再次打开。SSH 加固、体检调优、目标筛选都在一个菜单里，不用记参数。

### 安装与启动

```bash
# 安装到 /usr/local/bin/rc，装完直接进面板
curl -LfsS https://raw.githubusercontent.com/G1oow/RC/main/rc.sh \
  -o /usr/local/bin/rc && chmod +x /usr/local/bin/rc && rc
```

以后只需：

```bash
rc
```

首次在仓库内执行、或 `curl | bash` 执行时，脚本会先把自身装到 `/usr/local/bin/rc`，再打开面板；重复执行是幂等的。

### 面板功能

| 分类 | 编号 | 功能 |
|---|---|---|
| SSH 加固 | 1 | 写入公钥 + 改 SSH 端口 + 放行防火墙（阶段 0） |
|  | 2 | 只改 SSH 端口 |
|  | 3 | 关闭密码登录（阶段 0b，需先确认新端口可登入） |
|  | 4 | 回滚 SSH 配置 |
| 体检与调优 | 5 | TCP 质量检测（TcpQuality） |
|  | 6 | NQ 测试（NodeQuality） |
|  | 7 | TCP 调优（tcpfit） |
| 目标筛选 | 8 | Reality 伪装目标扫描（reality-checker） |
|  | 9 | 重装 reality-checker |
| 维护 | 10 | 默认设置（端口、公钥、扫描目录、条数、DRY_RUN） |
|  | 11 | 更新 rc |
|  | 12 | 查看执行日志 |
| 危险 | 13 | 卸载 rc |
| 退出 | 0 | 退出 |

### 非交互子命令

```bash
rc ssh           # 阶段 0：公钥 + 端口
rc ssh-close     # 阶段 0b：关闭密码登录
rc tcpq          # TCP 质量检测
rc score         # NQ 测试（NodeQuality）
rc tune          # TCP 调优
rc reality       # Reality 目标扫描
rc status        # 各组件状态
rc rollback      # 回滚 SSH 配置
rc update        # 更新 rc 自身
rc uninstall     # 卸载 rc
```

旧的阶段写法 `./vps-init.sh 0 | 0b | 1 | 2 | 3 | 4 | 5 | rollback` 仍然可用，`vps-init.sh` 现在只是转发到 `rc.sh` 的兼容壳。

### 参数与试跑

默认值持久化在 `/etc/rc-manager/rc.conf`（`0600`），同名环境变量优先级更高：

```bash
SSH_PORT=22022 rc ssh                    # 指定端口
SSH_PUBKEY_FILE=/root/k.pub rc ssh       # 从文件读公钥
DRY_RUN=1 rc ssh                         # 只打印，不落盘
```

改 SSH 前请务必：先在云厂商安全组放行新端口 → 保持当前会话不断开 → 另开终端 `ssh -p <新端口> root@<VPS_IP>` 验证 → 确认能登入后再 `rc ssh-close`。配置校验失败会自动回滚，回滚记录在 `/root/vps-init-backup`。

### 卸载

面板 `13` 或 `rc uninstall`，只删 `rc`、`RC`、`/etc/rc-manager` 与日志；已装的 reality-checker、tcpfit 和 SSH 备份目录都保留。

---

## 手动部署

主程序不再随仓库分发，统一从 Releases 获取：

```bash
mkdir -p /root/rc-new && cd /root/rc-new
curl -fL -o reality-checker-main \
  https://github.com/G1oow/RC/releases/latest/download/reality-checker-main
chmod +x reality-checker-main
./reality-checker-main auto <你的VPS_IP> --limit 5
```

指定版本时把 `latest` 换成对应 tag：`.../releases/download/<tag>/reality-checker-main`。

Windows 直接双击 `reality-checker-main.exe` 或按上面 PowerShell 命令运行。

**注意：`data/` 目录必须与主程序同级**，否则启动时会尝试从 GitHub 拉规则库，网络不好就会失败。

---

## 源码与自编译

完整源码在 [`src/`](./src)，取自上游 [qualvey/one-reality](https://github.com/qualvey/one-reality) 的 main 分支 —— 即修复了 `v2.2.3` csv 解析 bug 与 `v1.1.2` 证书校验 bug 的那条分支。Go + React 双端。

```bash
cd src
./build.sh          # Linux，产物输出到 src/dist/
```

```powershell
cd src
.\build.ps1         # Windows
```
构建脚本会自动校验（缺失则下载）`internal/data/assets/Country.mmdb` 用于内置 GeoIP，国内网络先在 `src/config.yaml` 配好 `proxy` 再构建。产物默认名为 `reality-checker`，需要与其他脚本对齐时用 `APP_NAME=reality-checker-main` 覆盖。构建不依赖源码目录下的 `src/data/`；运行时若需外部规则库，直接读主程序同级的 `data/`。

**产物不再提交进仓库**：推 tag（`git tag v1.0.0 && git push origin v1.0.0`）会触发 `.github/workflows/build.yml` 自动构建 Linux/Windows 产物并发布 Release，`install.sh` / `install.ps1` 从 Release 下载。

**顺序要求**：`web/dist` 是 `go:embed` 的编译依赖，必须先构建前端再编译 Go，否则报 `pattern dist/*: no matching files found`。环境：Go 1.26+、pnpm。

---

## 常用命令

```bash
# 全自动：查 ASN -> 拉同国家网段 -> 并发扫描 -> 按星级输出
./reality-checker-main auto <IP/CIDR> --limit 5

# 流式检测 RealiTLScanner 的 CSV 结果
cat file.csv | ./reality-checker-main pipe

# 检测单个域名
./reality-checker-main check <已知可用的域名>

# 批量检测
./reality-checker-main batch apple.com tesla.com microsoft.com

# 查询某 ASN 的网段
./reality-checker-main asn AS15169 US > asn.txt
./reality-checker-main auto --in asn.txt --limit 10

# 只要 IPv6 目标
./reality-checker-main auto 2001:db8::/64 --limit 5 -6
```

`auto` 常用参数：`--limit/-m`、`--check-all/-a`、`--threads/-t`、`--timeout`、`--ipv4-only/-4`、`--ipv6-only/-6`、`--allow-cdn`、`--allow-hot`、`--min-stars`、`--max-handshake`、`--country`、`--export`、`-v`。

完整参数说明见下方「常用命令」与 `reality-checker-main --help`，结果列含义见「挑选建议」。

---

## 挑选建议

只看 **推荐星级** 列：能拿到 5 星就用 5 星；同星级选手握时间最低的；实际配置前把前 2~3 个都试连一次。

星级门槛、延迟上限、证书最低天数、CDN/热门过滤、代理等全部在 `config.yaml` 里，改完立即生效，无需重编译。

---

## 常见问题

| 现象 | 处理 |
|---|---|
| `Permission denied` | `chmod +x reality-checker-main`（每次 `scp` 后都要重做） |
| 结果恒为 0 | 先 `./reality-checker-main check <已知可用的域名>` 自检；目标机房全是 CDN 时加 `--allow-cdn` |
| 扫描很慢 | 降低 `--timeout`，1 核机器并发别超过 200 |
| 程序卡死 | 另开终端 `kill -QUIT $(pidof reality-checker-main)` 抓协程堆栈，然后调低 `--threads` |
| 规则库下载失败 | 确认 `data/` 五个文件都在，或在 `config.yaml` 的 `proxy.download` 走代理 |

---

## 文件说明

| 文件 | 说明 |
|---|---|
| `reality-checker-main` | Linux 主程序（从 Releases 下载，不再入库） |
| `reality-checker-main.exe` | Windows 主程序（从 Releases 下载，不再入库） |
| `config.yaml` | 过滤策略与运行参数 |
| `data/` | 离线规则库（必须与主程序同级） |
| `file.csv` | 历史扫描结果样例（已脱敏，IP/域名均为示例值），可直接 `pipe` 喂入 |
| `install.sh` / `install.ps1` | 一键部署脚本 |
| `rc.sh` | `rc` 面板主脚本（装到 `/usr/local/bin/rc`，SSH 加固 / 体检 / 选目标） |
| `vps-init.sh` | 兼容壳，旧阶段参数 `0/0b/1-5/rollback` 转发到 `rc.sh` |
| `src/` | 完整源码（Go + React，含 build.sh / build.ps1） |

---

**免责声明**：本工具仅用于网络技术研究与学习，请遵守当地法律法规，合理使用网络资源。
