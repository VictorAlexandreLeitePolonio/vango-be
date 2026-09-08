#!/usr/bin/env python3
"""Exercise Cycle 6 lock ordering with two real PostgreSQL sessions.

The harness creates the existing Cycle 4 fixture inside the isolated
``vango_cycle_6`` database, commits only that disposable fixture, and removes
it in a finally block.  It never accepts a remote host or the shared
``postgres`` database.
"""

from __future__ import annotations

import os
import re
import select
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[3]
PSQL_DEFAULT = "/opt/homebrew/opt/libpq/bin/psql"
LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}
DATABASE = "vango_cycle_6"
MARKER_RE = re.compile(r"^VANGO_TRACKING_([A-Z_]+)=([0-9a-fA-F-]+)$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")
FIXTURE_USER_IDS = (
    "40000000-0000-0000-0000-000000000001",
    "40000000-0000-0000-0000-000000000002",
    "40000000-0000-0000-0000-000000000003",
    "40000000-0000-0000-0000-000000000004",
    "40000000-0000-0000-0000-000000000005",
    "60000000-0000-0000-0000-000000000001",
    "60000000-0000-0000-0000-000000000002",
    "60000000-0000-0000-0000-000000000003",
    "60000000-0000-0000-0000-000000000004",
    "60000000-0000-0000-0000-000000000005",
)
FIXTURE_FLEET_IDS = (
    "41000000-0000-0000-0000-000000000001",
    "41000000-0000-0000-0000-000000000002",
)
FIXTURE_SCHOOL_ID = "65000000-0000-0000-0000-000000000001"


class TrackingRaceError(AssertionError):
    """A concurrency invariant was not demonstrated."""


def database_url() -> str:
    value = os.environ.get(
        "VANGO_TEST_DATABASE_URL",
        "postgresql://supabase_admin:postgres@127.0.0.1:54322/vango_cycle_6",
    )
    parsed = urlparse(value)
    if parsed.scheme not in {"postgres", "postgresql"}:
        raise TrackingRaceError("database URL must use postgres or postgresql")
    if parsed.hostname not in LOCAL_HOSTS:
        raise TrackingRaceError("refusing a non-loopback database host")
    try:
        parsed_port = parsed.port
    except ValueError as error:
        raise TrackingRaceError("database URL has an invalid port") from error
    if parsed_port != 54322:
        raise TrackingRaceError("database URL must use the local Supabase port 54322")
    query_keys = {key.lower() for key in parse_qs(parsed.query, keep_blank_values=True)}
    if query_keys.intersection({"host", "hostaddr", "service", "servicefile", "port", "dbname"}):
        raise TrackingRaceError("database URL cannot override its local connection target")
    if any(
        os.environ.get(key)
        for key in (
            "PGHOST",
            "PGHOSTADDR",
            "PGPORT",
            "PGDATABASE",
            "PGSERVICE",
            "PGSERVICEFILE",
        )
    ):
        raise TrackingRaceError("libpq environment cannot override the local connection target")
    database = parsed.path.removeprefix("/")
    if database != DATABASE:
        raise TrackingRaceError(
            f"refusing a database other than {DATABASE} (got {database!r})"
        )
    return value


def psql_path() -> str:
    requested = os.environ.get("VANGO_PSQL", PSQL_DEFAULT)
    if os.path.isabs(requested):
        if not os.access(requested, os.X_OK):
            raise TrackingRaceError(f"psql is not executable: {requested}")
        return requested
    resolved = shutil.which(requested)
    if not resolved:
        raise TrackingRaceError("psql was not found; set VANGO_PSQL")
    return resolved


def command_args(psql: str, dsn: str, *extra: str) -> list[str]:
    return [psql, dsn, "-X", "-v", "ON_ERROR_STOP=1", *extra]


def run_sql(psql: str, dsn: str, sql: str) -> str:
    completed = subprocess.run(
        command_args(psql, dsn, "-A", "-t", "-P", "pager=off", "-c", sql),
        cwd=ROOT,
        env=os.environ.copy(),
        text=True,
        capture_output=True,
        check=False,
        timeout=20,
    )
    if completed.returncode != 0:
        raise TrackingRaceError(
            f"observation query failed with exit {completed.returncode}: "
            f"{completed.stderr.strip()}"
        )
    return completed.stdout.strip()


