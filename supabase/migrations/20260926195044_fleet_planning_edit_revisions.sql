alter table public.vans add column edit_revision bigint not null default 1 check (edit_revision > 0);
alter table public.routes add column edit_revision bigint not null default 1 check (edit_revision > 0);
alter table public.route_schedules add column edit_revision bigint not null default 1 check (edit_revision > 0);

-- Configuration versions exclude route-calculation bookkeeping.
create function private.advance_planning_edit_revision() returns trigger
language plpgsql set search_path = '' as $$
begin
 if (to_jsonb(new)-array['edit_revision','updated_at','routing_revision'])
   is distinct from (to_jsonb(old)-array['edit_revision','updated_at','routing_revision']) then
   new.edit_revision := old.edit_revision+1;
 end if;
 return new;
end;
$$;
revoke all on function private.advance_planning_edit_revision() from public,anon,authenticated;
create trigger vans_edit_revision before update on public.vans for each row execute function private.advance_planning_edit_revision();
create trigger routes_edit_revision before update on public.routes for each row execute function private.advance_planning_edit_revision();
create trigger route_schedules_edit_revision before update on public.route_schedules for each row execute function private.advance_planning_edit_revision();

create function private.advance_route_school_edit_revision() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if tg_op <> 'INSERT' then
   update public.routes set edit_revision=edit_revision+1 where id=old.route_id;
 end if;
 if tg_op = 'INSERT' or (tg_op = 'UPDATE' and new.route_id<>old.route_id) then
   update public.routes set edit_revision=edit_revision+1 where id=new.route_id;
 end if;
 return null;
end;
$$;
revoke all on function private.advance_route_school_edit_revision() from public,anon,authenticated;
create trigger route_schools_edit_revision after insert or update or delete on public.route_schools
 for each row execute function private.advance_route_school_edit_revision();
