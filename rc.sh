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
#   rc reality      阶段 4：Reality 伪装目标筛选（每次询问 IPv4/IPv6/双栈）
#
#   rc status       查看各组件状态（含 TCP 拥塞控制算法）
#   rc rollback     回滚 SSH 配置（加 --yes 跳过确认）
#   rc rollback-cancel  取消已排定的自动回滚
#   rc install-self 把本脚本安装/修复到 /usr/local/bin/rc
#   rc update       更新 rc 自身
#   rc uninstall    卸载 rc + 已装引擎 + tcpfit（含 iperf3）；卸载 tcpfit 前先问是否回滚调优
#   rc uninstall <engine|tcpfit|iperf3>   只卸载某个模块
#
# 兼容旧阶段参数：0 / 0b / 1 / 2 / 3 / 4 / 5 仍可用。
#
# 安全说明：改 SSH 前备份到 /root/vps-init-backup，改完用 sshd -t 校验，失败自动回滚。
# 默认值持久化在 /etc/rc-manager/rc.conf（0600）；同名环境变量优先级更高。
#
# 目标系统：Debian 13（minimal）/ Alpine / 常见 systemd 发行版；Ubuntu 23.04+ 的
# ssh.socket 会自动识别并走 socket 分支；OpenRC / SysV 走 init.d 分支。
#

set -Eeuo pipefail
umask 077

trap 'printf "\n\033[31mfail\033[0m 第 %s 行执行失败\n" "$LINENO" >&2' ERR

RC_VERSION='1.3.1'

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
  for k in SSH_PORT SSH_PUBKEY SSH_PUBKEY_FILE RC_DIR SCAN_LIMIT DRY_RUN BACKUP_ROOT RC_BACKUP_KEEP RC_SSH_AUTO_ROLLBACK_MIN; do
    if [[ -n ${!k:-} ]]; then envset[$k]=${!k}; fi
  done

  SSH_PORT='' SSH_PUBKEY='' SSH_PUBKEY_FILE='' RC_DIR='' SCAN_LIMIT='' DRY_RUN='' BACKUP_ROOT=''
  RC_BACKUP_KEEP='' RC_SSH_AUTO_ROLLBACK_MIN=''
  # 文件由 conf_set 以 %q 写入，可直接 source
  # shellcheck disable=SC1090
  if [[ -f $CONF_FILE ]]; then . "$CONF_FILE"; fi

  for k in "${!envset[@]}"; do printf -v "$k" '%s' "${envset[$k]}"; done

  : "${SSH_PORT:=30000}"
  : "${RC_DIR:=/root/rc-new}"
  : "${SCAN_LIMIT:=10}"
  : "${DRY_RUN:=0}"
  : "${BACKUP_ROOT:=/root/vps-init-backup}"
  : "${RC_BACKUP_KEEP:=10}"
  : "${RC_SSH_AUTO_ROLLBACK_MIN:=0}"
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

# ---------------------------------------------------------------- 平台兼容层

# 非登录 shell 的 PATH 常缺 /usr/sbin（Alpine / busybox / curl|bash 场景），补齐后再找系统命令
ensure_sbin_path() {
  case ":${PATH}:" in
    *:/usr/sbin:*) ;;
    *) PATH="/usr/sbin:/sbin:${PATH}" ;;
  esac
  export PATH
}

# 识别 init 系统：systemd / openrc / sysvinit / unknown
init_system() {
  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    printf 'systemd'
  elif command -v rc-service >/dev/null 2>&1; then
    printf 'openrc'
  elif [[ -d /etc/init.d ]]; then
    printf 'sysvinit'
  else
    printf 'unknown'
  fi
}

# busybox 的 sed 不一定支持 -E，探测一次后固定用法
SED_IRE_FLAG=''
sed_ire() { # FILE 'expr'  —— 原地 ERE 替换
  local f=$1 expr=$2
  if [[ -z $SED_IRE_FLAG ]]; then
    if printf 'a\n' | sed -E 's/a/b/' >/dev/null 2>&1; then SED_IRE_FLAG='-E'
    elif printf 'a\n' | sed -r 's/a/b/' >/dev/null 2>&1; then SED_IRE_FLAG='-r'
    else SED_IRE_FLAG='-E'; fi
  fi
  sed -i "$SED_IRE_FLAG" "$expr" "$f"
}

# ---------------------------------------------------------------- SSH 探测层

SSHD_BIN=''
SSHD_PROBE_ERR=''

find_sshd() {
  if [[ -n $SSHD_BIN ]]; then printf '%s' "$SSHD_BIN"; return 0; fi
  ensure_sbin_path
  local p
  for p in "$(command -v sshd 2>/dev/null || true)" /usr/sbin/sshd /usr/local/sbin/sshd /sbin/sshd; do
    if [[ -n $p && -x $p ]]; then
      SSHD_BIN=$p
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# sshd -T 需要特权分离目录，缺失时会直接报 Missing privilege separation directory
# （Alpine、精简容器镜像的典型症状），因此探测前先补齐
ensure_sshd_privsep() {
  [[ -d /run/sshd ]] && return 0
  mkdir -p /run/sshd 2>/dev/null || return 1
  chmod 0755 /run/sshd 2>/dev/null || true
  return 0
}

# sshd -T 的完整生效配置。结果写入 SSHD_DUMP，失败原因写入 SSHD_PROBE_ERR。
# 刻意不用「命令替换返回值」的写法：命令替换跑在子 shell 里，SSHD_PROBE_ERR
# 会随子 shell 一起丢掉，面板就永远看不到失败原因。
SSHD_DUMP=''
sshd_load() {
  local bin errfile out
  SSHD_DUMP=''
  SSHD_PROBE_ERR=''
  if ! bin="$(find_sshd)"; then
    SSHD_PROBE_ERR='找不到 sshd（已尝试 /usr/sbin、/usr/local/sbin、/sbin）'
    return 1
  fi
  ensure_sshd_privsep >/dev/null 2>&1 || true
  errfile="$(mktemp 2>/dev/null || printf '/tmp/rc-sshd.$$')"

  if [[ -r $SSHD_CONFIG ]]; then
    if ! out="$("$bin" -T -f "$SSHD_CONFIG" 2>"$errfile")"; then
      SSHD_PROBE_ERR="$(tr '\n' ' ' <"$errfile" 2>/dev/null | cut -c1-160)"
      rm -f "$errfile"
      return 1
    fi
  else
    if ! out="$("$bin" -T 2>"$errfile")"; then
      SSHD_PROBE_ERR="$(tr '\n' ' ' <"$errfile" 2>/dev/null | cut -c1-160)"
      rm -f "$errfile"
      return 1
    fi
  fi

  rm -f "$errfile"
  SSHD_DUMP="$out"
  return 0
}

# 兜底解析 sshd 配置：按 OpenSSH「首次出现生效」语义取首个未注释命中，
# Include 原位展开，Match 块内的条目是条件生效的，不计入
_parse_sshd_file() {
  local file=$1 key=$2 line kw val inc f got in_match=0
  [[ -r $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z $line ]] && continue
    kw="${line%%[[:space:]]*}"
    kw="${kw,,}"
    case $kw in
      match)
        in_match=1
        continue
        ;;
      include)
        ((in_match)) && continue
        inc="${line#*[[:space:]]}"
        for f in $inc; do
          [[ -e $f ]] || continue
          got="$(_parse_sshd_file "$f" "$key")"
          if [[ -n $got ]]; then printf '%s' "$got"; return 0; fi
        done
        continue
        ;;
      "$key")
        ((in_match)) && continue
        val="${line#*[[:space:]]}"
        val="${val%%[[:space:]]*}"
        printf '%s' "${val,,}"
        return 0
        ;;
    esac
  done <"$file"
  return 0
}

