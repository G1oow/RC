#!/usr/bin/env bash
# rc.sh —— RC：VPS 聚合运维面板（SSH 加固 / 体检调优 / 目标筛选）
#
# 一键安装（Debian / Ubuntu，root；装完直接进面板）：
#   curl -fsSL https://raw.githubusercontent.com/G1oow/RC/main/rc.sh | bash
#
# 脚本会把自己装到 /usr/local/bin/rc 并创建 RC 别名，之后输入 rc 或 RC 进面板。
#
# 非交互子命令：
#   rc ssh          阶段 0：写入公钥 + 改 SSH 端口 + 放行防火墙
#   rc ssh-close    阶段 0b：确认新端口可用后关闭密码登录
#   rc tcpq         阶段 1：TCP 质量检测
#   rc score        阶段 2：NQ 测试（NodeQuality）
#   rc tune         阶段 3：TCP 调优（tcpfit）
#   rc reality      阶段 4：Reality 伪装目标筛选
#
#   rc status       查看各组件状态
#   rc rollback     回滚 SSH 配置
#   rc install-self 把本脚本安装/修复到 /usr/local/bin/rc
#   rc update       更新 rc 自身
#   rc uninstall    卸载 rc
#
# 兼容旧阶段参数：0 / 0b / 1 / 2 / 3 / 4 / 5 仍可用。
#
# 安全说明：改 SSH 前备份到 /root/vps-init-backup，改完用 sshd -t 校验，失败自动回滚。
# 默认值持久化在 /etc/rc-manager/rc.conf（0600）；同名环境变量优先级更高。
#
# 目标系统：Debian 13（minimal）；Ubuntu 23.04+ 的 ssh.socket 会自动识别并走 socket 分支。

set -Eeuo pipefail
umask 077

trap 'printf "\n\033[31mfail\033[0m 第 %s 行执行失败\n" "$LINENO" >&2' ERR

RC_VERSION='1.2.5'

CONF_DIR='/etc/rc-manager'
CONF_FILE="${CONF_DIR}/rc.conf"
LOG_FILE='/var/log/rc-manager.log'
SELF='/usr/local/bin/rc'
ALIAS='/usr/local/bin/RC'

SSHD_CONFIG=/etc/ssh/sshd_config
SOCKET_DROPIN=/etc/systemd/system/ssh.socket.d/10-vps-init-port.conf

