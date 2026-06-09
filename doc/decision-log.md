# Decision Log - crz-opt

## 2026-05-29 - Project skeleton

Zalozeny samostatny projekt `projects/crz-opt` s minimalnou strukturou:

- `README.md`
- `VERSION`
- `doc/software-requirements-specification.md`
- `doc/decision-log.md`
- prazdne adresare pre `app/`, `data/`, `research/` a `scripts/`

Rozhodnutie: zatial nevytvarat Docker Compose, framework ani deployment konfiguraciu, kym nie je jasny hlavny workflow projektu.

## 2026-05-29 - PostgreSQL restore lab

Steve upresnil predmet projektu: optimalizacia vykonu PostgreSQL restore zo standardneho komprimovaneho `*.gz` dumpu.

Pridane:

- `docker-compose.yml` s lokalnou PostgreSQL 16 instanciou,
- `.env.example`,
- read-only mount `data/dumps/` do kontajnera,
- skripty `up-db.sh`, `restart-db.sh`, `reset-db.sh`, `restore-gz.sh`, `benchmark-restore.sh`,
- ukladanie restore logov a vysledkov do `data/restore-runs/`.

Rozhodnutie: prva verzia pouziva plain SQL restore cez `gzip -dc | psql`, pretoze cielom je najprv zmerat aktualny pomaly baseline. Dalsi pravdepodobny optimalizacny krok je porovnanie s PostgreSQL custom dump formatom a `pg_restore -j`, ak bude mozne ovplyvnit sposob vytvarania dumpu.

## 2026-05-31 - Switch to MariaDB restore lab

Realny dump dodany do `data/dumps/` je MariaDB/MySQL plain SQL dump, nie PostgreSQL dump.

Rozhodnutie: projekt sa prepina na MariaDB lab namiesto pokusu konvertovat dump do PostgreSQL. Dovody:

- dump obsahuje MariaDB specificku hlavicku, MyISAM/InnoDB definicie a MySQL syntax,
- priame `psql` restore by zlyhalo uz na DDL,
- cielom je optimalizovat realny restore existujuceho dumpu, nie menit databazovy engine.

Implementovane:

- Docker image `mariadb:12.1`,
- restore cez `gzip -dc | mariadb`,
- server tuning pre velke SQL importy a MyISAM index rebuild,
- kontajnerove helper skripty pre stabilne spustanie cez NAS compose helper.

Prve realne meranie:

- `RESTORE_MODE=fast`,
- dump `mariadb_crz_crz-sql_20260510-231000.sql.gz`,
- trvanie `4384` sekund,
- `143` tabuliek,
- `mariadb-check --fast --databases crz` OK.

## 2026-05-31 - Aggressive MariaDB buffer profile

Otestovany agresivnejsi server profil:

- `key_buffer_size=4G`,
- `myisam_sort_buffer_size=4G`,
- `bulk_insert_buffer_size=1G`,
- `aria_pagecache_buffer_size=1G`,
- `innodb_buffer_pool_size=4G`,
- `performance_schema=OFF`,
- `innodb_autoinc_lock_mode=2`.

Rozhodnutie: profil ponechat ako aktualny najlepsi full-restore profil, ale nepovazovat dalsie zvacsovanie buffrov za hlavny optimalizacny smer.

Vysledok:

- `RESTORE_MODE=aggressive`,
- trvanie `4253` sekund (`1:10:53`),
- zlepsenie oproti `fast`: `131` sekund (`~3.0 %`),
- `mariadb-check --fast --databases crz` OK.

Dalsi smer: ak je cielom vyrazne rychlejsi restore, treba zmenit strategiu: pruned restore bez nepotrebnych log/counter/robot tabuliek alebo split dumpu po tabulkach s paralelizaciou. Samotne zvacsovanie MyISAM buffrov ma pri tomto dumpe maly efekt.

## 2026-05-31 - Pruned data restore mode

Otestovana ina strategia ako dalsie ladenie buffrov: ponechat schemu vsetkych tabuliek, ale neimportovat data z velkych prevadzkovych/historickych tabuliek.

