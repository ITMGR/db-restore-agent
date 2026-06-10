#!/usr/bin/env python3
import csv
import base64
import hmac
import os
import subprocess
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


PROJECT_DIR = Path(os.environ.get("RESTORE_WORKER_PROJECT_DIR", Path(__file__).resolve().parents[1]))
STATE_DIR = Path(os.environ.get("RESTORE_STATE_DIR", PROJECT_DIR / "data" / "restore-state"))
DUMP_DIR = Path(os.environ.get("DUMP_WATCH_DIR", PROJECT_DIR / "data" / "dumps"))
RUNS_DIR = PROJECT_DIR / "data" / "restore-runs"
PORT = int(os.environ.get("METRICS_PORT", "9100"))
PRUNE_RE = os.environ.get("PRUNE_DATA_TABLE_REGEX", r"^(log_[0-9]+|counter_[0-9]+|robot_01|robot_02|elastic1)$")
DB_HOST = os.environ.get("DB_HOST", "db")
DB_PORT = os.environ.get("DB_PORT", "3306")
DB_NAME = os.environ.get("MARIADB_DATABASE", "crz")
DB_USER = os.environ.get("MARIADB_USER", "crz")
DB_PASSWORD = os.environ.get("MARIADB_PASSWORD", "")
AUTH_ENABLED = os.environ.get("METRICS_BASIC_AUTH_ENABLED", "false").lower() == "true"
AUTH_USERNAME = os.environ.get("METRICS_BASIC_AUTH_USERNAME", "")
AUTH_PASSWORD = os.environ.get("METRICS_BASIC_AUTH_PASSWORD", "")
START_TIME = time.time()


def prom_escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def sql_quote(value):
    return "'" + str(value).replace("\\", "\\\\").replace("'", "''") + "'"


def labels(**items):
    if not items:
        return ""
    body = ",".join(f'{key}="{prom_escape(value)}"' for key, value in sorted(items.items()))
    return "{" + body + "}"


def metric(name, value, help_text=None, metric_type="gauge", **label_items):
    lines = []
    if help_text:
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} {metric_type}")
    lines.append(f"{name}{labels(**label_items)} {value}")
    return lines


def parse_state(path):
    data = {}
    if not path.exists():
        return data
    for line in path.read_text(errors="replace").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key] = value.replace("\\|", "|").strip("'\"")
    return data


def parse_ts(value):
    if not value:
        return 0
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0


def last_csv_row(path):
    if not path.exists():
        return None
    rows = []
    with path.open(newline="", errors="replace") as handle:
        for row in csv.reader(handle):
            if len(row) >= 4 and row[0] != "run_id":
                rows.append(row)
    return rows[-1] if rows else None


