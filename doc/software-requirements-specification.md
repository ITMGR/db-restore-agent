# Software Requirements Specification - crz-opt

## 1. Ucel dokumentu

Tento dokument definuje poziadavky pre projekt `crz-opt`. Dokument je zalozeny v style IEEE 29148 a bude sa doplnat pocas optimalizacnych iteracii.

## 2. Scope

`crz-opt` je testovacie prostredie na optimalizaciu MariaDB restore vykonu pre CRZ databazu.

Aktualne potvrdene:

- system bude obsahovat lokalnu MariaDB instanciu spustanu cez Docker Compose,
- restore vstup bude komprimovany MariaDB SQL dump `*.sql.gz`,
- skripty musia vediet restartovat databazu, resetovat lokalne data a merat restore cas,
- cielom je postupne znizovat cas restore a merat rozdiely medzi pokusmi,
- zatial nema produkcne nasadenie ani verejne rozhranie.

Otvorene:

- cielovy cas restore,
- hardver, na ktorom sa budu finalne merania robit.

## 3. Kontext produktu

Existujuce suvisiace projekty:

- `crz-scraper` - stahovanie a normalizacia detailu zmluvy z CRZ do `document.json`,
- `crz-static` - mirror CRZ s vyhladavanim, indexaciou a PDF fulltextom,
- `crz-potvrdenie` - generovanie PDF potvrdeni o zverejneni,
- `crz-restore-gateway` - samostatny restore/sync gateway pre CRZ infrastrukturu.

`crz-opt` je oddelene restore lab prostredie. Nesmie menit produkcne data v existujucich CRZ projektoch.

## 4. Pouzivatelske triedy

- technicky administrator optimalizujuci restore proces,
- operator spustajuci merania,
- automatizovany benchmark skript.

## 5. Funkcne poziadavky

| ID | Poziadavka | Stav |
| --- | --- | --- |
| FR-001 | System musi spustit lokalnu MariaDB instanciu cez Docker Compose. | Implementovane |
| FR-002 | System musi vediet restartovat MariaDB kontajner skriptom. | Implementovane |
| FR-003 | System musi vediet resetovat lokalny MariaDB data adresar pred benchmarkom. | Implementovane |
| FR-004 | System musi obnovit databazu zo suboru `*.gz`. | Implementovane |
| FR-005 | System musi merat cas restore a zapisat vysledok do suboru. | Implementovane |
| FR-006 | System musi podporovat viac restore rezimov pre porovnanie baseline a optimalizacii. | Implementovane |
| FR-007 | System musi podporovat orezany restore, ktory zachova schemu vsetkych tabuliek a vynecha data vybranych tabuliek. | Implementovane |
| FR-008 | System musi podporovat asynchronne dohratie vybranych prevadzkovych dat po rychlom restore jadra. | Implementovane ciastocne |
| FR-009 | System musi vediet automaticky sledovat dump adresar a pri novom stabilnom dumpe spustit restore + backfill workflow. | Implementovane ciastocne |
| FR-010 | System musi ukladat stav naposledy uspesne obnoveneho dumpu. | Implementovane |
| FR-011 | Restore worker musi poskytovat Prometheus-compatible metrics endpoint so stavom workeru, restore workflow a databazy. | Implementovane |
| FR-012 | Metrics endpoint musi podporovat volitelne HTTP Basic Auth prihlasovanie cez konfiguracne premenne. | Implementovane |

## 6. Nefunkcne poziadavky

| ID | Poziadavka | Stav |
| --- | --- | --- |
| NFR-001 | Benchmark musi byt opakovatelny z cisteho lokalneho MariaDB data adresara. | Implementovane |
| NFR-002 | Destruktivne reset operacie musia vyzadovat explicitne potvrdenie. | Implementovane |
| NFR-003 | Restore logy a casy musia byt ulozene mimo MariaDB data adresara. | Implementovane |
| NFR-004 | Projektova dokumentacia musi byt udrziavana spolu s implementaciou. | Navrh |
| NFR-005 | Workflow musi rozlisovat cas do dostupnej aplikacie od casu do kompletne dohratych prevadzkovych dat. | Navrh |
| NFR-006 | Automaticky restore worker nesmie byt spusteny defaultnym `docker compose up` bez explicitneho profilu. | Implementovane |

## 7. Externe rozhrania

- Docker Compose service `db` s image `mariadb:12.1`,
- lokalny TCP port `127.0.0.1:${MARIADB_PORT:-53306}`,
- vstupny adresar `data/dumps/`,
- vystupny adresar `data/restore-runs/`,
- stavovy adresar `data/restore-state/`,
- Prometheus metrics endpoint restore workeru `http://127.0.0.1:${RESTORE_WORKER_METRICS_PORT:-59100}/metrics`,
- shell skripty v `scripts/`.

