# Reality 目标检测 · Windows 一键部署脚本
# 用法: .\install.ps1 [安装目录]      默认目录: $env:USERPROFILE\reality-checker
$ErrorActionPreference = 'Stop'

$Repo = 'G1oow/RC'
$Ref = if ($env:REF) { $env:REF } else { 'main' }
# 主程序走 GitHub Releases 发布产物；未指定 REF_TAG 时取 latest release
$RefTag = if ($env:REF_TAG) { $env:REF_TAG } else { 'latest' }
$Dir = if ($args.Count -ge 1 -and $args[0]) { $args[0] } else { Join-Path $env:USERPROFILE 'reality-checker' }
$Base = "https://raw.githubusercontent.com/$Repo/$Ref"
if ($RefTag -eq 'latest') {
    $RelBase = "https://github.com/$Repo/releases/latest/download"
} else {
    $RelBase = "https://github.com/$Repo/releases/download/$RefTag"
}
$DataFiles = @('Country.mmdb', 'gfwlist.conf', 'cdn_keywords.txt', 'hot_websites.txt', 'exclude_rules.txt')

New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'data') | Out-Null

Write-Host "[*] 下载主程序 -> $Dir\reality-checker-main.exe (release: $RefTag)"
try {
    Invoke-WebRequest -Uri "$RelBase/reality-checker-main.exe" -OutFile (Join-Path $Dir 'reality-checker-main.exe')
} catch {
    Write-Host "  [x] 主程序下载失败: $RelBase/reality-checker-main.exe" -ForegroundColor Red
    Write-Host '      请确认仓库已发布 release，或设置 $env:REF_TAG=<tag> 指定版本。' -ForegroundColor Red
    throw
}

Write-Host "[*] 下载配置与数据文件"
Invoke-WebRequest -Uri "$Base/config.yaml" -OutFile (Join-Path $Dir 'config.yaml')
foreach ($f in $DataFiles) {
    Invoke-WebRequest -Uri "$Base/data/$f" -OutFile (Join-Path $Dir "data\$f")
}

# 解除下载文件的"来自 Internet"标记，避免被拦截
Get-ChildItem -Path $Dir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

# ---------- 探测本机出口 IP，生成可执行的运行命令 ----------
function Get-ExitIp {
    param([ValidateSet('4', '6')][string]$Family)
    foreach ($h in @("api$Family.ipify.org", "ipv$Family.icanhazip.com")) {
        try {
            $r = Invoke-RestMethod -Uri "https://$h" -TimeoutSec 6
            if ($r) { return ("$r").Trim() }
        } catch { }
    }
    return $null
}

# 反查入口 IP 归属地，返回 ISO 国家码；全部来源失败返回 $null（按"未知"处理）
function Get-IpCountry {
    param([string]$Ip)
    if (-not $Ip) { return $null }
    # ipinfo：纯文本国家码，v4/v6 均支持
    try {
        $v = (Invoke-RestMethod -Uri "https://ipinfo.io/$Ip/country" -TimeoutSec 6)
        $v = "$v".Trim().ToUpper()
        if ($v -match '^[A-Z]{2}$') { return $v }
    } catch { }
    # ip.sb：JSON，取 country_code
    try {
        $v = (Invoke-RestMethod -Uri "https://api.ip.sb/geoip/$Ip" -TimeoutSec 6).country_code
        if ($v -match '^[A-Za-z]{2}$') { return "$v".ToUpper() }
    } catch { }
    # ip-api：仅 IPv4，作为最后兜底
    if ($Ip -notmatch ':') {
        try {
            $v = (Invoke-RestMethod -Uri "http://ip-api.com/json/$($Ip)?fields=countryCode" -TimeoutSec 6).countryCode
            if ($v -match '^[A-Za-z]{2}$') { return "$v".ToUpper() }
        } catch { }
    }
    return $null
}
# 非交互环境（irm | iex、CI）下 Read-Host 会抛错，统一降级到默认值
function Read-Answer {
    param([string]$Prompt, [string]$Default = '')
    try {
        $v = Read-Host $Prompt
        if ($v) { return "$v".Trim() }
        return $Default
    } catch { return $Default }
}

Write-Host ''
Write-Host "[*] 部署完成: $Dir"
Write-Host '[*] 正在探测本机出口 IP ...'
$Ip4 = Get-ExitIp '4'
$Ip6 = Get-ExitIp '6'

$Target = $null
$FamilyFlag = $null
if ($Ip4 -and $Ip6) {
    Write-Host '    检测到本机双栈出口：'
    Write-Host "      1) IPv4  $Ip4"
    Write-Host "      2) IPv6  $Ip6"
    $choice = Read-Answer '    用哪个作为入口 IP？[1/2]（默认 1）' '1'
    if ($choice -eq '2') { $Target = $Ip6; $FamilyFlag = '-6' } else { $Target = $Ip4 }
}
elseif ($Ip4) {
    $Target = $Ip4
    Write-Host "    检测到 IPv4: $Target"
}
elseif ($Ip6) {
    $Target = $Ip6
    $FamilyFlag = '-6'
    Write-Host "    检测到 IPv6: $Target"
}
else {
    Write-Host '    [!] 未能自动探测出口 IP，请手动填写'
    $Target = Read-Answer '    入口 IP'
}

Write-Host ''
if ($Target) {
    $runArg = @('auto', $Target, '--limit', '5')
    if ($FamilyFlag) { $runArg += $FamilyFlag }

    # 只提示不拦截：主程序已不再按出口地区阻断运行，扫描 CN 段时它会自行给出视角提示
    $cc = Get-IpCountry $Target
    if ($cc -and $cc -ne 'CN') {
        Write-Host ''
        Write-Host "    [i] 本机出口归属地：$cc"
        Write-Host '        扫描海外网段不受影响；若扫描中国大陆网段，握手延迟不代表国内客户端的真实体验。'
    }

    Write-Host "[*] 运行命令: cd `"$Dir`"; .\reality-checker-main.exe $($runArg -join ' ')"
    $go = Read-Answer '    现在开始扫描？[y/N]' 'n'
    if ($go -match '^(y|yes)$') {
        Set-Location $Dir
        & .\reality-checker-main.exe @runArg
    }
}
else {
    Write-Host "[*] 用法: cd `"$Dir`"; .\reality-checker-main.exe auto <你的VPS_IP> --limit 10"
}