Implementovane:

- novy rezim `RESTORE_MODE=pruned-data`,
- filter `scripts/filter-pruned-data.awk`,
- nastavitelny regex `PRUNE_DATA_TABLE_REGEX`,
- predvolene orezanie `counter_*`, `log_*`, `robot_01`, `robot_02` a `elastic1`.

Vysledok:

- run `20260531T120233Z-pruned-data`,
- trvanie `2579` sekund (`42:59`),
- zlepsenie oproti `aggressive`: `1674` sekund (`~39.4 %`),
- data adresar po restore: 36 GiB namiesto 78 GiB,
- databaza ma stale `143` tabuliek,
- orezane tabulky su prazdne,
- `mariadb-check --fast --databases crz` OK.

Rozhodnutie: `pruned-data` je aktualne najlepsi rychly restore profil pre aplikacne minimum. Nepovazovat ho za ekvivalent plneho restore; pred produkcnym pouzitim treba potvrdit, ci aplikacia a navazne procesy nepotrebuju data z orezanych tabuliek.

## 2026-05-31 - Two-phase restore (pruned-data + backfill)

Riesenie: dvojfazovy restore — jadro/ovaciu schema najprv, prevadzokove data neskor.

Implementovane:
- `scripts/container-backfill.sh` — spusta sa v DB kontajneri, cita dump, filtruje data pre orezane tabulky a doleje ich,
- `scripts/filter-backfill.awk` — inverzia `filter-pruned-data.awk`; emituje data blok len pre tabulky v `backfill_re`,
- `container-backfill.sh` pouziva rovnaky `PRUNE_DATA_TABLE_REGEX` ako pruned-data restore,
- backfill sa spusta az po uspesnom restoredata, bez resetu DB,
- ak ziadna tabulka nepasuje na regex (alebo uz bola naplnena), skript skonci s `exit 0`.

Skript caka na MariaDB readiness, takze moze bezet hned za `benchmark-restore.sh`.

Pouzitie:
```bash
# Faza 1: rychle jadro (~43 min)
RESTORE_MODE=pruned-data scripts/benchmark-restore.sh data/dumps/...sql.gz
# Faza 2: dolejenie prevadzkovych dát (~30 min)
docker exec crz-opt-mariadb sh /opt/crz-opt-scripts/container-backfill.sh /dumps/...sql.gz
```

## 2026-05-31 - Backfill test (partial, with statistics)

Test dvojfázového restore s reálnym spustením `container-backfill.sh`.

Výsledok (časť 13/16 tabuliek, kill po ~17 min):

- phase 1 pruned-data: 2579 s
- phase 2 backfill (13/16 tabuliek): 1034 s → kill
- celkom: 3613 s (60:13) pre 13 tabuliek
- zostávajú: counter_04, counter_06, robot_02 (0 rows, pravdepodobne malé/prázdne tabuľky)
- riadkov načítaných: 104,6 milióna
- integrita: všetkých 13 tabuliek OK (CHECK TABLE status OK)
- úspora proti fast: -17.6% (3613 s vs 4384 s)

Záver:
- backfill je pomalší ako by sme chceli, ale to nevadí pre hlavný cieľ,
- primárna metrika je čas do dostupnej aplikácie, nie čas do kompletných prevádzkových dát,
- `pruned-data` je stále najlepší na rýchly štart (`42:59`),
- backfill má bežať asynchrónne po štarte aplikácie,
- ďalší krok je spraviť backfill resumable/table-scoped, aby sa dali dohrávať alebo opakovať jednotlivé prevádzkové tabuľky bez kompletného skenovania dumpu.

## 2026-05-31 - Restore worker image

Pridana prva verzia automatickeho restore workeru.

Implementovane:

