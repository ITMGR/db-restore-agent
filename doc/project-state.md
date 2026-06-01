# Project State - crz-opt

## 2026-05-29

`crz-opt` je zalozeny ako PostgreSQL restore performance lab pre CRZ databazu.

Aktualny ciel:

- optimalizovat cas restore PostgreSQL databazy zo standardneho komprimovaneho `*.gz` SQL dumpu,
- najprv zmerat baseline restore cez `gzip -dc | psql`,
- nasledne postupne porovnavat optimalizacie PostgreSQL konfiguracie, session nastaveni a restore pipeline.

Aktualny stav implementacie:

- projektovy adresar: `projects/crz-opt`,
- verzia: `v0.1.0-dev`,
- `docker-compose.yml` obsahuje lokalnu PostgreSQL 16 instanciu,
- `.env.example` definuje `POSTGRES_DB=crz_opt`, `POSTGRES_USER=crz`, `POSTGRES_PORT=55432`,
- lokalny `.env` bol vytvoreny z `.env.example` a je ignorovany gitom,
- dumpy patria do `data/dumps/`,
- vysledky merani patria do `data/restore-runs/`,
- `data/postgres/` je lokalny PostgreSQL data adresar a moze byt zmazany reset skriptom.

Skripty:

- `scripts/up-db.sh` - spusti PostgreSQL a pocka na readiness,
- `scripts/restart-db.sh` - restartuje PostgreSQL kontajner,
- `scripts/reset-db.sh --yes` - destruktivne zmaze `data/postgres/` a spusti cistu DB,
- `scripts/restore-gz.sh data/dumps/<dump.sql.gz>` - obnovi dump a zapise cas,
- `scripts/benchmark-restore.sh data/dumps/<dump.sql.gz>` - reset + restore v jednom merani.

Overenie k 2026-05-29:

- shell syntax skriptov presla cez `bash -n`,
- `docker-compose.yml` presiel YAML parsing,
- lokalny runtime nema `docker` CLI,
- `scripts/nas-compose.sh crz-opt config` na NAS presiel po vytvoreni `.env`,
- kontajner este nebol spusteny a realny restore este nebol merany.

Najblizsie kroky:

1. Dodat realny CRZ PostgreSQL dump `*.gz` do `data/dumps/`.
2. Spustit baseline:

   ```bash
   cd projects/crz-opt
   scripts/benchmark-restore.sh data/dumps/<dump.sql.gz>
   ```

3. Zapisat velkost dumpu, velkost rozbaleneho SQL a baseline cas.
4. Porovnat:

   ```bash
   RESTORE_MODE=fast scripts/benchmark-restore.sh data/dumps/<dump.sql.gz>
   ```

5. Podla vysledkov rozhodnut dalsie optimalizacie:
   - PostgreSQL config,
   - `UNLOGGED`/WAL strategie pre testy,
   - vypnutie alebo odlozenie indexov/constraints,
   - `pg_restore -j` po prechode na custom dump format, ak bude mozne zmenit sposob vytvarania dumpu.

Pripomienka: pokracovat v pondelok 2026-06-01 po obede.

## 2026-05-31

Do `data/dumps/` bol pridany realny dump:

- `mariadb_crz_crz-sql_20260510-231000.sql.gz`
- komprimovana velkost: 12 GiB
- hlavicka dumpu: MariaDB dump 10.19, server `12.1.2-MariaDB-ubu2404`

Zistenie: dump nie je PostgreSQL, ale MariaDB/MySQL plain SQL dump. Projekt bol preto prepnuty z PostgreSQL labu na MariaDB lab.

Aktualny stav implementacie:

- `docker-compose.yml` pouziva `mariadb:12.1` a data adresar `data/mariadb/`,
- `.env.example` a `.env` pouzivaju `MARIADB_*` premenne,
- skripty automaticky pouziju lokalny `docker compose`, alebo NAS helper `scripts/nas-compose.sh crz-opt`,
- restore logika v kontajneri je v `scripts/container-restore.sh`,
- readiness check v kontajneri je v `scripts/container-wait-ready.sh`,
- `fast` rezim pridava session nastavenia `sql_log_bin=0`, `unique_checks=0`, `foreign_key_checks=0`, `autocommit=0`.

