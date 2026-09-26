#!/usr/bin/env python3
"""Prove allocation races in disposable databases on an explicitly local server."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

import planning


def command(case: dict, enrollment: str, token: str, revision: int = 1) -> str:
    """Build one authenticated direct allocation using fixture-only values."""
    pairs = json.dumps(case['allocations'])
    return ("select row_to_json(r) from public.assign_fleet_student_transport("
            f"'{enrollment}','{case['school_id']}','{pairs}'::jsonb,"
            f"'{case['effective_on']}','{token}',{revision}) r;")


def compete(env: dict, owner: str, first_sql: str, second_sql: str,
            expected_error: str | None, second_owner: str | None = None) -> None:
    """Observe the contender waiting before releasing the first transaction."""
    marker = uuid.uuid4().hex
    first = planning.session(env, 'transport-a-' + marker)
    second_name = 'transport-b-' + marker
    second = planning.session(env, second_name)
    try:
        planning.send(first, planning.auth_sql(owner) +
                      'begin; select private.lock_planning();\n\\echo VANGO_LOCKED\n')
        planning.wait_for_lock_marker(first)
        planning.send(second, planning.auth_sql(second_owner or owner) +
                      'begin; set local role authenticated;\n' + second_sql + '\ncommit;\n')
        planning.wait_for_advisory_wait(env, second_name)
        planning.send(first, 'set local role authenticated;\n' + first_sql + '\ncommit;\n')
        first.stdin.close()
        second.stdin.close()
        first.wait(timeout=15)
        second.wait(timeout=15)
        first_error = first.stderr.read()
        second_error = second.stderr.read()
        if first.returncode:
            raise AssertionError('First command failed: ' + first_error)
        if expected_error:
            assert second.returncode and expected_error in second_error, second_error
        else:
            assert second.returncode == 0, second_error
            first_receipts = [line for line in first.stdout.read().splitlines() if '"enrollment_id"' in line and line.strip().startswith('{')]
            second_receipts = [line for line in second.stdout.read().splitlines() if '"enrollment_id"' in line and line.strip().startswith('{')]
            assert first_receipts == second_receipts and len(first_receipts) == 1
    finally:
        for process in (first, second):
            if process.poll() is None:
                process.kill()
            process.wait()


def registration_race(env: dict, owner: str, sql: str) -> None:
    """Observe the unique-key wait used by legacy registration receipts."""
    name = 'registration-' + uuid.uuid4().hex
    args = planning.psql_args(env, '-qAt')
    first = subprocess.Popen(args, env=env, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    second = None
    try:
        planning.send(first, "set request.jwt.claims = '" + json.dumps({'sub': owner, 'role': 'authenticated'}) + "';" +
                      'begin; set local role authenticated; ' + sql + " select 'READY';\n")
        receipt = first.stdout.readline().strip()
        assert receipt.startswith('{') and first.stdout.readline().strip() == 'READY'
        second = subprocess.Popen(args + ['-c', "set request.jwt.claims = '" + json.dumps({'sub': owner, 'role': 'authenticated'}) + "';" +
                                  'begin; set local role authenticated; ' + sql + ' commit;'],
                                  env={**env, 'PGAPPNAME': name}, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            state = planning.run_sql("select wait_event_type from pg_stat_activity where application_name='" + name + "'", env)
            if state == 'Lock':
                break
            time.sleep(0.05)
        else:
            raise AssertionError('Registration contender did not wait on the unique key')
        planning.send(first, 'commit;\n')
        first.stdin.close()
        first.wait(timeout=10)
        result, error = second.communicate(timeout=10)
        assert first.returncode == 0, first.stderr.read()
        assert second.returncode == 0 and result.strip() == receipt, error
        student = json.loads(receipt)['student_id']
        assert planning.run_sql("select count(*) from public.audit_events where action='fleet_student_registered' and entity_id='" + student + "'", env) == '1'
    finally:
        for process in (first, second):
            if process and process.poll() is None:
                process.kill()
                process.wait()


def main() -> None:
    """Clone the local baseline, run each race, and drop only owned test databases."""
    env = planning.env_for_psql()
    if env.get('PGDATABASE') != 'postgres' or env.get('PGUSER') != 'postgres':
        raise RuntimeError('Use the disposable local postgres database as baseline')
    with tempfile.TemporaryDirectory(prefix='fleet-transport-races-') as folder:
        dump = Path(folder) / 'baseline.sql'
        with dump.open('w') as output:
            subprocess.run(['pg_dump', '--exclude-extension=pg_cron', '--exclude-schema=cron'], env=env, check=True, stdout=output)
        for race in ('same-command', 'revision', 'actor', 'last-seat', 'direct-marketplace', 'marketplace-direct', 'registration'):
            database = 'transport_race_' + uuid.uuid4().hex
            planning.run_sql(f'create database {database}', env)
            target = {**env, 'PGDATABASE': database}
            try:
                planning.run_file(dump, {**target, 'PGUSER': 'supabase_admin'})
                output = planning.run_file(Path(__file__).with_name('fleet_transport_setup.psql'), target)
                case = json.loads(next(line.removeprefix('FIXTURE ') for line in output.splitlines() if line.startswith('FIXTURE ')))
                request = next(line.removeprefix('REQUEST ') for line in output.splitlines() if line.startswith('REQUEST '))
                first = command(case, case['enrollment_id'], case['command_a'])
                second = command(case, case['enrollment_id'], case['command_b'])
                expected = 'revision_conflict'
                second_owner = None
                if race == 'registration':
                    first = ("select row_to_json(r) from public.create_fleet_managed_student("
                             f"'{case['fleet_id']}','{case['command_a']}','minor','Registration Race',"
                             "'2015-01-01','18000000','Race Street','10',null,'Center','Test City','3550000','SP',"
                             f"-23.5,-46.6,'{case['school_id']}','morning','Contact','race@example.test',null) r;")
                    second, expected = first, None
                elif race == 'same-command':
                    second, expected = first, None
                elif race == 'actor':
                    second, expected, second_owner = first, 'idempotency_conflict', case['second_owner_id']
                elif race == 'last-seat':
                    second = command(case, case['adult_enrollment_id'], case['command_b'])
                    expected = 'capacity_exceeded'
                elif 'marketplace' in race:
                    market_pairs = [dict(schedule_id=case[direction + '_schedule_id'] if direction == 'return' else case['going_schedule_id'],
                                         weekday=day, direction=direction) for direction in ('going', 'return') for day in range(1, 6)]
                    market = f"select public.approve_transport_request('{request}','{json.dumps(market_pairs)}'::jsonb,'{case['effective_on']}');"
                    first, second = (first, market) if race == 'direct-marketplace' else (market, first)
                    expected = 'capacity_exceeded'
                if race == 'registration':
                    registration_race(target, case['owner_id'], first)
                else:
                    compete(target, case['owner_id'], first, second, expected, second_owner)
                receipt_count = planning.run_sql('select count(*) from private.fleet_student_transport_commands', target)
                assert receipt_count == ('0' if race in ('marketplace-direct', 'registration') else '1'), receipt_count
                enrollment_count = planning.run_sql("select count(distinct enrollment_id) from public.transport_reservations where status='active'", target)
                assert enrollment_count == ('0' if race == 'registration' else '1'), enrollment_count
                if race == 'registration':
                    count = planning.run_sql(f"select count(*) from public.fleet_enrollments where registration_command_id='{case['command_a']}'", target)
                    assert count == '1', count
                print(race + ': PASS (contender lock wait observed)')
            finally:
                # The random database was created by this invocation; shared databases are untouched.
                planning.run_sql(f'drop database {database} with (force)', env)


if __name__ == '__main__':
    main()