def assert_fixture_ids_free(psql: str, dsn: str) -> None:
    user_ids = ", ".join(f"'{value}'::uuid" for value in FIXTURE_USER_IDS)
    fleet_ids = ", ".join(f"'{value}'::uuid" for value in FIXTURE_FLEET_IDS)
    query = f"""
select count(*)
from (
  select id from auth.users where id in ({user_ids})
  union all
  select id from public.fleets where id in ({fleet_ids})
  union all
  select id from public.schools where id = '{FIXTURE_SCHOOL_ID}'::uuid
) occupied;
"""
    occupied = run_sql(psql, dsn, query)
    if occupied != "0":
        raise TrackingRaceError(
            "tracking fixture IDs are already occupied; refusing to overwrite them"
        )


def setup_fixture(psql: str, dsn: str) -> tuple[dict[str, str], Path]:
    setup_sql = r"""
begin;
\ir __HELPERS__
\ir __PLANNING__
\ir __OPERATIONS__
\ir __TRACKING__
select pg_temp.seed_tracking();
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select public.request_trip_route_calculation(
  (select id from operation_ids where kind = 'return')
) as route_revision \gset
select id as active_trip
from tracking_ids where kind = 'trip' \gset
select id as active_assignment
from tracking_ids where kind = 'assignment' \gset
select id as active_student
from tracking_ids where kind = 'student' \gset
select id as active_fleet
from tracking_ids where kind = 'fleet' \gset
select id as return_trip
from operation_ids where kind = 'return' \gset
select :'route_revision' as return_route_revision \gset
select 'VANGO_TRACKING_TRIP=' || :'active_trip';
select 'VANGO_TRACKING_ASSIGNMENT=' || :'active_assignment';
select 'VANGO_TRACKING_STUDENT=' || :'active_student';
select 'VANGO_TRACKING_FLEET=' || :'active_fleet';
select 'VANGO_TRACKING_RETURN_TRIP=' || :'return_trip';
select 'VANGO_TRACKING_ROUTE_REVISION=' || :'return_route_revision';
commit;
"""
    for placeholder, path in (
        ("__HELPERS__", ROOT / "supabase/tests/_helpers.psql"),
        ("__PLANNING__", ROOT / "supabase/tests/_planning.psql"),
        ("__OPERATIONS__", ROOT / "supabase/tests/_operations.psql"),
        ("__TRACKING__", ROOT / "supabase/tests/_tracking.psql"),
    ):
        setup_sql = setup_sql.replace(placeholder, str(path))
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".psql", prefix="vango-cycle6-setup-", delete=False
    ) as handle:
        handle.write(setup_sql)
        setup_path = Path(handle.name)
    committed = False
    try:
        completed = subprocess.run(
            command_args(psql, dsn, "-A", "-t", "-P", "pager=off", "-f", str(setup_path)),
            cwd=ROOT,
            env=os.environ.copy(),
            text=True,
            capture_output=True,
            check=False,
            timeout=30,
        )
        if completed.returncode != 0:
            raise TrackingRaceError(
                f"tracking fixture setup failed: {completed.stderr.strip()}"
            )
        committed = True
        values: dict[str, str] = {}
        for line in completed.stdout.splitlines():
            match = MARKER_RE.fullmatch(line.strip())
            if match:
                key, value = match.groups()
                if key == "ROUTE_REVISION":
                    if not value.isdigit() or int(value) < 1:
                        raise TrackingRaceError("setup returned an invalid route revision")
                elif not UUID_RE.fullmatch(value):
                    raise TrackingRaceError(f"setup returned an invalid UUID for {key}")
                values[key] = value.lower()
        required = {
            "TRIP", "ASSIGNMENT", "STUDENT", "FLEET", "RETURN_TRIP", "ROUTE_REVISION"
        }
        missing = required - values.keys()
        if missing:
            raise TrackingRaceError(f"setup did not return markers: {sorted(missing)}")
        return values, setup_path
    except Exception:
        if committed:
            cleanup_fixture(psql, dsn, setup_path)
        else:
            setup_path.unlink(missing_ok=True)
        raise


