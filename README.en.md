<p align="center">
  <img src="./assets/icon.png" width="200" alt="RC logo">
</p>

<h1 align="center">RC</h1>

<p align="center">A VPS operations panel that aggregates SSH hardening, connectivity checks and tuning, and REALITY camouflage target selection behind a single <code>rc</code>.</p>

<p align="center">
  <a href="./README.en.md">English</a> | <a href="./README.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/G1oow/RC/actions/workflows/build.yml"><img src="https://github.com/G1oow/RC/actions/workflows/build.yml/badge.svg" alt="Build and Release workflow status"></a>
  <img src="https://img.shields.io/badge/Go-1.26.0-3776AB?style=flat-square&logo=go" alt="Go 1.26.0">
  <img src="https://img.shields.io/badge/platform-linux--amd64%20%7C%20linux--arm64%20%7C%20windows--amd64-4B5563?style=flat-square" alt="Linux amd64, Linux arm64 and Windows amd64 builds">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-22C55E?style=flat-square" alt="MIT License"></a>
</p>

RC is the single entry point for taking a fresh VPS from bare to usable. Run `rc`, get a menu: lock SSH down first (key, port, password login off, with rollback), then check and tune TCP (TcpQuality / NodeQuality / tcpfit) and stand up the sing-box panel (singbox-lite, command `sb`) while you are there, then pick REALITY camouflage domains from the same box. Every stage lives in one menu, so you stop collecting one-off script URLs.

The panel holds no scanning logic itself: picking targets is delegated to the bundled scanning engine. The panel installs and drives that engine, and the engine also runs standalone as a CLI or a systemd daemon.

## What the menu looks like

Running `rc` drops you on this screen: a banner, three status lines (OS, SSH port, password login, key count, ufw, TCP congestion control, engine / tcpfit / sb state), then the 16 entries grouped into five sections. The menu itself is Chinese-only; every entry also has a non-interactive subcommand.

```text
  ____   ____
 |  _ \ / ___|
 | |_) | |
 |  _ <| |___
 |_| \_\____|  VPS 聚合面板

  rc v1.5.0   (实机执行)

  系统: Debian GNU/Linux 13  |  SSH 端口: 30000  |  密码登录: no
  公钥: 1 条  |  ufw: 已启用  |  拥塞控制: BBRv3
  引擎: 已安装  |  tcpfit: 已安装  |  sb: 已安装

【SSH 加固】
    1) 写入公钥+改端口      2) 只改端口
    3) 关闭密码登录         4) 回滚 SSH 配置

【体检与调优】
    5) TCP 质量检测         6) NQ 测试
    7) TCP 调优(tcpfit)
    8) sing-box 面板(sb)

【目标筛选】
    9) Reality 目标扫描     10) 重装扫描引擎

【维护】
   11) 默认设置            12) 更新 rc
   13) 查看执行日志

【危险】
   14) 卸载 rc（含引擎/tcpfit）
   15) 模块单独卸载
   16) 查看当前 SSH 端口

  ─────────────────────────────────────────
    0) 退出

  请选择 [0-16]:
```

## What the panel does

