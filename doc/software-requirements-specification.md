# Software Requirements Specification - crz-opt

## 1. Účel dokumentu

Tento dokument definuje požiadavky pre projekt `crz-opt`. Dokument je založený v štýle IEEE 29148 a bude sa dopĺňať počas optimalizačných iterácií.

## 2. Scope

`crz-opt` je testovacie prostredie na optimalizáciu MariaDB restore výkonu pre CRZ databázu.

**Verzia 1.0.0 - kompletná rearchitektúra:**
- Dva nezávislé Docker Compose stacky: `docker-compose.db.yml` (MariaDB) a `docker-compose.yml` (restore-worker)
- Zdieľaný externý bridge network `crz-opt-net` (subnet `10.91.0.0/24`)
- Všetky skripty embedded v `restore-worker` image (`/opt/crz-opt-scripts/`)
- Automatický restore workflow cez `watch-dumps.sh`

## 3. Kontext produktu

Existujúce súvisiace projekty:
- `crz-scraper` - stahovanie a normalizácia detailu zmluvy z CRZ do `document.json`
- `crz-static` - mirror CRZ s vyhľadávaním, indexáciou a PDF fulltextom
- `crz-potvrdenie` - generovanie PDF potvrdení o zverejnení
- `crz-restore-gateway` - samostatný restore/sync gateway pre CRZ infraštruktúru

`crz-opt` je oddelené restore lab prostredie. Nesmie meniť produkčné data v existujúcich CRZ projektoch.

## 4. Používateľské triedy

| Trieda | Popis |
|--------|-------|
| Technický administrátor | Optimalizácia restore procesu, konfigurácia |
| Benchmark runner | Spúšťanie meraní, vyhodnocovanie výsledkov |
| Automatický workflow | `watch-dumps.sh` - bez zásahu spúšťa restore pri novom dumpe |

## 5. Funkčné požiadavky

| ID | Požiadavka | Stav |
|----|------------|------|
| FR-001 | Systém musí spustiť MariaDB 12.1 cez `docker-compose.db.yml` na porte `127.0.0.1:53306`. | Implementované |
| FR-002 | Systém musí spustiť restore-worker cez `docker-compose.yml` s profilom `restore-worker`. | Implementované |
| FR-003 | DB a restore-worker musia zdieľať externý bridge network `crz-opt-net`. | Implementované |
| FR-004 | Restore-worker musí komunikovať s DB cez hostname `crz-opt-mariadb` na sieti `crz-opt-net`. | Implementované |
| FR-005 | Všetky skripty musia byť embedded v `restore-worker` image, nie mountnuté ako volumes. | Implementované |
| FR-006 | Systém musí vedieť restartovať MariaDB kontajner skriptom. | Implementované |
| FR-007 | Systém musí vedieť resetovať MariaDB Docker volume pred benchmarkom. | Implementované |
| FR-008 | Systém musí obnoviť databázu zo súboru `*.sql.gz`. | Implementované |
| FR-009 | Systém musí merať čas restore a zapísať výsledok do súboru. | Implementované |
| FR-010 | Systém musí podporovať viac restore režimov pre porovnanie. | Implementované |
| FR-011 | Systém musí podporovať orezaný restore (`pruned-data`) s preskočením vybraných tabuliek. | Implementované |
| FR-012 | Systém musí podporovať asynchrónne dohranie prevádzkových dát po rýchlom restore jadra. | Implementované |
| FR-013 | Systém musí automaticky sledovať `data/dumps/` adresár a pri novom stabilnom dumpe spustiť restore + backfill workflow. | Implementované |
| FR-014 | Systém musí ukladať stav naposledy úspešne obnoveného dumpu do `last-success.id`. | Implementované |
| FR-015 | Restore worker musí poskytovať Prometheus-compatible metrics endpoint. | Implementované |
| FR-016 | Metrics endpoint musí podporovať voliteľné HTTP Basic Auth prihlasovanie. | Implementované |
| FR-017 | Restore worker musí riadiť restore cez SQL prikazy a bash pipeline bez Docker socketu. | Implementované |
| FR-018 | `container-wait-ready.sh` musí používať `MARIADB_USER=crz` namiesto root pre healthcheck. | Implementované |
| FR-019 | Restore skripty musia zobrazovať `pv` progress bar počas restore. | Implementované |

## 6. Nefunkčné požiadavky

| ID | Požiadavka | Stav |
|----|------------|------|
| NFR-001 | Benchmark musí byť opakovateľný z čistého MariaDB Docker volume. | Implementované |
| NFR-002 | Destruktívne reset operácie musia vyžadovať explicitné potvrdenie. | Implementované |
| NFR-003 | Restore logy a časy musia byť uložené mimo MariaDB Docker volume. | Implementované |
| NFR-004 | Automatický restore worker nesmie byť spustený defaultným `docker compose up` bez explicitného profilu. | Implementované |
| NFR-005 | Restore worker nesmie mať mountnutý `/var/run/docker.sock`. | Implementované |
| NFR-006 | Workflow musí rozlisovať čas do dostupnej aplikácie od času do kompletne dohratých prevádzkových dát. | Implementované |
| NFR-007 | `DB_HOST` env var musí byť context-aware: worker context = `crz-opt-mariadb`, local context = `127.0.0.1`. | Implementované |

## 7. Externé rozhrania