# sshd -t 配置校验（自带 sshd 发现与特权分离目录补齐，Alpine 也能跑）
sshd_validate() {
  local bin
  if ! bin="$(find_sshd)"; then
    SSHD_PROBE_ERR='找不到 sshd（已尝试 /usr/sbin、/usr/local/sbin、/sbin）'
    return 1
  fi
  ensure_sshd_privsep >/dev/null 2>&1 || true
  if [[ -r $SSHD_CONFIG ]]; then
    "$bin" -t -f "$SSHD_CONFIG"
  else
    "$bin" -t
  fi
}

# 取 sshd 生效值：优先 sshd -T，失败回落到配置解析，最后用内置默认值
# 返回 0 表示实测值，1 表示配置推断值
sshd_effective_value() { # KEY DEFAULT
  local key=$1 def=$2 v='' f
  if sshd_load; then
    v="$(printf '%s\n' "$SSHD_DUMP" | awk -v k="$key" 'tolower($1)==k{print tolower($2); exit}')"
    if [[ -n $v ]]; then printf '%s' "$v"; return 0; fi
  fi
  v="$(_parse_sshd_file "$SSHD_CONFIG" "$key")"
  if [[ -z $v ]]; then
    shopt -s nullglob
    for f in /etc/ssh/sshd_config.d/*.conf; do
      v="$(_parse_sshd_file "$f" "$key")"
      [[ -n $v ]] && break
    done
    shopt -u nullglob
  fi
  if [[ -n $v ]]; then printf '%s' "$v"; return 1; fi
  # 配置存在但没写这个键：OpenSSH 走内置默认值
  if [[ -r $SSHD_CONFIG ]]; then printf '%s' "$def"; return 1; fi
  # 既测不到也读不到配置
  printf '%s' ''
  return 1
}

effective_ssh_port() {
  local p=''
  if sshd_load; then
    p="$(printf '%s\n' "$SSHD_DUMP" | awk 'tolower($1)=="port"{print $2; exit}')"
  fi
  if [[ -z $p ]]; then p="$(_parse_sshd_file "$SSHD_CONFIG" port)"; fi
  printf '%s' "${p:-$SSH_PORT}"
}

# yes / no 为实测；带（配置推断）说明 sshd -T 不可用、结果来自配置解析
ssh_password_auth() {
  local v=''
  # 先在当前 shell 探一次：命令替换跑在子 shell 里，SSHD_PROBE_ERR 只在这里才留得住
  sshd_load || true
  if v="$(sshd_effective_value passwordauthentication yes)"; then
    printf '%s' "$v"
    return 0
  fi
  if [[ -z $v ]]; then
    printf '未知（%s）' "${SSHD_PROBE_ERR:-sshd -T 不可用}"
  else
    printf '%s（配置推断）' "$v"
  fi
}

# ---------------------------------------------------------------- TCP 拥塞控制

tcp_cc_raw() {
  local cc=''
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  if [[ -z $cc ]]; then
    cc="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)"
  fi
  cc="${cc%%[[:space:]]*}"
  printf '%s' "$cc"
}

# bbr 的版本号只有部分内核/模块对外暴露（BBRv3 补丁版通常写 3），取不到就按 BBR 展示
tcp_bbr_version() {
  local v='' rel
  if [[ -r /sys/module/tcp_bbr/version ]]; then
    v="$(tr -d '[:space:]' </sys/module/tcp_bbr/version)"
  fi
  if [[ -z $v ]] && command -v modinfo >/dev/null 2>&1; then
    v="$(modinfo -F version tcp_bbr 2>/dev/null | tr -d '[:space:]')"
  fi
  if [[ -z $v ]]; then
    rel="$(uname -r 2>/dev/null || true)"
    case "${rel,,}" in
      *bbr3*) v='3' ;;
    esac
  fi
  printf '%s' "$v"
}

tcp_cc_label() {
  local cc avail label version
  cc="$(tcp_cc_raw)"
  if [[ -z $cc ]]; then
    printf '未知'
    return 0
  fi
  if [[ $cc == bbr ]]; then
    version="$(tcp_bbr_version)"
    case $version in
      '' | 0) label='BBR' ;;
      3 | 3.* | v3 | v3.*) label='BBRv3' ;;
      *) label="BBRv${version}" ;;
    esac
  else
    label="${cc^^}"
  fi
  avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
  if [[ $cc != bbr && $avail == *bbr* ]]; then
    label="${label}（可用 BBR）"
  fi
  printf '%s' "$label"
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

ssh_socket_state() {
  command -v systemctl >/dev/null 2>&1 || { printf '无 systemd'; return 0; }
  if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then printf '已启用'; else printf '未启用'; fi
}

# ssh.socket（socket 激活）是否存在；非 systemd 系统上恒为假
ssh_socket_active() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-enabled --quiet ssh.socket 2>/dev/null
}

tool_state() { # $1 = 可执行路径
  [[ -x $1 ]] && printf '已安装' || printf '未安装'
}

status_brief() {
  printf '  系统: %s  |  SSH 端口: %s  |  密码登录: %s\n' "$(os_name)" "$(effective_ssh_port)" "$(ssh_password_auth)"
  printf '  公钥: %s 条  |  ufw: %s  |  拥塞控制: %s\n' "$(auth_key_count)" "$(ufw_state)" "$(tcp_cc_label)"
  printf '  引擎: %s  |  tcpfit: %s' \
    "$(tool_state "${RC_DIR}/reality-checker-main")" \
    "$(command -v tcpfit >/dev/null 2>&1 && printf '已安装' || printf '未安装')"
}

status_full() {
  local ip
  ip="$(curl -fsS --max-time 6 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  # 在当前 shell 里先探一次，SSHD_PROBE_ERR 才不会随命令替换的子 shell 丢掉
  sshd_load || true
  step "rc v${RC_VERSION} / 环境状态"
  printf '  系统            : %s\n' "$(os_name)"
  printf '  内核            : %s\n' "$(uname -r 2>/dev/null || printf '未知')"
  printf '  init 系统       : %s\n' "$(init_system)"
  printf '  ssh.socket      : %s\n' "$(ssh_socket_state)"
  printf '  SSH 生效端口    : %s\n' "$(effective_ssh_port)"
  printf '  密码登录        : %s\n' "$(ssh_password_auth)"
  [[ -n $SSHD_PROBE_ERR ]] && printf '  sshd -T 失败    : %s\n' "$SSHD_PROBE_ERR"
  printf '  公钥条数        : %s\n' "$(auth_key_count)"
  printf '  ufw             : %s\n' "$(ufw_state)"
  printf '  TCP 拥塞控制    : %s\n' "$(tcp_cc_label)"
  printf '  出口 IP         : %s\n' "${ip:-探测失败}"
  printf '  引擎            : %s (%s)\n' "$(tool_state "${RC_DIR}/reality-checker-main")" "$RC_DIR"
  printf '  tcpfit          : %s\n' "$(tool_state "$(command -v tcpfit 2>/dev/null || printf /usr/local/bin/tcpfit)")"
  printf '  配置文件        : %s\n' "$( [[ -f $CONF_FILE ]] && printf '已存在' || printf '未创建')"
  printf '  备份目录        : %s（保留最近 %s 份）\n' "$BACKUP_ROOT" "$RC_BACKUP_KEEP"
  printf '  SSH 自动回滚    : %s\n' "$( [[ ${RC_SSH_AUTO_ROLLBACK_MIN:-0} -gt 0 ]] && printf '%s 分钟' "$RC_SSH_AUTO_ROLLBACK_MIN" || printf '未启用')"
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

# ---------------------------------------------------------------- 模块卸载

pkg_manager() {
  local m
  for m in apt-get apk dnf yum; do
    if command -v "$m" >/dev/null 2>&1; then printf '%s' "$m"; return 0; fi
  done
  return 1
}

purge_package() { # NAME
  local name=$1 pm
  if ! command -v "$name" >/dev/null 2>&1; then ok "$name 未安装，跳过"; return 0; fi
  if ! pm="$(pkg_manager)"; then
    warn "未识别包管理器，请手动卸载 $name"
    return 1
  fi
  case $pm in
    apt-get) run env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$name" ;;
    apk) run apk del "$name" ;;
    dnf) run dnf remove -y "$name" ;;
    yum) run yum remove -y "$name" ;;
  esac
}

engine_state() { [[ -d $RC_DIR ]] && printf '已安装（%s）' "$RC_DIR" || printf '未安装'; }
tcpfit_state() { command -v tcpfit >/dev/null 2>&1 && printf '已安装（%s）' "$(command -v tcpfit)" || printf '未安装'; }
iperf3_state() { command -v iperf3 >/dev/null 2>&1 && printf '已安装（%s）' "$(command -v iperf3)" || printf '未安装'; }

# stage3 跑 tcpfit 之前记录 iperf3 是否存在，卸载时据此判断该不该连带删除
iperf3_marker() { printf '%s/markers/tcpfit.iperf3' "$CONF_DIR"; }

record_tcpfit_baseline() {
  command -v tcpfit >/dev/null 2>&1 && return 0
  local m
  m="$(iperf3_marker)"
  mkdir -p "$(dirname "$m")" 2>/dev/null || return 0
  if command -v iperf3 >/dev/null 2>&1; then
    printf 'present\n' >"$m"
  else
    printf 'absent\n' >"$m"
  fi
  chmod 600 "$m" 2>/dev/null || true
}

uninstall_engine() {
  step "卸载扫描引擎（$RC_DIR）"
  if [[ ! -d $RC_DIR ]]; then ok '引擎目录不存在，跳过'; return 0; fi

  local db="${RC_DIR}/data/reality_targets.db"
  if [[ -s $db ]]; then
    printf '    发现资产库 %s，卸载前备份到 /root/rc-backup/？[Y/n]: ' "$db"
    case "$(read_ans y)" in
      n | N | no | NO) ;;
      *)
        if [[ $DRY_RUN == 1 ]]; then
          printf '    [dry] 备份 %s -> /root/rc-backup/\n' "$db"
        else
          mkdir -p /root/rc-backup && chmod 700 /root/rc-backup 2>/dev/null
          if cp -a "$db" "/root/rc-backup/reality_targets.$(date +%Y%m%d-%H%M%S).db"; then
            ok '资产库已备份到 /root/rc-backup'
          else
            warn '资产库备份失败'
          fi
        fi
        ;;
    esac
  fi

  if ! run rm -rf -- "$RC_DIR"; then
    warn "删除失败：$RC_DIR"
    return 1
  fi
  ok "已删除 $RC_DIR"
  log_record "uninstall engine dir=${RC_DIR}"
}

# tcpfit 是否因为用户选择「保留调优」而被留下，供 uninstall() 决定要不要连带删 iperf3
TCPFIT_KEPT=0

# tcpfit 的 uninstall 内部必然先 cmd_rollback（没有只删脚本不回滚的开关），
# 所以卸载前必须问一次：用户要保留调优时直接不卸，别替他把内核参数还原掉。
uninstall_tcpfit() {
  step '卸载 tcpfit'
  TCPFIT_KEPT=0
  if ! command -v tcpfit >/dev/null 2>&1; then ok 'tcpfit 未安装，跳过'; return 0; fi

  warn 'tcpfit 把卸载和回滚绑在一起：uninstall 会还原 sysctl / initcwnd / 整形'
  printf '    卸载前回滚内核调优？[y/N]: '
  local rollback=0
  case "$(read_ans n)" in
    y | Y | yes | YES) rollback=1 ;;
  esac
  if [[ $rollback == 0 ]]; then
    TCPFIT_KEPT=1
    ok '已保留内核调优，本次不卸载 tcpfit'
    printf '    它没有「只删脚本、不动调优」的卸载方式，要保留调优就留着 tcpfit；\n'
    printf '    想撤销调优先执行 tcpfit rollback，确认机器正常后再回来卸载。\n'
    log_record 'uninstall tcpfit skipped rollback=no'
    return 0
  fi

  printf '    保留调优存档（/var/lib/tcpfit，重装 tcpfit 后仍可 archive restore）？[Y/n]: '
  local keep=1
  case "$(read_ans y)" in
    n | N | no | NO) keep=0 ;;
  esac

  if [[ $DRY_RUN == 1 ]]; then
    if [[ $keep == 1 ]]; then
      printf '    [dry] tcpfit uninstall --yes --keep-archives\n'
    else
      printf '    [dry] tcpfit uninstall --yes\n'
    fi
  else
    if [[ $keep == 1 ]]; then
      tcpfit uninstall --yes --keep-archives || { warn 'tcpfit 卸载失败（可手动执行 tcpfit uninstall）'; return 1; }
    else
      tcpfit uninstall --yes || { warn 'tcpfit 卸载失败（可手动执行 tcpfit uninstall）'; return 1; }
    fi
  fi
  ok 'tcpfit 已卸载（内核调优已回滚）'
  log_record "uninstall tcpfit keep_archives=${keep}"
}

uninstall_iperf3() {
  step '卸载 iperf3'
  if ! command -v iperf3 >/dev/null 2>&1; then ok 'iperf3 未安装，跳过'; return 0; fi

  local baseline=''
  [[ -r "$(iperf3_marker)" ]] && baseline="$(tr -d '[:space:]' <"$(iperf3_marker)")"
  case $baseline in
    absent)
      printf '    iperf3 是 tcpfit 装的，一并卸载？[Y/n]: '
      case "$(read_ans y)" in n | N | no | NO) ok '已保留 iperf3'; return 0 ;; esac
      ;;
    present)
      printf '    iperf3 在安装 tcpfit 之前就存在，仍然卸载？[y/N]: '
      case "$(read_ans n)" in y | Y | yes | YES) ;; *) ok '已保留 iperf3'; return 0 ;; esac
      ;;
    *)
      printf '    没有安装来源记录，卸载 iperf3？[y/N]: '
      case "$(read_ans n)" in y | Y | yes | YES) ;; *) ok '已保留 iperf3'; return 0 ;; esac
      ;;
  esac

  purge_package iperf3 || return 1
  ok 'iperf3 已卸载'
  log_record 'uninstall iperf3'
}

uninstall_conf() {
  step '删除 rc 配置与日志'
  printf '    将删除 %s（含持久化设置）与 %s，继续？[y/N]: ' "$CONF_DIR" "$LOG_FILE"
  case "$(read_ans n)" in
    y | Y | yes | YES) ;;
    *) printf '    已取消\n'; return 0 ;;
  esac
  rm -rf -- "$CONF_DIR" 2>/dev/null || warn "删除失败：$CONF_DIR"
  rm -f -- "$LOG_FILE" 2>/dev/null || warn "删除失败：$LOG_FILE"
  ok '配置与日志已删除'
  log_record 'uninstall conf'
}

# 菜单 14)：模块单独卸载
menu_modules() {
  local choice
  while true; do
    step '模块单独卸载'
    printf '  1) 扫描引擎        : %s\n' "$(engine_state)"
    printf '  2) tcpfit          : %s\n' "$(tcpfit_state)"
    printf '  3) iperf3          : %s\n' "$(iperf3_state)"
    printf '  4) rc 配置与日志   : %s\n' "$( [[ -d $CONF_DIR ]] && printf '已存在（%s）' "$CONF_DIR" || printf '未创建')"
    printf '  0) 返回\n\n'
    printf '  请选择 [0-4]: '
    choice="$(read_ans 0)"
    case $choice in
      1) uninstall_engine || true ;;
      2) uninstall_tcpfit || true ;;
      3) uninstall_iperf3 || true ;;
      4) uninstall_conf || true ;;
      0) return 0 ;;
      *) warn "无效输入：$choice" ;;
    esac
    [[ $choice == 0 ]] || pause_back
  done
}

# 菜单 13)：卸载面板 + 已装模块（SSH 改动与备份保留）
uninstall() {
  need_root
  step '卸载 rc（面板 + 已装模块）'
  cat <<EOF

将删除：
  - $SELF、$ALIAS
  - $CONF_DIR（含持久化配置与安装标记）
  - $LOG_FILE
  - 扫描引擎：$RC_DIR
  - tcpfit：$(tcpfit_state)（卸载前会问是否回滚内核调优，默认不回滚、保留 tcpfit）
  - iperf3：$(iperf3_state)（tcpfit 被保留时一并保留）
保留：
  - SSH 加固改动与备份目录 $BACKUP_ROOT（需要还原请先跑 rc rollback）
  - /root/rc-backup 下的资产库备份
  - tcpfit 调优存档 /var/lib/tcpfit（默认保留）

EOF
  printf '    确认全部卸载？[y/N]: '
  case "$(read_ans n)" in
    y | Y | yes | YES) ;;
    *) printf '    已取消\n'; return 0 ;;
  esac

  # 先卸模块（要用到 CONF_DIR 里的 iperf3 安装标记），最后再删面板自身
  uninstall_engine || warn '引擎卸载未完成'
  uninstall_tcpfit || warn 'tcpfit 卸载未完成'
  if [[ ${TCPFIT_KEPT:-0} == 1 ]]; then
    warn 'tcpfit 已按你的选择保留，iperf3 一并留下'
  else
    uninstall_iperf3 || warn 'iperf3 卸载未完成'
  fi

  if ! rm -f -- "$SELF" "$ALIAS" 2>/dev/null; then
    warn "删除失败（只读根分区？）：$SELF"
    return 1
  fi
  rm -rf -- "$CONF_DIR" 2>/dev/null || warn "删除失败：$CONF_DIR"
  rm -f -- "$LOG_FILE" 2>/dev/null || warn "删除失败：$LOG_FILE"
  ok '已卸载 rc 与已装模块'
  warn "SSH 改动与备份仍在（$BACKUP_ROOT）；确认无需回滚后可手动删除"
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
  prune_backups
}

# 只保留最近 RC_BACKUP_KEEP 份同类备份，避免备份目录无限增长
prune_backups() {
  local keep="${RC_BACKUP_KEEP:-10}" pattern f list
  [[ $keep =~ ^[0-9]+$ ]] || keep=10
  ((keep > 0)) || return 0
  [[ $DRY_RUN == 1 ]] && return 0
  [[ -d $BACKUP_ROOT ]] || return 0

  for pattern in 'sshd_config.*' 'etc-ssh.*.tar.gz' '10-vps-init-port.conf.*'; do
    # shellcheck disable=SC2086
    list="$(ls -1t ${BACKUP_ROOT}/${pattern} 2>/dev/null || true)"
    [[ -z $list ]] && continue
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      rm -f -- "$f" 2>/dev/null || true
      log_record "prune backup $(basename "$f")"
    done <<<"$(printf '%s\n' "$list" | tail -n "+$((keep + 1))")"
  done
}

reload_sshd() {
  local init svc s
  init="$(init_system)"

  if [[ $init == systemd ]] && command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
      # 先停 service，否则 restart 会因「already active」被拒
      run systemctl stop ssh.service || true
      run systemctl restart ssh.socket
    elif [[ -f /lib/systemd/system/ssh.service || -f /usr/lib/systemd/system/ssh.service || -f /etc/init.d/ssh ]]; then
      run systemctl reload ssh
    else
      run systemctl reload sshd
    fi
    return 0
  fi

  # OpenRC（Alpine）：优先 reload，失败再 restart
  if [[ $init == openrc ]] && command -v rc-service >/dev/null 2>&1; then
    svc=sshd
    [[ -f /etc/init.d/sshd ]] || svc=ssh
    if [[ -x /etc/init.d/$svc ]]; then
      if [[ $DRY_RUN == 1 ]]; then
        printf '    [dry] rc-service %s reload\n' "$svc"
        return 0
      fi
      rc-service "$svc" reload 2>/dev/null || rc-service "$svc" restart
      return 0
    fi
  fi

  # SysV / 其它：直接叫 init 脚本
  for s in /etc/init.d/ssh /etc/init.d/sshd; do
    if [[ -x $s ]]; then
      if [[ $DRY_RUN == 1 ]]; then
        printf '    [dry] %s reload\n' "$s"
        return 0
      fi
      "$s" reload 2>/dev/null || "$s" restart
      return 0
    fi
  done

  warn '未识别的 init 系统，无法自动重载 sshd，请手动重启 SSH 服务'
  return 1
}

# 端口监听探测：ss 的 -H 在 iproute2 / busybox 上不一致，逐级回退
port_is_listening() { # PORT
  local port=$1 out=''
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -Hlnt 2>/dev/null || ss -lnt 2>/dev/null || true)"
  fi
  if [[ -z $out ]] && command -v netstat >/dev/null 2>&1; then
    out="$(netstat -lnt 2>/dev/null || true)"
  fi
  [[ -n $out ]] || return 2
  printf '%s\n' "$out" | grep -qE "[:.]${port}[[:space:]]"
}

# 关闭密码登录前的机器校验：端口在监听 + sshd 真能应答（能取到主机钥）
verify_new_port() { # PORT
  local port=$1 rc=0
  port_is_listening "$port" || rc=$?
  if [[ $rc -eq 2 ]]; then
    warn '既没有 ss 也没有 netstat，跳过端口监听检查'
    return 0
  fi
  if [[ $rc -ne 0 ]]; then
    warn "未发现端口 $port 在监听"
    return 1
  fi
  ok "端口 $port 已在监听"

  if command -v ssh-keyscan >/dev/null 2>&1; then
    # 带 -p 时 ssh-keyscan 的主机字段是 [host]:port，密钥类型在行内，用 '^ssh-' 永远匹配不到。
    # 先取输出再判断，避免 grep -q 提前退出触发 SIGPIPE、在 pipefail 下被误判为失败。
    local scan_out=''
    scan_out="$(ssh-keyscan -T 5 -p "$port" 127.0.0.1 2>/dev/null || true)"
    if grep -qE '^[^#].*[[:space:]]ssh-[a-z0-9]' <<<"$scan_out"; then
      ok "端口 $port 上 sshd 正常应答（已取到主机钥）"
      return 0
    fi
    warn "端口 $port 在监听，但 ssh-keyscan 未取到主机钥（sshd 可能没真正加载新配置）"
    return 1
  fi
  return 0
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
    if ssh_socket_active; then
      # drop-in 不是单元文件，直接校验单元本体
      if ! systemd-analyze verify ssh.socket >/dev/null 2>&1; then
        warn 'socket drop-in 校验失败，回滚'
        rollback_socket
        die '已回滚'
      fi
    elif ! sshd_validate; then
      warn 'sshd -t 校验失败，回滚'
      rollback_sshd
      die '已回滚'
    fi
  fi
  # 重载本身也可能失败（端口被占、init 系统不识别等），失败同样回滚，别把机器留在半挂状态
  if [[ $DRY_RUN == 1 ]]; then
    reload_sshd
    return 0
  fi
  if ! reload_sshd; then
    warn '重载失败，回滚'
    if ssh_socket_active; then rollback_socket; else rollback_sshd; fi
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
    if verify_new_port "$SSH_PORT"; then
      ok "端口 $SSH_PORT 已在监听并应答"
    else
      warn "端口 $SSH_PORT 暂未确认可用：ss -lntp | grep $SSH_PORT，必要时 rc rollback"
    fi
    schedule_auto_rollback
  fi

  cat <<EOF

    下一步（保持当前会话不要断开）：
      1. 云厂商安全组/防火墙放行 TCP $SSH_PORT
      2. 本地新开终端验证：ssh -p $SSH_PORT root@<VPS_IP>
      3. 登录成功后再执行：rc ssh-close（同时会取消自动回滚）

EOF
  log_record "stage0 port=${SSH_PORT}"
}

stage0b() {
  need_root
  step '阶段 0b / 关闭密码登录'

  local keys=/root/.ssh/authorized_keys
  [[ -s $keys ]] || die 'authorized_keys 为空，先跑阶段 0（rc ssh）'

  # 先做机器层面的校验，再要人工确认：避免「端口根本没起来还被关掉密码登录」
  local port_ok=0
  if [[ $DRY_RUN == 1 ]]; then
    printf '    [dry] 校验端口 %s 监听与 sshd 应答\n' "$SSH_PORT"
    port_ok=1
  elif verify_new_port "$(effective_ssh_port)"; then
    port_ok=1
  else
    warn '端口校验未通过：新端口可能还没生效'
  fi

  warn "确认已能 ssh -p $(effective_ssh_port) root@<VPS_IP> 登入后再继续"
  printf '    已确认能用新端口登入？[y/N]: '
  case "$(read_ans n)" in
    y | Y | yes | YES) ;;
    *) printf '    已取消\n'; return 0 ;;
  esac

  if [[ $port_ok != 1 ]]; then
    printf '    端口校验没通过，强行关闭密码登录可能把自己锁在外面。仍然继续？[y/N]: '
    case "$(read_ans n)" in
      y | Y | yes | YES) warn '已确认强行继续' ;;
      *) printf '    已取消\n'; return 0 ;;
    esac
  fi

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

  sed_ire "$SSHD_CONFIG" 's/^([[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+).*/\1no/'
  grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$SSHD_CONFIG" ||
    echo 'PasswordAuthentication no' >>"$SSHD_CONFIG"

  shopt -s nullglob
  for f in /etc/ssh/sshd_config.d/*.conf; do
    sed_ire "$f" 's/^([[:space:]]*PasswordAuthentication[[:space:]]+).*/\1no/'
    sed_ire "$f" 's/^([[:space:]]*KbdInteractiveAuthentication[[:space:]]+).*/\1no/'
    sed_ire "$f" 's/^([[:space:]]*ChallengeResponseAuthentication[[:space:]]+).*/\1no/'
    grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$f" ||
      echo 'PasswordAuthentication no' >>"$f"
    ok "已加固 $f"
  done
  shopt -u nullglob

  # root 登录限制为仅密钥
  sed_ire "$SSHD_CONFIG" 's/^([[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]]+).*/\1prohibit-password/'
  grep -qiE '^[[:space:]]*PermitRootLogin' "$SSHD_CONFIG" ||
    echo 'PermitRootLogin prohibit-password' >>"$SSHD_CONFIG"

  if ! sshd_validate; then
    warn 'sshd -t 失败，从整目录备份回滚'
    rollback_sshd "${BACKUP_ROOT}/etc-ssh.${stamp}.tar.gz"
    die '已回滚'
  fi
  reload_sshd
  prune_backups

  local eff
  if sshd_load; then
    eff="$(printf '%s\n' "$SSHD_DUMP" | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)' || true)"
  else
    eff=''
  fi
  if [[ -n $eff ]]; then
    printf '%s\n' "$eff" | sed 's/^/    /'
  else
    printf '    实测值不可读（%s），按配置推断：\n' "${SSHD_PROBE_ERR:-sshd -T 不可用}"
    printf '    passwordauthentication %s\n' "$(sshd_effective_value passwordauthentication yes || true)"
    printf '    permitrootlogin %s\n' "$(sshd_effective_value permitrootlogin prohibit-password || true)"
  fi
  case "$(ssh_password_auth)" in
    no*) ok '密码登录已关闭' ;;
    *) warn "生效值仍为 $(ssh_password_auth)，检查 drop-in 顺序" ;;
  esac

  cancel_auto_rollback
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
    # 记录 tcpfit 之前 iperf3 是否已存在，卸载时据此决定是否连带删除 iperf3
    record_tcpfit_baseline
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