# 各阶段上游一键地址
SRC_TCPQUALITY='https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh'
SRC_NQ='https://run.NodeQuality.com'
SRC_TCPFIT='https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh'
SRC_RC_INSTALL='https://raw.githubusercontent.com/G1oow/RC/main/install.sh'
# 仓库文件地址给两种写法，兼容 RC.sh / rc.sh（raw 路径大小写敏感）
SELF_URL_CANDIDATES=(
  'https://raw.githubusercontent.com/G1oow/RC/main/rc.sh'
  'https://raw.githubusercontent.com/G1oow/RC/main/RC.sh'
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok() { printf '    \033[32mok\033[0m %s\n' "$*"; }
warn() { printf '    \033[33mwarn\033[0m %s\n' "$*" >&2; }
die() {
  printf '\n\033[31mfail\033[0m %s\n' "$*" >&2
  exit 1
}

log_record() {
  [[ $EUID -eq 0 ]] || return 0
  printf '%s\t%s\t%s\n' "$(date '+%F %T')" "$$" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

# 只打印不执行的执行器：DRY_RUN=1 时生效
run() {
  if [[ $DRY_RUN == 1 ]]; then
    printf '    [dry] %s\n' "$*"
  else
    "$@"
  fi
}

# 远程脚本执行：先落盘校验，避免 curl -f 失败时 bash 读到空脚本仍返回 0
run_remote() {
  local url=$1 tmp
  if [[ $DRY_RUN == 1 ]]; then
    printf '    [dry] bash <(curl -fsSL %s)\n' "$url"
    return 0
  fi
  need_curl
  tmp="$(mktemp)" || { warn '无法创建临时文件'; return 1; }
  if ! fetch_to "$url" "$tmp" || [[ ! -s $tmp ]]; then
    rm -f "$tmp"
    warn "下载失败：$url"
    return 1
  fi
  bash -n "$tmp" 2>/dev/null || warn '远端脚本语法校验未通过，仍尝试执行'
  bash "$tmp"
  local rc=$?
  rm -f "$tmp"
  [[ $rc -eq 0 ]] || warn "远端脚本退出码 $rc"
  return $rc
}

need_root() {
  [[ ${VPS_INIT_ALLOW_NONROOT:-0} == 1 ]] && { warn '已跳过 root 检查'; return 0; }
  [[ ${EUID:-0} == 0 ]] || die '请用 root 运行（或 sudo -i）'
}

need_curl() {
  command -v curl >/dev/null 2>&1 || die '缺少 curl，请先安装: apt install -y curl'
}

# 是否存在可读写的控制终端（curl | bash、MSYS 等场景需探测，不能只看文件存在）
has_tty() {
  { : < /dev/tty; } 2>/dev/null
}

# 从终端读一行；无 tty（CI、全自动场景）时回落到默认值
# RC_ASSUME_STDIN=1 时强制读 stdin，便于脚本化喂入
read_ans() { # $1 = 默认值
  local def="${1:-}" ans=''
  if [[ ${RC_ASSUME_STDIN:-0} != 1 ]] && has_tty; then
    read -r ans < /dev/tty 2>/dev/null || ans=''
  elif [[ ${RC_ASSUME_STDIN:-0} == 1 || -t 0 ]]; then
    read -r ans 2>/dev/null || ans=''
  fi
  printf '%s' "${ans:-$def}"
}

pause_back() {
  if ! has_tty && [[ -t 0 ]]; then return 0; fi
  printf '\n    按回车返回面板... '
  read_ans '' >/dev/null
}

# ---------------------------------------------------------------- 配置层

# 加载顺序：配置文件提供默认值，环境变量（同名）覆盖之
_init_vars() {
  local -A envset=()
  local k
  for k in SSH_PORT SSH_PUBKEY SSH_PUBKEY_FILE RC_DIR SCAN_LIMIT DRY_RUN BACKUP_ROOT; do
    if [[ -n ${!k:-} ]]; then envset[$k]=${!k}; fi
  done

  SSH_PORT='' SSH_PUBKEY='' SSH_PUBKEY_FILE='' RC_DIR='' SCAN_LIMIT='' DRY_RUN='' BACKUP_ROOT=''
  # 文件由 conf_set 以 %q 写入，可直接 source
  # shellcheck disable=SC1090
  if [[ -f $CONF_FILE ]]; then . "$CONF_FILE"; fi

  for k in "${!envset[@]}"; do printf -v "$k" '%s' "${envset[$k]}"; done

  : "${SSH_PORT:=30000}"
  : "${RC_DIR:=/root/rc-new}"
  : "${SCAN_LIMIT:=5}"
  : "${DRY_RUN:=0}"
  : "${BACKUP_ROOT:=/root/vps-init-backup}"
  [[ $DRY_RUN == 1 ]] || DRY_RUN=0
}

conf_set() { # KEY VALUE
  local key=$1 value=$2 tmp line
  mkdir -p "$CONF_DIR" 2>/dev/null || { warn "无法创建 $CONF_DIR，本次设置不落盘"; return 0; }
  chmod 700 "$CONF_DIR" 2>/dev/null || true
  tmp="${CONF_FILE}.tmp"

  : >"$tmp" 2>/dev/null || { warn "无法写入 $tmp，本次设置不落盘"; return 0; }
  if [[ -f $CONF_FILE ]]; then
    while IFS= read -r line; do
      [[ ${line%%=*} == "$key" ]] && continue
      printf '%s\n' "$line" >>"$tmp"
    done <"$CONF_FILE"
  fi
  printf '%s=%q\n' "$key" "$value" >>"$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$CONF_FILE" 2>/dev/null || warn "写入 $CONF_FILE 失败"
  chmod 600 "$CONF_FILE" 2>/dev/null || true
}


# 从一个（可能含多把 key 的）公钥文件里取第一条 key
first_pubkey() {
  local f=$1
  [[ -r $f ]] || return 1
  grep -m1 -E '^(ssh-|ecdsa-|sk-)' "$f" 2>/dev/null | tr -d '\r'
}
# ---------------------------------------------------------------- 状态层

os_name() {
  if [[ -r /etc/os-release ]]; then
    local n
    n="$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release | head -n1)"
    if [[ -n $n ]]; then printf '%s' "$n"; return 0; fi
  fi
  uname -s
}

effective_ssh_port() {
  local p=''
  if command -v sshd >/dev/null 2>&1; then
    p="$(sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2; exit}')" || p=''
  fi
  printf '%s' "${p:-$SSH_PORT}"
}

ssh_password_auth() {
  local v=''
  if command -v sshd >/dev/null 2>&1; then
    v="$(sshd -T 2>/dev/null | awk 'tolower($1)=="passwordauthentication"{print $2; exit}')" || v=''
  fi
  case $v in
    yes) printf 'yes' ;;
    no) printf 'no' ;;
    *) printf '未知' ;;
  esac
}

auth_key_count() {
  local f=/root/.ssh/authorized_keys
  [[ -r $f ]] || { printf '0'; return 0; }
  grep -cE '^(ssh-|ecdsa-|sk-)' "$f" 2>/dev/null || true
}

ufw_state() {
  command -v ufw >/dev/null 2>&1 || { printf '未安装'; return 0; }
  if ufw status 2>/dev/null | grep -qi '^Status: active'; then printf '已启用'; else printf '未启用'; fi
}

tool_state() { # $1 = 可执行路径
  [[ -x $1 ]] && printf '已安装' || printf '未安装'
}

status_brief() {
  printf '  系统: %s  |  SSH 端口: %s  |  密码登录: %s\n' "$(os_name)" "$(effective_ssh_port)" "$(ssh_password_auth)"
  printf '  公钥: %s 条  |  ufw: %s\n' "$(auth_key_count)" "$(ufw_state)"
  printf '  引擎: %s  |  tcpfit: %s' \
    "$(tool_state "${RC_DIR}/reality-checker-main")" \
    "$(command -v tcpfit >/dev/null 2>&1 && printf '已安装' || printf '未安装')"
}

