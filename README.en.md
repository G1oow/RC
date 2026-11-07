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

RC is the single entry point for taking a fresh VPS from bare to usable. Run `rc`, get a menu: lock SSH down first (key, port, password login off, with rollback), then check and tune TCP (TcpQuality / NodeQuality / tcpfit), then pick REALITY camouflage domains from the same box. Every stage lives in one menu, so you stop collecting one-off script URLs.

The panel holds no scanning logic itself: picking targets is delegated to the bundled scanning engine. The panel installs and drives that engine, and the engine also runs standalone as a CLI or a systemd daemon.

## What the panel does

| Section | Entry | Behaviour |
|---|---|---|
| SSH | `1` write key + change port | Appends the public key, changes the SSH port, opens the firewall; backs up to `/root/vps-init-backup`, validates with `sshd -t`, rolls back automatically on failure |
| SSH | `2` port only / `3` disable password login / `4` rollback | Tighten step by step; disabling password login first confirms the new port works; rollback restores any backup |
| Checks & tuning | `5` TCP quality / `6` NQ test / `7` TCP tuning | Runs TcpQuality, NodeQuality and tcpfit in turn, then applies the suggested kernel tuning |
| Target selection | `8` REALITY target scan | Probes the local egress IP, drives the engine across the ASN's prefixes, prints ranked candidates |
| Target selection | `9` reinstall engine | Reinstalls the engine into `RC_DIR` when it is missing or broken |
| Maintenance | `10` defaults / `11` update rc / `12` view log | Edit SSH port, key, scan directory and scan limit; self-update the panel; read `/var/log/rc-manager.log` |
| Danger | `13` uninstall rc | Removes `rc`, the `RC` symlink, `/etc/rc-manager` and the log; the installed engine, tcpfit, SSH changes and backups all stay |

The panel changes system state: with `DRY_RUN=1` every action is printed instead of executed, which is the recommended way to try it first.

## Install

Debian / Ubuntu, as root, one command and you land in the menu:

```bash
curl -LfsS https://raw.githubusercontent.com/G1oow/RC/main/rc.sh \
  -o /usr/local/bin/rc && chmod +x /usr/local/bin/rc && rc
```

The script installs the panel at `/usr/local/bin/rc` and creates the `/usr/local/bin/RC` symlink, so both `rc` and `RC` open the menu. The scanning engine needs no manual install: entry `8) REALITY target scan` downloads it into `RC_DIR` (default `/root/rc-new`).

## Subcommands

Every menu action has a non-interactive subcommand for scripting:

| Command | Effect |
|---|---|
| `rc` | Open the interactive menu (default) |
| `rc ssh` | Write public key, change SSH port, open firewall |
| `rc ssh-close` | Disable password login after confirming the new port |
| `rc tcpq` | TCP quality check (TcpQuality) |
| `rc score` | NQ test (NodeQuality) |
| `rc tune` | TCP tuning (tcpfit) |
| `rc reality` | REALITY camouflage target selection |
| `rc status` | Show OS, SSH, ufw, engine and tcpfit status |
| `rc rollback` | Roll back the SSH configuration |
| `rc install-self` | Install or repair the panel at `/usr/local/bin/rc` |
| `rc update` | Update the panel itself |
| `rc uninstall` | Uninstall the panel |
| `rc help` | Show help |

Legacy arguments `0` / `0b` / `1` / `2` / `3` / `4` still work and map to the subcommands above (`5`, the old sb panel entry, is no longer wired). The `vps-init.sh` file at the repository root is only a compatibility shim that forwards to `rc.sh`.

## Panel and engine

`rc reality` makes sure the engine is present, probes the machine's egress IP (`icanhazip.com`), then drives a scan and prints the result. Domain selection criteria belong to the engine: same ASN or same facility, no public CDN, not a top-traffic site, a real TLS 1.3 + X25519 + HTTP/2 handshake, enough remaining certificate lifetime, low handshake latency.

Run on its own, the engine keeps its full CLI surface; the panel is just one caller:

| Engine command | Effect |
|---|---|
| `get <ip> [-n 5] [-s 3] [--fresh] [--json]` | Return ranked targets for an IP, cache first |
| `auto <ip/cidr> [--limit 5] [-v]` | Resolve the input's ASN prefixes and scan them into the database |
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
| `SCAN_LIMIT` | `5` | Maximum targets kept by `rc reality` |
| `DRY_RUN` | `0` | `1` prints every action instead of executing it |
| `BACKUP_ROOT` | `/root/vps-init-backup` | SSH configuration backup directory |

The engine's `config.yaml` is independent of the panel; the keys that matter most:

| Key | Effect |
|---|---|
| `database.driver` | `sqlite` (built-in default) or `postgres` |
| `database.sqlite.path` | Asset database path, default `data/reality_targets.db` |
| `reality_filter.scan_threads` | Scan concurrency, default `200` |
| `reality_filter.scan_timeout` | Per-IP handshake timeout in seconds, default `3` |
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