# 探测本机某协议族的出口 IP：4 / 6
probe_ip() {
  local fam=$1 out url
  need_curl
  for url in "https://api${fam}.ipify.org" "https://ipv${fam}.icanhazip.com"; do
    out="$(curl -"$fam" -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
    if [[ -n $out ]]; then printf '%s' "$out"; return 0; fi
  done
  return 1
}

# 每次扫描都重新询问协议族：不记忆、不沿用上一次的选择
prompt_family() {
  local ip4='' ip6='' def=3 choice
  ip4="$(probe_ip 4 || true)"
  ip6="$(probe_ip 6 || true)"

  printf '\n    选择本次扫描的协议族（每次都重新询问，不记忆）：\n'
  printf '      1) IPv4   %s\n' "${ip4:-本机无 IPv4 出口}"
  printf '      2) IPv6   %s\n' "${ip6:-本机无 IPv6 出口}"
  printf '      3) 双栈（不限制协议族）\n'
  if [[ -n $ip4 ]]; then def=1; elif [[ -n $ip6 ]]; then def=2; fi
  printf '    请选择 [1/2/3]（默认 %s）: ' "$def"

  choice="$(read_ans "$def")"
  SCAN_FAMILY=''
  SCAN_ENTRY_IP=''
  case $choice in
    1) SCAN_FAMILY='4'; SCAN_ENTRY_IP="$ip4" ;;
    2) SCAN_FAMILY='6'; SCAN_ENTRY_IP="$ip6" ;;
    3) SCAN_FAMILY=''; SCAN_ENTRY_IP="${ip4:-$ip6}" ;;
    *) warn "无效输入：$choice"; return 1 ;;
  esac

  if [[ -z $SCAN_ENTRY_IP ]]; then
    warn '所选协议族没有可用出口 IP：仍可按 ASN 前缀扫描，但无法做入口归属校验'
  fi
  return 0
}

