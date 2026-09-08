#!/usr/bin/env python3
"""Exercise Ciclo 4 operation serialization with real PostgreSQL sessions.

Every scenario uses a committed, disposable fixture in vango_cycle_4.  One
session holds the global planning advisory lock at a barrier while the other
session starts its command.  The second session must either complete against
the committed state or fail with the stable domain error; cleanup is always
scoped to the fixture IDs and runs in ``finally``.
"""

from __future__ import annotations

import json
import os
import re
import select
import shutil
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SETUP = Path(__file__).with_name("operations_setup.psql")
CLEANUP = Path(__file__).with_name("operations_cleanup.psql")
LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")
MARKER_RE = re.compile(
    r"^VANGO_C4_OPERATION_([A-Z_]+)=([0-9a-fA-F-]+)$"
)


class OperationRaceError(AssertionError):
    """A concurrency invariant was not demonstrated."""


def env_for_psql() -> dict[str, str]:
    env = os.environ.copy()
    host = env.get("PGHOST")
    port = env.get("PGPORT")
    database = env.get("PGDATABASE")
    user = env.get("PGUSER")
    if host not in LOCAL_HOSTS:
        raise OperationRaceError(
            "PGHOST must be one of 127.0.0.1, localhost, or ::1; "
            "refusing a remote operation test"
        )
    if not port or not port.isdigit() or not (1 <= int(port) <= 65535):
        raise OperationRaceError("PGPORT must identify a local PostgreSQL listener")
    if database != "vango_cycle_4":
        raise OperationRaceError(
            "PGDATABASE must be exactly vango_cycle_4 for operation races"
        )
    if user != "postgres":
        raise OperationRaceError("PGUSER must be postgres for the isolated fixture")
    if not env.get("PGPASSWORD"):
        raise OperationRaceError("PGPASSWORD must be supplied by the environment")
    for variable in ("PGHOSTADDR", "PGSERVICE", "PGSERVICEFILE"):
        if env.get(variable):
            raise OperationRaceError(
                f"{variable} must be unset so the local operation target is unambiguous"
            )
    psql = shutil.which("psql")
    if not psql:
        raise OperationRaceError("psql is required for the real-session test")
    env["VANGO_PSQL"] = psql
    return env


def psql_args(env: dict[str, str], *extra: str) -> list[str]:
    return [
        env["VANGO_PSQL"],
        "-X",
        "-h",
        env["PGHOST"],
        "-p",
        env["PGPORT"],
        "-U",
        env["PGUSER"],
        "-d",
        env["PGDATABASE"],
        "-v",
        "ON_ERROR_STOP=1",
        *extra,
    ]


