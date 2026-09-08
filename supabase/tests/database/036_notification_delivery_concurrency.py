"""Exercise notification delivery claiming with two real PostgreSQL sessions."""

from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import sys
import time
from urllib.parse import parse_qs, urlparse
import uuid


PSQL = os.environ.get("VANGO_PSQL", "psql")
DSN_ENV = "VANGO_TEST_DATABASE_URL"


def require_local_dsn(dsn: str) -> None:
    """Refuse credentials that could target a non-local database."""
    try:
        parsed = urlparse(dsn)
    except ValueError as error:
        raise SystemExit("invalid database URL") from error
    if parsed.scheme not in {"postgres", "postgresql"}:
        raise SystemExit("database URL must use postgres or postgresql")
    if parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise SystemExit("refusing a non-loopback database host")
    if any(name in parse_qs(parsed.query) for name in ("host", "hostaddr", "service")):
        raise SystemExit("database URL cannot override its loopback host")
    database = parsed.path.removeprefix("/")
    if database != "vango_cycle_5":
        raise SystemExit(
            f"refusing a database other than vango_cycle_5 (got {database!r})"
        )


def ensure_psql() -> None:
    if os.path.isabs(PSQL):
        if not os.access(PSQL, os.X_OK):
            raise SystemExit(f"psql is not executable: {PSQL}")
    elif shutil.which(PSQL) is None:
        raise SystemExit("psql was not found; set VANGO_PSQL to its executable")


