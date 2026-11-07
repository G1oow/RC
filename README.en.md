<p align="center">
  <img src="./assets/icon.png" width="200" alt="RealityChecker logo">
</p>

<h1 align="center">RealityChecker</h1>

<p align="center">A Go toolchain that discovers, probes and ranks REALITY SNI camouflage targets, shipped with one-command VPS deployment.</p>

<p align="center">
  <a href="./README.en.md">English</a> | <a href="./README.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/G1oow/RC/actions/workflows/build.yml"><img src="https://github.com/G1oow/RC/actions/workflows/build.yml/badge.svg" alt="Build and Release workflow status"></a>
  <img src="https://img.shields.io/badge/Go-1.26.0-3776AB?style=flat-square&logo=go" alt="Go 1.26.0">
  <img src="https://img.shields.io/badge/platform-linux--amd64%20%7C%20linux--arm64%20%7C%20windows--amd64-4B5563?style=flat-square" alt="Linux amd64, Linux arm64 and Windows amd64 builds">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-22C55E?style=flat-square" alt="MIT License"></a>
</p>

RealityChecker answers one narrow question: which public websites on a given network range still pass a real REALITY handshake test? It expands a VPS IP into its announced ASN prefixes, scans those ranges, keeps only hosts that negotiate TLS 1.3 with X25519 and HTTP/2, and stores every verdict in a local asset database. Results are ranked 1-5 by protocol support, certificate and CDN signals, so you pick a camouflage domain from evidence instead of guessing one.

## Highlights

| Highlight | Why it matters |
|---|---|
| Linux one-command deploy | `install.sh` pulls the release binary, `config.yaml` and the `data/` files, probes the machine's egress IPv4/IPv6 address, and prints the exact `auto` command to run next |
| Windows one-command deploy | `install.ps1` creates the same layout under `%USERPROFILE%\reality-checker` |
| Runs as a service | `src/deploy/systemd/reasni-daemon.service` with `reasni.env` starts the 24h daemon under systemd |
| VPS bootstrap panel (`rc` / `RC`) | `rc.sh` installs as `rc` and creates the `RC` alias, then walks a fresh Debian/Ubuntu host through SSH hardening (backed up, checked with `sshd -t`, auto-rolled back on failure), TCP quality checks, NQ scoring, TCP tuning, and finally REALITY target selection |
| Protocol-level filtering | A candidate must support TLS 1.3, X25519 and HTTP/2, and is dropped when it is a CDN edge, a hot website list entry, a default nginx page, a redirect, a blocked domain or a CN site |
| Ranked, cache-first results | `get` serves targets scored 1-5 from the local SQLite database without rescanning (`--fresh` forces a rescan); `serve` exposes the same data over REST and SSE |

## Architecture

```text
┌────────────────────────────────────────────────────────────────────┐
│ cmd (src/main.go)                                                  │
│ get  auto  serve  daemon  patrol  asn  pipe  check  batch          │
└────────────────────────────────────────────────────────────────────┘
                                   │
┌──────────────────────────────────▼─────────────────────────────────┐
│ core.Engine  -  internal/core                                      │
│ auto_scanner  pipeline  filter  patrol  daemon                     │
└──────────┬───────────────────────┬───────────────────────┬─────────┘
           │                       │                       │
┌──────────▼─────────┐  ┌──────────▼─────────┐  ┌──────────▼─────────┐
│ internal/asn       │  │ internal/detectors │  │ internal/storage   │
│ RIPEstat prefixes  │  │ TLS1.3, X25519, h2 │  │ SQLite/PostgreSQL  │
│ country lookup     │  │ CDN/302/hot site   │  │ ASN + target store │
└────────────────────┘  └──────────┬─────────┘  └────────────────────┘
                                   │
                        ┌──────────▼─────────┐
                        │ target websites    │
                        └────────────────────┘

HTTP surface
┌──────────────────┐     ┌──────────────────────────────┐     ┌──────────────────┐
│ serve / daemon   │ ──▶ │ internal/server: REST + SSE  │ ──▶ │ embedded web UI  │
└──────────────────┘     └──────────────────────────────┘     └──────────────────┘
```