Overenie:

- `scripts/nas-compose.sh crz-opt config` presiel,
- cisty restore v `fast` rezime prebehol uspesne,
- run ID: `20260531T082028Z-fast`,
- trvanie: `4384` sekund (`1:13:04`),
- obnovena databaza ma `143` tabuliek,
- data adresar po restore ma 78 GiB,
- kontajner `crz-opt-mariadb` je healthy,
- `mariadb-check --fast --databases crz` prebehol bez chyb.

Najvacsie tabulky po restore:

- `robot_01`: ~30.4M riadkov, 26.31 GiB,
- `art_03`: ~5.64M riadkov, 7.27 GiB,
- `location`: ~24.26M riadkov, 6.19 GiB,
- `art`: ~11.85M riadkov, 4.88 GiB,
- `counter_01`: ~18.32M riadkov, 4.14 GiB.

Pozorovanie vykonu:

- hlavne zdrzania boli MyISAM `ENABLE KEYS`/`Repair by sorting` na velkych tabulkach,
- najvyraznejsie viditelne boli `art_03`, `log_07`, `robot_01` a dalsie velke MyISAM tabulky,
- dalsie optimalizacie maju cielit najma na MyISAM sort/key buffery, tempdir/disk a pripadne delenie restore po tabulkach.

### Optimalizacny beh `aggressive`

Zmeny:

- `MARIADB_KEY_BUFFER_SIZE=4G`,
- `MARIADB_MYISAM_SORT_BUFFER_SIZE=4G`,
- `MARIADB_BULK_INSERT_BUFFER_SIZE=1G`,
- `MARIADB_ARIA_PAGECACHE_BUFFER_SIZE=1G`,
- `MARIADB_INNODB_BUFFER_POOL_SIZE=4G`,
- `performance_schema=OFF`,
- `innodb_autoinc_lock_mode=2`,
- novy restore rezim `RESTORE_MODE=aggressive`.

Vysledok:

- run ID: `20260531T102426Z-aggressive`,
- trvanie: `4253` sekund (`1:10:53`),
- zlepsenie proti `fast`: `131` sekund (`~3.0 %`),
- obnovena databaza ma `143` tabuliek,
- data adresar po restore ma 78 GiB,
- kontajner `crz-opt-mariadb` je healthy,
- `mariadb-check --fast --databases crz` prebehol bez chyb.

Zaver:

- vacsie MyISAM buffery priniesli iba male zlepsenie,
- viacero tazkych `Repair by sorting` faz ostalo CPU/I/O bound,
- dalsi vacsi zisk pravdepodobne nepride dalsim zvacsovanim buffrov,
- dalsi realny smer je pruned restore bez log/counter/robot tabuliek alebo rozdelenie dumpu po tabulkach a paralelizacia nezavislych casti.

### Optimalizacny beh `pruned-data`

Pridany bol restore rezim `RESTORE_MODE=pruned-data`, ktory ponecha DDL pre vsetky tabulky, ale pomocou `scripts/filter-pruned-data.awk` preskoci datove bloky pre tabulky podla `PRUNE_DATA_TABLE_REGEX`.

Predvolene orezane tabulky:

- `counter_01` az `counter_06`,
- `elastic1`,
- `log_01` az `log_07`,
- `robot_01`,
- `robot_02`.

Vysledok:

- run ID: `20260531T120233Z-pruned-data`,
- trvanie: `2579` sekund (`42:59`),
- zlepsenie proti `aggressive`: `1674` sekund (`~39.4 %`),
- zlepsenie proti `fast`: `1805` sekund (`~41.2 %`),
- obnovena databaza ma stale `143` tabuliek,
- data adresar po restore ma 36 GiB,
- orezane tabulky maju 0 riadkov a 0 MiB,
- `mariadb-check --fast --databases crz` prebehol bez chyb.

