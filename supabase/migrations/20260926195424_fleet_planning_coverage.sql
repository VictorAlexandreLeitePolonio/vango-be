-- Administrative catalog data is deliberately empty until a reviewed import.
create table public.catalog_municipalities (
 city_ibge_code text primary key check(city_ibge_code ~ '^35[0-9]{5}$'),
 city_name text not null check(btrim(city_name)<>''),
 state_code text not null default 'SP' check(state_code='SP'),
 source_reference text not null check(btrim(source_reference)<>'')
);
alter table public.catalog_municipalities enable row level security;
revoke all on public.catalog_municipalities from public,anon,authenticated;
grant select(city_ibge_code,city_name,state_code) on public.catalog_municipalities to authenticated;
create policy catalog_municipalities_read on public.catalog_municipalities for select to authenticated using(true);

create table private.school_publications (
 school_id uuid primary key references public.schools(id) on delete restrict,
 school_fingerprint bytea not null check(octet_length(school_fingerprint)=32),
 evidence_reference text not null check(btrim(evidence_reference)<>''),
 verified_at timestamptz not null check(isfinite(verified_at))
);
alter table private.school_publications enable row level security;
revoke all on private.school_publications from public,anon,authenticated;

-- Address/identity/coordinate corrections invalidate publication until re-reviewed.
create function private.school_publication_fingerprint(p_school uuid) returns bytea
language sql stable security definer set search_path = '' as $$
 select extensions.digest((to_jsonb(s)-array['created_at','updated_at','status','source_updated_at'])::text,'sha256')
 from public.schools s where s.id=p_school;
$$;
revoke all on function private.school_publication_fingerprint(uuid) from public,anon,authenticated;
create function private.is_published_school(p_school uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.schools s join private.school_publications p on p.school_id=s.id
   join public.catalog_municipalities c on c.city_ibge_code=s.city_ibge_code and c.city_name=s.city_name and c.state_code=s.state_code
   where s.id=p_school and s.status='active' and s.latitude between -90 and 90 and s.longitude between -180 and 180
     and p.school_fingerprint=private.school_publication_fingerprint(s.id));
$$;
revoke all on function private.is_published_school(uuid) from public,anon,authenticated;

-- ponytail: reuse the global planning lock; partition locks only if throughput requires it.
create function private.lock_service_coverage() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 perform private.lock_planning();
 return null;
end;
$$;
revoke all on function private.lock_service_coverage() from public,anon,authenticated;
create trigger service_cities_lock before insert or update or delete on public.fleet_service_cities
 for each statement execute function private.lock_service_coverage();
create trigger service_schools_lock before insert or update or delete on public.fleet_service_schools
 for each statement execute function private.lock_service_coverage();

create function private.validate_fleet_service_coverage() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if current_setting('role',true)='authenticated' then
   if not private.current_user_email_confirmed() or not private.has_fleet_role(
     case when tg_op='DELETE' then old.fleet_id else new.fleet_id end,auth.uid(),'owner') then
     raise insufficient_privilege using message='Confirmed owner required';
   end if;
   if tg_op<>'DELETE' and new.created_by is distinct from auth.uid() then
     raise insufficient_privilege using message='Actor must be current user';
   end if;
 end if;
 if tg_table_name='fleet_service_cities' and tg_op<>'DELETE' then
  if not exists(
   select 1 from public.catalog_municipalities c where c.city_ibge_code=new.city_ibge_code
     and c.city_name=new.city_name and c.state_code=new.state_code) then
   perform private.raise_api_error('invalid_input','Unknown municipality or mismatched metadata',400);
  end if;
 end if;
 if tg_table_name='fleet_service_schools' and tg_op<>'DELETE' then
   if not exists(select 1 from public.schools s join public.fleet_service_cities c
     on c.city_ibge_code=s.city_ibge_code and c.fleet_id=new.fleet_id
     where s.id=new.school_id and private.is_published_school(s.id)) then
     perform private.raise_api_error('invalid_input','School requires covered municipality',400);
   end if;
 end if;
 if tg_op='DELETE' then
   if tg_table_name='fleet_service_cities' then
     if exists(select 1 from public.fleet_service_schools f join public.schools s on s.id=f.school_id
       where f.fleet_id=old.fleet_id and s.city_ibge_code=old.city_ibge_code) then
       perform private.raise_api_error('resource_in_use','Municipality still has linked schools',409);
     end if;
   elsif exists(select 1 from public.route_schools r where r.fleet_id=old.fleet_id and r.school_id=old.school_id)
     or exists(select 1 from public.fleet_enrollments e where e.fleet_id=old.fleet_id and e.school_id=old.school_id
       and (e.status='active' or exists(select 1 from public.transport_reservations r where r.enrollment_id=e.id and r.status='active'))) then
     perform private.raise_api_error('resource_in_use','School is used by planning',409);
   end if;
   return old;
 end if;
 return new;
