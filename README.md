# Immich Resource Control

Power-aware CPU management for [Immich](https://immich.app) on small, shared
home servers. It lets you switch Immich between **ECO**, **PWR** and **AUTO**
resource profiles and shows you exactly what is currently in effect:
job concurrency, hard CPU caps (per container), and the live job queues.

Originally built for an **Intel Core i3-3240 (4 threads)** running Immich
v3.3.5 under CasaOS/Docker, but the mechanics work on any Docker host running
Immich 3.x.

## The problem

Immich's machine-learning tasks (face recognition, OCR, smart search) run
inside the `immich-machine-learning` container and can easily saturate a small
CPU (we measured ~294% CPU on a 4-thread box). Meanwhile `immich-server`
transcoding/thumbnails also compete for cores with the rest of your stack. The
default tuning is "use everything available," which fights your other services
and wastes power when nothing is going on.

This repo gives you manual control plus an optional automatic "emergency brake"
that hands the CPU back to other workloads when they need it.

## What is inside

```
immich-resource-control/
├── scripts/
│   ├── resource-control.sh    # interactive + non-interactive menu (ECO/PWR/AUTO + scheduling)
│   └── cpu-brake.sh           # per-minute brake: dynamic in AUTO, cap enforcer in ECO/PWR
├── .brake-mode                # created on first run: AUTO | ECO | PWR
├── .brake-state               # brake internal state (level + calm counter)
├── .brake-expire              # created only for scheduled ECO/PWR (epoch seconds)
├── cpu-brake.log              # brake audit log
├── AGENTS.md
└── README.md
```

## Modes

| Mode | Job concurrency | CPU caps (server / ML) | What the brake does each minute |
|------|----------------|------------------------|---------------------------------|
| **ECO** | 1 for every queue | 0.5 / 0.25 cores | Re-asserts those caps if they drift (lock survives container recreation) |
| **PWR** | Immich defaults (thumb 3, meta 5, ML 2, …) | Unlimited (4/4) | Re-asserts uncaps if they drift |
| **AUTO** | 1 for every queue | Released (3.5/3.0), brake decides | Evaluates *non-Immich* CPU load: idle → release, light → throttle, heavy → curb |

## Scheduling (ECO and PWR)

Both ECO and PWR can be scheduled for a duration, after which the mode
auto-reverts to **AUTO**:

```bash
# non-interactive
resource-control.sh eco 4d11h9m   # ECO for 4 days 11 h 9 min, then AUTO
resource-control.sh pwr 7h        # PWR for 7 hours, then AUTO
resource-control.sh eco 20m       # ECO for 20 minutes, then AUTO
resource-control.sh auto          # cancel any pending schedule immediately
```

Duration format: `4d11h9m` / `7h` / `20m` / `3d` / `1h30m` — days `d`,
hours `h`, minutes `m`, seconds `s`, combinable.

Interactively, press **E** or **P** and you'll be prompted:
"Toggle to ECO [Enter] or Schedule ECO (input in format: 4d11h9m or 7h or 20m or 3d)?"
Press Enter for immediate, or type a duration to schedule.

The expiry is stored in `.brake-expire` (epoch seconds). The brake checks it
every minute; once passed it flips the mode back to AUTO and re-releases the
caps.

## How a manual lock stays locked

In ECO/PWR the brake doesn't just stand down — it enforces. Every minute it
compares the live Docker CPU caps against the mode's pinned values and
re-applies them if something (a `docker compose up` recreation, a manual
`docker update`, a host reboot) drifted them. So once you lock ECO or PWR it
stays locked until you switch modes or the schedule expires.

## Quick start

### 1. Install on your Immich host

Pick a place where the Immich stack already lives (e.g.
`/var/lib/home-server/stacks/immich` for CasaOS):

```bash
mkdir -p /opt/immich-resource-control/scripts
# copy both scripts there, then:
chmod +x /opt/immich-resource-control/scripts/*.sh
```

### 2. Switch a mode

Interactively:

```bash
/opt/immich-resource-control/scripts/resource-control.sh
```

Non-interactively (good for cron or other automation):

```bash
/opt/immich-resource-control/scripts/resource-control.sh eco
/opt/immich-resource-control/scripts/resource-control.sh pwr
/opt/immich-resource-control/scripts/resource-control.sh auto
```

With a duration:

```bash
/opt/immich-resource-control/scripts/resource-control.sh eco 20m
/opt/immich-resource-control/scripts/resource-control.sh pwr 7h
```

### 3. Enable the automatic brake (AUTO mode)

Add this to your crontab:

```bash
* * * * * /opt/immich-resource-control/scripts/cpu-brake.sh >/dev/null 2>&1
```

The brake samples CPU for 10 seconds each run, computes how many cores are
used by **non-Immich** work, and adjusts Docker CPU caps accordingly:
heavy other load → `CURB` (0.4 / 0.1 cores), light load → `THROTTLE`
(1.0 / 0.4), sustained idle → `RELEASED` (3.5 / 3.0). State lives in
`.brake-state` next to the script; an audit log goes to `cpu-brake.log`.

### How it applies settings

- **CPU caps** (`docker update --cpus`) take effect instantly — no restart.
- **Job concurrency** lives in Immich's `system_metadata.system-config` JSONB
  column in Postgres; changing it restarts `immich-server` once so the new
  concurrency is picked up.
- Switching to/from **PWR** changes concurrency → restarts the server once.
- Switching to **ECO/AUTO** leaves concurrency at 1 → no restart unless
  needed.

## Sample output

```
Immich Resource Control
============================================================
Brake mode     : AUTO (emergency brake ACTIVE)
Brake state    : RELEASED (calm counter 3)
CPU caps       : 3.5/3.0 of 4 cores
ML tasks       : facialRecognition/OCR/smartSearch ENABLED, memories generation OFF
Transcoding    : vaapi (QSV unsupported on this iGPU), 720p, ultrafast, two-pass off
CPU shares     : server 512 / ML 256 of 1024
Job concurrency: backgroundTask=1 editor=1 ... smartSearch=1 thumbnailGeneration=1
Queues waiting : faceDetection=117 smartSearch=0 facialRecognition=1185 ocr=1530
Live usage     : immich-server 2.06% ... immich-machine-learning 10.35% ...
============================================================
Resource Control Setting: [E]ECO mode  [P]PWR mode  [A]AUTO mode  [R]refresh  [Q]Quit
```

## Prerequisites

- Docker + `docker compose` (or `docker-compose`)
- Immich 3.x with a running Postgres container named `immich-postgres`
  and a Valkey/Redis container named `immich-redis`
- `jq`, `bash`, `cron` (for AUTO)
- A system user able to run `docker` commands

## Customizing

Edit the top of `scripts/cpu-brake.sh` for your hardware:

```bash
THREADS=4               # nproc of your machine
WINDOW=10               # brake sampling window (seconds)
SRV_CONTAINER=immich-server
ML_CONTAINER=immich-machine-learning
```

and the decision thresholds inside `cpu-brake.sh` (heavy >1.5 cores,
light >0.4 cores, release after 3 calm samples).

Edit `scripts/resource-control.sh` `JSON_LOW` / `JSON_HIGH` to pick your own
concurrency presets.

## Removing / reverting

```bash
# stop the brake
crontab -e   # remove the cpu-brake.sh line

# restore unlimited caps (example)
docker update --cpus 4 immich-server
docker update --cpus 4 immich-machine-learning
# restore default concurrency via Immich UI → Machine Learning Settings,
# or reset system-config in Postgres system_metadata table
```

Then delete `/opt/immich-resource-control`.

## License

MIT — do whatever you want, no warranty.