def cleanup_fixture(psql: str, dsn: str, setup_path: Path) -> None:
    setup_path.unlink(missing_ok=True)
    cleanup_sql = """
begin;
delete from private.notification_manual_commands
where fleet_id in ('41000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000002');
delete from private.trip_location_summaries
where fleet_id in ('41000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000002');
delete from public.trip_location_points
where fleet_id in ('41000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000002');
delete from public.trip_location_receipts
where fleet_id in ('41000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000002');
delete from public.trip_current_locations
where fleet_id in ('41000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000002');
delete from public.trip_route_calculations
where fleet_id in ('41000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000002');
delete from public.notifications
where fleet_id in ('41000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000002');
commit;
"""
    # The C6 rows are deleted first because the existing C4 fixture cleanup
    # removes assignments and trips.  Reuse that narrow, fixed-fleet cleanup
    # instead of duplicating its full FK order here.
    cleanup_sql += "\n" + (ROOT / "supabase/tests/concurrency/operations_cleanup.psql").read_text()
    completed = subprocess.run(
        command_args(psql, dsn, "-A", "-t", "-P", "pager=off", "-c", cleanup_sql),
        cwd=ROOT,
        env=os.environ.copy(),
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )
    if completed.returncode != 0:
        raise TrackingRaceError(f"tracking C6 cleanup failed: {completed.stderr.strip()}")


def session(psql: str, dsn: str, application_name: str) -> subprocess.Popen[str]:
    environment = os.environ.copy()
    environment["PGAPPNAME"] = application_name
    return subprocess.Popen(
        command_args(psql, dsn, "-A", "-t", "-P", "pager=off"),
        cwd=ROOT,
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )


def send(process: subprocess.Popen[str], sql: str) -> None:
    if process.stdin is None:
        raise TrackingRaceError("psql stdin is unavailable")
    process.stdin.write(sql)
    process.stdin.flush()


def wait_for_marker(process: subprocess.Popen[str], marker: str) -> None:
    if process.stdout is None:
        raise TrackingRaceError("psql stdout is unavailable")
    deadline = time.monotonic() + 8
    output = b""
    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        ready, _, _ = select.select([process.stdout], [], [], remaining)
        if not ready:
            break
        chunk = os.read(process.stdout.fileno(), 4096)
        if not chunk:
            raise TrackingRaceError(f"session ended before {marker}")
        output += chunk
        if marker.encode() in output.splitlines():
            return
    raise TrackingRaceError(f"session did not publish {marker}")


def wait_for_advisory_wait(psql: str, dsn: str, application_name: str) -> None:
    deadline = time.monotonic() + 8
    query = (
        "select count(*) from pg_stat_activity "
        f"where application_name = '{application_name}' "
        "and wait_event = 'advisory'"
    )
    while time.monotonic() < deadline:
        if run_sql(psql, dsn, query) == "1":
            return
        time.sleep(0.05)
    raise TrackingRaceError(f"{application_name} did not wait on planning lock")


def finish_process(process: subprocess.Popen[str], timeout: float = 12) -> tuple[int, str, str]:
    if process.stdin is not None and not process.stdin.closed:
        process.stdin.close()
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        process.kill()
        process.wait(timeout=3)
        raise TrackingRaceError("concurrency session timed out") from error
    stdout = process.stdout.read() if process.stdout is not None else ""
    stderr = process.stderr.read() if process.stderr is not None else ""
    return process.returncode, stdout, stderr


