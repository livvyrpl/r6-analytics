-- Liv Analytics, schedule updates. Paste this whole file into Supabase > SQL Editor > Run.
-- Run schema.sql, scrims.sql and schedule.sql first. This file is safe to run more than once.

-- automatic time zones: an exact moment in time, which each person's browser shows in their own zone
alter table public.schedule_entries add column if not exists starts_at timestamptz;

-- link each scrim to the schedule entry that created it
-- the first time this runs, scrims already on the schedule are added to the scrim list,
-- unless the list already has one for that team, date and opponent
do $$ begin
  if not exists (select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'scrims' and column_name = 'schedule_entry_id') then
    alter table public.scrims add column schedule_entry_id uuid unique references public.schedule_entries(id) on delete set null;
    insert into public.scrims (team_id, scrim_date, opponent, maps, schedule_entry_id)
      select e.team_id, e.entry_date, coalesce(left(nullif(btrim(e.opponent), ''), 120), 'TBD'), e.maps, e.id
      from public.schedule_entries e
      where e.kind = 'scrim' and not exists (select 1 from public.scrims s
        where s.team_id = e.team_id and s.scrim_date = e.entry_date
        and lower(s.opponent) = lower(coalesce(left(nullif(btrim(e.opponent), ''), 120), 'TBD')));
  end if;
end $$;

-- keeps the scrim list in step with the schedule
create or replace function public.sync_scheduled_scrim() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.kind = 'scrim' then
      insert into scrims (team_id, scrim_date, opponent, maps, schedule_entry_id)
      values (new.team_id, new.entry_date, coalesce(left(nullif(btrim(new.opponent), ''), 120), 'TBD'), new.maps, new.id);
    end if;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if old.kind <> 'scrim' and new.kind = 'scrim' then
      insert into scrims (team_id, scrim_date, opponent, maps, schedule_entry_id)
      values (new.team_id, new.entry_date, coalesce(left(nullif(btrim(new.opponent), ''), 120), 'TBD'), new.maps, new.id);
      return new;
    elsif old.kind = 'scrim' and new.kind = 'scrim' then
      -- only copy what changed, so edits made in the scrim list are not overwritten
      update scrims set
        team_id = new.team_id,
        scrim_date = case when new.entry_date is distinct from old.entry_date then new.entry_date else scrim_date end,
        opponent = case when new.opponent is distinct from old.opponent then coalesce(left(nullif(btrim(new.opponent), ''), 120), 'TBD') else opponent end,
        maps = case when new.maps is distinct from old.maps then new.maps else maps end
      where schedule_entry_id = new.id;
      return new;
    elsif old.kind <> 'scrim' then
      return new;
    end if;
  end if;

  -- the scheduled scrim was deleted or changed to another type:
  -- remove it from the scrim list if nothing was recorded on it, otherwise keep it
  delete from scrims s where s.schedule_entry_id = old.id
    and coalesce(btrim(s.score), '') = '' and coalesce(btrim(s.split), '') = ''
    and s.our_bans = '{}' and s.their_bans = '{}' and btrim(s.notes) = ''
    and not exists (select 1 from scrim_player_notes n where n.scrim_id = s.id and btrim(n.notes) <> '');
  update scrims set schedule_entry_id = null where schedule_entry_id = old.id;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

drop trigger if exists schedule_scrim_saved on public.schedule_entries;
create trigger schedule_scrim_saved after insert or update on public.schedule_entries
  for each row execute function public.sync_scheduled_scrim();
drop trigger if exists schedule_scrim_deleted on public.schedule_entries;
create trigger schedule_scrim_deleted before delete on public.schedule_entries
  for each row execute function public.sync_scheduled_scrim();

-- tell Supabase to pick up the new columns straight away
notify pgrst, 'reload schema';