stage4() {
  step '阶段 4 / Reality 伪装目标筛选（扫描引擎）'
  ensure_reality_checker

  prompt_family || return 0

  local family_flag='' family_text='双栈'
  case $SCAN_FAMILY in
    4) family_flag='--ipv4-only'; family_text='IPv4' ;;
    6) family_flag='--ipv6-only'; family_text='IPv6' ;;
  esac

  if [[ -z $SCAN_ENTRY_IP ]]; then
    warn "取不到本机出口 IP，先手动跑：cd ${RC_DIR} && ./reality-checker-main auto <你的VPS_IP> --limit ${SCAN_LIMIT} ${family_flag}"
    return 0
  fi
  ok "本次入口 IP：${SCAN_ENTRY_IP}（${family_text}）"

  if [[ $DRY_RUN == 1 ]]; then
    printf '    [dry] cd %s && ./reality-checker-main auto %s --limit %s %s\n' "$RC_DIR" "$SCAN_ENTRY_IP" "$SCAN_LIMIT" "$family_flag"
  else
    ( cd "$RC_DIR" && ./reality-checker-main auto "$SCAN_ENTRY_IP" --limit "$SCAN_LIMIT" $family_flag ) || warn '扫描退出码非 0'
  fi
  warn '同 ASN 命中不足时会自动回退同地区（同国家）继续找；IPv6 扫不出来时先调大 ipv6_budget 或加 --threads'
  warn '从中挑 5 星里握手最低的 2~3 个，配节点前先各自试连'
  log_record "stage4 ip=${SCAN_ENTRY_IP} limit=${SCAN_LIMIT} family=${SCAN_FAMILY:-both}"
}

