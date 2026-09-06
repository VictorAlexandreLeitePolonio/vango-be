alter table public.profiles enable row level security;
alter table public.fleets enable row level security;
alter table public.fleet_memberships enable row level security;
alter table public.fleet_membership_roles enable row level security;
alter table public.audit_events enable row level security;

revoke all on table public.profiles from anon, authenticated;
revoke all on table public.fleets from anon, authenticated;
revoke all on table public.fleet_memberships from anon, authenticated;
revoke all on table public.fleet_membership_roles from anon, authenticated;
revoke all on table public.audit_events from anon, authenticated;

grant select on table public.profiles to authenticated;
grant update (full_name, phone, avatar_path) on table public.profiles to authenticated;
grant select on table public.fleets to authenticated;
grant update (name, slug, description, logo_path, status) on table public.fleets to authenticated;
grant select on table public.fleet_memberships to authenticated;
grant select on table public.fleet_membership_roles to authenticated;
grant select on table public.audit_events to authenticated;

grant usage on schema private to authenticated;
grant execute on function private.is_active_fleet_member(uuid, uuid) to authenticated;
grant execute on function private.has_fleet_role(uuid, uuid, text) to authenticated;

create policy profiles_select_own
on public.profiles for select
to authenticated
using ((select auth.uid()) = id);

create policy profiles_update_own
on public.profiles for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

create policy fleets_select_active_members
on public.fleets for select
to authenticated
using (private.is_active_fleet_member(id, (select auth.uid())));

create policy fleets_update_owners
on public.fleets for update
to authenticated
using (private.has_fleet_role(id, (select auth.uid()), 'owner'))
with check (
  private.has_fleet_role(id, (select auth.uid()), 'owner')
  and status in ('draft', 'published', 'archived')
);

create policy memberships_select_own_or_owner
on public.fleet_memberships for select
to authenticated
using (
  user_id = (select auth.uid())
  or private.has_fleet_role(fleet_id, (select auth.uid()), 'owner')
);

create policy membership_roles_select_own_or_owner
on public.fleet_membership_roles for select
to authenticated
using (
  exists (
    select 1
    from public.fleet_memberships fm
    where fm.id = membership_id
      and (
        fm.user_id = (select auth.uid())
        or private.has_fleet_role(fm.fleet_id, (select auth.uid()), 'owner')
      )
  )
);

create policy audit_events_select_owners
on public.audit_events for select
to authenticated
using (private.has_fleet_role(fleet_id, (select auth.uid()), 'owner'));