status_full() {
  local ip
  ip="$(curl -fsS --max-time 6 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  step "rc v${RC_VERSION} / 环境状态"
  printf '  系统            : %s\n' "$(os_name)"
  printf '  内核            : %s\n' "$(uname -r 2>/dev/null || printf '未知')"
  printf '  ssh.socket      : %s\n' "$(systemctl is-enabled --quiet ssh.socket 2>/dev/null && printf '已启用' || printf '未启用')"
  printf '  SSH 生效端口    : %s\n' "$(effective_ssh_port)"
  printf '  密码登录        : %s\n' "$(ssh_password_auth)"
  printf '  公钥条数        : %s\n' "$(auth_key_count)"
  printf '  ufw             : %s\n' "$(ufw_state)"
  printf '  出口 IP         : %s\n' "${ip:-探测失败}"
  printf '  引擎            : %s (%s)\n' "$(tool_state "${RC_DIR}/reality-checker-main")" "$RC_DIR"
  printf '  tcpfit          : %s\n' "$(tool_state "$(command -v tcpfit 2>/dev/null || printf /usr/local/bin/tcpfit)")"
  printf '  配置文件        : %s\n' "$( [[ -f $CONF_FILE ]] && printf '已存在' || printf '未创建')"
  printf '  备份目录        : %s\n' "$BACKUP_ROOT"
  printf '  DRY_RUN         : %s\n' "$DRY_RUN"
}

# ---------------------------------------------------------------- 自安装

fetch_to() { # url dest
  need_curl
  curl -fL --retry 3 --connect-timeout 15 --max-time 300 -o "$2" "$1" 2>/dev/null ||
    { command -v wget >/dev/null 2>&1 && wget -q --timeout=15 --tries=3 -O "$2" "$1"; }
}

# 按候选地址依次尝试，全部失败才返回非零
fetch_self() { # dest
  local dest=$1 url
  for url in "${SELF_URL_CANDIDATES[@]}"; do
    fetch_to "$url" "$dest" 2>/dev/null && [[ -s $dest ]] && return 0
  done
  return 1
}

verify_script() { # path
  local f=$1
  [[ -s $f ]] || { warn "校验失败：$f 为空"; return 1; }
  [[ "$(head -c 2 "$f" 2>/dev/null)" == '#!' ]] || { warn '校验失败：缺少 shebang'; return 1; }
  bash -n "$f" 2>/dev/null || { warn '校验失败：语法错误'; return 1; }
  return 0
}

ensure_alias() {
  [[ $EUID -eq 0 ]] || return 0
  [[ -L $ALIAS || -e $ALIAS ]] || ln -sf "$SELF" "$ALIAS" 2>/dev/null || true
}

