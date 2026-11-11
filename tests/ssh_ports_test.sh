#!/usr/bin/env bash
set -Eeuo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/etc/ssh/sshd_config.d" "$tmp/systemd/ssh.socket.d" "$tmp/backups"
export RC_LIB_ONLY=1
# shellcheck source=../rc.sh
. "$repo/rc.sh"
SSHD_CONFIG="$tmp/etc/ssh/sshd_config"
SOCKET_DROPIN="$tmp/systemd/ssh.socket.d/10-vps-init-port.conf"
BACKUP_ROOT="$tmp/backups"
CONF_DIR="$tmp/conf"
CONF_FILE="$CONF_DIR/rc.conf"
SSH_PORT=30000
DRY_RUN=0
VPS_INIT_ALLOW_NONROOT=1

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_has() { grep -qF "$2" "$1" || fail "$1 缺少 $2"; }
assert_not_has() { if grep -qF "$2" "$1"; then fail "$1 意外包含 $2"; fi; }
sshd_load() {
  SSHD_DUMP=''
  local file line
  while IFS= read -r file; do
    while IFS= read -r line; do
      if [[ $line =~ ^Port[[:space:]]+([0-9]+) ]]; then SSHD_DUMP+="port ${BASH_REMATCH[1]}"$'\n'; fi
    done <"$file"
  done < <(ssh_port_files)
  [[ -n $SSHD_DUMP ]] || SSHD_DUMP=$'port 22\n'
}
sshd_validate() { [[ ${INVALID_CONFIG:-0} == 0 ]]; }
# 真实 ssh_port_responds 依赖 ss -p 的属主字段；这里用桩模拟 sshd/systemd 监听
ss() {
  local p
  [[ -f $tmp/live ]] || return 0
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    if [[ ${OWNER_OVERRIDE:-sshd} == sshd ]]; then
      printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:* users:(("sshd",pid=1,fd=6))\n' "$p"
    else
      printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:* users:(("nginx",pid=1,fd=6))\n' "$p"
    fi
  done <"$tmp/live"
}
port_is_listening() { grep -qxF "$1" "$tmp/live"; }
reload_sshd() {
  [[ ${FAIL_RELOAD:-0} == 0 ]] || return 1
  if [[ $DRY_RUN != 1 ]]; then
    if [[ $SSH_PORTS_SOURCE == socket ]]; then
      systemctl show ssh.socket -p Listen --value | sed -nE 's/.*:([0-9]+) \(Stream\).*/\1/p' >"$tmp/live"
    else
      sshd_load
      printf '%s\n' "$SSHD_DUMP" | awk '$1=="port"{print $2}' >"$tmp/live"
      # 模拟 sshd 未真正加载新配置：旧端口仍在监听
      if [[ ${KEEP_OLD_LIVE:-0} == 1 ]]; then printf '22\n' >>"$tmp/live"; fi
    fi
  fi
}
open_firewall() { :; }
ssh_socket_active() { [[ ${TEST_SOCKET:-0} == 1 ]]; }
systemctl() {
  case $1 in
    show)
      if [[ -f $SOCKET_DROPIN ]]; then
        sed -nE 's/^ListenStream=([0-9]+)/[::]:\1 (Stream)/p' "$SOCKET_DROPIN"
      else
        printf '[::]:22 (Stream)\n'
      fi
      ;;
    list-sockets)
      while IFS= read -r p; do printf '[::]:%s ssh.socket ssh.service\n' "$p"; done <"$tmp/live"
      ;;
    *) : ;;
  esac
}
systemd-analyze() { :; }
read_ans() {
  local result=''
  IFS= read -r result || true
  printf '%s' "${result:-${1:-}}"
}
case_name() { printf 'PASS: %s\n' "$1"; }

printf 'Port 22\nInclude %s\n' "$tmp/etc/ssh/sshd_config.d/*.conf" >"$SSHD_CONFIG"
printf 'Port 22\nPasswordAuthentication no\n' >"$tmp/etc/ssh/sshd_config.d/cloud.conf"
printf '22\n' >"$tmp/live"
ssh_ports_load
[[ ${SSH_PORTS[*]} == 22 ]] || fail '初始 SSH 端口不是 22'
printf '1\ny\ny\n' | ssh_ports_manage >"$tmp/output" 2>&1 || fail '唯一端口拒关应正常返回'
assert_has "$tmp/live" '22'
assert_not_has "$SSHD_CONFIG" 'Port 30000'
assert_has "$tmp/output" '禁止关闭唯一 SSH 端口'
case_name '拒绝关闭唯一端口'

