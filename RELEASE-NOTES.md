# Release Notes - crz-opt

## v1.0.0 - 2026-06-09

Major release - kompletná rearchitektúra na dva nezávislé Docker Compose stacky s automatickým restore workflow.

### Zmeny架构

**Nová štruktúra Docker Compose:**
- `docker-compose.db.yml` - samostatný MariaDB 12.1 stack (port 53306)
- `docker-compose.yml` - samostatný restore-worker stack
- Zdieľaný externý bridge network `crz-opt-net` (subnet `10.91.0.0/24`)
- `restore-worker` beží na `crz-opt-net` a komunikuje s DB cez hostnme `crz-opt-mariadb`

**Scripts embedded v image:**
- `Dockerfile.restore-worker` kopíruje `scripts/` do `/opt/crz-opt-scripts/`
- Všetky skripty bežia z container image, nie cez volume mount
- Entry point: `restore-worker-entrypoint.sh`

**Auto-restore workflow:**
- `watch-dumps.sh` automaticky sleduje `data/dumps/*.sql.gz`
- Pri novom stabilnom dumpe (120s stabilita) spustí restore + backfill
- Stav v `data/restore-state/`: `last-success.id`, `last-success.state`, `current.state`
- Lockfile mechanism pre zabránenie parallel restore

**Progress monitoring:**
- `pv` progress bar pri restore cez pipe
- Progress logging každých 50,000 statements do run logu
- CSV formát: `timestamp,total_bytes,bytes_read,time_elapsed,speed`

**DB operácie:**
- `container-wait-ready.sh` používa `MARIADB_USER=crz` namiesto root
- `DB_HOST` env var pre context-aware pripojenie (worker: `crz-opt-mariadb`, local: `127.0.0.1`)
- Bez root DB user pre healthcheck operácie

### Opravy

- `sql-restore-gz.sh`: `pv` progress filter nesprávne zaradzoval komentáre do dát
- `sql-lib.sh`: `PROJECT_DIR` computation fix pre scripts v `/opt/`
- Volume mount comment cleanup v `docker-compose.yml`

### Obsah

- MariaDB 12.1 so všetkými tuning parametrami
- `sql-benchmark-restore.sh` - hlavný restore workflow
- `sql-backfill-gz.sh` - async backfill pruned tabuliek
- `watch-dumps.sh` - automatický monitoring a spúšťanie
- `restore-metrics.py` - Prometheus-compatible metrics
- `container-restore.sh`, `container-backfill.sh` - helper scripts
- `filter-pruned-data.awk`, `filter-backfill.awk` - AWK filtre

### Restore režimy

| Režim | Prístup |
|-------|---------|
| `baseline` | Čistý restore bez optimalizácií |
| `fast` | Disable unique checks, foreign keys, autocommit |
| `aggressive` | + `key_buffer_size=4G`, `myisam_sort_buffer_size=4G`, performance_schema=OFF |
| `pruned-data` | Preskočenie `log_[0-9]+`, `counter_[0-9]+`, `robot_01`, `robot_02`, `elastic1` tabuliek |

### Overené merania (z v0.1.x)

| Režim | Čas | Poznámka |
|-------|-----|-----------|
| `fast` | 4384s (1:13:04) | - |
| `aggressive` | 4253s (1:10:53) | -131s vs fast |
| `pruned-data` | 2579s (42:59) | -1674s vs aggressive |

---

## v0.1.1 - 2026-06-01

Patch release:

- Volitelne HTTP Basic Auth prihlasovanie na metrics endpoint cez `METRICS_BASIC_AUTH_ENABLED`, `METRICS_BASIC_AUTH_USERNAME` a `METRICS_BASIC_AUTH_PASSWORD`.
- Metrics server pri chybajucom Docker CLI alebo timeout-e vrati scrape-failure metriky namiesto padu request handlera.

## v0.1.0 - 2026-06-01

Prva pouzitelna verzia MariaDB restore labu pre CRZ dump.