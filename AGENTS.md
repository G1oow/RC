# AGENTS.md

给在本仓库里动手的 AI 代理与协作者看的仓库约定。改代码前先读，改完按「验证清单」自查。

## 项目定位

**RC 是 VPS 聚合运维面板。** 一个 `rc` 面板把新机器的开荒流程串起来：SSH 加固 → 连通体检与 TCP 调优 → REALITY 伪装目标筛选，另有 24h ASN 扫描守护进程。

- **RC 不是 RealityChecker 的缩写**。不要用 `RealityChecker` 当项目全称，也不要用 `reality-checker-main` 当示例命令——它是发布产物别名，只出现在脚本与 CI 内部。
- 面板之外的扫描能力统一叫**「扫描引擎」**（代码与资产里的 `reality-checker` / `reasni` 是历史命名，属于功能路径，不要为了统一措辞去改它）。
- 内置 HTTP API 与 Web 控制台已下线，不要恢复。

## 仓库结构

| 路径 | 说明 |
|---|---|
| `rc.sh` | 面板本体。安装为 `/usr/local/bin/rc` 并建 `/usr/local/bin/RC` 软链；配置在 `/etc/rc-manager/rc.conf`（0600），日志 `/var/log/rc-manager.log`，备份 `/root/vps-init-backup` |
| `vps-init.sh` | 兼容壳，只转发到 `rc.sh`，不放逻辑 |
| `install.sh` / `install.ps1` | 引擎安装脚本（Linux / Windows），装到 `/root/rc-new` 或 `%USERPROFILE%\reality-checker` |
| `config.yaml`、`data/` | 引擎配置与内置资产（规则库、GeoIP） |
| `src/` | Go 扫描引擎：`internal/cmd` 子命令、`internal/core` 扫描与守护调度、`internal/detectors` 协议与伪装判定、`internal/storage` SQLite/PostgreSQL、`src/deploy/systemd` 服务单元 |
| `src/doc/` | VitePress 文档站（`pnpm docs:dev`） |

## 构建与测试

需要 Go 1.26+。**不需要** Node / pnpm 参与构建，只有文档站用 pnpm。

```bash
cd src
go build ./...
go vet ./...
go test ./...
```

脚本类改动做语法检查：`bash -n rc.sh vps-init.sh install.sh src/scripts/install.sh`。

## 代码约定

- **Go 子命令**：`flag.NewFlagSet` 解析，注册在 `src/internal/cmd/root.go` 的 switch 里；新增或删除子命令必须同步 `internal/cmd/usage.go` 与「可用命令」列表。
- **配置键**：新增键要同时改 `internal/types/types.go`、`internal/config/config.go`（默认值与合并逻辑）和 `config.yaml` 的注释示例。
- **`rc.sh`**：
  - 所有写操作走 `run()`，`DRY_RUN=1` 时只打印不执行；新增系统改动必须保留这个分支。
  - 改 SSH 前必须备份，改完 `sshd -t` 校验，失败自动回滚；不要绕过 `need_root`。
  - 面向用户的文案用中文，路径、命令、标识符保持英文。
- **守护进程兼容层**：`daemon` 的 `--port/--host/--token/--no-http` 是让旧 `/etc/default/reasni` 不因未知 flag 崩掉的空操作，不要删。

## 提交与 PR

- Conventional Commits，摘要用中文、≤50 字、动词开头、不加句号；类型取 `feat|fix|refactor|docs|test|chore|build|ci`。细分规则见 `src/.agent/rules/guidline.md`。
- 一个 commit 一件事，格式化与功能分开；每个 commit 要能编译通过。
- 不从本地直接推 `main`：走分支 + PR，合并信息用 merge commit。
- 版本 tag 形如 `v1.2.3`，push tag 会触发 `.github/workflows/build.yml` 构建三平台产物并发布 Release。

## 自动化与发布边界

协作代理默认只做到「提出变更」为止。下列动作必须由维护者明确指令，**不能**从「提 PR」「触发构建」「更新 tag」这类话里自行推断出前置步骤：

- **合并 PR**：`gh pr merge` 或任何合并动作。PR 创建完就停下，等维护者自己合并。
- **打 tag 与发布**：`git tag`、`git push origin <tag>`、`gh release create` / `edit` / `delete`。
- **改写已发布内容**：已发布 Release 的正文与资产、已推送的 tag。
- **重写历史**：`git push --force`、`git reset --hard`、`git rebase`、删除远端分支或 tag。

需要前置步骤才能继续时（例如「打 tag」要求改动先落在 `main` 上），只报告卡点与可选路径，不自行补齐。口径对照：用户说「提 PR」= 只创建 PR；说「触发构建」= 不包含合并 PR。

## 对外口径与脱敏

- 项目自称 **RC**；面板与引擎的措辞见「项目定位」。
- README 中英双份（`README.md` / `README.en.md`）必须同步改；英文版要注明菜单是中文的。
- 示例地址只用保留地址：`203.0.113.0/24`、`198.51.100.0/24`、`192.0.2.0/24`、`2001:db8::/32`、`example.com`。**不得**写入真实 IP、域名、Token、连接串。
- 面板 ASCII 预览要与 `rc.sh` 的 `menu_header` / `status_brief` 真实输出逐行一致，改了菜单就同步改 README。

## 验证清单

改完至少自查对应项：

1. `go build ./...`、`go vet ./...`、`go test ./...` 全绿（Go 改动）。
2. `bash -n` 通过（脚本改动）；`rc.sh` 的菜单/横幅可单独抽出 heredoc 跑一遍比对。
3. 对外口径：`grep -n "RealityChecker\|reality-checker-main\|/api/" README.md README.en.md` 应为空。
4. 文档内链指向真实存在的文件；`config.yaml` 里写的键名与代码一致。
5. 不提交 `data/*.db`、`src/data/`、`.pi/` 等运行或工具产物。

## 不要做

- 不要重新引入 `src/web`、`src/internal/server`、`serve` 子命令或任何 HTTP 监听。
- 不要改 go module 名 `RealityChecker`、发布资产名 `reality-checker-*`、`install.sh` 下载的 `reality-checker-main`（牵动 CI 与已发布资产）。
- 不要在未确认的情况下重写 git 历史、强推、删除 tag，或执行 `rc.sh` 里会改 SSH / 防火墙的分支。
- 不要把用户已有的本地改动顺手重构掉。