def psql(dsn: str, sql: str, *, check: bool = True) -> str:
    try:
        result = subprocess.run(
            [
                PSQL,
                dsn,
                "-X",
                "-q",
                "-A",
                "-t",
                "-v",
                "ON_ERROR_STOP=1",
                "-c",
                sql,
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except subprocess.TimeoutExpired as error:
        if check:
            raise RuntimeError("psql timed out") from error
        return ""
    if result.returncode != 0:
        if check:
            raise RuntimeError(result.stderr.strip() or "psql failed")
        return ""
    return result.stdout.strip()


def wait_for_claim_sentinel(process: subprocess.Popen[str]) -> list[str]:
    """Wait until session A has completed its claim in its open transaction."""
    if process.stdout is None:
        raise RuntimeError("session A has no stdout")
    file_descriptor = process.stdout.fileno()
    os.set_blocking(file_descriptor, False)
    lines: list[str] = []
    buffer = b""
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        readable, _, _ = select.select([file_descriptor], [], [], remaining)
        if not readable:
            break
        try:
            buffer += os.read(file_descriptor, 4096)
        except BlockingIOError:
            continue
        while b"\n" in buffer:
            raw_line, buffer = buffer.split(b"\n", 1)
            value = raw_line.decode("utf-8", errors="replace").strip()
            if value == "CLAIMED_A":
                os.set_blocking(file_descriptor, True)
                return lines
            if value:
                lines.append(value)
    os.set_blocking(file_descriptor, True)
    raise RuntimeError("session A did not publish its post-claim sentinel")


def cleanup(
    dsn: str,
    *,
    notification_id: str | None,
    device_id: str,
    membership_id: str,
    fleet_id: str,
    owner_id: str,
) -> None:
    notification_clause = (
        f"delete from public.notifications where id = '{notification_id}';"
        if notification_id
        else ""
    )
    psql(
        dsn,
        f"""
        begin;
        {notification_clause}
        delete from public.device_tokens where id = '{device_id}';
        delete from public.fleet_membership_roles where membership_id = '{membership_id}';
        delete from public.fleet_memberships where id = '{membership_id}';
        delete from public.fleets where id = '{fleet_id}';
        delete from auth.users where id = '{owner_id}';
        commit;
        """,
        check=True,
    )
    notification_check = (
        f"(select count(*) from public.notifications where id = '{notification_id}')"
        if notification_id
        else "0"
    )
    remaining = psql(
        dsn,
        "select ("
        f"{notification_check} "
        f"+ (select count(*) from public.device_tokens where id = '{device_id}') "
        f"+ (select count(*) from public.fleet_membership_roles where membership_id = '{membership_id}') "
        f"+ (select count(*) from public.fleet_memberships where id = '{membership_id}') "
        f"+ (select count(*) from public.fleets where id = '{fleet_id}') "
        f"+ (select count(*) from auth.users where id = '{owner_id}')"
        ")::integer",
        check=True,
    )
    if remaining != "0":
        raise RuntimeError("concurrency fixture cleanup was incomplete")


def main() -> int:
    ensure_psql()
    dsn = os.environ.get(DSN_ENV)
    if not dsn:
        raise SystemExit(f"set {DSN_ENV} to the isolated vango_cycle_5 DSN")
    require_local_dsn(dsn)
    current_database = psql(dsn, "select current_database()")
    if current_database != "vango_cycle_5":
        raise SystemExit(
            f"refusing to run outside vango_cycle_5 (got {current_database!r})"
        )

    owner_id = str(uuid.uuid4())
    fleet_id = str(uuid.uuid4())
    membership_id = str(uuid.uuid4())
    device_id = str(uuid.uuid4())
    installation_id = str(uuid.uuid4())
    lease_a = str(uuid.uuid4())
    lease_b = str(uuid.uuid4())
    token = f"cycle5-concurrency-{uuid.uuid4()}"
    notification_id: str | None = None
    process_a: subprocess.Popen[str] | None = None

    try:
        setup = f"""
        begin;
        insert into auth.users (
          instance_id, id, aud, role, email, encrypted_password,
          email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
          created_at, updated_at
        ) values (
          '00000000-0000-0000-0000-000000000000', '{owner_id}',
          'authenticated', 'authenticated',
          'cycle5-concurrency-{owner_id}@example.test',
          extensions.crypt('local-test-password', extensions.gen_salt('bf')),
          clock_timestamp(),
          '{{"provider":"email","providers":["email"]}}'::jsonb,
          '{{}}'::jsonb, clock_timestamp(), clock_timestamp()
        );
        insert into public.fleets (id, name, slug, created_by)
        values (
          '{fleet_id}', 'Cycle 5 concurrency fixture',
          'cycle-5-concurrency-{owner_id}', '{owner_id}'
        );
        insert into public.fleet_memberships (id, fleet_id, user_id)
        values ('{membership_id}', '{fleet_id}', '{owner_id}');
        insert into public.fleet_membership_roles (membership_id, role)
        values ('{membership_id}', 'owner');
        insert into public.device_tokens (
          id, user_id, installation_id, platform, token
        ) values (
          '{device_id}', '{owner_id}', '{installation_id}', 'android', '{token}'
        );
        select private.create_notification(
          '{fleet_id}',
          'cycle5-concurrency:{owner_id}',
          'notice', 'manual', '{owner_id}',
          '{{"message":"concurrency test","scope":"user","target_id":"{owner_id}"}}'::jsonb,
          clock_timestamp(), clock_timestamp() + interval '24 hours',
          array['{owner_id}'::uuid]
        );
        commit;
        """
        setup_output = psql(dsn, setup)
        notification_id = setup_output.splitlines()[-1].strip()
        if not notification_id:
            raise RuntimeError("notification setup returned no id")
        psql(
            dsn,
            f"""
            insert into public.notification_deliveries (
              notification_id, device_id, state, attempt, next_attempt_at
            ) values (
              '{notification_id}', '{device_id}', 'pending', 4, clock_timestamp()
            );
            """,
        )

        session_a_sql = f"""
        begin;
        select public.claim_notification_deliveries(1, '{lease_a}');
        select 'CLAIMED_A';
        select pg_sleep(2);
        commit;
        """
        process_a = subprocess.Popen(
            [
                PSQL,
                dsn,
                "-X",
                "-q",
                "-A",
                "-t",
                "-v",
                "ON_ERROR_STOP=1",
                "-c",
                session_a_sql,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        claim_a_lines = wait_for_claim_sentinel(process_a)
        claim_b = psql(
            dsn,
            f"select public.claim_notification_deliveries(1, '{lease_b}')",
        )
        output_a, error_a = process_a.communicate(timeout=10)
        if process_a.returncode != 0:
            raise RuntimeError(error_a.strip() or "session A failed")

        claim_a_lines.extend(
            line.strip() for line in output_a.splitlines() if line.strip()
        )
        claim_a = json.loads(claim_a_lines[0])
        claim_b_value = json.loads(claim_b)
        if (
            len(claim_a) != 1
            or not isinstance(claim_a[0], dict)
            or claim_a[0].get("attempt") != 5
        ):
            raise AssertionError("session A did not claim the fifth attempt")
        if claim_b_value != []:
            raise AssertionError("session B stole the active fifth lease")

        state = psql(
            dsn,
            "select state || '|' || lease_id || '|' || attempt "
            f"from public.notification_deliveries where notification_id = '{notification_id}'",
        )
        expected_state = f"processing|{lease_a}|5"
        if state != expected_state:
            raise AssertionError("unexpected delivery state after concurrent claim")

        finished = psql(
            dsn,
            "select public.finish_notification_delivery("
            f"(select id from public.notification_deliveries where notification_id = '{notification_id}'),"
            f"'{lease_a}', 'sent', 'cycle5-provider', null, null)",
        )
        if finished != "sent":
            raise AssertionError("session A could not finish the active lease")

        print(
            "delivery concurrency: PASS "
            "(fifth lease kept by claim A; claim B=0; finish=sent)"
        )
        return 0
    finally:
        if process_a is not None and process_a.poll() is None:
            process_a.kill()
            process_a.communicate()
        cleanup(
            dsn,
            notification_id=notification_id,
            device_id=device_id,
            membership_id=membership_id,
            fleet_id=fleet_id,
            owner_id=owner_id,
        )


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"delivery concurrency: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