The Go binary embeds the built frontend (`src/web`), so `serve` and `daemon` serve the console and the `/api/*` endpoints from the same process.

## Usage Example

`get` returns targets for one IP from the asset database first; `auto` scans the surrounding range into it; `serve` publishes the result set.

```bash
./reality-checker-main get 203.0.113.10 -n 5 -s 4
./reality-checker-main get 203.0.113.10 --json
./reality-checker-main auto 203.0.113.10 --limit 5
./reality-checker-main serve --port 8881
```

`get` prints a ranked table (JSON with `--json`) and only rescans with `--fresh`. `auto` scans concurrently and keeps at most `--limit` suitable targets. `serve` listens on `:8881`, serves the embedded console at `/`, and requires a token only when one is configured.

## Quick Install

Linux: bash, curl, and a published release (the script defaults to `REF_TAG=latest`).

```bash
curl -LfsS https://raw.githubusercontent.com/G1oow/RC/main/install.sh -o install.sh
bash install.sh            # optional first argument: install directory (default /root/rc-new)
```

Windows PowerShell:

```powershell
.\install.ps1              # optional first argument: install directory (default %USERPROFILE%\reality-checker)
```

From source. Go 1.26, Node 22 and pnpm 9 are required because the web assets must be built and embedded before `go build`:

```bash
cd src && ./build.sh
```

On Windows, use `.\src\build.ps1` instead. Either script writes `dist/reality-checker-linux-amd64`, `dist/reality-checker-linux-arm64` and `dist/reality-checker-windows-amd64.exe`.

## Quick Start

```bash
cd /root/rc-new
./reality-checker-main auto 203.0.113.10 --limit 5
```

A bare IPv4 is expanded to its `/24` and a bare IPv6 to its `/64`; a CIDR is scanned as given. Startup probes the public egress IP first, and needs `-f` when that probe fails (offline hosts, blocked probe endpoints). Verdicts land in `data/reality_targets.db`.

## Commands

| Command | What it does |
|---|---|
| `get <ip> [-n 5] [-s 3] [--fresh] [--json]` | Return scored targets for an IP, cache first |
| `auto <ip/cidr> [--limit 5] [-v]` | Resolve ASN prefixes for the input and scan them concurrently into the database |
| `serve [--port 8881] [--host 0.0.0.0] [--token TOKEN]` | Start the REST/SSE service and embedded console |
| `daemon [-t 500] [--interval 10] [--country US]` | Run the 24h multi-ASN scanning daemon |
| `patrol [--daemon]` | Re-test stored assets and apply lifecycle maintenance |
| `asn <ASN> <country> [--stats] [--seed]` | List an ASN's announced prefixes filtered by country |
| `pipe` | Stream targets from stdin |
| `check <domain>` | Probe a single domain |
| `batch <d1> <d2> ...` | Probe several domains |
| `migrate [--from ...] [--to ...]` | Move the asset database between SQLite and PostgreSQL |
| `version` | Print version, commit and build time |

Global options: `-c, --config FILE` and `-f, --force`.

## VPS Panel (rc / RC)

`rc.sh` is the bundled single-file operations panel. It installs to `/usr/local/bin/rc` and creates the `/usr/local/bin/RC` symlink, so both `rc` and `RC` open it. Debian / Ubuntu, root required.

```bash
curl -LfsS https://raw.githubusercontent.com/G1oow/RC/main/rc.sh \
  -o /usr/local/bin/rc && chmod +x /usr/local/bin/rc && rc
```

Panel menu:

