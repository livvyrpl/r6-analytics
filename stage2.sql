-- Liv Analytics, stage 2: scrims and schedule.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run schema.sql first. This file is safe to run more than once, and it is safe
-- if the earlier scrims.sql, schedule.sql or schedule_sync.sql files were already run.

-- TABLES: every row belongs to one team

create table if not exists public.scrims (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  scrim_date date not null,
  opponent text not null check (char_length(btrim(opponent)) between 1 and 120),
  maps text[] not null default '{}',
  our_bans text[] not null default '{}',
  their_bans text[] not null default '{}',
  score text,
  split text,
  notes text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists scrims_team_date on public.scrims (team_id, scrim_date desc);

create table if not exists public.scrim_player_notes (
  scrim_id uuid references public.scrims(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  notes text not null default '',
  primary key (scrim_id, user_id)
);

create table if not exists public.schedule_entries (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  kind text not null,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  entry_date date not null,
  entry_time time,
  notes text not null default '',
  opponent text,
  maps text[] not null default '{}',
  -- who the event is for; empty means the whole team
  user_id uuid references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists schedule_team_date on public.schedule_entries (team_id, entry_date);

-- automatic time zones: an exact moment in time, which each person's browser shows in their own zone
alter table public.schedule_entries add column if not exists starts_at timestamptz;

-- event types are scrim, gameday, off day and other; only scrims and gamedays have an opponent and maps
alter table public.schedule_entries
  drop constraint if exists schedule_entries_kind_check,
  drop constraint if exists schedule_entries_check,
  drop constraint if exists schedule_entries_check1,
  drop constraint if exists schedule_entries_kind_allowed,
  drop constraint if exists schedule_entries_game_details;
alter table public.schedule_entries
  add constraint schedule_entries_kind_allowed check (kind in ('scrim','gameday','off_day','other')),
  add constraint schedule_entries_game_details check (kind in ('scrim','gameday') or (opponent is null and maps = '{}'));

-- tie each player note to the same team as its scrim
alter table public.scrim_player_notes add column if not exists team_id uuid references public.teams(id) on delete cascade;
update public.scrim_player_notes n set team_id = s.team_id from public.scrims s where s.id = n.scrim_id and n.team_id is null;
alter table public.scrim_player_notes alter column team_id set not null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'scrims_id_team_key') then
    alter table public.scrims add constraint scrims_id_team_key unique (id, team_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'scrim_player_notes_same_team') then
    alter table public.scrim_player_notes add constraint scrim_player_notes_same_team
      foreign key (scrim_id, team_id) references public.scrims (id, team_id) on delete cascade on update cascade;
  end if;
end $$;

-- link each scrim to the schedule event that created it
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

alter table public.scrims enable row level security;
alter table public.scrim_player_notes enable row level security;
alter table public.schedule_entries enable row level security;

-- HELPER CHECKS (they bypass RLS on purpose, the same way as the ones in schema.sql)
-- is_staff() means the owner or an admin, so they pass every check here on every team

-- coaches, assistant coaches and analysts can see, add, edit and delete their team's scrims
create or replace function public.can_see_scrims(t uuid) returns boolean language sql security definer stable set search_path = public as
$$ select public.is_staff() or exists(select 1 from team_members tm join profiles p on p.id = tm.user_id
   where tm.team_id = t and tm.user_id = auth.uid() and not p.suspended
   and tm.roles && array['coach','assistant_coach','analyst']) $$;
create or replace function public.can_edit_scrims(t uuid) returns boolean language sql security definer stable set search_path = public as
$$ select public.is_staff() or exists(select 1 from team_members tm join profiles p on p.id = tm.user_id
   where tm.team_id = t and tm.user_id = auth.uid() and not p.suspended
   and tm.roles && array['coach','assistant_coach','analyst']) $$;
-- coaches and assistant coaches can change their team's schedule
create or replace function public.can_edit_schedule(t uuid) returns boolean language sql security definer stable set search_path = public as
$$ select public.is_staff() or exists(select 1 from team_members tm join profiles p on p.id = tm.user_id
   where tm.team_id = t and tm.user_id = auth.uid() and not p.suspended
   and tm.roles && array['coach','assistant_coach']) $$;
create or replace function public.is_team_player(t uuid) returns boolean language sql security definer stable set search_path = public as
$$ select exists(select 1 from team_members tm join profiles p on p.id = tm.user_id
   where tm.team_id = t and tm.user_id = auth.uid() and not p.suspended
   and tm.roles && array['player']) $$;

-- WHO CAN SEE AND CHANGE WHAT

drop policy if exists scrims_read on public.scrims;
create policy scrims_read on public.scrims for select to authenticated
  using (public.can_see_scrims(team_id));
drop policy if exists scrims_write on public.scrims;
create policy scrims_write on public.scrims for all to authenticated
  using (public.can_edit_scrims(team_id)) with check (public.can_edit_scrims(team_id));

drop policy if exists scrim_notes_read on public.scrim_player_notes;
create policy scrim_notes_read on public.scrim_player_notes for select to authenticated
  using (public.can_see_scrims(team_id));
drop policy if exists scrim_notes_write on public.scrim_player_notes;
create policy scrim_notes_write on public.scrim_player_notes for all to authenticated
  using (public.can_edit_scrims(team_id)) with check (public.can_edit_scrims(team_id));

-- everyone on the team, plus the owner and admins, can see the schedule
drop policy if exists schedule_read on public.schedule_entries;
create policy schedule_read on public.schedule_entries for select to authenticated
  using (public.is_staff() or public.is_member_of(team_id));
-- coaches, assistant coaches, the owner and admins can change everything on it
drop policy if exists schedule_write on public.schedule_entries;
create policy schedule_write on public.schedule_entries for all to authenticated
  using (public.can_edit_schedule(team_id)) with check (public.can_edit_schedule(team_id));
-- players can add and delete only their own off days
drop policy if exists schedule_own_off_add on public.schedule_entries;
create policy schedule_own_off_add on public.schedule_entries for insert to authenticated
  with check (kind = 'off_day' and user_id = auth.uid() and public.is_team_player(team_id));
drop policy if exists schedule_own_off_edit on public.schedule_entries;
drop policy if exists schedule_own_off_remove on public.schedule_entries;
create policy schedule_own_off_remove on public.schedule_entries for delete to authenticated
  using (kind = 'off_day' and user_id = auth.uid() and public.is_team_player(team_id));

grant select, insert, update, delete on public.scrims, public.scrim_player_notes, public.schedule_entries to authenticated;

-- A SCRIM ON THE SCHEDULE ALSO APPEARS IN THE SCRIM LIST

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
