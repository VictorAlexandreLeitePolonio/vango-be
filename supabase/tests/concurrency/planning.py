#!/usr/bin/env python3
"""Exercise Ciclo 3 planning serialization with two real psql sessions.

This is intentionally a local-only test.  It uses the same public approval
RPC that the application calls and observes the second process waiting on the
database advisory lock before the first process commits.
"""

from __future__ import annotations

import os
import json
import re
import select
import shutil
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SETUP = Path(__file__).with_name("planning_setup.psql")
CLEANUP = Path(__file__).with_name("planning_cleanup.psql")
LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")
MARKER_RE = re.compile(r"^VANGO_CONCURRENCY_([A-Z_]+)=([0-9a-fA-F-]+)$")


class PlanningRaceError(AssertionError):
    """A concurrency invariant was not demonstrated."""


def env_for_psql() -> dict[str, str]:
    env = os.environ.copy()
    host = env.get("PGHOST")
    port = env.get("PGPORT")
    if host not in LOCAL_HOSTS:
        raise PlanningRaceError(
            "PGHOST must be one of 127.0.0.1, localhost, or ::1; "
            "refusing a remote planning test"
        )
    if not port or not port.isdigit() or not (1 <= int(port) <= 65535):
        raise PlanningRaceError("PGPORT must identify a local PostgreSQL listener")
    if not env.get("PGPASSWORD"):
        raise PlanningRaceError("PGPASSWORD must be supplied by the environment")
    for variable in ("PGHOSTADDR", "PGSERVICE", "PGSERVICEFILE"):
        if env.get(variable):
            raise PlanningRaceError(
                f"{variable} must be unset so the local planning target is unambiguous"
            )
    psql = shutil.which("psql")
    if not psql:
        raise PlanningRaceError("psql is required for the real-session test")
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
        "-v",
        "ON_ERROR_STOP=1",
        *extra,
    ]