| Item | Action |
|---|---|
| 1 | SSH hardening: write the public key, change the port, open the firewall (stage 0) |
| 2 | Change the SSH port only |
| 3 | Disable password login (stage 0b) |
| 4 | Roll back the SSH configuration |
| 5 | TCP quality check (TcpQuality) |
| 6 | NQ test (NodeQuality) |
| 7 | TCP tuning (tcpfit) |
| 8 | REALITY target selection (reality-checker) |
| 9 | Reinstall reality-checker |
| 10 | Defaults: SSH port, public key, scan directory, scan limit, DRY_RUN |
| 11 | Update rc itself |
| 12 | View the execution log |
| 13 | Uninstall rc |
| 0 | Exit |

Every item also runs non-interactively:

```bash
rc                 # open the panel (default)
rc ssh             # stage 0: public key, SSH port, firewall
rc ssh-close       # stage 0b: disable password login after the new port works
rc tcpq            # stage 1: TCP quality check
rc score           # stage 2: NQ test
rc tune            # stage 3: TCP tuning
rc reality         # stage 4: REALITY target selection
rc status          # component status
rc rollback        # roll back the SSH configuration
rc install-self    # install or repair /usr/local/bin/rc
rc update          # update rc itself
rc uninstall       # uninstall rc
rc help            # help
```

Legacy numeric arguments `0 / 0b / 1 / 2 / 3 / 4` still work (`5`, once the sb panel hook, is no longer wired up); `vps-init.sh` is a compatibility shell that forwards to `rc.sh`.

Defaults persist in `/etc/rc-manager/rc.conf` (mode `0600`) and same-named environment variables win, for example `SSH_PORT`, `RC_DIR`, `SCAN_LIMIT`, `DRY_RUN` and `BACKUP_ROOT`. SSH changes are backed up to `/root/vps-init-backup`, validated with `sshd -t`, and rolled back automatically on failure; the log lives at `/var/log/rc-manager.log`. Uninstalling removes only `rc`, `RC`, `/etc/rc-manager` and the log, while an installed reality-checker, tcpfit, the SSH changes and the backup directory stay.

## HTTP API

`serve` and `daemon` expose `/api/health`, `/api/stats`, `/api/filter/default`, `/api/targets/smart`, `/api/targets/stream` (SSE), `/api/targets/check`, `/api/targets`, `/api/targets/{domain}` and `/api/asns`. Authentication is off by default; enable it with `--token`, `RC_API_TOKEN`, or `server.api_token` in the config.

## Configuration

`config.yaml` is picked up from `-c/--config`, then the environment, the working directory, and the binary's directory.

| Key | Effect |
|---|---|
| `database.driver` | `sqlite` (built-in default) or `postgres`; the shipped file selects `postgres` with `host: 127.0.0.1` |
| `database.sqlite.path` | Asset database path, default `data/reality_targets.db` |
| `reality_filter.scan_threads` | Scan concurrency, default `200` |
| `reality_filter.scan_timeout` | Per-IP handshake timeout in seconds, default `3` |
| `reality_filter.require_no_cdn` / `require_no_cn` | Reject CDN edges and CN sites |
| `reality_filter.check_gfw` | Toggle the static GFW list check (off in the shipped file) |
| `reality_filter.use_cache` / `cache_max_days` | Serve from the asset DB and set cache age, default 7 days |

## Documentation

| Topic | What it covers | Link |
|---|---|---|
| Run as a service | systemd unit and environment template | [src/deploy/systemd/README.md](./src/deploy/systemd/README.md) |
| Build and release | Cross-compilation, embedded assets, CI entry point | [src/build.sh](./src/build.sh) |
| Development docs | Architecture, database lifecycle, scanner design | [src/doc/dev](./src/doc/dev) |
| Docs site source | VitePress home page and navigation | [src/doc/index.md](./src/doc/index.md) |
| All options | Commented reference for every config key | [config.yaml](./config.yaml) |

## License

This project is licensed under the [MIT License](./LICENSE).
