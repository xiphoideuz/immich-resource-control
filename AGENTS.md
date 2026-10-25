# AGENTS.md

This repo contains `immich-resource-control`: power-aware CPU management
scripts for Immich on small shared home servers.

## What lives here

- `scripts/resource-control.sh` — interactive/non-interactive mode switcher
  (ECO / PWR / AUTO). Reads + writes Immich job concurrency from Postgres
  (`system_metadata.system-config`) and sets Docker CPU caps on
  `immich-server` / `immich-machine-learning`. Supports optional duration
  scheduling for ECO and PWR (auto-revert to AUTO after expiry).
- `scripts/cpu-brake.sh` — per-minute brake. In AUTO mode it samples
  whole-machine CPU over a 10s window and throttles/releases Immich caps based
  on *non-Immich* load. In ECO/PWR mode it re-asserts the pinned caps every
  run, so a manual lock survives container recreation or cap drift.
- State files (created at runtime on the target host, NOT committed here):
  `.brake-mode` (AUTO|ECO|PWR), `.brake-state` (level + calm counter),
  `.brake-expire` (epoch seconds, only while scheduled), `cpu-brake.log`.

## How the modes work (canonical source)

See `resource-control.sh`:

- `JSON_LOW` — concurrency 1 for all 15 job queues (ECO/AUTO)
- `JSON_HIGH` — Immich defaults (PWR)
- `caps_for_mode()` — ECO 0.5/0.25, PWR 4/4, AUTO 3.5/3.0
- `parse_duration()` — `4d11h9m` / `7h` / `20m` / `3d` / combos → seconds
- `apply_scheduled()` — writes `.brake-expire`, applies mode, schedules revert
- Switching to/from PWR changes concurrency → `docker restart immich-server`
- CPU caps apply via `docker update --cpus` instantly
- Manual mode writes `.brake-mode`; cpu-brake.sh enforces fixed caps in
  ECO/PWR, runs dynamic evaluation only in AUTO

## If you edit anything

- **Concurrency defaults** → edit `JSON_LOW` / `JSON_HIGH` in
  `resource-control.sh`
- **Brake thresholds/levels** → edit `cpu-brake.sh` (THREADS, WINDOW,
  RELEASE_CALM_REQUIRED, the 0.4 / 1.5 core breakpoints, cap values per level)
- **Paths** → `DIR="$(cd "$(dirname "$0")" && pwd)"` inside both scripts;
  state/log files live next to them

## Testing without an Immich host

```bash
bash -n scripts/resource-control.sh scripts/cpu-brake.sh
# parse_duration is sourced inline; test it by extracting the function:
source <(sed -n '/^parse_duration()/,/^}/p' scripts/resource-control.sh)
parse_duration 4d11h9m   # expect 367740
parse_duration 7h        # expect 25200
parse_duration abc       # expect error
```

On a real host you need running containers `immich-postgres`,
`immich-machine-learning`, `immich-server`, `immich-redis`, plus `jq` and
`docker` perms. Cron line:

```cron
* * * * * /path/to/scripts/cpu-brake.sh >/dev/null 2>&1
```

## Target-host layout (reference; not part of repo)

```
/var/lib/home-server/stacks/immich/
    cpu-brake.sh
    resource-control.sh
    .brake-mode      # AUTO|ECO|PWR  (created by resource-control.sh)
    .brake-state     # level + calm counter
    .brake-expire    # epoch seconds, only while ECO/PWR scheduled
    cpu-brake.log
```

Read `scripts/resource-control.sh` for full mode logic and `README.md` for
the user-facing install guide.