Zaver:

- pruned restore je zatial najrychlejsia overena metoda,
- nejde o plny restore, ale o aplikacne-minimalny restore s prazdnymi prevadzkovymi/historickymi tabulkami,
- najvacsie zostavajuce tabulky su jadrove datove tabulky `art_03`, `location`, `art`, `art_01` a `art_o3`,
- dalsi smer je bud potvrdit, ze orezane tabulky nie su potrebne na bezny start systemu, alebo ich obnovovat asynchronne v druhej faze.

### Dvojfázový restore — fáza 2 (backfill)

Pridaná druhá fáza pre plný restore: `scripts/container-backfill.sh` doleje prevádzkové/historické dáta do už obnovenej databázy. Používa inverzný filter `scripts/filter-backfill.awk`, ktorý emituje data bloky iba pre tabuľky v `PRUNE_DATA_TABLE_REGEX`.

Skript je idempotentný — ak sú tabuľky už naplnené, skončí s `exit 0`. Pred spustením čaká na MariaDB readiness.

Použitie:

```bash
# Fáza 1: rýchle jadro (~43 min)
RESTORE_MODE=pruned-data scripts/benchmark-restore.sh data/dumps/...sql.gz
# Fáza 2: dolejenie prevádzkových dát (~30 min, v kontajneri)
docker exec crz-opt-mariadb sh /opt/crz-opt-scripts/container-backfill.sh /dumps/...sql.gz
```

Primárna metrika pre tento workflow nie je celkový čas do plného restore, ale čas do dostupnej aplikácie. Aktuálne najlepšia hodnota je `2579` s (`42:59`) pre jadrové dáta; prevádzkové dáta sa majú dohrávať asynchrónne po štarte aplikácie.

### Automaticky restore worker

Pridana prva verzia Docker image/sluzby, ktora sleduje dump adresar a automaticky spusti restore workflow pri novom stabilnom `*.sql.gz` subore.

Komponenty:

- `Dockerfile.restore-worker`,
- `restore-worker` service v `docker-compose.yml` pod profilom `restore-worker`,
- `scripts/watch-dumps.sh`,
- `scripts/backfill-gz.sh`,
- stavovy adresar `data/restore-state/`.

Workflow:

1. najde najnovsi `*.sql.gz` v `data/dumps/`,
2. overi, ze sa subor uz nemeni (`RESTORE_STABLE_SECONDS`),
3. porovna `path|size|mtime` s `data/restore-state/last-success.id`,
4. ak je dump novy, spusti `RESTORE_MODE=pruned-data scripts/benchmark-restore.sh`,
5. nasledne spusti `scripts/backfill-gz.sh`,
6. po uspechu zapise `last-success.id` a `last-success.state`.

Worker je zamerne mimo default compose profilu, aby sa destruktivny restore nespustil neplanovane.

## 2026-06-01

Auto-restore worker bol overeny realnym testom cez kopiu dumpu:

- testovaci dump: `data/dumps/mariadb_crz_crz-sql_20260510-231000.auto-restore-test-20260601T072350Z.sql.gz`,
- restore run: `20260601T073039Z-pruned-data`,
- restore jadra: `2575` s (`42:55`),
- backfill run: `20260601T081334Z-backfill`,
- backfill: `2088` s (`34:48`),
- workflow finished: `2026-06-01T08:48:23Z`,
- vysledok: `success`, `143` tabuliek, `last-success.state` zapisany.

Po teste bol restore worker rozsirený o Prometheus-compatible metrics endpoint:

- kontajnerovy endpoint: `:9100/metrics`,
- host bind: `127.0.0.1:59100`,
- implementacia: `scripts/restore-metrics.py`,
- entrypoint wrapper: `scripts/restore-worker-entrypoint.sh`.

Metriky pokryvaju stav workeru, Docker Compose sluzieb, dump adresara, posledneho restore/backfill behu, MariaDB dostupnosti, pocet tabuliek a riadky v pruned/backfill tabulkach.

Release stav: `v0.1.0`.