- `Dockerfile.restore-worker` - maly Docker CLI image s bash/coreutils/gawk/gzip,
- Docker Compose service `restore-worker` v profile `restore-worker`,
- `scripts/watch-dumps.sh` - pravidelne skenuje `data/dumps/*.sql.gz`,
- `scripts/backfill-gz.sh` - host-side wrapper na kontajnerovy backfill s logovanim,
- stav v `data/restore-state/`, hlavne `last-success.id` a `last-success.state`.

Rozhodnutie: worker nie je spusteny v default profile, aby omylom neresetoval existujucu DB pri beznom `up-db.sh`. Spusta sa explicitne cez:

```bash
docker compose --profile restore-worker up -d --build restore-worker
```

Povodne worker pouzival `/var/run/docker.sock` a vnutorne spustal `docker compose`.
Od 2026-06-04 to uz neplati: worker restore riadi priamo cez MariaDB klienta,
SQL prikazy a bash pipeline. `RESTORE_WORKER_PROJECT_DIR` stale urcuje mountnutu
projektovu cestu, ale nie je potrebny kvoli Docker socketu.

## 2026-06-09 - v1.0.0: Kompletná rearchitektúra na dva nezávislé stacky

Rozhodnutie: Kompletná rearchitektúra restore labu na dva oddelené Docker Compose stacky.

**Dôvody:**
- Pôvodný jednotný `docker-compose.yml` mixoval DB a worker, čo sťažovolo nezávislé nasadenie
- Worker potrebuje vlastnú sieťovú komunikáciu s DB, nie cez localhost
- Scripts mali byť v image, nie v volume mountoch

**Implementácia:**

Nová štruktúra:
- `docker-compose.db.yml` - samostatný MariaDB stack, port 53306
- `docker-compose.yml` - samostatný restore-worker stack
- Zdieľaný externý bridge `crz-opt-net` (10.91.0.0/24)
- `Dockerfile.restore-worker` - COPY scripts/ do /opt/crz-opt-scripts/
- Worker entrypoint: `restore-worker-entrypoint.sh` → metrics + watch-dumps

**Sieťová architektúra:**
```
crz-opt-net (10.91.0.0/24, external bridge)
├── crz-opt-mariadb (10.91.0.2:3306)
└── crz-opt-restore-worker (10.91.0.x:3306) → DB_HOST=crz-opt-mariadb
```

**Scripts v image:**
Všetky skripty sú teraz embedded v `restore-worker` image v `/opt/crz-opt-scripts/`:
- `sql-benchmark-restore.sh` - hlavný restore workflow
- `sql-restore-gz.sh` - restore s pv progress
- `sql-backfill-gz.sh` - async backfill
- `watch-dumps.sh` - automatický monitoring
- `container-restore.sh`, `container-backfill.sh` - container-aware helpers
- `container-wait-ready.sh` - DB healthcheck cez `MARIADB_USER=crz`

**PV progress monitoring:**
`sql-restore-gz.sh` teraz používa pv na zobrazenie progress počas restore:
```bash
pv -petrb -s "$UNCOMPRESSED_SIZE" < "$DUMP_FILE" | gzip -dc | mariadb ...
```

**DB_HOST context-aware:**
- Worker context: `DB_HOST=crz-opt-mariadb` (sieťový hostname)
- Local context: `127.0.0.1` (pre local debugging)
- `container-wait-ready.sh` defaultuje na `127.0.0.1` ak nie je nastavené

**Výsledky testov:**
- Auto-restore simulation: 500k rows, 3.5s restore
- Watch-dumps.sh funguje: detection → 120s stable → restore → backfill
- Metrics endpoint: OK
- PV progress: funguje (bez PTY binary mode)

**Nasadenie na NAS:**
```bash
# Network + volume
docker network create crz-opt-net --driver bridge --subnet 10.91.0.0/24
docker volume create crz-opt-mariadb-data

# Štart DB
docker compose -f docker-compose.db.yml up -d

# Štart worker (auto-restore)
docker compose -f docker-compose.yml --profile restore-worker up -d
```

**Ďalšie kroky:**
- [ ] Reálny ~78GB dump restore test
- [ ] Stress test s viacerými dump súbormi
- [ ] Git commit pre v1.0.0