# ---------------------------------------------------------------- 回滚

# 回滚后把面板记录的 SSH_PORT 与实际生效端口对齐：否则配置里残留被回滚掉的旧端口，
# 下次 rc ssh 回车沿用就会把机器又改回那个端口（回滚不完整）
sync_panel_ssh_port() {
  local eff=''
  eff="$(effective_ssh_port 2>/dev/null || true)"
  [[ -n $eff ]] || return 0
  [[ $eff == "$SSH_PORT" ]] && return 0
  SSH_PORT="$eff"
  conf_set SSH_PORT "$eff"
  ok "面板记录的 SSH 端口已同步为 $eff"
}

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
    ok "已恢复 $latest（仅主配置，drop-in 未动）"
  fi
  if sshd_validate; then
    reload_sshd
    sync_panel_ssh_port
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
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || warn 'daemon-reload 失败'
    if systemctl restart ssh.socket; then
      ok 'socket drop-in 已回滚'
      sync_panel_ssh_port
    else
      warn 'ssh.socket 重启失败（端口可能被占用），当前会话先别断开，用旧端口重试'
      return 1
    fi
  else
    warn '当前系统没有 systemd，ssh.socket drop-in 已清理但仍需手动重启 sshd'
    reload_sshd || return 1
    ok 'socket drop-in 已回滚（走 init 脚本重载）'
    sync_panel_ssh_port
  fi
}

