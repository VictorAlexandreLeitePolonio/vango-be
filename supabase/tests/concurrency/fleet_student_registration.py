#!/usr/bin/env python3
"""Prove same-command owner registration serialization against local PostgreSQL."""

import os
import subprocess
import time
import uuid


FLEET = "51000000-0000-0000-0000-000000000001"
OWNER = "50000000-0000-0000-0000-000000000001"
SCHOOL = "60000000-0000-0000-0000-000000000001"


def main():
    """Run two overlapping sessions and verify their IDs and side effects."""
    env = os.environ.copy()
    if (env.get("PGHOST"), env.get("PGPORT"), env.get("PGDATABASE"), env.get("PGUSER")) != (
        "127.0.0.1", "54322", "postgres", "postgres"
    ) or not env.get("PGPASSWORD") or any(env.get(key) for key in ("PGHOSTADDR", "PGSERVICE", "PGSERVICEFILE")):
        raise RuntimeError("Use explicit local PostgreSQL settings for the disposable Supabase database")
    command = str(uuid.uuid4())
    name = "PRD10 Race " + command
    args = ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1"]
    call = f"""select student_id || '|' || enrollment_id
      from public.create_fleet_managed_student(
      '{FLEET}', '{command}', 'minor', '{name}', '2015-01-01',
      '18000000', 'Race Street', '10', null, 'Center', 'Test City',
      '3550000', 'SP', -23.5, -47.5, '{SCHOOL}', 'morning',
      'Race Contact', 'race@example.test', null);"""
    claims = f"set local request.jwt.claims = '{{\"sub\":\"{OWNER}\",\"role\":\"authenticated\"}}'; set local role authenticated;"
    a = None
    b = None
    try:
        a = subprocess.Popen(args, env={**env, "PGAPPNAME": "prd10-race-a"}, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        assert a.stdin and a.stdout
        a.stdin.write(f"begin; {claims} {call} select 'A_READY';\n")
        a.stdin.flush()
        first = a.stdout.readline().strip()
        if not first or a.stdout.readline().strip() != "A_READY":
            raise AssertionError("first registration did not reach the transaction barrier")
        b = subprocess.Popen(args + ["-c", f"begin; {claims} {call} commit;"], env={**env, "PGAPPNAME": "prd10-race-b"}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            state = subprocess.run(args + ["-c", "select wait_event_type from pg_stat_activity where application_name = 'prd10-race-b'"], env=env, capture_output=True, text=True, check=True).stdout.strip()
            if state == "Lock":
                break
            time.sleep(0.05)
        else:
            raise AssertionError("second registration did not overlap the first transaction")
        a.stdin.write("commit;\n")
        a.stdin.flush()
        second, error = b.communicate(timeout=10)
        if b.returncode or second.strip() != first:
            raise AssertionError(f"same-command sessions disagreed: {first!r}, {second.strip()!r}, {error.strip()!r}")
        counts = subprocess.run(args + ["-c", f"""select
          (select count(*) from public.students where full_name = '{name}') || ',' ||
          (select count(*) from public.fleet_enrollments where registration_command_id = '{command}') || ',' ||
          (select count(*) from public.fleet_student_contacts c join public.fleet_enrollments e on e.id = c.enrollment_id where e.registration_command_id = '{command}') || ',' ||
          (select count(*) from public.audit_events where action = 'fleet_student_registered' and entity_id = '{first.split('|')[0]}');"""], env=env, capture_output=True, text=True, check=True).stdout.strip()
        if counts != "1,1,1,1":
            raise AssertionError(f"duplicate or missing registration side effects: {counts}")
        print("PASS: concurrent same-command calls returned one registration and 1,1,1,1 side effects")
    finally:
        if a:
            a.terminate()
            a.communicate(timeout=5)
        if b and b.poll() is None:
            b.terminate()
            b.communicate(timeout=5)
        subprocess.run(args + ["-c", f"""delete from public.audit_events where entity_id in
          (select id from public.students where full_name = '{name}');
          delete from public.fleet_student_contacts where enrollment_id in
          (select id from public.fleet_enrollments where registration_command_id = '{command}');
          delete from public.fleet_enrollments where registration_command_id = '{command}';
          delete from public.students where full_name = '{name}';"""], env=env, capture_output=True, text=True, check=True)


if __name__ == "__main__":
    main()
