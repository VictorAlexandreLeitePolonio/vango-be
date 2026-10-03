#!/usr/bin/env python3
"""Exercise real local Auth/PostgREST overload dispatch and persisted planning.

Requires a freshly seeded disposable local database, PG* settings, and VANGO_TEST_STATUS
pointing to an external `supabase status -o json` file. Never logs credentials.
The local fixture remains for inspection; reset the owned test project afterwards.
"""
import json
from datetime import date, timedelta
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'concurrency'))
import planning


def main():
    """Use actual authenticated HTTP requests, including legacy parameter sets."""
    env = planning.env_for_psql()
    if env.get('PGDATABASE') != 'postgres':
        raise RuntimeError('Use a disposable local postgres baseline')
    status = json.loads(Path(os.environ['VANGO_TEST_STATUS']).read_text())
    base = status['API_URL']
    if urllib.parse.urlparse(base).hostname not in planning.LOCAL_HOSTS:
        raise RuntimeError('HTTP tests require a local Supabase instance')
    if env.get('PGPORT') != '56322' or urllib.parse.urlparse(base).port != 56321:
        raise RuntimeError('Use the owned vango-task16-17 test ports')
    if planning.run_sql("select count(*) from public.fleets where id not in ('51000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000002')", env) != '0':
        raise RuntimeError('Refusing to seed a nonempty database; reset only the owned test project')
    output = planning.run_file(Path(__file__).resolve().parents[1] / 'concurrency/fleet_planning_setup.psql', env)
    fields = dict(line.split(' ', 1) for line in output.splitlines() if line.startswith(('FIXTURE ', 'CONFIG ', 'VAN ', 'ROUTE ')))
    case = json.loads(fields['FIXTURE'])
    planning.run_sql("update auth.users set confirmation_token='',recovery_token='',email_change_token_new='',email_change='',email_change_token_current='',reauthentication_token='' where email in ('owner-a1@example.test','owner-b@example.test','driver-a@example.test'); notify pgrst,'reload schema';", env)

    def request(path, payload, token=None):
        headers = {'apikey': status['ANON_KEY'], 'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        req = urllib.request.Request(base + path, data=json.dumps(payload).encode(), headers=headers, method='POST')
        try:
            with urllib.request.urlopen(req, timeout=15) as response:
                body = response.read()
                return response.status, json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            body = error.read()
            return error.code, json.loads(body) if body else None

    def signin(email):
        code, body = request('/auth/v1/token?grant_type=password', {'email': email, 'password': 'local-test-password'})
        assert code == 200, 'Local fixture authentication failed with status ' + str(code)
        return body['access_token']

    owner = signin('owner-a1@example.test')
    foreign = signin('owner-b@example.test')
    driver = signin('driver-a@example.test')

    def rpc(name, payload, token=owner, expected=200):
        code, body = request('/rest/v1/rpc/' + name, payload, token)
        assert code == expected, (name, code, body.get('code') if isinstance(body, dict) else 'unexpected response')
        return body

    # Schema reload is asynchronous; readiness is checked against the new named overload.
    deadline = time.monotonic() + 10
    van = {'p_fleet_id': case['fleet_id'], 'p_van_id': None, 'p_plate': 'HTP1234', 'p_model': 'HTTP', 'p_public_name': 'HTTP van', 'p_capacity': 12}
    command = {**van, 'p_command_id': str(uuid.uuid4()), 'p_expected_revision': None}
    while True:
        code, body = request('/rest/v1/rpc/save_van', command, owner)
        if code == 200:
            break
        if not isinstance(body, dict) or body.get('code') != 'PGRST202' or time.monotonic() >= deadline:
            raise AssertionError(('overload readiness', code, body.get('code') if isinstance(body, dict) else None))
        time.sleep(0.1)
    saved_van = body
    uuid.UUID(saved_van)
    assert rpc('save_van', command) == saved_van
    legacy_van = rpc('save_van', {**van, 'p_plate': 'OLD1234'})
    uuid.UUID(legacy_van)
    edit = {**command, 'p_van_id': saved_van, 'p_expected_revision': 1, 'p_command_id': str(uuid.uuid4()), 'p_model': 'Updated HTTP'}
    assert rpc('save_van', edit) == saved_van
    assert rpc('save_van', command) == saved_van
    rejected_before = planning.run_sql('select count(*) from private.fleet_planning_commands', env)
    for malformed in ({key: value for key, value in command.items() if key != 'p_command_id'},
                      {key: value for key, value in command.items() if key != 'p_expected_revision'},
                      {**command, 'unexpected': True}):
        code, result = request('/rest/v1/rpc/save_van', malformed, owner)
        assert code >= 400 and result.get('code') != 'PGRST203'
    rpc('save_van', {**command, 'p_command_id': str(uuid.uuid4()), 'p_expected_revision': 1}, expected=400)
    rpc('save_van', {**command, 'p_command_id': 'not-a-uuid'}, expected=400)
    rpc('save_van', command, token=foreign, expected=404)
    code, _ = request('/rest/v1/rpc/save_van', command)
    assert code in (401, 403)
    assert planning.run_sql('select count(*) from private.fleet_planning_commands', env) == rejected_before

    config = json.loads(fields['CONFIG'])
    config.update(name='HTTP route', van_id=saved_van, paired_route_id=None)
    route_params = {'p_fleet_id': case['fleet_id'], 'p_route_id': None, 'p_config': config}
    legacy_route = rpc('save_route', route_params)
    new_route_command = {**route_params, 'p_config': {**config, 'name': 'New HTTP route'}, 'p_command_id': str(uuid.uuid4()), 'p_expected_revision': None}
    route = rpc('save_route', new_route_command)
    assert rpc('save_route', new_route_command) == route
    projection = rpc('get_fleet_planning', {'p_fleet_id': case['fleet_id']})
    revision = next(row['edit_revision'] for row in projection['routes'] if row['id'] == route)
    rpc('save_route', {**new_route_command, 'p_route_id': route, 'p_command_id': str(uuid.uuid4()), 'p_expected_revision': revision, 'p_config': {**config, 'name': 'Edited HTTP route'}})
    schedule = {'weekdays': [7], 'starts_at': '21:00', 'ends_at': '22:00', 'ends_next_day': False, 'timezone': 'America/Sao_Paulo', 'valid_from': case['effective_on'], 'valid_until': (date.fromisoformat(case['effective_on']) + timedelta(days=14)).isoformat(), 'confirmation_minutes': 0}
    legacy_schedule = rpc('save_route_schedule', {'p_route_id': legacy_route, 'p_schedule_id': None, 'p_schedule': schedule})
    new_schedule_command = {'p_route_id': route, 'p_schedule_id': None, 'p_schedule': {**schedule, 'weekdays': [6]}, 'p_command_id': str(uuid.uuid4()), 'p_expected_revision': None}
    schedule_id = rpc('save_route_schedule', new_schedule_command)
    assert rpc('save_route_schedule', new_schedule_command) == schedule_id
    rpc('save_route_schedule', {**new_schedule_command, 'p_schedule_id': schedule_id, 'p_command_id': str(uuid.uuid4()), 'p_expected_revision': 1, 'p_schedule': {**schedule, 'weekdays': [6], 'confirmation_minutes': 1440}})
    for name, parameters in [('save_route', new_route_command), ('save_route_schedule', new_schedule_command)]:
        for missing in ('p_command_id', 'p_expected_revision'):
            code, result = request('/rest/v1/rpc/' + name, {key: value for key, value in parameters.items() if key != missing}, owner)
            assert code >= 400 and result.get('code') != 'PGRST203'

    rpc('link_fleet_service_city', {'p_fleet_id': case['fleet_id'], 'p_city_ibge_code': '3550000', 'p_command_id': str(uuid.uuid4())}, expected=204)
    rpc('link_fleet_service_school', {'p_fleet_id': case['fleet_id'], 'p_school_id': case['school_id'], 'p_command_id': str(uuid.uuid4())}, expected=204)
    roles = rpc('enable_owner_driving', {'p_fleet_id': case['fleet_id'], 'p_command_id': str(uuid.uuid4())})
    assert 'owner' in roles and 'driver' in roles
    reopened = rpc('get_fleet_planning', {'p_fleet_id': case['fleet_id']})
    assert next(v['model'] for v in reopened['vans'] if v['id'] == saved_van) == 'Updated HTTP'
    assert next(r['name'] for r in reopened['routes'] if r['id'] == route) == 'Edited HTTP route'
    assert {schedule_id, legacy_schedule} <= {s['id'] for s in reopened['schedules']}
    assert reopened['owner_operator']['is_driver']
    assert len(reopened['enrollment_revisions']) == 2
    restricted = rpc('get_fleet_planning', {'p_fleet_id': case['fleet_id']}, token=driver)
    assert 'service_cities' not in restricted and 'owner_operator' not in restricted
    assert planning.run_sql('select (select count(*) from public.transport_reservations)+(select count(*) from public.trips)', env) == '0'
    print('PASS: real Auth/PostgREST legacy/new overloads, explicit nulls, rejection isolation, adapters, persisted reload and driver privacy')


if __name__ == '__main__':
    main()