# ---------------------------------------------------------------- 自动回滚兜底

# 排定「N 分钟后自动回滚 SSH 配置」的安全网（RC_SSH_AUTO_ROLLBACK_MIN，默认 0 = 关闭）
schedule_auto_rollback() {
  local mins="${RC_SSH_AUTO_ROLLBACK_MIN:-0}"
  [[ $mins =~ ^[0-9]+$ ]] || mins=0
  ((mins > 0)) || return 0

  if command -v systemd-run >/dev/null 2>&1; then
    run systemd-run --on-active="${mins}min" --unit=rc-ssh-rollback "$SELF" rollback --yes ||
      { warn '排定自动回滚失败（systemd-run）'; return 0; }
  elif command -v at >/dev/null 2>&1; then
    printf '%s rollback --yes\n' "$SELF" | at now + "$mins" minutes 2>/dev/null ||
      { warn '排定自动回滚失败（at）'; return 0; }
  else
    warn "自动回滚需要 systemd-run 或 at，本次未排定（${mins} 分钟兜底未生效）"
    return 0
  fi
  ok "${mins} 分钟后将自动回滚 SSH 配置；确认能登录后执行 rc ssh-close 或 rc rollback-cancel 取消"
}

cancel_auto_rollback() {
  local cancelled=1
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-timers --all 2>/dev/null | grep -q 'rc-ssh-rollback'; then
      run systemctl stop rc-ssh-rollback.timer 2>/dev/null || true
      cancelled=0
    fi
  fi
  if ((cancelled == 1)) && command -v atq >/dev/null 2>&1; then
    local job
    while IFS= read -r job; do
      printf '%s\n' "$job" | grep -q 'rc rollback' && { run atrm "${job%%[[:space:]]*}" 2>/dev/null || true; cancelled=0; }
    done <<<"$(atq 2>/dev/null || true)"
  fi
  ((cancelled == 0)) && ok '已取消排定的自动回滚'
  return 0
}