def run_command(command, timeout=8, env=None):
    try:
        return subprocess.run(
            command,
            cwd=PROJECT_DIR,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as exc:
        return subprocess.CompletedProcess(command, 127, "", str(exc))
    except subprocess.TimeoutExpired as exc:
        return subprocess.CompletedProcess(command, 124, exc.stdout or "", exc.stderr or "timeout")


def db_metrics():
    sql = (
        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE(); "
        "SELECT TABLE_NAME,TABLE_ROWS FROM information_schema.TABLES "
        f"WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME RLIKE {sql_quote(PRUNE_RE)} ORDER BY TABLE_NAME; "
        "SELECT "
        "  SUM(DATA_LENGTH+INDEX_LENGTH) AS total_bytes, "
        "  SUM(DATA_LENGTH) AS data_bytes, "
        "  SUM(INDEX_LENGTH) AS index_bytes, "
        "  SUM(TABLE_ROWS) AS total_rows "
        "FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE();"
    )
    command = [
        "mariadb",
        f"--host={DB_HOST}",
        f"--port={DB_PORT}",
        f"--user={DB_USER}",
        "--skip-column-names",
        "--batch",
        DB_NAME,
        "-e",
        sql,
    ]
    env = os.environ.copy()
    env["MYSQL_PWD"] = DB_PASSWORD
    result = run_command(command, timeout=12, env=env)
    lines = []
    if result.returncode != 0:
        lines += metric("crz_restore_database_scrape_success", 0, "Whether MariaDB metrics scrape succeeded.")
        return lines

    output = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    lines += metric("crz_restore_database_scrape_success", 1, "Whether MariaDB metrics scrape succeeded.")
    if output:
        try:
            lines += metric("crz_restore_database_tables_total", int(output[0]), "Total table count in restored database.")
        except ValueError:
            pass

    # Parse size row (total_bytes, data_bytes, index_bytes, total_rows)
    for line in output[1:]:
        parts = line.split("\t")
        if len(parts) == 4:
            try:
                total_bytes = int(parts[0]) or 0
                data_bytes = int(parts[1]) or 0
                index_bytes = int(parts[2]) or 0
                total_rows = int(parts[3]) or 0
                lines += metric("crz_restore_database_size_bytes", total_bytes, "Total database size (data+index).")
                lines += metric("crz_restore_database_data_bytes", data_bytes, "Database data size.")
                lines += metric("crz_restore_database_index_bytes", index_bytes, "Database index size.")
                lines += metric("crz_restore_database_total_rows", total_rows, "Total rows across all tables.")
            except ValueError:
                pass
            break

    pruned_total = 0
    pruned_empty = 0
    pruned_started = False
    for line in output[1:]:
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        # Skip the size row (4 columns) — already handled
        try:
            int(parts[0])
            continue  # numeric table name? skip
        except ValueError:
            pass
        table, row_count = parts
        try:
            rows = int(row_count)
        except ValueError:
            rows = 0
        pruned_total += 1
        if rows == 0:
            pruned_empty += 1
        lines += metric("crz_restore_database_pruned_table_rows", rows, "Rows per pruned/backfilled table.", table=table)

    lines += metric("crz_restore_database_pruned_tables_total", pruned_total, "Number of tables watched for async backfill.")
    lines += metric("crz_restore_database_pruned_tables_empty", pruned_empty, "Number of watched backfill tables still empty.")
    return lines


def dump_metrics():
    files = sorted(DUMP_DIR.glob("*.sql.gz"), key=lambda p: p.stat().st_mtime if p.exists() else 0)
    total_bytes = 0
    newest_mtime = 0
    newest_name = ""
    for file in files:
        stat = file.stat()
        total_bytes += stat.st_size
        if stat.st_mtime >= newest_mtime:
            newest_mtime = int(stat.st_mtime)
            newest_name = file.name
    lines = []
    lines += metric("crz_restore_dump_files_total", len(files), "Number of SQL gzip dump files in watch directory.")
    lines += metric("crz_restore_dump_bytes", total_bytes, "Total size of SQL gzip dump files in watch directory.")
    if newest_name:
        lines += metric("crz_restore_dump_newest_mtime_seconds", newest_mtime, "Newest dump mtime.", dump=newest_name)
    return lines


def restore_state_metrics():
    current = parse_state(STATE_DIR / "current.state")
    success = parse_state(STATE_DIR / "last-success.state")
    failure = parse_state(STATE_DIR / "last-failure.state")
    restore_row = last_csv_row(RUNS_DIR / "results.csv")
    backfill_row = last_csv_row(RUNS_DIR / "backfill-results.csv")

    lines = []
    lines += metric("crz_restore_worker_up", 1, "Restore worker metrics endpoint is up.")
    lines += metric("crz_restore_worker_start_time_seconds", int(START_TIME), "Metrics server start time.")
    lines += metric("crz_restore_workflow_running", 1 if current else 0, "Whether restore workflow is currently running.")

    if current:
        lines += metric(
            "crz_restore_workflow_current_state",
            1,
            "Current restore workflow phase and status.",
            phase=current.get("phase", "unknown"),
            status=current.get("status", "unknown"),
        )
        lines += metric(
            "crz_restore_workflow_current_updated_timestamp_seconds",
            parse_ts(current.get("updated_at_utc")),
            "Current workflow state update timestamp.",
        )

    if success:
        lines += metric(
            "crz_restore_last_success_info",
            1,
            "Last successful restore workflow info.",
            status=success.get("status", "unknown"),
            restore_mode=success.get("restore_mode", "unknown"),
            auto_backfill=success.get("auto_backfill", "unknown"),
            dump=os.path.basename(success.get("dump", "")),
        )
        lines += metric(
            "crz_restore_last_success_timestamp_seconds",
            parse_ts(success.get("finished_at_utc")),
            "Last successful workflow finish timestamp.",
        )

    if failure:
        lines += metric(
            "crz_restore_last_failure_timestamp_seconds",
            parse_ts(failure.get("updated_at_utc")),
            "Last failed workflow timestamp.",
        )

    if restore_row:
        lines += metric(
            "crz_restore_last_restore_duration_seconds",
            int(restore_row[3]),
            "Last phase-1 restore duration.",
            run_id=restore_row[0],
            mode=restore_row[1],
        )
    if backfill_row:
        lines += metric(
            "crz_restore_last_backfill_duration_seconds",
            int(backfill_row[3]),
            "Last async backfill duration.",
            run_id=backfill_row[0],
        )
    return lines


def render_metrics():
    lines = []
    lines.extend(restore_state_metrics())
    lines.extend(dump_metrics())
    lines.extend(db_metrics())
    lines.append("")
    return "\n".join(lines).encode()


def auth_header_valid(header):
    if not AUTH_ENABLED:
        return True
    if not AUTH_USERNAME or not AUTH_PASSWORD:
        return False
    if not header.startswith("Basic "):
        return False
    try:
        decoded = base64.b64decode(header[6:], validate=True).decode()
    except Exception:
        return False
    username, separator, password = decoded.partition(":")
    if separator != ":":
        return False
    return hmac.compare_digest(username, AUTH_USERNAME) and hmac.compare_digest(password, AUTH_PASSWORD)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/metrics", "/metrics/"):
            self.send_response(404)
            self.end_headers()
            return
        if not auth_header_valid(self.headers.get("Authorization", "")):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="crz-opt metrics"')
            self.end_headers()
            return
        body = render_metrics()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"restore metrics listening on 0.0.0.0:{PORT}", flush=True)
    server.serve_forever()