apply_ssh_port >"$tmp/output" || fail '默认端口切换失败'
assert_has "$SSHD_CONFIG" 'Port 30000'
assert_not_has "$SSHD_CONFIG" 'Port 22'
assert_not_has "$tmp/etc/ssh/sshd_config.d/cloud.conf" 'Port 22'
assert_has "$tmp/live" '30000'
assert_not_has "$tmp/live" '22'
case_name '移除主配置和 Include 内的默认端口'


printf '2\ny\n' | ssh_ports_manage >"$tmp/output" || fail '开启主路径关闭的 22 失败'
assert_has "$tmp/live" '22'
case_name 'rc ssh 关闭的端口可从历史开启'
SSH_PORTS=(22 30000); SSH_PORTS_SOURCE=sshd
ssh_ports_commit || fail '添加第二端口失败'
printf '1\ny\ny\n' | ssh_ports_manage >"$tmp/output" || fail '关闭多端口中的一个失败'
assert_not_has "$tmp/live" '22'
assert_has "$BACKUP_ROOT/ssh-closed-ports" '22'
printf '2\ny\n' | ssh_ports_manage >"$tmp/output" || fail '重新开启历史端口失败'
assert_has "$tmp/live" '22'
assert_not_has "$BACKUP_ROOT/ssh-closed-ports" '22'
case_name '多端口关闭与重新开启'

printf '22\n30000\n' >"$tmp/live"
SSH_PORTS=(22 30000); SSH_PORTS_SOURCE=sshd
KEEP_OLD_LIVE=1
ssh_ports_commit 22 >"$tmp/output" 2>&1 && fail '旧端口仍监听时不应提交'
KEEP_OLD_LIVE=0
assert_has "$tmp/live" '22'
case_name '旧端口仍监听时自动恢复'

printf '40003\n' >"$tmp/live"
OWNER_OVERRIDE=nginx
if ssh_port_responds 40003; then fail '非 sshd 属主不应算 SSH 可用'; fi
OWNER_OVERRIDE=sshd
ssh_port_responds 40003 || fail 'sshd 属主应判定可用'
case_name '按监听属主判定 SSH 端口'
before="$(cat "$SSHD_CONFIG")"
SSH_PORTS=(30000); SSH_PORTS_SOURCE=sshd
INVALID_CONFIG=1
ssh_ports_commit 22 >"$tmp/output" 2>&1 && fail '无效配置不应提交'
INVALID_CONFIG=0
[[ $(cat "$SSHD_CONFIG") == "$before" ]] || fail '配置校验失败后未还原主配置'
case_name '配置失败自动恢复'

FAIL_RELOAD=1
ssh_ports_commit 22 >"$tmp/output" 2>&1 && fail '重载失败不应提交'
FAIL_RELOAD=0
[[ $(cat "$SSHD_CONFIG") == "$before" ]] || fail '重载失败后未还原主配置'
case_name '重载失败自动恢复'

DRY_RUN=1
ssh_ports_commit 22 >"$tmp/output" || fail 'DRY_RUN 失败'
[[ $(cat "$SSHD_CONFIG") == "$before" ]] || fail 'DRY_RUN 写入了主配置'
DRY_RUN=0
case_name 'DRY_RUN 不写入配置'

TEST_SOCKET=1
rm -f "$SOCKET_DROPIN"
printf '22\n' >"$tmp/live"
ssh_ports_load
[[ ${SSH_PORTS[*]} == 22 ]] || fail 'socket 默认端口未识别'
SSH_PORTS=(30000)
ssh_ports_commit 22 >"$tmp/output" || fail 'socket 端口切换失败'
assert_has "$SOCKET_DROPIN" 'ListenStream=30000'
assert_not_has "$tmp/live" '22'
[[ -n $(find "$BACKUP_ROOT" -name '*.absent' -print -quit) ]] || fail '缺少 socket 原配置不存在的快照'
case_name 'socket 默认 22 收口并记录 absent 快照'


snapshot="$(find "$BACKUP_ROOT" -name '*.absent' -print -quit)"
SSH_PORT_SNAPSHOT=$snapshot
ssh_port_restore >/dev/null
[[ ! -e $SOCKET_DROPIN ]] || fail 'absent 快照未删除 socket drop-in'
case_name 'socket absent 快照可回滚'

TEST_SOCKET=0
printf 'Port 30000\n' >"$SSHD_CONFIG"
printf '30000\n' >"$tmp/live"
SSH_PORT=30000

apply_ssh_port >"$tmp/output" || fail '同端口重新应用失败'
assert_has "$tmp/live" '30000'
case_name '目标端口未变化时保持监听'
TEST_SOCKET=1
systemctl() { printf '[::]:22 (Stream) [::]:30000 (Stream)\n'; }
ssh_ports_load
[[ ${SSH_PORTS[*]} == '22 30000' ]] || fail "socket 同一行双端口解析错误：${SSH_PORTS[*]}"
case_name 'socket 同一行解析多个端口'

printf 'All SSH port tests passed\n'