def run_file(path: Path, env: dict[str, str]) -> str:
    completed = subprocess.run(
        psql_args(env, "-P", "pager=off", "-f", str(path)),
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        error = OperationRaceError(
            f"{path.name} failed with exit {completed.returncode}:\n"
            f"{completed.stdout}\n{completed.stderr}"
        )
        error.setup_output = completed.stdout  # type: ignore[attr-defined]
        raise error
    return completed.stdout


def run_sql(sql: str, env: dict[str, str]) -> str:
    completed = subprocess.run(
        psql_args(env, "-At", "-P", "pager=off", "-c", sql),
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        raise OperationRaceError(
            f"observation query failed with exit {completed.returncode}: "
            f"{completed.stderr.strip()}"
        )
    return completed.stdout.strip()


def parse_setup(output: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in output.splitlines():
        match = MARKER_RE.match(line.strip())
        if match:
            key, value = match.groups()
            if not UUID_RE.fullmatch(value):
                raise OperationRaceError(f"setup returned an invalid UUID for {key}")
            values[key] = value.lower()
    required = {
        "FLEET",
        "OWNER",
        "GUARDIAN",
        "DRIVER",
        "REPLACEMENT_DRIVER",
        "GOING",
        "RETURN",
        "FUTURE_GOING",
        "ENROLLMENT",
        "STUDENT",
        "REPLACEMENT_VAN",
    }
    missing = required - values.keys()
    if missing:
        raise OperationRaceError(f"setup did not return markers: {sorted(missing)}")
    return values


def session(env: dict[str, str], application_name: str) -> subprocess.Popen[str]:
    session_env = env.copy()
    session_env["PGAPPNAME"] = application_name
    return subprocess.Popen(
        psql_args(env, "-P", "pager=off"),
        cwd=ROOT,
        env=session_env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )


def send(process: subprocess.Popen[str], sql: str) -> None:
    if process.stdin is None:
        raise OperationRaceError("psql stdin is unavailable")
    process.stdin.write(sql)
    process.stdin.flush()


def wait_for_marker(process: subprocess.Popen[str]) -> None:
    if process.stdout is None:
        raise OperationRaceError("psql stdout is unavailable")
    deadline = time.monotonic() + 5
    output = b""
    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        ready, _, _ = select.select([process.stdout], [], [], remaining)
        if not ready:
            break
        chunk = os.read(process.stdout.fileno(), 4096)
        if not chunk:
            raise OperationRaceError("first session ended before acquiring the lock")
        output += chunk
        if b"VANGO_C4_LOCKED" in output.splitlines():
            return
    raise OperationRaceError("first session did not publish the lock barrier")


def wait_for_advisory_wait(env: dict[str, str], application_name: str) -> None:
    deadline = time.monotonic() + 5
    query = (
        "select count(*) from pg_stat_activity "
        f"where application_name = '{application_name}' "
        "and wait_event = 'advisory'"
    )
    while time.monotonic() < deadline:
        if run_sql(query, env) == "1":
            return
        time.sleep(0.05)
    raise OperationRaceError("second session did not wait on the advisory lock")


def auth_sql(user_id: str) -> str:
    claims = json.dumps({"sub": user_id, "role": "authenticated"})
    return f"select set_config('request.jwt.claims', '{claims}', false);\n"


def run_race(
  ids: dict[str, str],
  env: dict[str, str],
  name: str,
  first_sql: str,
  second_sql: str,
  second_error: str | None,
  second_user: str | None = None,
) -> None:
    first = session(env, f"vango-c4-{name}-first")
    second = session(env, f"vango-c4-{name}-second")
    try:
        send(
            first,
            auth_sql(ids["OWNER"])
            + "begin; select private.lock_planning();\n"
            + "\\echo VANGO_C4_LOCKED\n",
        )
        wait_for_marker(first)
        send(
            second,
            auth_sql(second_user or ids["OWNER"])
            + "begin; set local role authenticated;\n"
            + second_sql
            + "\ncommit;\n",
        )
        wait_for_advisory_wait(env, f"vango-c4-{name}-second")
        send(
            first,
            "set local role authenticated;\n" + first_sql + "\ncommit;\n",
        )
        if first.stdin is not None:
            first.stdin.close()
        if second.stdin is not None:
            second.stdin.close()
        first.wait(timeout=10)
        second.wait(timeout=10)
        first_error = first.stderr.read() if first.stderr is not None else ""
        second_error_text = second.stderr.read() if second.stderr is not None else ""
        if first.returncode != 0:
            raise OperationRaceError(
                f"{name}: first session failed: {first_error}"
            )
        if second_error is None:
            if second.returncode != 0:
                raise OperationRaceError(
                    f"{name}: second session failed unexpectedly: "
                    f"{second_error_text}"
                )
        elif second.returncode == 0 or second_error not in second_error_text:
            raise OperationRaceError(
                f"{name}: second session must fail with {second_error}: "
                f"{second_error_text}"
            )
    finally:
        for process in (first, second):
            if process.poll() is None:
                process.kill()
            process.wait()


def start_sql(ids: dict[str, str], command_id: str) -> str:
    return (
        "select public.start_trip("
        f"'{ids['GOING']}'::uuid, '{command_id}'::uuid);"
    )


def address_sql(ids: dict[str, str]) -> str:
    return (
        "select public.update_student("
        f"'{ids['STUDENT']}'::uuid, 'Aluno Corrida', current_date - 10 * 365, "
        "'18000000', 'Rua Corrida', '99', null, 'Centro', 'Cidade Teste', "
        "'3550000', 'SP', -23.5510, -46.6340);"
    )


def main() -> int:
    env: dict[str, str] | None = None
    exit_code = 1
    try:
        env = env_for_psql()
        if run_sql("select current_database()", env) != "vango_cycle_4":
            raise OperationRaceError("use the isolated vango_cycle_4 database")
        if run_sql(
            "select count(*) from auth.users "
            "where id::text like '40000000-%' or id::text like '60000000-%'",
            env,
        ) != "0":
            raise OperationRaceError(
                "isolated database contains prior fixtures; clean it first"
            )

        scenarios = (
            (
                "start-address",
                lambda ids: start_sql(
                    ids, "7c000000-0000-0000-0000-000000000010"
                ),
                address_sql,
                None,
                lambda ids: (
                    run_sql(
                        f"select status from public.trips where id='{ids['GOING']}'",
                        env,
                    )
                    == "active"
                    and run_sql(
                        f"select address_snapshot->>'label' from public.trip_stops "
                        f"where trip_id='{ids['GOING']}' and kind='home' limit 1",
                        env,
                    )
                    == "Residência Ciclo 3"
                    and run_sql(
                        f"select address_snapshot->>'street' from public.trip_stops "
                        f"where trip_id='{ids['FUTURE_GOING']}' and kind='home' limit 1",
                        env,
                    )
                    == "Rua Corrida"
                )
            ),
            (
                "start-end",
                lambda ids: start_sql(
                    ids, "7c000000-0000-0000-0000-000000000020"
                ),
                lambda ids: (
                    "select public.end_fleet_enrollment("
                    f"'{ids['ENROLLMENT']}'::uuid, 'encerramento concorrente');"
                ),
                "trip_active",
                lambda ids: (
                    run_sql(
                        f"select status from public.trips where id='{ids['GOING']}'",
                        env,
                    )
                    == "active"
                    and run_sql(
                        f"select status from public.fleet_enrollments "
                        f"where id='{ids['ENROLLMENT']}'",
                        env,
                    )
                    == "active"
                ),
            ),
            (
                "double-start",
                lambda ids: start_sql(
                    ids, "7c000000-0000-0000-0000-000000000030"
                ),
                lambda ids: (
                    "select public.start_trip("
                    f"'{ids['RETURN']}'::uuid, "
                    "'7c000000-0000-0000-0000-000000000031'::uuid);"
                ),
                "resource_in_use",
                lambda ids: (
                    run_sql(
                        f"select count(*) from public.trips where fleet_id='{ids['FLEET']}' "
                        "and status='active'",
                        env,
                    )
                    == "1"
                    and run_sql(
                        f"select status from public.trips where id='{ids['RETURN']}'",
                        env,
                    )
                    == "confirmation_closed"
                ),
            ),
            (
                "substitute-suspend",
                lambda ids: (
                    "select public.substitute_trip_resources("
                    f"'{ids['GOING']}'::uuid, '{ids['REPLACEMENT_VAN']}'::uuid, "
                    f"'{ids['REPLACEMENT_DRIVER']}'::uuid, 'substituição concorrente', "
                    "'7c000000-0000-0000-0000-000000000040'::uuid);"
                ),
                lambda ids: (
                    "select public.set_fleet_membership_status("
                    "'42000000-0000-0000-0000-000000000002'::uuid, 'suspended');"
                ),
                "resource_in_use",
                lambda ids: (
                    run_sql(
                        f"select status from public.fleet_memberships "
                        "where id='42000000-0000-0000-0000-000000000002'",
                        env,
                    )
                    == "active"
                    and run_sql(
                        f"select driver_user_id::text from public.trips "
                        f"where id='{ids['GOING']}'",
                        env,
                    )
                    == ids["REPLACEMENT_DRIVER"]
                ),
            ),
        )

        for name, first_builder, second_builder, expected_error, assertion in scenarios:
            ids: dict[str, str] | None = None
            try:
                ids = parse_setup(run_file(SETUP, env))
                first_sql = first_builder(ids)
                second_sql = second_builder(ids)
                run_race(
                    ids, env, name, first_sql, second_sql, expected_error,
                    ids["GUARDIAN"] if name in {"start-address", "start-end"} else ids["OWNER"],
                )
                if not assertion(ids):
                    raise OperationRaceError(
                        f"{name}: final state violates the operation invariant"
                    )
                print(f"  {name}: PASS")
            finally:
                cleanup = subprocess.run(
                    psql_args(env, "-P", "pager=off", "-f", str(CLEANUP)),
                    cwd=ROOT,
                    env=env,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                if cleanup.returncode != 0:
                    raise OperationRaceError(
                        f"{name}: fixture cleanup failed:\n"
                        f"{cleanup.stdout}\n{cleanup.stderr}"
                    )
        print("Ciclo 4 operations concurrency: PASS (including cleanup)")
        exit_code = 0
    except (OperationRaceError, subprocess.TimeoutExpired) as error:
        print(f"Ciclo 4 operations concurrency: FAIL\n{error}", file=sys.stderr)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