# 回滚 SSH：整目录快照优先（含 drop-in），同时清理 socket drop-in。
# 用法：rollback [--yes]
rollback() {
  need_root
  local assume_yes=0 arg
  for arg in "$@"; do
    case $arg in
      --yes | -y) assume_yes=1 ;;
    esac
  done

  step '回滚 SSH 配置'
  if ! compgen -G "${BACKUP_ROOT}/*" >/dev/null 2>&1; then
    warn "备份目录为空或不存在：$BACKUP_ROOT，先执行一次 rc ssh 才会产生备份"
    return 0
  fi

  if [[ $assume_yes != 1 ]]; then
    printf '    将用 %s 下最近的备份覆盖当前 SSH 配置（不含公钥）。继续？[y/N]: ' "$BACKUP_ROOT"
    case "$(read_ans n)" in
      y | Y | yes | YES) ;;
      *) printf '    已取消\n'; return 0 ;;
    esac
  fi

  local full rc=0
  full="$(ls -1t "${BACKUP_ROOT}"/etc-ssh.*.tar.gz 2>/dev/null | head -n1 || true)"

  # 1) /etc/ssh 整目录快照优先；没有快照再退回单文件
  if [[ -n $full ]]; then
    rollback_sshd "$full" || rc=1
  else
    rollback_sshd || rc=1
    warn '未找到 /etc/ssh 整目录快照：只还原了主配置，drop-in 里的加固改动需要手动处理'
  fi

  # 2) socket 激活的端口 drop-in 在 /etc/ssh 之外，存在就一并还原
  if [[ -e $SOCKET_DROPIN || -n "$(ls -1t "${BACKUP_ROOT}"/10-vps-init-port.conf.* 2>/dev/null | head -n1 || true)" ]]; then
    rollback_socket || rc=1
  fi

  cancel_auto_rollback
  warn "备份目录保留在 $BACKUP_ROOT，确认无误后可删（rc 只保留最近 ${RC_BACKUP_KEEP} 份）"
  log_record 'rollback'
  return $rc
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
    printf '  6) 备份保留份数    : %s\n' "$RC_BACKUP_KEEP"
    printf '  7) SSH 自动回滚    : %s\n' "$( [[ ${RC_SSH_AUTO_ROLLBACK_MIN:-0} -gt 0 ]] && printf '%s 分钟' "$RC_SSH_AUTO_ROLLBACK_MIN" || printf '未启用（0）')"
    printf '  0) 返回\n\n'
    printf '  请选择 [0-7]: '
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
      6)
        printf '    保留最近几份备份（0 = 不自动清理）: '
        value="$(read_ans "$RC_BACKUP_KEEP")"
        if [[ $value =~ ^[0-9]+$ ]]; then
          RC_BACKUP_KEEP="$value"
          conf_set RC_BACKUP_KEEP "$value"
          ok "已保存：$value"
        else
          warn "无效输入：$value"
        fi
        ;;
      7)
        printf '    改完 SSH 后多少分钟自动回滚（0 = 关闭）: '
        value="$(read_ans "$RC_SSH_AUTO_ROLLBACK_MIN")"
        if [[ $value =~ ^[0-9]+$ ]]; then
          RC_SSH_AUTO_ROLLBACK_MIN="$value"
          conf_set RC_SSH_AUTO_ROLLBACK_MIN "$value"
          ok "已保存：$value 分钟"
        else
          warn "无效输入：$value"
        fi
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
  printf '   13) 卸载 rc（含引擎/tcpfit）\n'
  printf '   14) 模块单独卸载\n\n'
  printf '  ─────────────────────────────────────────\n'
  printf '    0) 退出\n\n'
  printf '  请选择 [0-14]: '
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
      14) menu_modules ;;
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
  reality      阶段 4：Reality 伪装目标筛选（每次询问 IPv4/IPv6/双栈）
  status       查看各组件状态（含 TCP 拥塞控制算法）
  rollback     回滚 SSH 配置（--yes 跳过确认）
  rollback-cancel  取消排定的 SSH 自动回滚
  install-self 安装/修复到 /usr/local/bin/rc
  update       更新 rc 自身
  uninstall [all|engine|tcpfit|iperf3|conf]
               卸载：默认删除面板 + 已装引擎 + tcpfit + iperf3；
               带模块名时只卸载该模块
               卸 tcpfit 前会问是否回滚内核调优，默认保留（保留时 tcpfit 不删）
  help         显示本帮助

