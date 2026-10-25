# AGENTS.md

This repo contains `immich-resource-control`: power-aware CPU management
scripts for Immich on small shared home servers.

## What lives here

- `scripts/resource-control.sh` — interactive/non-interactive mode switcher
  (ECO / PWR / AUTO). Reads + writes Immich job concurrency from Postgres
  (`system_metadata.system-config`) and sets Docker CPU caps on
  `immich-server` / `immich-machine-learning`.
- `scripts/cpu-brake.sh` — per-minute emergency brake for AUTO mode. Measures
  whole-machine CPU over a 10s window, subtracts Immich's share, and adjusts
  Docker `--cpus` caps when *other* work is running.
- State files (created at runtime on the target host, NOT committed here):
  `.brake-mode`, `.brake-state`, `cpu-brake.log`.

## How the modes work (canonical source)

See `resource-control.sh`:

- `JSON_LOW` — concurrency 1 for all 15 job queues (ECO/AUTO)
- `JSON_HIGH` — Immich defaults (PWR)
- `caps_for_mode()` — ECO 0.5/0.25, PWR 4/4, AUTO 3.5/3.0
- Switching to/from PWR changes concurrency → `docker restart immich-server`
- CPU caps apply via `docker update --cpus` instantly
- Manual mode writes `.brake-mode`; cpu-brake.sh exits early unless mode is AUTO

## If you edit anything

- **Concurrency defaults** → edit `JSON_LOW` / `JSON_HIGH` in
  `resource-control.sh`
- **Brake thresholds/levels** → edit `cpu-brake.sh` (THREADS, WINDOW,
  RELEASE_CALM_REQUIRED, the 0.4 / 1.5 core breakpoints, cap values per level)
- **Paths** → `DIR="$(cd "$(dirname "$0")" && pwd)"` inside both scripts,
  state/log files live next to them

## Testing without an Immich host

Neither script has unit tests. Smoke checks:

```bash
bash -n scripts/resource-control.sh scripts/cpu-brake.sh
shellcheck scripts/*.sh          # optional
# Non-interactive mode prints status; use --help-less first arg:
./scripts/resource-control.sh auto   # writes mode file, sets caps, shows status
```

On a real host you need running containers `immich-postgres`,
`immich-machine-learning`, `immich-server`, `immich-redis`, plus `jq` and
`docker` perms.

## Target-host layout (reference; not part of repo)

```
/var/lib/home-server/stacks/immich/
    cpu-brake.sh
    resource-control.sh
    .brake-mode      # AUTO|ECO|PWR  (created by resource-control.sh)
    .brake-state     # level + calm counter
    cpu-brake.log
crontab: * * * * * /var/lib/home-server/stacks/immich/cpu-brake.sh
```

Read `scripts/resource-control.sh` for full mode logic and `README.md` for
the user-facing install guide.