end;
$$;
revoke all on function private.validate_fleet_service_coverage() from public,anon,authenticated;
create trigger service_cities_invariant before insert or update or delete on public.fleet_service_cities
 for each row execute function private.validate_fleet_service_coverage();
create trigger service_schools_invariant before insert or update or delete on public.fleet_service_schools
 for each row execute function private.validate_fleet_service_coverage();

create function public.link_fleet_service_city(p_fleet_id uuid,p_city_ibge_code text,p_command_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_payload jsonb := jsonb_build_object('city_ibge_code',p_city_ibge_code); v_city public.catalog_municipalities%rowtype;
begin
 if private.planning_command_receipt(p_fleet_id,p_command_id,'city',v_payload) is not null then return; end if;
 select * into v_city from public.catalog_municipalities where city_ibge_code=p_city_ibge_code;
 if not found then perform private.raise_api_error('invalid_input','Unknown municipality',400); end if;
 insert into public.fleet_service_cities(fleet_id,city_ibge_code,city_name,state_code,created_by)
 values(p_fleet_id,v_city.city_ibge_code,v_city.city_name,v_city.state_code,auth.uid()) on conflict do nothing;
 perform private.record_planning_command(p_fleet_id,p_command_id,'city',v_payload,'{"accepted":true}');
end;
$$;
revoke all on function public.link_fleet_service_city(uuid,text,uuid) from public,anon;
grant execute on function public.link_fleet_service_city(uuid,text,uuid) to authenticated;

create function public.link_fleet_service_school(p_fleet_id uuid,p_school_id uuid,p_command_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_payload jsonb := jsonb_build_object('school_id',p_school_id);
begin
 if private.planning_command_receipt(p_fleet_id,p_command_id,'school',v_payload) is not null then return; end if;
 if p_school_id is null then perform private.raise_api_error('invalid_input','School is required',400); end if;
 insert into public.fleet_service_schools(fleet_id,school_id,created_by)
 values(p_fleet_id,p_school_id,auth.uid()) on conflict do nothing;
 perform private.record_planning_command(p_fleet_id,p_command_id,'school',v_payload,'{"accepted":true}');
end;
$$;
revoke all on function public.link_fleet_service_school(uuid,uuid,uuid) from public,anon;
grant execute on function public.link_fleet_service_school(uuid,uuid,uuid) to authenticated;

create or replace function public.search_schools(
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
  where private.is_published_school(s.id)
    and (v_query is null or extensions.unaccent(lower(s.name)) like '%' || extensions.unaccent(lower(v_query)) || '%')
    and (p_city_ibge_code is null or s.city_ibge_code = p_city_ibge_code)
    and (p_institution_type is null or s.institution_type = p_institution_type)
  order by s.name, s.id
  limit p_limit offset p_offset;
end;
$$;
create or replace function private.assert_route_school_change(
  p_route_id uuid,
  p_schools jsonb
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_route_id is null or jsonb_typeof(p_schools) is distinct from 'array' then
    perform private.raise_api_error('invalid_input', 'Route schools are invalid', 400);
  end if;
  if jsonb_array_length(p_schools)=0 or exists(
    select 1 from jsonb_array_elements(p_schools) item
    where not exists(select 1 from public.schools s join public.fleet_service_schools f on f.school_id=s.id
      join public.routes r on r.id=p_route_id and r.fleet_id=f.fleet_id
      where lower(item->>'school_id')=s.id::text and private.is_published_school(s.id))) then
    perform private.raise_api_error('invalid_input','Route requires published covered schools',400);
  end if;
  if exists (
    select 1
    from public.transport_reservations tr
    join public.fleet_enrollments e
      on e.id = tr.enrollment_id and e.fleet_id = tr.fleet_id
    where tr.route_id = p_route_id
      and tr.status = 'active'
      and tr.valid_until >= current_date
      and e.school_id is not null
      and not exists (
        select 1
        from jsonb_array_elements(p_schools) item
        where lower(item->>'school_id') = e.school_id::text
      )
  ) then
    perform private.raise_api_error(
      'resource_in_use',
      'Route has current or future reservations for a removed school',
      409
    );
  end if;
end;
$$;

-- Return only active covered school identifiers and names to confirmed fleet owners.
create or replace function public.list_fleet_service_schools(p_fleet_id uuid)
returns table(id uuid, name text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if not exists (select 1 from public.fleets f where f.id = p_fleet_id)
     or not private.has_fleet_role(p_fleet_id, auth.uid(), 'owner') then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;
  return query
    select s.id, s.name
    from public.schools s
    join public.fleet_service_schools coverage on coverage.school_id = s.id
    where coverage.fleet_id = p_fleet_id and private.is_published_school(s.id)
    order by lower(s.name), s.id;
end;
$$;
revoke execute on function public.list_fleet_service_schools(uuid) from public, anon;
grant execute on function public.list_fleet_service_schools(uuid) to authenticated;