| Rozhranie | Detaily |
|-----------|---------|
| MariaDB service | `docker-compose.db.yml`, image `mariadb:12.1`, port `127.0.0.1:53306` |
| Restore-worker service | `docker-compose.yml` s profilom `restore-worker`, image `crz-opt-restore-worker:local` |
| Sieť | External bridge `crz-opt-net`, subnet `10.91.0.0/24` |
| Vstupný adresár | `data/dumps/` - `.sql.gz` dumpy |
| Výstupný adresár | `data/restore-runs/` - logy jednotlivých behov |
| Stavový adresár | `data/restore-state/` - `last-success.id`, `last-success.state`, `current.state` |
| Metrics endpoint | `http://127.0.0.1:59100/metrics` |
| DB hostname (v sieti) | `crz-opt-mariadb` (TCP port 3306) |

## 8. Obmedzenia

- `reset-db.sh` maže iba obsah MariaDB Docker volume `crz-opt-mariadb-data`.
- Dump musí byť uložený pod `data/dumps/`, aby bol dostupný v restore-worker kontajneri.
- Projekt zatial nepocíta s verejným nasadením.
- Produkčné destruktívne operácie vyžadujú explicitné schválenie.
- Restore-worker beží na sieti `crz-opt-net` a nemá prístup k host Docker socketu.

## 9. Verifikácia

| ID | Test | Príkaz |
|----|------|--------|
| V-001 | Docker Compose config pre db | `docker compose -f docker-compose.db.yml config` |
| V-002 | Docker Compose config pre worker | `docker compose -f docker-compose.yml config` |
| V-003 | Štart DB a healthcheck | `docker compose -f docker-compose.db.yml up -d && scripts/container-wait-ready.sh` |
| V-004 | Štart restore-worker | `docker compose -f docker-compose.yml --profile restore-worker up -d` |
| V-005 | Watch-dumps.sh beží | `docker logs crz-opt-restore-worker 2>&1 \| grep "watching"` |
| V-006 | Manuálny restore | `docker exec crz-opt-restore-worker bash -c 'RESTORE_MODE=pruned-data bash /opt/crz-opt-scripts/sql-benchmark-restore.sh data/dumps/<dump.sql.gz>'` |
| V-007 | Auto-restore na nový dump | `cp <new.sql.gz> data/dumps/ && sleep 180 && docker logs crz-opt-restore-worker` |
| V-008 | Metrics endpoint | `curl http://127.0.0.1:59100/metrics \| grep crz_restore` |
| V-009 | PV progress v logs | `docker logs crz-opt-restore-worker 2>&1 \| grep -E "pv|rows in set"` |
| V-010 | Last-success.state aktualizovaný | `cat data/restore-state/last-success.state` |

## 10. Traceability

| FR | Verifikácia | Implementácia |
|----|-------------|---------------|
| FR-001 | `docker compose -f docker-compose.db.yml config` | `docker-compose.db.yml` |
| FR-002 | `docker compose -f docker-compose.yml --profile restore-worker config` | `docker-compose.yml`, `Dockerfile.restore-worker` |
| FR-003 | Obě compose súbory používajú `crz-opt-net` external | `docker-compose.db.yml`, `docker-compose.yml` |
| FR-004 | Worker komunikuje s DB cez hostname | `docker-compose.yml` env `DB_HOST=crz-opt-mariadb` |
| FR-005 | Scripts embedded v image | `Dockerfile.restore-worker` COPY |
| FR-006 | `scripts/restart-db.sh` | `scripts/restart-db.sh` |
| FR-007 | `scripts/reset-db.sh --yes` | `scripts/reset-db.sh` |
| FR-008 | `sql-benchmark-restore.sh` | `scripts/sql-benchmark-restore.sh` |
| FR-009 | Výsledky v `data/restore-runs/` | `scripts/sql-lib.sh` |
| FR-010 | Viac režimov | `scripts/sql-restore-gz.sh` RESTORE_MODE |
| FR-011 | Pruned-data režim | `scripts/filter-pruned-data.awk` |
| FR-012 | Async backfill | `scripts/sql-backfill-gz.sh` |
| FR-013 | Auto-restore workflow | `scripts/watch-dumps.sh` |
| FR-014 | State tracking | `scripts/watch-dumps.sh` write `last-success.id` |
| FR-015 | Metrics endpoint | `scripts/restore-metrics.py` |
| FR-016 | Basic Auth | `scripts/restore-metrics.py` METRICS_BASIC_AUTH |
| FR-017 | Bez Docker socketu | `docker-compose.yml` bez socket mount |
| FR-018 | crz user healthcheck | `scripts/container-wait-ready.sh` |
| FR-019 | PV progress | `scripts/sql-restore-gz.sh` pv pipe |

## 11. Aktuálne overenie (v1.0.0)

| Dátum | Overenie | Výsledok |
|-------|----------|----------|
| 2026-06-09 | Dva samostatné compose stacky na `crz-opt-net` | OK |
| 2026-06-09 | Scripts embedded v `crz-opt-restore-worker:local` image | OK |
| 2026-06-09 | `container-wait-ready.sh` s `MARIADB_USER=crz` | OK |
| 2026-06-09 | Auto-restore workflow s `watch-dumps.sh` | OK - simulation-big.sql.gz automaticky spracovaný |
| 2026-06-09 | PV progress v `sql-restore-gz.sh` | OK |
| 2026-06-09 | 500k rows test restore cez worker | OK - 500000 rows, 3.5s |
| 2026-06-09 | Metrics endpoint | OK |

## 12. História verzií

| Verzia | Dátum | Zmena |
|--------|-------|-------|
| v0.1.0 | 2026-06-01 | Prvá použiteľná verzia |
| v0.1.1 | 2026-06-01 | Basic Auth pre metrics |
| v1.0.0 | 2026-06-09 | Kompletná rearchitektúra - dva nezávislé stacky, auto-restore, embedded scripts |