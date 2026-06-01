# Release Notes - crz-opt

## v0.1.1 - 2026-06-01

Patch release:

- Volitelne HTTP Basic Auth prihlasovanie na metrics endpoint cez `METRICS_BASIC_AUTH_ENABLED`, `METRICS_BASIC_AUTH_USERNAME` a `METRICS_BASIC_AUTH_PASSWORD`.
- Metrics server pri chybajucom Docker CLI alebo timeout-e vrati scrape-failure metriky namiesto padu request handlera.

## v0.1.0 - 2026-06-01

Prva pouzitelna verzia MariaDB restore labu pre CRZ dump.

Obsah:

- MariaDB 12.1 Docker Compose restore prostredie.
- Benchmark skripty pre `baseline`, `fast`, `aggressive` a `pruned-data` restore rezimy.
- Dvojfazovy workflow: rychly `pruned-data` restore jadra a async backfill prevadzkovych tabuliek.
- Automaticky `restore-worker`, ktory sleduje `data/dumps/*.sql.gz` a pri novom stabilnom dumpe spusti restore + backfill.
- Perzistentny stav workeru v `data/restore-state/`.
- Prometheus-compatible metrics endpoint restore workeru na `127.0.0.1:59100/metrics`.

Overene merania:

- `fast`: `4384` s (`1:13:04`).
- `aggressive`: `4253` s (`1:10:53`).
- `pruned-data`: `2579` s (`42:59`).
- auto-restore test cez kopiu dumpu: restore `2575` s (`42:55`), backfill `2088` s (`34:48`), workflow `success`.
