alter table public.profiles
add column onboarding_intent text;

alter table public.profiles
add constraint profiles_onboarding_intent_valid check (
  onboarding_intent is null
  or onboarding_intent in ('fleet_owner', 'driver', 'guardian', 'adult_student')
);

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_onboarding_intent text := new.raw_user_meta_data ->> 'onboarding_intent';
begin
  insert into public.profiles (id, full_name, onboarding_intent)
  values (
    new.id,
    nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
    case
      when v_onboarding_intent in ('fleet_owner', 'driver', 'guardian', 'adult_student')
        then v_onboarding_intent
      else null
    end
  );

  return new;
end;
$$;

create function public.get_my_access_context()
returns table (
  onboarding_intent text,
  account_roles text[],
  dependent_student_ids uuid[],
  adult_student_id uuid,
  fleet_access jsonb[]
)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;

  return query
  select
    p.onboarding_intent,
    array(
      select distinct role_name
      from (
        select fmr.role as role_name
        from public.fleet_memberships fm
        join public.fleet_membership_roles fmr on fmr.membership_id = fm.id
        where fm.user_id = v_user_id
          and fm.status = 'active'
        union all
        select 'guardian'
        from public.student_guardians sg
        where sg.guardian_user_id = v_user_id
          and sg.status = 'active'
        union all
        select 'student'
        from public.students s
        where s.profile_id = v_user_id
          and s.student_type = 'adult'
      ) roles
      order by role_name
    ),
    array(
      select sg.student_id
      from public.student_guardians sg
      where sg.guardian_user_id = v_user_id
        and sg.status = 'active'
      order by sg.student_id
    ),
    (
      select s.id
      from public.students s
      where s.profile_id = v_user_id
        and s.student_type = 'adult'
    ),
    array(
      select jsonb_build_object(
        'fleet_id', fm.fleet_id,
        'roles', array_agg(fmr.role order by fmr.role)
      )
      from public.fleet_memberships fm
      join public.fleet_membership_roles fmr on fmr.membership_id = fm.id
      where fm.user_id = v_user_id
        and fm.status = 'active'
      group by fm.fleet_id
      order by fm.fleet_id
    )
  from public.profiles p
  where p.id = v_user_id;
end;
$$;

revoke execute on function public.get_my_access_context() from public, anon;
grant execute on function public.get_my_access_context() to authenticated;
