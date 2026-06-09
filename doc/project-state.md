# Project State - crz-opt

**Verzia:** v1.0.0  
**Dátum:** 2026-06-09  
**Stav:** Active - restore lab

## Architektúra v1.0.0

Dva nezávislé Docker Compose stacky zdieľajúce externý bridge network:

```
crz-opt-net (10.91.0.0/24)
├── crz-opt-mariadb (MariaDB 12.1, 127.0.0.1:53306)
└── crz-opt-restore-worker (auto-restore worker)
```

## Komponenty

### docker-compose.db.yml
- MariaDB 12.1 service
- Port: 127.0.0.1:53306
- Volume: crz-opt-mariadb-data
- Tuning: key_buffer_size=4G, innodb_buffer_pool_size=4G, atď.
- Healthcheck cez `MARIADB_USER=crz` (nie root)

### docker-compose.yml
- restore-worker s profilom `restore-worker`
- Image: crz-opt-restore-worker:local (built from Dockerfile.restore-worker)
- Scripts: embedded v `/opt/crz-opt-scripts/`
- Env: DB_HOST=crz-opt-mariadb, RESTORE_WORKFLOW_MODE=pruned-data
- Metrics: 127.0.0.1:59100

## Restore režimy

| Režim | Čas | Popis |
|-------|-----|-------|
| baseline | 1h+ | Čistý restore |
| fast | ~73 min | Vypnuté checks, bulk optimalizácie |
| aggressive | ~71 min | + veľké buffre |
| pruned-data | ~43 min | Preskočenie log/counter/robot/elastic tabuliek |

## Auto-restore workflow

1. `watch-dumps.sh` sleduje `data/dumps/*.sql.gz` (60s polling)
2. Pri novom stabilnom dumpe (120s) spustí:
   - `sql-benchmark-restore.sh` (restore + pv progress)
   - `sql-backfill-gz.sh` (ak sú pruned tabuľky)
3. Výsledok: `last-success.id`, `last-success.state`

## Aktuálne nasadenie (NAS)

```
NAS: 192.168.88.100
Projekt path: /data/deploy/openclaw/config/workspace/projects/crz-opt
```

- Network: crz-opt-net (external, bridge, 10.91.0.0/24)
- Volume: crz-opt-mariadb-data (external)
- Dumpy: data/dumps/
- State: data/restore-state/

## Ďalšie kroky

- [ ] Reálny dump restore test (celý ~78GB dump)
- [ ] Stress test auto-restore workflow s viacerými dump súbormi
- [ ] Dokumentácia metrics formátu
- [ ] Git commit pre v1.0.0

## Historické merania

| Dátum | Režim | Čas | Tabuľky | Poznámka |
|-------|-------|-----|---------|-----------|
| 2026-05-31 | fast | 4384s | 143 | - |
| 2026-05-31 | aggressive | 4253s | 143 | -131s vs fast |
| 2026-05-31 | pruned-data | 2579s | 143 | -1674s vs aggressive |
| 2026-05-31 | backfill (async) | ~1046s | 13/16 tabuliek | 104.6M rows |
| 2026-06-09 | pruned-data (simulation) | 4s | 1 | 500k rows test |