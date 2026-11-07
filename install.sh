#!/usr/bin/env bash
# Reality 目标检测 · Linux 一键部署脚本
# 用法: bash install.sh [安装目录]      默认目录: /root/rc-new
set -euo pipefail

REPO="G1oow/RC"
REF="${REF:-main}"
# 主程序走 GitHub Releases 发布产物；未指定 REF_TAG 时取 latest release
REF_TAG="${REF_TAG:-latest}"
DIR="${1:-/root/rc-new}"
BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
if [ "${REF_TAG}" = "latest" ]; then
  REL_BASE="https://github.com/${REPO}/releases/latest/download"
else
  REL_BASE="https://github.com/${REPO}/releases/download/${REF_TAG}"
fi
DATA_FILES="Country.mmdb gfwlist.conf cdn_keywords.txt hot_websites.txt exclude_rules.txt"

command -v curl >/dev/null 2>&1 || { echo "缺少 curl，请先安装: apt install -y curl"; exit 1; }

mkdir -p "${DIR}/data"
cd "${DIR}"

echo "[*] 下载主程序 -> ${DIR}/reality-checker-main (release: ${REF_TAG})"
curl -fL --retry 3 --connect-timeout 15 --max-time 900 -o reality-checker-main "${REL_BASE}/reality-checker-main" \
  || { echo "  ❌ 主程序下载失败：${REL_BASE}/reality-checker-main" >&2
       echo "     请确认仓库已发布 release，或用 REF_TAG=<tag> 指定版本。" >&2
       exit 1; }
chmod +x reality-checker-main

echo "[*] 下载配置与数据文件"
curl -fsSL --retry 3 --connect-timeout 10 --max-time 300 -o config.yaml "${BASE}/config.yaml" || echo "  ⚠️ 下载失败: config.yaml（可稍后重跑本脚本补齐）"
for f in ${DATA_FILES}; do
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 300 -o "data/${f}" "${BASE}/data/${f}" || echo "  ⚠️ 下载失败: data/${f}（可稍后重跑本脚本补齐）"
done

# ---------- 探测本机出口 IP，生成可执行的运行命令 ----------

probe_ip() { # $1 = -4 / -6
  local flag="$1" out url
  for url in "https://api${flag#-}.ipify.org" "https://ipv${flag#-}.icanhazip.com"; do
    out=$(curl "${flag}" -fsS --max-time 6 "${url}" 2>/dev/null | tr -d '[:space:]') || continue
    if [ -n "${out}" ]; then
      printf '%s' "${out}"
      return 0
    fi
  done
  return 1
}
# 反查入口 IP 归属地，只输出 ISO 国家码；全部来源失败则返回非零（调用方按"未知"处理）
geo_of() { # $1 = IP
  local ip="$1" out cc
  [[ -n ${ip} ]] || return 1
  # ipinfo：纯文本国家码，v4/v6 均支持
  out=$(curl -fsS --max-time 6 "https://ipinfo.io/${ip}/country" 2>/dev/null | tr -d '[:space:]') && \
    [[ ${out} =~ ^[A-Z]{2}$ ]] && { printf '%s' "${out}"; return 0; }
  # ip.sb：JSON，按 country_code 提取
  out=$(curl -fsS --max-time 6 "https://api.ip.sb/geoip/${ip}" 2>/dev/null) && \
    cc=$(printf '%s' "${out}" | sed -n 's/.*"country_code":[[:space:]]*"\([A-Za-z]*\)".*/\1/p') && \
    [[ -n ${cc} ]] && { printf '%s' "${cc}" | tr '[:lower:]' '[:upper:]'; return 0; }
  # ip-api：仅 IPv4，作为最后兜底
  [[ ${ip} == *:* ]] && return 1
  out=$(curl -fsS --max-time 6 "http://ip-api.com/json/${ip}?fields=countryCode" 2>/dev/null) && \
    cc=$(printf '%s' "${out}" | sed -n 's/.*"countryCode":[[:space:]]*"\([A-Za-z]*\)".*/\1/p') && \
    [[ -n ${cc} ]] && { printf '%s' "${cc}" | tr '[:lower:]' '[:upper:]'; return 0; }
  return 1
}

# 优先读终端；无 tty（全自动场景）时直接返回默认值
ask() {
  local ans=""
  read -r ans 2>/dev/null < /dev/tty || true
  printf '%s' "${ans:-$1}"
}

echo
echo "[*] 部署完成: ${DIR}"
echo "[*] 正在探测本机出口 IP ..."
IP4=$(probe_ip -4 || true)
IP6=$(probe_ip -6 || true)

TARGET=""
FAMILY_FLAG=""
if [ -n "${IP4}" ] && [ -n "${IP6}" ]; then
  echo "    检测到本机双栈出口："
  echo "      1) IPv4  ${IP4}"
  echo "      2) IPv6  ${IP6}"
  printf '    用哪个作为入口 IP？[1/2]（默认 1）: '
  case "$(ask 1)" in
    2) TARGET="${IP6}"; FAMILY_FLAG="-6" ;;
    *) TARGET="${IP4}" ;;
  esac
elif [ -n "${IP4}" ]; then
  TARGET="${IP4}"
  echo "    检测到 IPv4: ${TARGET}"
elif [ -n "${IP6}" ]; then
  TARGET="${IP6}"; FAMILY_FLAG="-6"
  echo "    检测到 IPv6: ${TARGET}"
else
  echo "    ⚠️ 未能自动探测出口 IP，请手动填写"
  printf '    入口 IP: '
  TARGET=$(ask '')
fi

echo
if [ -n "${TARGET}" ]; then
  RUN_ARGS=(auto "${TARGET}" --limit 10)
  if [ -n "${FAMILY_FLAG}" ]; then
    RUN_ARGS+=("${FAMILY_FLAG}")
  fi

  # 只提示不拦截：主程序已不再按出口地区阻断运行，扫描 CN 段时它会自行给出视角提示
  CC=$(geo_of "${TARGET}" || true)
  if [ -n "${CC}" ] && [ "${CC}" != "CN" ]; then
    echo
    echo "    [i] 本机出口归属地：${CC}"
    echo "        扫描海外网段不受影响；若扫描中国大陆网段，握手延迟不代表国内客户端的真实体验。"
  fi


  echo "[*] 运行命令: cd ${DIR} && ./reality-checker-main ${RUN_ARGS[*]}"
  printf '    现在开始扫描？[y/N]: '
  case "$(ask n)" in
    y|Y|yes|YES) cd "${DIR}" && exec ./reality-checker-main "${RUN_ARGS[@]}" ;;
  esac
else
  echo "[*] 用法: cd ${DIR} && ./reality-checker-main auto <你的VPS_IP> --limit 10"
fi
echo "[*] 完整说明见: ${BASE}/README.md"