def assert_revocation_race(psql: str, dsn: str, ids: dict[str, str]) -> None:
    trip = ids["TRIP"]
    assignment = ids["ASSIGNMENT"]
    driver = "40000000-0000-0000-0000-000000000003"
    first = session(psql, dsn, "vango-cycle6-revocation-first")
    second = session(psql, dsn, "vango-cycle6-ingest-second")
    try:
        send(
            first,
            "begin;\n"
            "select private.lock_planning();\n"
            f"update public.trip_assignments set valid_until = clock_timestamp() "
            f"where id = '{assignment}' and valid_until is null;\n"
            "select 'VANGO_REVOKED';\n",
        )
        wait_for_marker(first, "VANGO_REVOKED")
        send(
            second,
            "begin;\n"
            f"select set_config('request.jwt.claims', '{{\"sub\":\"{driver}\","
            "\"role\":\"authenticated\"}', false);\n"
            f"select public.ingest_trip_locations('{trip}'::uuid, '{assignment}'::uuid, "
            "jsonb_build_array(jsonb_build_object('sequence', 990001, "
            "'captured_at', clock_timestamp(), 'latitude', -23.5, 'longitude', -46.6, "
            "'accuracy', 5)), true);\n"
            "commit;\n",
        )
        wait_for_advisory_wait(psql, dsn, "vango-cycle6-ingest-second")
        send(first, "commit;\n")
        first_result = finish_process(first)
        second_result = finish_process(second)
        if first_result[0] != 0:
            raise TrackingRaceError(f"revocation session failed: {first_result[2]}")
        if second_result[0] == 0 or '"code": "invalid_transition"' not in second_result[2] or "Live GPS requires an active trip assignment" not in second_result[2]:
            raise TrackingRaceError(
                "ingest after committed assignment revocation did not fail closed: "
                + second_result[2]
            )
    finally:
        for process in (first, second):
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)


def assert_route_revision_race(psql: str, dsn: str, ids: dict[str, str]) -> None:
    trip = ids["RETURN_TRIP"]
    revision = ids["ROUTE_REVISION"]
    first = session(psql, dsn, "vango-cycle6-route-edit-first")
    second = session(psql, dsn, "vango-cycle6-route-apply-second")
    try:
        send(
            first,
            "begin;\n"
            "select private.lock_planning();\n"
            f"update public.trip_stops set address_snapshot = '{{\"label\":\"race\"}}'::jsonb "
            f"where trip_id = '{trip}'::uuid and reached_at is null "
            "and id = (select id from public.trip_stops where trip_id = '"
            f"{trip}'::uuid and reached_at is null order by position limit 1);\n"
            "select 'VANGO_ROUTE_EDITED';\n",
        )
        wait_for_marker(first, "VANGO_ROUTE_EDITED")
        send(
            second,
            f"select public.apply_trip_route_result('{trip}'::uuid, {revision}::bigint, "
            "'{}'::jsonb);\n",
        )
        wait_for_advisory_wait(psql, dsn, "vango-cycle6-route-apply-second")
        send(first, "commit;\n")
        first_result = finish_process(first)
        second_result = finish_process(second)
        if first_result[0] != 0:
            raise TrackingRaceError(f"route edit session failed: {first_result[2]}")
        if second_result[0] != 0 or "superseded" not in second_result[1]:
            raise TrackingRaceError(
                "stale route result was not superseded after concurrent edit: "
                + second_result[1] + second_result[2]
            )
        state = run_sql(
            psql,
            dsn,
            f"select status from public.trip_route_calculations "
            f"where trip_id = '{trip}'::uuid and revision = {revision};",
        )
        if state != "superseded":
            raise TrackingRaceError(f"stale calculation state was {state!r}")
    finally:
        for process in (first, second):
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)


def main() -> int:
    dsn = database_url()
    psql = psql_path()
    current_database = run_sql(psql, dsn, "select current_database();")
    if current_database != DATABASE:
        raise TrackingRaceError(f"refusing to run outside {DATABASE} (got {current_database!r})")
    assert_fixture_ids_free(psql, dsn)
    ids: dict[str, str] | None = None
    setup_path: Path | None = None
    try:
        ids, setup_path = setup_fixture(psql, dsn)
        assert_revocation_race(psql, dsn, ids)
        assert_route_revision_race(psql, dsn, ids)
        print("tracking concurrency: revocation×ingest and route revision×apply PASS")
        return 0
    finally:
        if setup_path is not None:
            cleanup_fixture(psql, dsn, setup_path)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except TrackingRaceError as error:
        raise SystemExit(str(error)) from error