## 8. Obmedzenia

- `reset-db.sh` maze iba lokalny adresar `projects/crz-opt/data/mariadb`.
- Dump musi byt ulozeny pod `data/dumps/`, aby bol dostupny v kontajneri ako read-only mount.
- Projekt zatial nepocita s verejnym nasadenim.
- Produkcne destruktivne operacie a zmeny existujucich CRZ dat vyzaduju explicitne schvalenie.

## 9. Verifikacia

- `docker compose config` musi prejst bez chyby,
- `scripts/up-db.sh` musi spustit MariaDB a prejst healthcheck,
- `scripts/restart-db.sh` musi restartovat DB a znovu prejst readiness,
- `scripts/benchmark-restore.sh data/dumps/<dump.sql.gz>` musi vytvorit log v `data/restore-runs/`.

## 10. Traceability

| Poziadavka | Verifikacia | Implementacia |
| --- | --- | --- |
| FR-001 | `docker compose config`, `scripts/up-db.sh` | `docker-compose.yml` |
| FR-002 | `scripts/restart-db.sh` | `scripts/restart-db.sh` |
| FR-003 | `scripts/reset-db.sh --yes` | `scripts/reset-db.sh` |
| FR-004 | `scripts/restore-gz.sh data/dumps/<dump.sql.gz>` | `scripts/restore-gz.sh` |
| FR-005 | kontrola `data/restore-runs/results.csv` | `scripts/restore-gz.sh` |
| FR-006 | `RESTORE_MODE=fast scripts/benchmark-restore.sh ...` | `scripts/restore-gz.sh` |
| FR-007 | `RESTORE_MODE=pruned-data scripts/benchmark-restore.sh ...`, kontrola prazdnych orezanych tabuliek | `scripts/container-restore.sh`, `scripts/filter-pruned-data.awk` |
| FR-008 | `docker exec crz-opt-mariadb sh /opt/crz-opt-scripts/container-backfill.sh /dumps/...sql.gz`, kontrola naplnenosti orezanych tabuliek | `scripts/container-backfill.sh`, `scripts/filter-backfill.awk` |
| FR-009 | `docker compose --profile restore-worker config`, kontrola `scripts/watch-dumps.sh` | `Dockerfile.restore-worker`, `docker-compose.yml`, `scripts/watch-dumps.sh` |
| FR-010 | kontrola `data/restore-state/last-success.id` a `last-success.state` po uspesnom behu | `scripts/watch-dumps.sh` |
| FR-011 | `curl http://127.0.0.1:59100/metrics` obsahuje `crz_restore_worker_up`, `crz_restore_database_tables_total` | `scripts/restore-metrics.py`, `scripts/restore-worker-entrypoint.sh`, `docker-compose.yml` |
| FR-012 | pri `METRICS_BASIC_AUTH_ENABLED=true` vracia `/metrics` bez auth HTTP 401 a s platnym `Authorization: Basic` HTTP 200 | `scripts/restore-metrics.py`, `.env.example`, `docker-compose.yml` |

## 11. Aktualne overenie

| Datum | Overenie | Vysledok |
| --- | --- | --- |
| 2026-05-31 | `scripts/nas-compose.sh crz-opt config` | OK |
| 2026-05-31 | `RESTORE_MODE=fast scripts/benchmark-restore.sh data/dumps/mariadb_crz_crz-sql_20260510-231000.sql.gz` | OK, 4384 s |
| 2026-05-31 | `RESTORE_MODE=aggressive scripts/benchmark-restore.sh data/dumps/mariadb_crz_crz-sql_20260510-231000.sql.gz` | OK, 4253 s |
| 2026-05-31 | `RESTORE_MODE=pruned-data scripts/benchmark-restore.sh data/dumps/mariadb_crz_crz-sql_20260510-231000.sql.gz` | OK, 2579 s; `143` tabuliek; orezane tabulky prazdne |
| 2026-05-31 | backfill AWK filter unit test (mock dump) | OK, správne emit/prune pre `log_01`, `counter_01`, `robot_01` |
| 2026-05-31 | realny async backfill test po `pruned-data` restore | ciastocne OK; 13/16 tabuliek, 104.6M riadkov, aplikacna dostupnost po 2579 s |
| 2026-05-31 | `mariadb-check --fast --databases crz` | OK |
| 2026-06-01 | realny auto-restore worker cez kopiu dumpu + async backfill | OK; restore 2575 s, backfill 2088 s, workflow success |
| 2026-06-01 | Prometheus metrics endpoint restore workeru | OK; `/metrics` vracia worker, compose, dump a MariaDB restore metriky |
| 2026-06-01 | Basic Auth pre metrics endpoint | OK; volitelne zapnutie cez `METRICS_BASIC_AUTH_ENABLED`, neautorizovany request 401, autorizovany request 200 |