self_install() {
  need_root
  local target
  target="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  # 管道执行（curl ... | bash）时 $0 是解释器名，不能当成源文件
  case ${0##*/} in bash | sh | dash | zsh | ksh) target='' ;; esac
  if [[ $target == "$SELF" ]]; then
    ensure_alias
    return 0
  fi

  local tmp bindir
  bindir="$(dirname "$SELF")"
  mkdir -p "$bindir" 2>/dev/null || { warn "无法创建 $bindir"; return 1; }
  tmp="$(mktemp "${bindir}/.rc.XXXXXX" 2>/dev/null || mktemp)" || { warn '无法创建临时文件'; return 1; }

  # 本地真实文件优先（仓库内执行时最贴近现状），否则从仓库重新下载
  if [[ -f $target && $target != /dev/fd/* && $target != /proc/* ]]; then
    cp -a "$target" "$tmp" 2>/dev/null || { rm -f "$tmp"; warn "复制失败：$target"; return 1; }
  else
    fetch_self "$tmp" || { rm -f "$tmp"; warn "下载失败：${SELF_URL_CANDIDATES[0]}"; return 1; }
  fi

  if ! verify_script "$tmp"; then
    rm -f "$tmp"
    warn '安装中止：新脚本未通过校验，原文件保持不变'
    return 1
  fi

  chmod 755 "$tmp"
  if mv -f "$tmp" "$SELF" 2>/dev/null; then
    ensure_alias
    ok "已安装到 $SELF（输入 rc 进入面板）"
  else
    rm -f "$tmp"
    warn "写入失败：$SELF（只读根分区？）"
    return 1
  fi
}

update_self() {
  need_root
  need_curl
  [[ -x $SELF ]] || self_install

  local tmp remote_version backup
  tmp="$(mktemp "$(dirname "$SELF")/.rc.XXXXXX" 2>/dev/null || mktemp)" || die '无法创建临时文件'
  step '更新 rc'
  printf '    当前版本: %s\n' "$RC_VERSION"

  fetch_self "$tmp" || { rm -f "$tmp"; die "下载失败：${SELF_URL_CANDIDATES[0]}"; }
  if ! verify_script "$tmp"; then
    rm -f "$tmp"
    die '更新中止：新脚本未通过校验，本地版本保持不变'
  fi

  # 版本号是防截断的最后一道：解析不出 RC_VERSION 就不装
  remote_version="$(sed -n "s/^RC_VERSION='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$tmp" | head -n1)"
  if [[ -z $remote_version ]]; then
    rm -f "$tmp"
    die '更新中止：远端脚本读不到版本号（多半是下载被截断），本地版本保持不变'
  fi
  printf '    远端版本: %s\n' "$remote_version"
  if [[ $remote_version == "$RC_VERSION" ]]; then
    rm -f "$tmp"
    ok '已是最新版本'
    return 0
  fi

  # 旧版本留一份 .bak，坏版本也能回退
  backup="${SELF}.bak"
  cp -a "$SELF" "$backup" 2>/dev/null || warn "备份旧版本失败：$backup"
  chmod 755 "$tmp"
  mv -f "$tmp" "$SELF" || { rm -f "$tmp"; die "写入失败：$SELF"; }
  ensure_alias
  log_record "update ${RC_VERSION} -> ${remote_version}"
  ok "已更新到 ${remote_version}，重新输入 rc 生效（旧版本留在 ${backup}）"
}

uninstall() {
  need_root
  step '卸载 rc'
  cat <<EOF

将删除：
  - $SELF
  - $ALIAS
  - $CONF_DIR（含持久化配置）
  - $LOG_FILE
保留：
  - 已装的 reality-checker（$RC_DIR）与 tcpfit
  - SSH 加固改动与备份目录 $BACKUP_ROOT

EOF
  case "$(read_ans n)" in
    y | Y | yes | YES) ;;
    *) printf '    已取消\n'; return 0 ;;
  esac

  if ! rm -f -- "$SELF" "$ALIAS" 2>/dev/null; then
    warn "删除失败（只读根分区？）：$SELF"
    return 1
  fi
  rm -rf -- "$CONF_DIR" 2>/dev/null || warn "删除失败：$CONF_DIR"
  rm -f -- "$LOG_FILE" 2>/dev/null || warn "删除失败：$LOG_FILE"
  ok '已卸载'
  warn "备份仍在 $BACKUP_ROOT，确认无需回滚后可手动删除"
  if [[ -x $SELF ]]; then
    printf '    文件仍在，本次面板可继续使用；退出后需重新安装\n'
  else
    printf '    退出当前面板后 rc 即不可用\n'
    exit 0
  fi
}

# ---------------------------------------------------------------- 交互取参

prompt_pubkey() {
  local key='' keyfile=''
  if [[ -n ${SSH_PUBKEY:-} ]]; then
    ok "已使用环境变量中的公钥：${SSH_PUBKEY:0:32}..."
    return 0
  fi
  if [[ -n ${SSH_PUBKEY_FILE:-} ]]; then
    keyfile="$SSH_PUBKEY_FILE"
  else
    printf '    粘贴公钥，或输入公钥文件路径（/root/k.pub）: '
    key="$(read_ans '')"
    if [[ -z $key ]]; then
      warn '没读到公钥：用 SSH_PUBKEY=... 或 SSH_PUBKEY_FILE=... 传参，或先 rc 面板里设置一次'
      return 1
    fi
    if [[ -f $key && -r $key ]]; then keyfile="$key"; else keyfile=''; fi
  fi

  if [[ -n $keyfile ]]; then
    # 一个文件里常有多把 key，只取第一条
    key="$(first_pubkey "$keyfile")"
    [[ -n $key ]] || { warn "文件里没有可用的公钥行：$keyfile"; return 1; }
    ok "已从 $keyfile 读取公钥"
  fi

  [[ $key == ssh-* || $key == ecdsa-* || $key == sk-* ]] || { warn "公钥格式不像 OpenSSH 公钥：${key:0:24}..."; return 1; }
  SSH_PUBKEY="$key"
  # 两个来源互斥，避免下次启动时读到旧的那条
  if [[ -n $keyfile ]]; then
    SSH_PUBKEY_FILE="$keyfile"
    conf_set SSH_PUBKEY_FILE "$keyfile"
    conf_set SSH_PUBKEY ''
    ok "公钥文件已记住：$keyfile"
  else
    SSH_PUBKEY_FILE=''
    conf_set SSH_PUBKEY "$key"
    conf_set SSH_PUBKEY_FILE ''
    ok '公钥已保存到配置'
  fi
}

prompt_port() {
  local current="${SSH_PORT}" port
  printf '    新 SSH 端口 [1-65535]（当前 %s，回车沿用）: ' "$current"
  port="$(read_ans "$current")"
  [[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || { warn "端口无效：$port"; return 1; }
  SSH_PORT="$port"
  if [[ $port != "$current" ]]; then conf_set SSH_PORT "$port"; fi
  return 0
}

# ---------------------------------------------------------------- SSH 实现

backup_file() {
  local f=$1
  [[ -e $f ]] || return 0
  if [[ $DRY_RUN == 1 ]]; then
    printf '    [dry] backup %s\n' "$f"
    return 0
  fi
  mkdir -p "$BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT" 2>/dev/null || true
  cp -a "$f" "$BACKUP_ROOT/$(basename "$f").$(date +%Y%m%d-%H%M%S)"
}

reload_sshd() {
  if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    # 先停 service，否则 restart 会因「already active」被拒
    run systemctl stop ssh.service || true
    run systemctl restart ssh.socket
  elif [[ -f /lib/systemd/system/ssh.service || -f /usr/lib/systemd/system/ssh.service || -f /etc/init.d/ssh ]]; then
    run systemctl reload ssh
  else
    run systemctl reload sshd
  fi
}

write_pubkey() {
  local keys=/root/.ssh/authorized_keys
  [[ $SSH_PUBKEY == ssh-* || $SSH_PUBKEY == ecdsa-* || $SSH_PUBKEY == sk-* ]] ||
    die "公钥格式不像 OpenSSH 公钥：${SSH_PUBKEY:0:20}..."

  run mkdir -p /root/.ssh
  run chmod 700 /root/.ssh
  [[ -e $keys ]] || run touch "$keys"
  run chmod 600 "$keys"

  if grep -qF "$SSH_PUBKEY" "$keys" 2>/dev/null; then
    ok '公钥已存在，跳过'
  else
    backup_file "$keys"
    if [[ $DRY_RUN == 1 ]]; then
      printf '    [dry] 追加公钥到 %s\n' "$keys"
    else
      printf '%s\n' "$SSH_PUBKEY" >>"$keys"
      ok "公钥已写入 $keys"
    fi
  fi
}

apply_ssh_port() {
  # 端口：优先处理 Ubuntu 的 socket activation，否则改 sshd_config
  if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    warn '检测到 ssh.socket（socket 激活），端口必须写在 socket drop-in 里，改 sshd_config 无效'
    run install -d -m 755 /etc/systemd/system/ssh.socket.d
    backup_file "$SOCKET_DROPIN"
    if [[ $DRY_RUN == 1 ]]; then
      printf '    [dry] 写入 %s，ListenStream=%s\n' "$SOCKET_DROPIN" "$SSH_PORT"
    else
      printf '[Socket]\nListenStream=\nListenStream=%s\n' "$SSH_PORT" >"$SOCKET_DROPIN"
    fi
    # drop-in 变更后 socket 必须重启才能生效；此时由它拉起的 ssh.service 仍 active，
    # systemd 会以「Socket service ssh.service already active, refusing」拒绝，故先停服务
    run systemctl stop ssh.service || true
    run systemctl daemon-reload
    return 0
  fi

  backup_file "$SSHD_CONFIG"
  if grep -qE "^[[:space:]]*Port[[:space:]]+${SSH_PORT}\b" "$SSHD_CONFIG" 2>/dev/null; then
    ok "sshd_config 已是 $SSH_PORT，跳过"
    return 0
  fi
  if [[ $DRY_RUN == 1 ]]; then
    printf '    [dry] 删除旧 Port 行并把 %s 设为 Port %s\n' "$SSHD_CONFIG" "$SSH_PORT"
    return 0
  fi
  sed -i -E '/^[[:space:]]*#?[[:space:]]*Port[[:space:]]+[0-9]+/d' "$SSHD_CONFIG"
  {
    printf 'Port %s\n' "$SSH_PORT"
    cat "$SSHD_CONFIG"
  } >"$SSHD_CONFIG.new"
  mv "$SSHD_CONFIG.new" "$SSHD_CONFIG"
  ok "sshd_config 端口已设为 $SSH_PORT"
}

open_firewall() {
  # 只动已启用的 ufw，避免凭空引入规则
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    run ufw allow "${SSH_PORT}/tcp"
    ok "ufw 已放行 ${SSH_PORT}/tcp"
  else
    warn "未检测到启用中的 ufw，iptables/nftables 需自行放行 ${SSH_PORT}/tcp"
  fi
}

verify_and_reload() {
  # 配置校验：失败就回滚，绝不带着坏配置重载
  if [[ $DRY_RUN != 1 ]]; then
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
      # drop-in 不是单元文件，直接校验单元本体
      if ! systemd-analyze verify ssh.socket >/dev/null 2>&1; then
        warn 'socket drop-in 校验失败，回滚'
        rollback_socket
        die '已回滚'
      fi
    elif ! sshd -t; then
      warn 'sshd -t 校验失败，回滚'
      rollback_sshd
      die '已回滚'
    fi
  fi
  # 重载本身也可能失败（端口被占等），失败同样回滚，别把机器留在半挂状态
  if [[ $DRY_RUN == 1 ]]; then
    reload_sshd
    return 0
  fi
  if ! reload_sshd; then
    warn '重载失败，回滚'
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then rollback_socket; else rollback_sshd; fi
    die '已回滚'
  fi
}

# ---------------------------------------------------------------- 阶段 0 / 0b

stage0() {
  need_root
  step "阶段 0 / SSH 加固：公钥 + 端口 $SSH_PORT"
  prompt_pubkey || return 1
  # 已有端口时先问一句，回车沿用；这样才能交互改端口
  prompt_port || return 1
  write_pubkey
  apply_ssh_port
  open_firewall
  verify_and_reload

  if [[ $DRY_RUN != 1 ]]; then
    if ss -Hlnt 2>/dev/null | grep -qE "[:.]${SSH_PORT}[[:space:]]"; then
      ok "端口 $SSH_PORT 已在监听"
    else
      warn "未看到 $SSH_PORT 处于监听，重载后稍等再查：ss -lntp | grep $SSH_PORT"
    fi
  fi

  cat <<EOF

    下一步（保持当前会话不要断开）：
      1. 云厂商安全组/防火墙放行 TCP $SSH_PORT
      2. 本地新开终端验证：ssh -p $SSH_PORT root@<VPS_IP>
      3. 登录成功后再执行：rc ssh-close

EOF
  log_record "stage0 port=${SSH_PORT}"
}

stage0b() {
  need_root
  step '阶段 0b / 关闭密码登录'

  local keys=/root/.ssh/authorized_keys
  [[ -s $keys ]] || die 'authorized_keys 为空，先跑阶段 0（rc ssh）'
  warn "当前未验证新端口可用，确认已能 ssh -p $SSH_PORT 登入后再继续"
  printf '    已确认能用新端口登入？[y/N]: '
  case "$(read_ans n)" in
    y | Y | yes | YES) ;;
    *) printf '    已取消\n'; return 0 ;;
  esac

  # 主配置 + 所有 drop-in（云镜像常把 PasswordAuthentication yes 写在 drop-in 里，
  # 而 sshd 采用「首次出现生效」，只改主配置会被 drop-in 覆盖）。
  # 一次备份整个目录，回滚才能整体还原。
  local f stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [[ $DRY_RUN != 1 ]]; then
    mkdir -p "$BACKUP_ROOT"
    chmod 700 "$BACKUP_ROOT" 2>/dev/null || true
    tar -czf "${BACKUP_ROOT}/etc-ssh.${stamp}.tar.gz" -C /etc ssh 2>/dev/null ||
      warn '备份 /etc/ssh 失败，回滚可能不完整'
    ok "已备份 /etc/ssh -> ${BACKUP_ROOT}/etc-ssh.${stamp}.tar.gz"
  fi

  if [[ $DRY_RUN == 1 ]]; then
    printf '    [dry] 主配置与 drop-in 全部置 PasswordAuthentication no\n'
    printf '    [dry] 主配置置 PermitRootLogin prohibit-password\n'
    printf '    [dry] sshd -t 校验后重载\n'
    return 0
  fi

  sed -i -E 's/^([[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+).*/\1no/' "$SSHD_CONFIG"
  grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$SSHD_CONFIG" ||
    echo 'PasswordAuthentication no' >>"$SSHD_CONFIG"

  shopt -s nullglob
  for f in /etc/ssh/sshd_config.d/*.conf; do
    sed -i -E 's/^([[:space:]]*PasswordAuthentication[[:space:]]+).*/\1no/' "$f"
    sed -i -E 's/^([[:space:]]*KbdInteractiveAuthentication[[:space:]]+).*/\1no/' "$f"
    sed -i -E 's/^([[:space:]]*ChallengeResponseAuthentication[[:space:]]+).*/\1no/' "$f"
    grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$f" ||
      echo 'PasswordAuthentication no' >>"$f"
    ok "已加固 $f"
  done
  shopt -u nullglob

  # root 登录限制为仅密钥
  sed -i -E 's/^([[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]]+).*/\1prohibit-password/' "$SSHD_CONFIG"
  grep -qiE '^[[:space:]]*PermitRootLogin' "$SSHD_CONFIG" ||
    echo 'PermitRootLogin prohibit-password' >>"$SSHD_CONFIG"

  if ! sshd -t; then
    warn 'sshd -t 失败，从整目录备份回滚'
    rollback_sshd "${BACKUP_ROOT}/etc-ssh.${stamp}.tar.gz"
    die '已回滚'
  fi
  reload_sshd

  local eff
  eff="$(sshd -T 2>/dev/null | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)' || true)"
  printf '%s\n' "$eff" | sed 's/^/    /'
  if grep -qi '^passwordauthentication no' <<<"$eff"; then
    ok '密码登录已关闭'
  else
    warn '生效值仍为 yes，检查 drop-in 顺序'
  fi
  log_record 'stage0b'
}

# ---------------------------------------------------------------- 阶段 1-5

stage1() {
  step '阶段 1 / TCP 质量检测（TcpQuality）'
  warn '会跑较长，建议在 tmux/screen 里执行，掉线不丢结果'
  run_remote "$SRC_TCPQUALITY"
  log_record 'stage1'
}

stage2() {
  step '阶段 2 / NQ 测试（NodeQuality）'
  warn '在临时系统里跑，结束后清理，不影响本机环境'
  run_remote "$SRC_NQ"
  log_record 'stage2'
}

stage3() {
  step '阶段 3 / TCP 调优（tcpfit）'
  warn '首次运行装到 /usr/local/bin/tcpfit 并弹菜单，选 1 为全自动；改动可用 tcpfit rollback 撤销'
  if command -v tcpfit >/dev/null 2>&1; then
    ok 'tcpfit 已安装，直接进入菜单'
    [[ $DRY_RUN == 1 ]] && printf '    [dry] tcpfit\n' || tcpfit
  else
    run_remote "$SRC_TCPFIT"
  fi
  log_record 'stage3'
}

ensure_reality_checker() {
  if [[ -x ${RC_DIR}/reality-checker-main ]]; then ok "已安装：${RC_DIR}/reality-checker-main"; return 0; fi
  warn "未安装，先执行 install.sh 到 ${RC_DIR}"
  run bash -c "curl -fsSL '${SRC_RC_INSTALL}' | bash -s -- '${RC_DIR}'"
  [[ $DRY_RUN == 1 || -x ${RC_DIR}/reality-checker-main ]] || die '扫描引擎安装失败'
}

stage4() {
  step '阶段 4 / Reality 伪装目标筛选（扫描引擎）'
  ensure_reality_checker

  local ip family=''
  ip="$(curl -fsS --max-time 8 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n $ip ]] || die "取不到公网 IP，先手动跑：cd ${RC_DIR} && ./reality-checker-main auto <你的VPS_IP> --limit ${SCAN_LIMIT}"
  if [[ $ip == *:* ]]; then family='-6'; fi
  ok "本机公网 IP：$ip"

  if [[ $DRY_RUN == 1 ]]; then
    printf '    [dry] cd %s && ./reality-checker-main auto %s --limit %s %s\n' "$RC_DIR" "$ip" "$SCAN_LIMIT" "$family"
  else
    ( cd "$RC_DIR" && ./reality-checker-main auto "$ip" --limit "$SCAN_LIMIT" $family ) || warn '扫描退出码非 0'
  fi
  warn '从中挑 5 星里握手最低的 2~3 个，配节点前先各自试连'
  log_record "stage4 ip=${ip} limit=${SCAN_LIMIT}"
}

# ---------------------------------------------------------------- 回滚

# $1 可选：整目录备份（tar.gz）。给了就整体还原（含 drop-in），否则回滚单文件
rollback_sshd() {
  local latest=${1:-}
  if [[ -z $latest ]]; then
    latest="$(ls -1t "${BACKUP_ROOT}"/sshd_config.* 2>/dev/null | head -n1 || true)"
    [[ -n $latest ]] || { warn '没有 sshd_config 备份'; return 1; }
  fi
  if [[ $DRY_RUN == 1 ]]; then
    printf '    [dry] 从 %s 还原 SSH 配置\n' "$latest"
    return 0
  fi
  if [[ $latest == *.tar.gz ]]; then
    tar -xzf "$latest" -C /etc || { warn "解包失败：$latest"; return 1; }
    ok "已从 $latest 整体还原 /etc/ssh"
  else
    cp -a "$latest" "$SSHD_CONFIG"
    ok "已恢复 $latest"
  fi
  if sshd -t; then
    reload_sshd
    ok '已重载'
  else
    warn '恢复后的配置仍未通过 sshd -t，请手工检查'
    return 1
  fi
}

rollback_socket() {
  local latest
  latest="$(ls -1t "${BACKUP_ROOT}"/10-vps-init-port.conf.* 2>/dev/null | head -n1 || true)"
  if [[ $DRY_RUN == 1 ]]; then
    printf '    [dry] 恢复 %s（备份: %s）\n' "$SOCKET_DROPIN" "${latest:-无，将删除}"
    return 0
  fi
  if [[ -n $latest ]]; then cp -a "$latest" "$SOCKET_DROPIN"; else rm -f "$SOCKET_DROPIN"; fi
  systemctl daemon-reload || warn 'daemon-reload 失败'
  if systemctl restart ssh.socket; then
    ok 'socket drop-in 已回滚'
  else
    warn 'ssh.socket 重启失败（端口可能被占用），当前会话先别断开，用旧端口重试'
    return 1
  fi
}

rollback() {
  need_root
  step '回滚 SSH 配置'
  if ! compgen -G "${BACKUP_ROOT}/*" >/dev/null 2>&1; then
    warn "备份目录为空或不存在：$BACKUP_ROOT，先执行一次 rc ssh 才会产生备份"
    return 0
  fi
  printf '    将用 %s 下最近的备份覆盖当前 SSH 配置（不含公钥）。继续？[y/N]: ' "$BACKUP_ROOT"
  case "$(read_ans n)" in
    y | Y | yes | YES) ;;
    *) printf '    已取消\n'; return 0 ;;
  esac
  local full
  full="$(ls -1t "${BACKUP_ROOT}"/etc-ssh.*.tar.gz 2>/dev/null | head -n1 || true)"
  if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    rollback_socket || return 1
  elif [[ -n $full ]]; then
    # 有整目录快照时先整体还原，再单独处理端口之外的残留
    rollback_sshd "$full" || return 1
  else
    rollback_sshd || return 1
  fi
  warn "备份目录保留在 $BACKUP_ROOT，确认无误后可删"
  log_record 'rollback'
}

# ---------------------------------------------------------------- 设置

menu_settings() {
  local choice value
  while true; do
    step '默认设置'
    printf '  1) SSH 端口        : %s\n' "$SSH_PORT"
    printf '  2) 公钥            : %s\n' "$( [[ -n $SSH_PUBKEY ]] && printf '%s...' "${SSH_PUBKEY:0:32}" || printf '未设置')"
    printf '  3) 扫描目录        : %s\n' "$RC_DIR"
    printf '  4) 扫描条数上限    : %s\n' "$SCAN_LIMIT"
    printf '  5) DRY_RUN 试跑    : %s\n' "$DRY_RUN"
    printf '  0) 返回\n\n'
    printf '  请选择 [0-5]: '
    choice="$(read_ans 0)"
    case $choice in
      1)
        printf '    新端口: '
        value="$(read_ans "$SSH_PORT")"
        if [[ $value =~ ^[0-9]+$ ]] && ((value >= 1)) && ((value <= 65535)); then
          SSH_PORT="$value"
          conf_set SSH_PORT "$value"
          ok "已保存：$value"
        else
          warn "端口无效：$value"
        fi
        ;;
      2)
        printf '    粘贴公钥或公钥文件路径: '
        value="$(read_ans '')"
        if [[ -f $value && -r $value ]]; then
          SSH_PUBKEY_FILE="$value"
          SSH_PUBKEY="$(tr -d '\r\n' <"$value")"
          conf_set SSH_PUBKEY_FILE "$value"
          ok "已保存公钥文件：$value"
        elif [[ $value == ssh-* || $value == ecdsa-* || $value == sk-* ]]; then
          SSH_PUBKEY="$value"
          SSH_PUBKEY_FILE=''
          conf_set SSH_PUBKEY "$value"
          ok '已保存公钥'
        else
          warn "公钥无效：$value"
        fi
        ;;
      3)
        printf '    目录: '
        value="$(read_ans "$RC_DIR")"
        if [[ -n $value ]]; then RC_DIR="$value"; conf_set RC_DIR "$value"; ok "已保存：$value"; fi
        ;;
      4)
        printf '    条数: '
        value="$(read_ans "$SCAN_LIMIT")"
        if [[ $value =~ ^[0-9]+$ ]]; then SCAN_LIMIT="$value"; conf_set SCAN_LIMIT "$value"; ok "已保存：$value"; fi
        ;;
      5)
        value="$( [[ $DRY_RUN == 1 ]] && printf 0 || printf 1 )"
        DRY_RUN="$value"
        conf_set DRY_RUN "$value"
        ok "DRY_RUN=$value"
        ;;
      0) return 0 ;;
      *) warn "无效输入：$choice" ;;
    esac
  done
}

