# crz-opt

Testovacie prostredie na optimalizáciu MariaDB restore výkonu pre CRZ databázu.

**Stav:** `v1.0.0` | Dva nezávislé Docker Compose stacky s auto-restore workflow

## Architektúra

```
┌─────────────────────────────────────────────────────────────┐
│  crz-opt-net (external bridge, 10.91.0.0/24)                 │
│                                                             │
│  ┌──────────────────┐      ┌────────────────────────────┐  │
│  │  crz-opt-mariadb │      │  crz-opt-restore-worker    │  │
│  │  MariaDB 12.1    │◄────►│  auto-restore workflow     │  │
│  │  port 53306      │ TCP  │  watch-dumps.sh            │  │
│  │  (127.0.0.1)     │      │  pv progress + metrics     │  │
│  └──────────────────┘      └────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Štruktúra

```
crz-opt/
├── docker-compose.db.yml      # MariaDB stack
├── docker-compose.yml         # Restore-worker stack
├── Dockerfile.restore-worker  # Image s embedded scripts
├── .env                       # Konfigurácia
├── VERSION                    # v1.0.0
├── scripts/                   # Všetky skripty (v image: /opt/crz-opt-scripts/)
│   ├── watch-dumps.sh         # Automatický monitoring dumpov
│   ├── sql-benchmark-restore.sh # Hlavný restore workflow
│   ├── sql-backfill-gz.sh     # Async backfill
│   ├── sql-restore-gz.sh      # Restore s pv progress
│   ├── container-restore.sh   # Container-aware restore
│   ├── container-backfill.sh  # Container-aware backfill
│   ├── container-wait-ready.sh # DB healthcheck
│   └── lib.sh / sql-lib.sh    # Zdieľané funkcie
├── data/
│   ├── dumps/                 # .sql.gz dumpy na obnovenie
│   ├── restore-state/         # Stav workeru
│   └── restore-runs/          # Logy jednotlivých behov
└── doc/
    ├── software-requirements-specification.md
    ├── project-state.md
    └── decision-log.md
```

## Rýchly štart

### 1. Vytvorenie siete a volume

```bash
docker network create crz-opt-net --driver bridge --subnet 10.91.0.0/24
docker volume create crz-opt-mariadb-data
```

### 2. Štart DB

```bash
cd projects/crz-opt
docker compose -f docker-compose.db.yml up -d
```

### 3. Štart restore-worker

```bash
docker compose -f docker-compose.yml --profile restore-worker up -d
```

Worker automaticky sleduje `data/dumps/*.sql.gz` a pri novom stabilnom dumpe spustí restore.

## Manualne spustenie restore

```bash
# V restore-worker containeri
docker exec crz-opt-restore-worker bash -c '
RESTORE_MODE=pruned-data RESTORE_AUTO_BACKFILL=true \
  bash /opt/crz-opt-scripts/sql-benchmark-restore.sh \
    /data/deploy/openclaw/config/workspace/projects/crz-opt/data/dumps/mydump.sql.gz
'

# Alebo z hosta cez docker exec
docker exec crz-opt-restore-worker \
  bash -c 'RESTORE_MODE=pruned-data bash /opt/crz-opt-scripts/sql-benchmark-restore.sh data/dumps/mydump.sql.gz'
```

## Konfigurácia (.env)

```env
# DB
MARIADB_DATABASE=crz
MARIADB_USER=crz
MARIADB_PASSWORD=crz-opt-dev
MARIADB_PORT=53306

# Restore worker
RESTORE_WORKFLOW_MODE=pruned-data     # baseline|fast|aggressive|pruned-data
RESTORE_AUTO_BACKFILL=true
RESTORE_POLL_INTERVAL=60              # sekúnd medzi kontrolami
RESTORE_STABLE_SECONDS=120           # čakanie na stabilitu dumpu
RESTORE_GZIP_TEST=false

# Metrics
METRICS_ENABLED=true
METRICS_PORT=9100
RESTORE_WORKER_METRICS_PORT=59100     # prístupné na 127.0.0.1:59100
```

## Restore režimy

| Režim | Čas (približne) | Popis |
|-------|-----------------|-------|
| `baseline` | 1h+ | Čistý restore bez optimalizácií |
| `fast` | ~73 min | Vypnuté unique/foreign checks, bulk insert optimalizácie |
| `aggressive` | ~71 min | + veľké key/myisam buffre, performance_schema=OFF |
| `pruned-data` | ~43 min | Preskočenie log/counter/robot/elastic tabuliek |

## Práca s dumpami

```bash
# Nahraj dump do watches adresára
cp /path/to/backup.sql.gz data/dumps/

# Worker ho automaticky spraguje do 120s
# Alebo spusti manuálne:
docker exec crz-opt-restore-worker bash -c '
  RESTORE_MODE=pruned-data bash /opt/crz-opt-scripts/sql-benchmark-restore.sh \
    data/dumps/backup.sql.gz
'
```

## Stavy workeru

```bash
# Pozri posledný úspešný restore
cat data/restore-state/last-success.state

# Pozri aktuálny stav
cat data/restore-state/current.state

# Logy behov
ls -la data/restore-runs/
```

## Metrics

```bash
curl http://127.0.0.1:59100/metrics
```

Dostupné metriky:
- `crz_restore_duration_seconds` - trvanie restore
- `crz_restore_rows_total` - počet obnovených riadkov
- `crz_restore_status` - status (1=success, 0=fail)
- `crz_db_table_counts` - počty riadkov v tabuľkách