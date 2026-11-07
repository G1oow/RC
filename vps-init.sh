#!/usr/bin/env bash
# vps-init.sh —— 兼容壳（旧阶段脚本已并入 rc.sh，保留文件名与全部旧参数）
#
# 旧用法仍然可用：
#   ./vps-init.sh 0 | 0b | 1 | 2 | 3 | 4 | 5 | rollback
# 推荐的用法是安装后直接进面板：
#   curl -fsSL https://raw.githubusercontent.com/G1oow/RC/main/rc.sh | bash
#
# 本壳只做转发，不含逻辑；完整功能见同目录 rc.sh。

set -Eeuo pipefail

here="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n ${BASH_SOURCE[0]:-} && ${BASH_SOURCE[0]} != "$0" ]]; then
  # 被 source：不 exec，避免顶掉调用方 shell
  if [[ -f "${here}/rc.sh" ]]; then
    bash "${here}/rc.sh" "$@"
  elif [[ -x /usr/local/bin/rc ]]; then
    /usr/local/bin/rc "$@"
  else
    printf '\033[31mfail\033[0m 找不到 rc.sh，也没安装 rc\n' >&2
  fi
  return 0 2>/dev/null || exit 0
fi

if [[ -f "${here}/rc.sh" ]]; then
  printf '\033[33mnote\033[0m vps-init.sh 已并入 rc.sh，建议直接使用 rc\n' >&2
  exec bash "${here}/rc.sh" "$@"
fi

if [[ -x /usr/local/bin/rc ]]; then
  printf '\033[33mnote\033[0m vps-init.sh 已并入 rc，已转发到 /usr/local/bin/rc\n' >&2
  exec /usr/local/bin/rc "$@"
fi

printf '\033[31mfail\033[0m 找不到 rc.sh，也没安装 rc。先执行：\n' >&2
printf '  curl -fsSL https://raw.githubusercontent.com/G1oow/RC/main/rc.sh | bash\\n' >&2
exit 1
