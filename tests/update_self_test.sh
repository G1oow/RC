#!/usr/bin/env bash
set -Eeuo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export RC_LIB_ONLY=1
# shellcheck source=../rc.sh
. "$repo/rc.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
case_name() { printf 'PASS: %s\n' "$1"; }

mkdir -p "$tmp/bin"
VPS_INIT_ALLOW_NONROOT=1
DRY_RUN=0
SELF="$tmp/bin/rc"
need_curl() { :; }
log_record() { :; }
# 远端脚本桩：内容由 REMOTE_VERSION 决定，模拟拿到新版本
remote_script() { printf "#!/usr/bin/env bash\nRC_VERSION='%s'\nprintf \"NEW_PANEL %s\\\\n\"\n" "$1" "$1"; }
fetch_self() { remote_script "$REMOTE_VERSION" >"$1"; }

printf '#!/usr/bin/env bash\nprintf "OLD_PANEL\\n"\n' >"$SELF"
chmod 755 "$SELF"
RC_VERSION='1.0.0'

# 1. 菜单里的更新：必须 exec 新脚本，不能再回到旧面板
REMOTE_VERSION='2.0.0'
out="$(update_self --restart; printf 'STILL_OLD_PANEL\n')" || fail '更新并重载失败'
[[ $out == *'NEW_PANEL 2.0.0'* ]] || fail "更新后未进入新版本面板：$out"
[[ $out != *'STILL_OLD_PANEL'* ]] || fail '更新后仍继续执行旧脚本'
[[ $out == *'重载面板'* ]] || fail '缺少重载面板提示'
grep -qF 'NEW_PANEL 2.0.0' "$SELF" || fail "$SELF 未写入新版本"
[[ -f ${SELF}.bak ]] || fail '缺少旧版本备份'
grep -qF 'OLD_PANEL' "${SELF}.bak" || fail '备份不是旧版本'
case_name '更新成功后 exec 新版本面板'

# 2. 非交互更新（rc update）：只提示，不替换当前进程
RC_VERSION='2.0.0'
REMOTE_VERSION='2.1.0'
out="$(update_self; printf 'AFTER_UPDATE\n')" || fail '非交互更新失败'
[[ $out == *'AFTER_UPDATE'* ]] || fail 'rc update 不应替换进程'
[[ $out == *'重新输入 rc 进入新版本'* ]] || fail '缺少手动进入新版本提示'
case_name 'rc update 不重启面板'

# 3. 已是最新版本：不重启
RC_VERSION='2.1.0'
REMOTE_VERSION='2.1.0'
out="$(update_self --restart; printf 'AFTER_LATEST\n')" || fail '已是最新版本时应正常返回'
[[ $out == *'已是最新版本'* ]] || fail '缺少已是最新版本提示'
[[ $out == *'AFTER_LATEST'* ]] || fail '已是最新版本时不应重启面板'
case_name '已是最新版本不重启'

# 4. DRY_RUN：只打印，不真正 exec
RC_VERSION='2.1.0'
REMOTE_VERSION='3.0.0'
DRY_RUN=1
out="$(update_self --restart; printf 'AFTER_DRY\n')" || fail 'DRY_RUN 更新失败'
[[ $out == *'[dry] exec'* ]] || fail 'DRY_RUN 应打印 exec 而不执行'
[[ $out == *'AFTER_DRY'* ]] || fail 'DRY_RUN 不应替换进程'
DRY_RUN=0
case_name 'DRY_RUN 不重启面板'
# 5. 菜单 12 分支：更新后直接进新面板，不再回到旧菜单
RC_VERSION='3.0.0'
REMOTE_VERSION='3.1.0'
printf '#!/usr/bin/env bash\nprintf "OLD_PANEL\\n"\n' >"$SELF"
chmod 755 "$SELF"
menu_header() { printf 'OLD_MENU\n'; }
pause_back() { :; }
RC_ASSUME_STDIN=1
printf '12\n0\n' >"$tmp/input"
out="$(menu_main <"$tmp/input"; printf 'AFTER_MENU\n')" || fail '菜单更新失败'
[[ $out == *'NEW_PANEL 3.1.0'* ]] || fail "菜单更新后未进入新版本：$out"
[[ $out != *'AFTER_MENU'* ]] || fail '菜单更新后仍回到旧面板循环'
[[ $(grep -c 'OLD_MENU' <<<"$out") == 1 ]] || fail '旧菜单被重复渲染'
case_name '菜单 12 更新后直接进入新版本'

printf 'All update_self tests passed\n'
