# REALITY 目标检测与扫描系统 - 版本管理与编译部署规范文档

本文档规范了 REALITY 渐进式目标检测系统（`reality-checker`）的代码版本控制 (Git Version Control) 和二进制编译注入 (Go Build Flags Version Injection) 标准流程。

---

## 一、 代码版本控制规范 (Git Version Control)

项目代码托管于 Git 仓库中。请遵循以下标准 Git 工作流对新功能与补丁进行版本追踪。

### 1. 代码提交与分支管理

修改或新增代码后，在项目根目录（`RealityChecker/`）下执行：

```bash
# 1. 查看暂存状态
git status

# 2. 暂存相关代码变更
git add .

# 3. 编写符合规范的 Commit 信息
git commit -m "feat: 深度融合 RealiTLScanner 源码，增加 auto 和 pipe 渐进式流处理模式"
```

### 2. 规范化 Tag 标签管理

每当完成重大功能更新或发布稳定版本时，需打了带有语义化版本（Semantic Versioning, e.g. `v3.0.0`）的 Git Tag 标签：

```bash
# 打带注释的正式版本标签
git tag -a v3.0.0 -m "Release v3.0.0: 内嵌 RealiTLScanner 引擎，实现单文件原生并发渐进式扫描"

# 推送代码与标签至远程仓库
git push origin main --tags
```

---

## 二、 二进制编译与版本注入规范 (Go Dynamic Build Injection)

为了让编译出的二进制文件能够自报家门（如运行 `./reality-checker version`），我们利用 Go 编译期的 `-ldflags` 参数将 **Git 版本号 (Version)**、**提交哈希 (Commit Hash)** 及 **构建时间 (Build Time)** 动态注入到 `RealityChecker/internal/version` 包的全局变量中。

### 1. 自动化编译脚本示例 (`build.sh`)

项目提供了自动化构建脚本，建议使用该方式编译二进制：

```bash
#!/usr/bin/env bash

set -euo pipefail

# 1. 自动提取 Git 标记、哈希与构建时间
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "v3.0.0-dev")
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "custom")
BUILD_TIME=$(date -u '+%Y-%m-%d_%H:%M:%S')

echo "=========================================="
echo "正在构建 reality-checker 单二进制文件..."
echo "版本 (Version):    ${VERSION}"
echo "提交 (Commit):     ${COMMIT}"
echo "时间 (BuildTime):  ${BUILD_TIME}"
echo "=========================================="

# 2. 执行带 ldflags 注入的编译
go build -ldflags "-s -w \
  -X RealityChecker/internal/version.Version=${VERSION} \
  -X RealityChecker/internal/version.Commit=${COMMIT} \
  -X RealityChecker/internal/version.BuildTime=${BUILD_TIME}" \
  -o ../reality-checker .

echo "构建成功！产物位置: ../reality-checker"
```

### 2. 编译参数解释

- `-s -w`：剥离符号表与调试信息，可将二进制文件体积缩减约 20% ~ 30%。
- `-X package.variable=value`：在编译期修改 Go 变量的值，实现静态注入。

---

## 三、 版本校验与发布验证

编译完成后，可通过以下命令验证版本注入是否成功：

```bash
./reality-checker version
```

**预期标准输出格式**：

```text
Reality协议目标网站检测工具
版本: v3.0.0
提交: 1a76f16
构建时间: 2026-08-03_13:12:47
GitHub: https://github.com/G1oow/RC
```

---

## 四、 跨平台交叉编译 (Cross-Compilation)

由于系统已经深度融合了 `RealiTLScanner` 源码，不再依赖外部平台特定二进制文件，因此可以在单台机器上轻松编译出适用于所有目标架构的二进制：

### 编译 Linux AMD64 (x86_64)
```bash
GOOS=linux GOARCH=amd64 go build -ldflags "-s -w -X RealityChecker/internal/version.Version=${VERSION} -X RealityChecker/internal/version.Commit=${COMMIT} -X RealityChecker/internal/version.BuildTime=${BUILD_TIME}" -o reality-checker-linux-amd64 .
```

### 编译 Linux ARM64 (aarch64)
```bash
GOOS=linux GOARCH=arm64 go build -ldflags "-s -w -X RealityChecker/internal/version.Version=${VERSION} -X RealityChecker/internal/version.Commit=${COMMIT} -X RealityChecker/internal/version.BuildTime=${BUILD_TIME}" -o reality-checker-linux-arm64 .
```

### 编译 Windows AMD64
```bash
GOOS=windows GOARCH=amd64 go build -ldflags "-s -w -X RealityChecker/internal/version.Version=${VERSION} -X RealityChecker/internal/version.Commit=${COMMIT} -X RealityChecker/internal/version.BuildTime=${BUILD_TIME}" -o reality-checker-windows-amd64.exe .
```
