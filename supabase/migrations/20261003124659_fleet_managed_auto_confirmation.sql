-- Fleet-managed students have no guardian or student account that can answer
-- respond_trip, so the fleet confirms them by default (opt-out). Absence is
-- recorded at the stop. Students with an account keep the normal flow.
create function private.auto_confirm_fleet_managed_passenger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.confirmation_status = 'pending' and exists (
    select 1
    from public.students s
    where s.id = new.student_id
      and s.registration_origin = 'fleet_owner_created'
      and s.profile_id is null
      and not exists (
        select 1 from public.student_guardians sg
        where sg.student_id = s.id and sg.status = 'active'
      )
  ) then
    new.confirmation_status := 'confirmed';
    new.confirmation_at := clock_timestamp();
    new.confirmation_by := null;
  end if;
  return new;
end;
$$;

revoke all on function private.auto_confirm_fleet_managed_passenger() from public, anon, authenticated;

create trigger trip_passengers_auto_confirm_fleet_managed
before insert or update of confirmation_status on public.trip_passengers
for each row execute function private.auto_confirm_fleet_managed_passenger();
