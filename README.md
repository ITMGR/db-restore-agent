# crz-opt

Testovacie prostredie na optimalizaciu MariaDB restore vykonu pre CRZ databazu.

Ciel: opakovatelne merat cas obnovy databazy zo suboru `*.sql.gz`, najprv baseline sposobom a potom s postupnymi optimalizaciami MariaDB nastaveni, restore pipeline a pripadne formatu dumpu.

## Stav

- verzia: `v0.1.0`
- faza: lokalne Docker Compose restore lab
- verejne nasadenie: nie
- Docker Compose: ano, MariaDB

## Struktura

```text
.
+-- app/       # buduci aplikacny kod
+-- data/      # mariadb data, dumpy a vysledky merani
+-- doc/       # poziadavky, rozhodnutia a technicka dokumentacia
+-- research/  # experimenty, analyzy, proof-of-concepts
+-- scripts/   # pomocne CLI skripty
+-- docker-compose.yml
+-- README.md
+-- VERSION
```

## Rychly start

```bash
cd projects/crz-opt
cp .env.example .env
scripts/up-db.sh
```

Databaza bude dostupna lokalne na `127.0.0.1:53306`.

Predvolene prihlasenie z `.env.example`:

- database: `crz`
- user: `crz`
- password: `crz-opt-dev`

## Praca s dumpom

Dump vloz do:

```text
data/dumps/
```

Priklad:

```bash
cp /path/to/backup.sql.gz data/dumps/
```

Baseline restore bez resetu databazoveho volume:

```bash
scripts/restore-gz.sh data/dumps/backup.sql.gz
```

Kompletny benchmark s cistym MariaDB data adresarom:

```bash
scripts/benchmark-restore.sh data/dumps/backup.sql.gz
```

Rychlejsi experimentalny rezim s restore session nastaveniami:

```bash
RESTORE_MODE=fast scripts/benchmark-restore.sh data/dumps/backup.sql.gz
```

Agresivnejsi profil s vacsimi MariaDB buffermi:

```bash
RESTORE_MODE=aggressive scripts/benchmark-restore.sh data/dumps/backup.sql.gz
```

Pruned-data rezim vytvori vsetky tabulky, ale neimportuje data z velkych prevadzkovych tabuliek podla `PRUNE_DATA_TABLE_REGEX`:

```bash
RESTORE_MODE=pruned-data scripts/benchmark-restore.sh data/dumps/backup.sql.gz
```

Vysledky sa ukladaju do:

```text
data/restore-runs/
```

Subor `data/restore-runs/results.csv` obsahuje riadky:

```text
run_id,mode,dump_file,duration_seconds
```

## Skripty

- `scripts/up-db.sh` - spusti MariaDB a pocka na readiness
- `scripts/restart-db.sh` - restartuje MariaDB kontajner
- `scripts/reset-db.sh --yes` - zastavi DB, zmaze lokalny data adresar a spusti cistu instanciu
- `scripts/restore-gz.sh <dump.sql.gz>` - obnovi dump do existujucej databazy a zmeria cas
- `scripts/benchmark-restore.sh <dump.sql.gz>` - reset + restore v jednom kroku
- `scripts/container-backfill.sh <dump.sql.gz>` - doleje prevadzkove data do uz obnovenej databazy (spúšťa sa v kontajneri)

`reset-db.sh` je destruktivny pre `data/mariadb/`, preto vyzaduje `--yes` alebo `RESET_CONFIRM=YES`.

MariaDB restore tuning je nastavitelny cez `.env`:

- `MARIADB_KEY_BUFFER_SIZE`
- `MARIADB_BULK_INSERT_BUFFER_SIZE`
- `MARIADB_MYISAM_SORT_BUFFER_SIZE`
- `MARIADB_ARIA_PAGECACHE_BUFFER_SIZE`
- `MARIADB_INNODB_BUFFER_POOL_SIZE`
- `MARIADB_INNODB_LOG_FILE_SIZE`
- `PRUNE_DATA_TABLE_REGEX`

## Dokumentacia

- `doc/software-requirements-specification.md` - uvodna SRS kostra podla IEEE 29148 stylu
- `doc/decision-log.md` - priebezne architektonicke a produktove rozhodnutia

## Posledne meranie

- dump: `data/dumps/mariadb_crz_crz-sql_20260510-231000.sql.gz`
- komprimovana velkost: 12 GiB
- restore rezim: `pruned-data` + backfill
- vysledok: uspesny restore jadra, `143` tabuliek; prevadzkove tabulky prazdne po `pruned-data`, dohratelne asynchronnym backfillom
- cas pruned-data: `2579` s (`42:59`)
- data po restore jadra: 36 GiB; cielovo ~78 GiB po uplnom backfilli
- rychla kontrola: `mariadb-check --fast --databases crz` bez chyb

Dvojfazovy workflow:

1. `RESTORE_MODE=pruned-data scripts/benchmark-restore.sh data/dumps/...sql.gz` — rychly restore jadra (~43 min)
2. `docker exec crz-opt-mariadb sh /opt/crz-opt-scripts/container-backfill.sh /dumps/...sql.gz` — dolejenie prevadzkovych dát (~30 min)

Automaticky restore worker:

```bash
docker compose --profile restore-worker up -d --build restore-worker
```

Worker sleduje `data/dumps/*.sql.gz`. Keď nájde nový stabilný dump, spustí:

1. `RESTORE_MODE=pruned-data scripts/benchmark-restore.sh ...`
2. `scripts/backfill-gz.sh ...`

Stav ukladá do `data/restore-state/`:

- `last-success.id` - identifikátor naposledy úspešne obnoveného dumpu (`path|size|mtime`)
- `last-success.state` - detail posledného úspechu
- `last-failure.state` - posledné zlyhanie
- `runs/<timestamp>/worker.log` - log konkrétneho behu

Prometheus metrics endpoint restore workeru:

```bash
curl http://127.0.0.1:59100/metrics
```

Endpoint poskytuje stav worker kontajnera, posledného restore workflow, dump adresára, MariaDB dostupnosti, počtu tabuliek a naplnenosti backfill tabuliek.

Porovnanie merani:

| Rezim | Cas | Rozdiel |
| --- | ---: | ---: |
| `fast` | 4384 s (`1:13:04`) | full restore baseline |
| `aggressive` | 4253 s (`1:10:53`) | -131 s / -3.0 % |
| `pruned-data` | 2579 s (`42:59`) | -1674 s / -39.4 % proti `aggressive` |
| `pruned-data` + async backfill | app dostupna po 2579 s (`42:59`) | prevadzkove data sa dohravaju na pozadi |

## Najblizsie kroky

1. Dorobit backfill ako resumable/table-scoped skript, aby sa dali dohrat alebo retry-nut jednotlive prevadzkove tabulky bez celeho scanovania dumpu.
2. Napojit `/metrics` na Prometheus/Grafana, ak bude projekt sledovany dlhodobo.
3. Rozhodnut, ci sa testovaci auto-restore dump ponecha alebo odstrani po release.
