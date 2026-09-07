create function private.audit_fleet_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_changed_fields text[] := array_remove(array[
    case when old.name is distinct from new.name then 'name' end,
    case when old.slug is distinct from new.slug then 'slug' end,
    case when old.description is distinct from new.description then 'description' end,
    case when old.logo_path is distinct from new.logo_path then 'logo_path' end,
    case when old.status is distinct from new.status then 'status' end
  ], null);
begin
  if cardinality(v_changed_fields) > 0 then
    insert into public.audit_events (
      fleet_id,
      actor_user_id,
      action,
      entity_type,
      entity_id,
      metadata
    ) values (
      new.id,
      auth.uid(),
      'fleet_updated',
      'fleet',
      new.id,
      jsonb_build_object('changed_fields', to_jsonb(v_changed_fields))
    );
  end if;

  return new;
end;
$$;

revoke execute on function private.audit_fleet_update() from public, anon, authenticated;

create trigger fleets_audit_update
after update on public.fleets
for each row execute function private.audit_fleet_update();