| Section | Entry | Behaviour |
|---|---|---|
| SSH | `1` write key + change port | Appends the public key, changes the SSH port, opens the firewall; after a successful switch only the new port remains and the old one (including the default 22) stops listening; backs up to `/root/vps-init-backup`, validates with `sshd -t` and rechecks listeners, rolls back automatically on failure |
| SSH | `2` port only / `3` disable password login / `4` rollback | Tighten step by step; disabling password login first confirms the new port works; rollback restores any backup. Old ufw rules are not removed automatically |
| Checks & tuning | `5` TCP quality / `6` NQ test / `7` TCP tuning | Runs TcpQuality, NodeQuality and tcpfit in turn, then applies the suggested kernel tuning |
| Checks & tuning | `8` sing-box panel (sb) | One-shot install of [singbox-lite](https://github.com/G1oow/singbox-lite): downloads `singbox.sh` to `/usr/local/bin/sb`, validates it and opens its own menu; when it is already installed the download is skipped and the menu opens directly. The sing-box / Xray cores are installed on demand from that menu |
| Target selection | `9` REALITY target scan | Asks every run which family to scan (IPv4 / IPv6 / dual stack — the previous choice is never reused), drives the engine across the ASN's prefixes, and falls back to other ASNs in the same country when the same ASN yields too few targets |
| Target selection | `10` reinstall engine | Reinstalls the engine into `RC_DIR` when it is missing or broken |
| Maintenance | `11` defaults / `12` update rc / `13` view log | Edit SSH port, key, scan directory, scan limit, backup retention and SSH auto-rollback; self-update the panel and reload straight into the new version (no bounce back to the old menu); read `/var/log/rc-manager.log` |
| Danger | `14` uninstall rc | Removes `rc`, the `RC` symlink, the engine directory, tcpfit (including iperf3), `/etc/rc-manager` and the log; SSH changes, backups, the asset-database backup and `/usr/local/bin/sb` stay (the sb menu uninstalls itself). Before uninstalling tcpfit the panel asks whether to roll back the kernel tuning — the default is **no rollback** (choosing to keep the tuning keeps both tcpfit and iperf3) |
| Danger | `15` uninstall a single module | Remove just one: scanning engine / tcpfit / iperf3 / rc config and log |
| Danger | `16` port switch | Lists the configured SSH ports with their listen state, can re-enable a closed port or close one of them, and refuses to close the only SSH port |

The panel changes system state: with `DRY_RUN=1` every action is printed instead of executed, which is the recommended way to try it first.

## Install

Debian / Ubuntu as root, one line and you land in the menu:

```bash
curl -fsSL https://raw.githubusercontent.com/G1oow/RC/main/rc.sh | bash
```

The script installs itself at `/usr/local/bin/rc`, creates the `/usr/local/bin/RC` symlink and opens the menu; use `| sudo bash` when you are not root, or `| bash -s -- install-self` to install without starting. The scanning engine needs no manual install: entry `9) REALITY target scan` downloads it into `RC_DIR` (default `/root/rc-new`). The sing-box panel needs no manual install either: entry `8) sing-box 面板(sb)` drops it at `/usr/local/bin/sb` and opens its menu.

## Subcommands

Every menu action has a non-interactive subcommand for scripting:

| Command | Effect |
|---|---|
| `rc` | Open the interactive menu (default) |
| `rc ssh` | Write public key, change SSH port, open firewall |
| `rc ssh-close` | Disable password login after confirming the new port |
| `rc ssh-ports` | List SSH ports and interactively open or close one; the only SSH port cannot be closed |
| `rc tcpq` | TCP quality check (TcpQuality) |
| `rc score` | NQ test (NodeQuality) |
| `rc tune` | TCP tuning (tcpfit) |
| `rc sb` | Install the sing-box panel (singbox-lite) and open its menu |
| `rc reality` | REALITY camouflage target selection |
| `rc status` | Show OS, SSH ports, ufw, TCP congestion control, engine, tcpfit and sb status |
| `rc rollback` | Roll back the SSH configuration (`--yes` skips the prompt; restores `/etc/ssh` and the socket drop-in) |
| `rc rollback-cancel` | Cancel a scheduled SSH auto-rollback |
| `rc install-self` | Install or repair the panel at `/usr/local/bin/rc` |
| `rc update` | Update the panel itself (non-interactive; re-run `rc` afterwards to enter the new version) |
| `rc uninstall` | Uninstall the panel plus the installed engine, tcpfit and iperf3 |
| `rc uninstall engine\|tcpfit\|iperf3\|conf` | Uninstall one module only |
| `rc help` | Show help |

Legacy arguments `0` / `0b` / `1` / `2` / `3` / `4` still work and map to the subcommands above (`5` is the same as `rc sb`). `rc ssh` and `rc ssh-ports` snapshot `/etc/ssh` (plus the socket drop-in in socket mode) before changing ports, and restore that snapshot when validation, reload or the post-change listener check fails. The `vps-init.sh` file at the repository root is only a compatibility shim that forwards to `rc.sh`.

## Panel and engine

`rc reality` makes sure the engine is present, then asks **every run** which family to scan (IPv4 / IPv6 / dual stack — the previous choice is never reused) before driving a scan. Domain selection criteria belong to the engine: same ASN or same facility, no public CDN, not a top-traffic site, a real TLS 1.3 + X25519 + HTTP/2 handshake, enough remaining certificate lifetime, low handshake latency. When the same ASN cannot fill the quota, the engine falls back to other ASNs in the same country plus locally cached assets. The default quota is 10 targets.

Run on its own, the engine keeps its full CLI surface; the panel is just one caller:

| Engine command | Effect |
|---|---|
| `get <ip> [-n 5] [-s 3] [--fresh] [--json]` | Return ranked targets for an IP, cache first |
| `auto <ip/cidr> [--limit 10] [--ipv4-only\|--ipv6-only] [-v]` | Resolve the input's ASN prefixes and scan them into the database; falls back to same-country ASNs when short |
| `daemon [-t 500] [--interval 10] [--country US]` | Run the 24h multi-ASN scanning daemon |
| `patrol [--daemon]` | Re-test stored assets and apply lifecycle maintenance |
| `asn <ASN> <country> [--stats] [--seed]` | List an ASN's announced prefixes filtered by country |
| `pipe` | Stream targets from stdin |
| `check <domain>` | Probe a single domain |
| `batch <d1> <d2> ...` | Probe several domains |
| `migrate [--from ...] [--to ...]` | Move the asset database between SQLite and PostgreSQL |
| `version` | Print version, commit and build time |

The engine's `install.sh` lays it down in `/root/rc-new` together with `config.yaml` and the `data/` files; verdicts land in `data/reality_targets.db`.

## Architecture

```text
          ┌─────────────────────────────────────────────────────┐
   you ─▶ │ rc panel (rc.sh → /usr/local/bin/rc)                 │
          │ ① SSH  ② checks & tuning  ③ targets  ④ maintenance  │
          └───────────────┬─────────────────────────────────────┘
                          │ rc reality: probe egress IP + call engine
          ┌───────────────▼─────────────────────────────────────┐
          │ scanning engine (/root/rc-new)                      │
          │ ASN prefixes → concurrent TLS handshakes → filters  │
          │ → asset database                                    │
          └───────────────┬─────────────────────────────────────┘
                          │
          ┌───────────────▼─────────────────────────────────────┐
          │ reasni-daemon.service: 24h ASN rotation + patrol     │
          └─────────────────────────────────────────────────────┘
```

Panel and engine are plain Bash and Go artifacts: no Node runtime and no frontend build step. The engine binary is cross-compiled and published by CI.

## Configuration

Panel settings persist in `/etc/rc-manager/rc.conf` (0600); environment variables of the same name take precedence:

| Key | Default | Effect |
|---|---|---|
| `SSH_PORT` | `30000` | Target SSH port |
| `SSH_PUBKEY` / `SSH_PUBKEY_FILE` | empty | Public key content or path to a public key file |
| `RC_DIR` | `/root/rc-new` | Engine install directory |
| `SCAN_LIMIT` | `10` | Maximum targets kept by `rc reality` |
| `DRY_RUN` | `0` | `1` prints every action instead of executing it |
| `BACKUP_ROOT` | `/root/vps-init-backup` | SSH configuration backup directory |
| `RC_BACKUP_KEEP` | `10` | How many backups of each kind are kept |
| `RC_SSH_AUTO_ROLLBACK_MIN` | `0` | Auto-roll back the SSH change after N minutes (`0` = off; needs `systemd-run` or `at`) |

The engine's `config.yaml` is independent of the panel; the keys that matter most:

| Key | Effect |
|---|---|
| `database.driver` | `sqlite` (built-in default) or `postgres` |
| `database.sqlite.path` | Asset database path, default `data/reality_targets.db` |
| `reality_filter.scan_threads` | Scan concurrency, default `200` |
| `reality_filter.scan_timeout` | Per-IP handshake timeout in seconds, default `3` |
| `reality_filter.ipv6_budget` | Per-prefix probe budget for IPv6, default `4096` (host bits are sampled as pseudo-random IIDs) |
| `reality_filter.require_no_cdn` / `require_no_cn` | Reject CDN edges and CN sites |
| `reality_filter.check_gfw` | Toggle the static GFW list check |
| `reality_filter.use_cache` / `cache_max_days` | Cache-first lookups and cache age, default 7 days |
| `proxy.url` / `proxy.scanner` | Outbound proxy for engine downloads and scanning |

## Upgrade note

Earlier versions shipped an embedded HTTP API and web console. Both are gone: the panel, the CLI and the systemd daemon no longer listen on any port. If `DAEMON_OPTS` in `/etc/default/reasni` still carries `--port` / `--host` / `--token` / `--no-http`, the engine prints a notice and ignores them, but you should drop them and keep only `-t` and `--interval`.

## Documentation

| Topic | What it covers | Link |
|---|---|---|
| Run as a service | systemd unit, `/etc/default/reasni` and maintenance commands | [src/deploy/systemd/README.md](./src/deploy/systemd/README.md) |
| Build and release | Cross-compilation, embedded assets, CI entry point | [src/build.sh](./src/build.sh) |
| Development docs | Architecture, database lifecycle, scanner design | [src/doc/dev](./src/doc/dev) |
| Docs site source | VitePress home page and navigation | [src/doc/index.md](./src/doc/index.md) |
| All options | Commented reference for every config key | [config.yaml](./config.yaml) |

## License

This project is licensed under the [MIT License](./LICENSE).

For network research and learning only. Follow local law and use network resources responsibly.