def run_file(path: Path, env: dict[str, str], *variables: str) -> str:
    completed = subprocess.run(
        psql_args(env, *variables, "-f", str(path)),
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        error = PlanningRaceError(
            f"{path.name} failed with exit {completed.returncode}:\n"
            f"{completed.stdout}\n{completed.stderr}"
        )
        # Keep any markers emitted before a fixture-side failure so the
        # caller can still run the narrowly scoped cleanup in finally.
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
        raise PlanningRaceError(
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
                raise PlanningRaceError(f"setup returned an invalid UUID for {key}")
            values[key] = value.lower()
    required = {
        "FLEET",
        "OWNER",
        "PRIMARY",
        "VAN",
        "GOING_SCHEDULE",
        "RETURN_SCHEDULE",
        "REQUEST_A",
        "REQUEST_B",
        "STUDENT_A",
        "STUDENT_B",
    }
    missing = required - values.keys()
    if missing:
        raise PlanningRaceError(f"setup did not return markers: {sorted(missing)}")
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
        raise PlanningRaceError("psql stdin is unavailable")
    process.stdin.write(sql)
    process.stdin.flush()


def wait_for_lock_marker(process: subprocess.Popen[str]) -> None:
    if process.stdout is None:
        raise PlanningRaceError("psql stdout is unavailable")
    deadline = time.monotonic() + 5
    output = b""
    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        ready, _, _ = select.select([process.stdout], [], [], remaining)
        if not ready:
            break
        chunk = os.read(process.stdout.fileno(), 4096)
        if not chunk:
            raise PlanningRaceError("first session ended before acquiring the lock")
        output += chunk
        if b"VANGO_LOCKED" in output.splitlines():
            return
    raise PlanningRaceError("first session did not publish the lock barrier")


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
        # This is a bounded observation poll.  The lock barrier, rather than
        # this interval, establishes ordering.
        time.sleep(0.05)
    raise PlanningRaceError("second session did not wait on the advisory lock")


def allocation_sql(ids: dict[str, str]) -> str:
    going = ids["GOING_SCHEDULE"]
    returning = ids["RETURN_SCHEDULE"]
    return (
        "select public.approve_transport_request("
        f"'{ids['REQUEST_A']}'::uuid, "
        "(select jsonb_agg(jsonb_build_object('schedule_id', item.schedule_id, "
        "'weekday', item.weekday) order by item.direction, item.weekday) "
        "from ("
        f"select '{going}'::uuid as schedule_id, gs::smallint as weekday, "
        "'going'::text as direction from generate_series(1, 5) as gs "
        "union all "
        f"select '{returning}'::uuid as schedule_id, gs::smallint as weekday, "
        "'return'::text as direction from generate_series(1, 5) as gs"
        ") as item), current_date + 1);"
    )


def run_race(ids, env, first_sql=None, second_sql=None,
             expected_error="capacity_exceeded", first_user=None, second_user=None):
    first_user = first_user or ids["OWNER"]
    second_user = second_user or ids["OWNER"]
    first_sql = first_sql or allocation_sql(ids)
    second_sql = second_sql or (
        "select public.approve_transport_request("
        f"'{ids['REQUEST_B']}', "
        f"jsonb_build_array(jsonb_build_object('schedule_id','{ids['GOING_SCHEDULE']}','weekday',1)), "
        "current_date + 1);"
    )
    first = session(env, "vango-cycle3-first")
    second = session(env, "vango-cycle3-second")
    try:
        send(first, auth_sql(first_user) +
             "begin; select private.lock_planning();\n\\echo VANGO_LOCKED\n")
        wait_for_lock_marker(first)
        send(second, auth_sql(second_user) + "begin; set local role authenticated;\n" +
             second_sql + "\ncommit;\n")
        wait_for_advisory_wait(env, "vango-cycle3-second")
        send(first, "set local role authenticated;\n" + first_sql + "\ncommit;\n")
        first.stdin.close()
        second.stdin.close()
        first.wait(timeout=10)
        second.wait(timeout=10)
        first_error = first.stderr.read()
        second_error = second.stderr.read()
        if first.returncode != 0:
            raise PlanningRaceError(f"first session failed: {first_error}")
        if second.returncode == 0 or expected_error not in second_error:
            raise PlanningRaceError(
                f"second session must fail with {expected_error}: {second_error}")
        return first.returncode, second.returncode
    finally:
        for process in (first, second):
            if process.poll() is None:
                process.kill()
            process.wait()


def auth_sql(user):
    claims = json.dumps({"sub": user, "role": "authenticated"})
    return f"select set_config('request.jwt.claims', '{claims}', false);\n"


def resource_races(ids, env):
    fleet_a, fleet_b = ids["FLEET"], "41000000-0000-0000-0000-000000000002"
    owner_a, owner_b = ids["OWNER"], "40000000-0000-0000-0000-000000000005"
    driver = "40000000-0000-0000-0000-000000000003"
    member = "42000000-0000-0000-0000-000000000002"
    reserve_driver = "40000000-0000-0000-0000-000000000002"
    school = "65000000-0000-0000-0000-000000000001"

    for plate, winner, loser, winner_user, loser_user in (
        ("RAC9001", fleet_a, fleet_b, owner_a, owner_b),
        ("RAC9002", fleet_b, fleet_a, owner_b, owner_a),
    ):
        def van_sql(fleet):
            return f"select public.save_van('{fleet}',null,'{plate}','Micro','Race',10);"
        run_race(ids, env, van_sql(winner), van_sql(loser), "plate_conflict",
                 winner_user, loser_user)
        if run_sql(f"select count(*) from public.vans where plate='{plate}' and fleet_id='{winner}'", env) != "1":
            raise PlanningRaceError("global plate race did not preserve the winning fleet")

    # Staff invitation uses the same public acceptance flow as the driver app.
    run_sql(auth_sql(owner_b) + f"""
        insert into public.fleet_service_cities(fleet_id,city_ibge_code,city_name,state_code,created_by)
        values('{fleet_b}','3550000','Cidade Teste','SP','{owner_b}');
        insert into public.fleet_service_schools(fleet_id,school_id,created_by)
        values('{fleet_b}','{school}','{owner_b}');
        do $fixture$ declare token text; begin
          token := public.create_fleet_invitation('{fleet_b}','driver-a@example.test','driver');
          perform set_config('request.jwt.claims','{{"sub":"{driver}","role":"authenticated"}}',true);
          perform public.accept_driver_invitation(token);
        end $fixture$;
        """, env)
    run_sql(auth_sql(owner_a) + f"select public.set_fleet_member_roles('{member}',array['owner','driver']);", env)

    def create_route(fleet, owner, route_driver, name, plate):
        van_id = run_sql(f"select id from public.vans where plate='{plate}'", env)
        config = json.dumps({"name": name, "direction": "going", "shift": "morning",
            "van_id": van_id, "driver_user_id": route_driver,
            "origin": {"latitude": 0, "longitude": 0, "label": "Origem"},
            "destination": {"latitude": 1, "longitude": 1, "label": "Destino"},
            "schools": [{"school_id": school, "position": 1}]})
        run_sql(auth_sql(owner) + f"select public.save_route('{fleet}',null,'{config}'::jsonb);", env)
        return run_sql(f"select id from public.routes where fleet_id='{fleet}' and name='{name}'", env)

    route_a = create_route(fleet_a, owner_a, driver, "Race A", "RAC9001")
    route_b = create_route(fleet_b, owner_b, driver, "Race B", "RAC9002")
    reserve_route = create_route(fleet_a, owner_a, reserve_driver, "Race suspension", "RAC9001")

    def schedule_sql(route, hour):
        return f"""select public.save_route_schedule('{route}',null,
          jsonb_build_object('weekdays',jsonb_build_array(1,2,3,4,5),
          'starts_at','{hour}:00','ends_at','{hour+1}:00','ends_next_day',false,
          'timezone','America/Sao_Paulo','valid_from',current_date+1,
          'valid_until',current_date+30,'confirmation_minutes',30));"""

    suspend = f"select public.set_fleet_membership_status('{member}','suspended');"
    run_race(ids, env, suspend, schedule_sql(reserve_route, 12), "resource_in_use")
    if run_sql(f"select count(*) from public.route_schedules where route_id='{reserve_route}'", env) != "0":
        raise PlanningRaceError("suspension winner still received an assignment")
    run_sql(auth_sql(owner_a) + f"select public.set_fleet_membership_status('{member}','active');", env)
    run_race(ids, env, schedule_sql(reserve_route, 12), suspend, "resource_in_use")
    if run_sql(f"select status from public.fleet_memberships where id='{member}'", env) != "active":
        raise PlanningRaceError("assigned driver was suspended")

    for winning_route, losing_route, winning_user, losing_user in (
        (route_a, route_b, owner_a, owner_b),
        (route_b, route_a, owner_b, owner_a),
    ):
        run_sql(f"delete from public.route_schedules where route_id in ('{route_a}','{route_b}');", env)
        run_race(ids, env, schedule_sql(winning_route, 10), schedule_sql(losing_route, 10),
                 "schedule_conflict", winning_user, losing_user)
        if run_sql(f"select count(*) from public.route_schedules where route_id='{losing_route}'", env) != "0":
            raise PlanningRaceError("driver was assigned to overlapping fleets")
    print("  resource races: plate, suspension/assignment, global driver; both orders PASS")


def main() -> int:
    env: dict[str, str] | None = None
    setup_output = ""
    ids: dict[str, str] | None = None
    exit_code = 1
    try:
        env = env_for_psql()
        if run_sql("select current_database()", env) != "vango_cycle_3":
            raise PlanningRaceError("use the isolated vango_cycle_3 database")
        if run_sql("select count(*) from auth.users where id::text like '40000000-%' or id::text like '60000000-%'", env) != "0":
            raise PlanningRaceError("isolated database contains prior fixtures; clean it first")
        setup_output = run_file(SETUP, env)
        ids = parse_setup(setup_output)
        resource_races(ids, env)
        first_returncode, second_returncode = run_race(ids, env)
        if first_returncode != 0:
            raise PlanningRaceError(
                f"first approval failed unexpectedly with exit {first_returncode}"
            )
        if second_returncode == 0:
            raise PlanningRaceError(
                "second approval unexpectedly succeeded; capacity race was not serialized"
            )
        active = run_sql(
            "select count(*) from public.transport_reservations "
            "where fleet_id = '41000000-0000-0000-0000-000000000001' "
            "and status = 'active'",
            env,
        )
        approved = run_sql(
            "select count(*) from public.fleet_join_requests "
            "where id = '" + ids["REQUEST_A"] + "' and status = 'approved'",
            env,
        )
        pending = run_sql(
            "select count(*) from public.fleet_join_requests "
            "where id = '" + ids["REQUEST_B"] + "' and status = 'pending'",
            env,
        )
        if active != "10" or approved != "1" or pending != "1":
            raise PlanningRaceError(
                "unexpected final state: "
                f"active_reservations={active}, approved_a={approved}, pending_b={pending}"
            )
        print("Ciclo 3 planning concurrency: assertions PASS; checking cleanup")
        print("  first approval: exit 0")
        print("  second approval: non-zero after advisory wait")
        print("  final state: 10 active reservations, A approved, B pending")
        exit_code = 0
    except (PlanningRaceError, subprocess.TimeoutExpired) as error:
        if not setup_output:
            setup_output = getattr(error, "setup_output", "")
            if setup_output:
                try:
                    ids = parse_setup(setup_output)
                except PlanningRaceError:
                    pass
        print(f"Ciclo 3 planning concurrency: FAIL\n{error}", file=sys.stderr)
    finally:
        if ids is not None and env is not None:
            cleanup_args = [
                "-v",
                f"student_a={ids['STUDENT_A']}",
                "-v",
                f"student_b={ids['STUDENT_B']}",
            ]
            cleanup = subprocess.run(
                psql_args(env, *cleanup_args, "-f", str(CLEANUP)),
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            if cleanup.returncode != 0:
                print(
                    "fixture cleanup failed; inspect local DB3 before rerunning:\n"
                    f"{cleanup.stdout}\n{cleanup.stderr}",
                    file=sys.stderr,
                )
                exit_code = 1
    if exit_code == 0:
        print("Ciclo 3 planning concurrency: PASS (including cleanup)")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
