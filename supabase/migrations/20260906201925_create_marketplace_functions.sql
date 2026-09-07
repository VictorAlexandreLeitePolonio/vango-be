create function private.audit_service_coverage()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fleet_id uuid := case when tg_op = 'DELETE' then old.fleet_id else new.fleet_id end;
  v_entity_id uuid;
  v_action text;
  v_entity_type text;
  v_metadata jsonb;
begin
  if tg_table_name = 'fleet_service_schools' then
    v_entity_id := case when tg_op = 'DELETE' then old.school_id else new.school_id end;
    v_entity_type := 'service_school';
    v_action := case when tg_op = 'INSERT' then 'service_school_added' else 'service_school_removed' end;
    v_metadata := jsonb_build_object(
      'fleet_id', v_fleet_id,
      'school_id', v_entity_id
    );
  else
    v_entity_id := v_fleet_id;
    v_entity_type := 'service_city';
    v_action := case when tg_op = 'INSERT' then 'service_city_added' else 'service_city_removed' end;
    v_metadata := jsonb_build_object(
      'fleet_id', v_fleet_id,
      'city_ibge_code', case when tg_op = 'DELETE' then old.city_ibge_code else new.city_ibge_code end
    );
  end if;

  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_fleet_id, auth.uid(), v_action, v_entity_type, v_entity_id, v_metadata
  );

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger fleet_service_cities_audit
after insert or delete on public.fleet_service_cities
for each row execute function private.audit_service_coverage();

create trigger fleet_service_schools_audit
after insert or delete on public.fleet_service_schools
for each row execute function private.audit_service_coverage();

create function public.search_schools(
  p_query text,
  p_city_ibge_code text,
  p_institution_type text,
  p_limit integer,
  p_offset integer
) returns table (
  id uuid,
  institution_type text,
  name text,
  postal_code text,
  street text,
  street_number text,
  address_complement text,
  neighborhood text,
  city_name text,
  city_ibge_code text,
  state_code text,
  latitude numeric,
  longitude numeric
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_query text := nullif(btrim(p_query), '');
begin
  if v_query is null and (p_city_ibge_code is null or p_city_ibge_code !~ '^[0-9]{7}$') then
    perform private.raise_api_error('invalid_input', 'A school query or valid city is required', 400);
  end if;
  if p_city_ibge_code is not null and p_city_ibge_code !~ '^[0-9]{7}$' then
    perform private.raise_api_error('invalid_input', 'Invalid city IBGE code', 400);
  end if;
  if p_institution_type is not null and p_institution_type not in ('school', 'higher_education') then
    perform private.raise_api_error('invalid_input', 'Invalid institution type', 400);
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 50 or p_offset is null or p_offset < 0 then
    perform private.raise_api_error('invalid_input', 'Invalid pagination', 400);
  end if;

  return query
  select s.id,
         s.institution_type,
         s.name,
         s.postal_code,
         s.street,
         s.street_number,
         s.address_complement,
         s.neighborhood,
         s.city_name,
         s.city_ibge_code,
         s.state_code,
         s.latitude,
         s.longitude
  from public.schools s
  where s.status = 'active'
    and (v_query is null or extensions.unaccent(lower(s.name)) like '%' || extensions.unaccent(lower(v_query)) || '%')
    and (p_city_ibge_code is null or s.city_ibge_code = p_city_ibge_code)
    and (p_institution_type is null or s.institution_type = p_institution_type)
  order by s.name, s.id
  limit p_limit offset p_offset;
end;
$$;

create function public.search_marketplace(
  p_city_ibge_code text,
  p_school_id uuid,
  p_limit integer,
  p_offset integer
) returns table (
  id uuid,
  name text,
  slug text,
  description text,
  logo_path text
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_city_ibge_code is null or p_city_ibge_code !~ '^[0-9]{7}$'
    or p_limit is null or p_limit < 1 or p_limit > 50
    or p_offset is null or p_offset < 0 then
    perform private.raise_api_error('invalid_input', 'Invalid marketplace filters', 400);
  end if;

  if p_school_id is not null and not exists (
    select 1 from public.schools s where s.id = p_school_id and s.status = 'active'
  ) then
    perform private.raise_api_error('not_found', 'School not found', 404);
  end if;

  return query
  select f.id, f.name, f.slug, f.description, f.logo_path
  from public.fleets f
  where f.status = 'published'
    and exists (
      select 1
      from public.fleet_service_cities city
      where city.fleet_id = f.id
        and city.city_ibge_code = p_city_ibge_code
    )
    and (p_school_id is null or exists (
      select 1
      from public.fleet_service_schools service_school
      where service_school.fleet_id = f.id
        and service_school.school_id = p_school_id
    ))
  order by f.name, f.id
  limit p_limit offset p_offset;
end;
$$;

revoke execute on function private.audit_service_coverage() from public, anon, authenticated;
revoke execute on function public.search_schools(text, text, text, integer, integer) from public;
revoke execute on function public.search_marketplace(text, uuid, integer, integer) from public;
grant execute on function public.search_schools(text, text, text, integer, integer) to anon, authenticated;
grant execute on function public.search_marketplace(text, uuid, integer, integer) to anon, authenticated;