view_log() {
  step '执行日志'
  if [[ -f $LOG_FILE ]]; then
    tail -n 40 "$LOG_FILE"
  else
    printf '  暂无日志：%s\n' "$LOG_FILE"
  fi
}


menu_header() {
  if [[ -t 1 ]]; then clear; fi
  printf '\033[36m'
  cat <<'BANNER'
  ____   ____
 |  _ \ / ___|
 | |_) | |
 |  _ <| |___
 |_| \_\____|  VPS 聚合面板
BANNER
  printf '%b\n' "$NC"
  if [[ $DRY_RUN == 1 ]]; then
    printf '  rc v%s   (DRY_RUN 试跑)\n' "$RC_VERSION"
  else
    printf '  rc v%s   (实机执行)\n' "$RC_VERSION"
  fi
  [[ $DRY_RUN == 1 ]] && printf '\033[33m  DRY_RUN=1：所有改动只打印不执行\033[0m\n'
  printf '\n'
  status_brief
  printf '\n\n'

  printf '\033[36m【SSH 加固】\033[0m\n'
  printf '    1) 写入公钥+改端口      2) 只改端口\n'
  printf '    3) 关闭密码登录         4) 回滚 SSH 配置\n\n'
  printf '\033[36m【体检与调优】\033[0m\n'
  printf '    5) TCP 质量检测         6) NQ 测试\n'
  printf '    7) TCP 调优(tcpfit)\n\n'
  printf '\033[36m【目标筛选】\033[0m\n'
  printf '    8) Reality 目标扫描     9) 重装扫描引擎\n\n'
  printf '\033[36m【维护】\033[0m\n'
  printf '   10) 默认设置            11) 更新 rc\n'
  printf '   12) 查看执行日志\n\n'
  printf '\033[36m【危险】\033[0m\n'
  printf '   13) 卸载 rc\n\n'
  printf '  ─────────────────────────────────────────\n'
  printf '    0) 退出\n\n'
  printf '  请选择 [0-13]: '
}