兼容旧参数: 0 / 0b / 1 / 2 / 3 / 4（5 原为 sb 面板，现已不再联动）

环境变量（优先于 /etc/rc-manager/rc.conf）:
  SSH_PORT=30000    SSH_PUBKEY_FILE=/root/k.pub
  RC_DIR=/root/rc-new  SCAN_LIMIT=10  DRY_RUN=1
  RC_BACKUP_KEEP=10（备份保留份数）  RC_SSH_AUTO_ROLLBACK_MIN=0（改 SSH 后 N 分钟自动回滚）

一键安装:
  curl -fsSL https://raw.githubusercontent.com/G1oow/RC/main/rc.sh | bash
EOF
}

main() {
  local cmd="${1:-menu}"
  case $cmd in
    help | -h | --help)
      usage
      exit 0
      ;;
  esac

  _init_vars
  SCAN_FAMILY=''
  SCAN_ENTRY_IP=''

  case $cmd in
    menu) self_install || warn '自安装失败，本次以内联方式运行（rc 命令可能不可用）'; menu_main ;;
    0 | ssh) self_install || warn '自安装失败，继续用内联方式执行'; stage0 ;;
    0b | ssh-close) stage0b ;;
    1 | tcpq) stage1 ;;
    2 | score) stage2 ;;
    3 | tune) stage3 ;;
    4 | reality) stage4 ;;
    status) status_full ;;
    rollback) shift || true; rollback "$@" ;;
    rollback-cancel) cancel_auto_rollback ;;
    install-self) self_install ;;
    update) update_self ;;
    uninstall | uninstall-all)
      case "${2:-all}" in
        all | '') uninstall ;;
        engine) need_root; uninstall_engine ;;
        tcpfit) need_root; uninstall_tcpfit ;;
        iperf3) need_root; uninstall_iperf3 ;;
        conf) need_root; uninstall_conf ;;
        *)
          usage
          printf '\n未知模块：%s（可选 all / engine / tcpfit / iperf3 / conf）\n' "${2:-}" >&2
          exit 1
          ;;
      esac
      ;;
    *)
      usage
      printf '\n未知子命令：%s\n' "$cmd" >&2
      exit 1
      ;;
  esac
}


# RC_LIB_ONLY=1 只加载函数定义、不执行入口（供测试用桩脚本 source）
[[ ${RC_LIB_ONLY:-0} == 1 ]] || main "$@"
