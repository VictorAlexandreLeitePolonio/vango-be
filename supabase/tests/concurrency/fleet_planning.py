#!/usr/bin/env python3
"""Prove owner planning serialization in invocation-owned local database copies."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import uuid

import planning


def race(env, first_actor, second_actor, first_sql, second_sql, expected, hold_after_first=False):
    """Observe a real advisory-lock wait before releasing the winning command."""
    marker = uuid.uuid4().hex
    first = planning.session(env, 'planning-first-' + marker)
    second_name = 'planning-second-' + marker
    second = planning.session(env, second_name)
    try:
        opening = first_sql if hold_after_first else 'select private.lock_planning();'
        planning.send(first, planning.auth_sql(first_actor) + 'begin;\n' + (('set local role authenticated;\n' + opening) if hold_after_first else opening) + '\n\\echo VANGO_LOCKED\n')
        planning.wait_for_lock_marker(first)
        planning.send(second, planning.auth_sql(second_actor) + 'begin; set local role authenticated;\n' + second_sql + '\ncommit;\n')
        planning.wait_for_advisory_wait(env, second_name)
        planning.send(first, ('' if hold_after_first else 'set local role authenticated;\n' + first_sql) + '\ncommit;\n')
        first.stdin.close()
        second.stdin.close()
        first.wait(timeout=15)
        second.wait(timeout=15)
        assert first.returncode == 0, first.stderr.read()
        error = second.stderr.read()
        if expected:
            assert second.returncode and expected in error, error
        else:
            assert second.returncode == 0, error
            ids_a = re.findall(r'^\s*([a-f0-9-]{36})\s*$', first.stdout.read(), re.M)
            ids_b = re.findall(r'^\s*([a-f0-9-]{36})\s*$', second.stdout.read(), re.M)
            assert ids_a == ids_b and len(ids_a) == 1
    finally:
        for process in (first, second):
            if process.poll() is None:
                process.kill()
            process.wait()


def main():
    """Clone a verified local baseline; never reset or clean a shared database."""
    env = planning.env_for_psql()
    if env.get('PGDATABASE') != 'postgres' or env.get('PGUSER') != 'postgres':
        raise RuntimeError('Use the disposable local postgres baseline')
    with tempfile.TemporaryDirectory(prefix='planning-races-') as directory:
        dump = Path(directory) / 'baseline.sql'
        with dump.open('w') as output:
            subprocess.run(['pg_dump', '--schema-only', '--exclude-extension=pg_cron', '--exclude-schema=cron'], env=env, stdout=output, check=True)
        for scenario in ('same-command', 'revision', 'link-delete', 'delete-link', 'route-unlink', 'revoke-save', 'registration-unlink', 'unlink-registration'):
            database = 'planning_race_' + uuid.uuid4().hex
            planning.run_sql('create database ' + database, env)
            target = {**env, 'PGDATABASE': database}
            try:
                planning.run_file(dump, {**target, 'PGUSER': 'supabase_admin'})
                output = planning.run_file(Path(__file__).with_name('fleet_planning_setup.psql'), target)
                fields = dict(line.split(' ', 1) for line in output.splitlines() if line.startswith(('FIXTURE ', 'CONFIG ', 'VAN ', 'ROUTE ')))
                case = json.loads(fields['FIXTURE'])
                fleet, owner, school = case['fleet_id'], case['owner_id'], case['school_id']
                token = str(uuid.uuid4())
                first_actor = second_actor = owner
                first = second = f"select public.save_van('{fleet}',null,'NEW1234','Model','Race',12,'{token}',null);"
                expected = None
                if scenario == 'revision':
                    first = f"select public.save_van('{fleet}','{fields['VAN']}','CYC1234','Model','First',12,'{token}',1);"
                    second = f"select public.save_van('{fleet}','{fields['VAN']}','CYC1234','Model','Second',13,'{uuid.uuid4()}',1);"
                    expected = 'revision_conflict'
                elif scenario in ('link-delete', 'delete-link'):
                    fleet = '41000000-0000-0000-0000-000000000002'
                    first_actor = second_actor = case['foreign_owner_id']
                    planning.run_sql(planning.auth_sql(first_actor) + f"select public.link_fleet_service_city('{fleet}','3550000','{uuid.uuid4()}');", target)
                    link = f"select public.link_fleet_service_school('{fleet}','{school}','{token}');"
                    delete = f"delete from public.fleet_service_cities where fleet_id='{fleet}' and city_ibge_code='3550000';"
                    first, second, expected = (link, delete, 'resource_in_use') if scenario == 'link-delete' else (delete, link, 'invalid_input')
                elif scenario in ('route-unlink','registration-unlink','unlink-registration'):
                    # Existing routes cannot be unlinked, so use another published synthetic school.
                    new_school = str(uuid.uuid4())
                    planning.run_sql(f"""insert into public.schools(id,provider,external_id,institution_type,name,postal_code,street,street_number,neighborhood,city_name,city_ibge_code,state_code,latitude,longitude)
                        select '{new_school}',provider,'race-school',institution_type,name,postal_code,street,street_number,neighborhood,city_name,city_ibge_code,state_code,latitude,longitude from public.schools where id='{school}';
                        insert into private.school_publications values('{new_school}',private.school_publication_fingerprint('{new_school}'),'Synthetic race evidence',clock_timestamp());""", target)
                    planning.run_sql(planning.auth_sql(owner) + f"select public.link_fleet_service_school('{fleet}','{new_school}','{uuid.uuid4()}');", target)
                    config = json.loads(fields['CONFIG'])
                    config['schools'] = [{'school_id': new_school, 'position': 1}]
                    first = f"select public.save_route('{fleet}',null,'{json.dumps(config)}'::jsonb,'{token}',null);"
                    second = f"delete from public.fleet_service_schools where fleet_id='{fleet}' and school_id='{new_school}';"
                    expected = 'resource_in_use'
                    if scenario != 'route-unlink':
                        register = ("select row_to_json(r) from public.create_fleet_managed_student("
                            f"'{fleet}','{token}','minor','Registration Race','2015-01-01',"
                            "'18000000','Race Street','10',null,'Center','Cidade Teste','3550000','SP',"
                            f"-23.5,-46.6,'{new_school}','morning','Contact','race@example.test',null) r;")
                        first, second = (register,second) if scenario=='registration-unlink' else (second,register)
                        expected = 'resource_in_use' if scenario=='registration-unlink' else 'invalid_input'
                elif scenario == 'revoke-save':
                    first_actor = case['second_owner_id']
                    first = "select public.set_fleet_member_roles('42000000-0000-0000-0000-000000000001',array['guardian']::text[]);"
                    expected = 'not_found'
                before = int(planning.run_sql('select count(*) from private.fleet_planning_commands', target))
                race(target, first_actor, second_actor, first, second, expected, hold_after_first=scenario=='registration-unlink')
                after = int(planning.run_sql('select count(*) from private.fleet_planning_commands', target))
                assert after - before == (0 if scenario in ('delete-link', 'revoke-save', 'registration-unlink', 'unlink-registration') else 1)
                dangling = planning.run_sql('''select count(*) from public.fleet_service_schools f join public.schools s on s.id=f.school_id
                    where not exists(select 1 from public.fleet_service_cities c where c.fleet_id=f.fleet_id and c.city_ibge_code=s.city_ibge_code)''', target)
                assert dangling == '0'
                assert planning.run_sql('''select count(*) from public.fleet_enrollments e where e.status='active'
                    and not exists(select 1 from public.fleet_service_schools f where f.fleet_id=e.fleet_id and f.school_id=e.school_id)''', target)=='0'
                print(scenario + ': PASS (contender advisory wait observed)')
            finally:
                planning.run_sql('drop database ' + database + ' with (force)', env)


if __name__ == '__main__':
    main()