act_port_only() {
  note_port_and_apply() {
    apply_ssh_port
    open_firewall
    verify_and_reload
  }
  prompt_port || return 0
  note_port_and_apply
  log_record "port=${SSH_PORT}"
}

menu_main() {
  need_root
  local choice
  while true; do
    menu_header
    choice="$(read_ans 0)"
    case $choice in
      1) stage0 || true ;;
      2) step '只改 SSH 端口'; act_port_only || true ;;
      3) stage0b || true ;;
      4) rollback || true ;;
      5) stage1 || true ;;
      6) stage2 || true ;;
      7) stage3 || true ;;
      8) stage4 || true ;;
      9) step '重装扫描引擎'; ensure_reality_checker || true ;;
      10) menu_settings ;;
      11) update_self || true ;;
      12) view_log ;;
      13) uninstall || true ;;
      0) exit 0 ;;
      *) warn "无效输入：$choice" ;;
    esac
    [[ $choice == 0 ]] || pause_back
  done
}

# ---------------------------------------------------------------- 入口

usage() {
  cat <<'EOF'
rc —— RC：VPS 聚合运维面板

用法:
  rc                    打开面板（默认）
  rc <子命令>           非交互执行单项

子命令:
  ssh          阶段 0：写入公钥 + 改 SSH 端口 + 放行防火墙
  ssh-close    阶段 0b：确认新端口可用后关闭密码登录
  tcpq         阶段 1：TCP 质量检测
  score        阶段 2：NQ 测试（NodeQuality）
  tune         阶段 3：TCP 调优（tcpfit）
  reality      阶段 4：Reality 伪装目标筛选
  status       查看各组件状态
  rollback     回滚 SSH 配置
  install-self 安装/修复到 /usr/local/bin/rc
  update       更新 rc 自身
  uninstall    卸载 rc
  help         显示本帮助

兼容旧参数: 0 / 0b / 1 / 2 / 3 / 4（5 原为 sb 面板，现已不再联动）

环境变量（优先于 /etc/rc-manager/rc.conf）:
  SSH_PORT=30000    SSH_PUBKEY_FILE=/root/k.pub
  RC_DIR=/root/rc-new  SCAN_LIMIT=5  DRY_RUN=1

一键安装:
  curl -fsSL https://raw.githubusercontent.com/G1oow/RC/main/rc.sh | bash
EOF
}

main() {
  local cmd="${1:-menu}"
  case $cmd in
    help | -h | --help) usage ;;
    *) ;;
  esac
  if [[ $cmd == help || $cmd == -h || $cmd == --help ]]; then exit 0; fi

  _init_vars

  case $cmd in
    menu) self_install || warn '自安装失败，本次以内联方式运行（rc 命令可能不可用）'; menu_main ;;
    0 | ssh) self_install || warn '自安装失败，继续用内联方式执行'; stage0 ;;
    0b | ssh-close) stage0b ;;
    1 | tcpq) stage1 ;;
    2 | score) stage2 ;;
    3 | tune) stage3 ;;
    4 | reality) stage4 ;;
    status) status_full ;;
    rollback) rollback ;;
    install-self) self_install ;;
    update) update_self ;;
    uninstall) uninstall ;;
    *)
      usage
      printf '\n未知子命令：%s\n' "$cmd" >&2
      exit 1
  esac
}


main "$@"
