-- Liv Analytics, stage 5: analyst stats and scouting (round results and operator bans by map).
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run schema.sql and stage2.sql first. This file is safe to run more than once.

-- one row per map played in a scrim, used for win rate by map and attack and defense round win rate
create table if not exists public.scrim_map_results (
  scrim_id uuid not null,
  team_id uuid not null references public.teams(id) on delete cascade,
  map text not null check (char_length(btrim(map)) between 1 and 120),
  atk_won integer not null default 0 check (atk_won >= 0),
  atk_lost integer not null default 0 check (atk_lost >= 0),
  def_won integer not null default 0 check (def_won >= 0),
  def_lost integer not null default 0 check (def_lost >= 0),
  created_at timestamptz not null default now(),
  primary key (scrim_id, map),
  -- a result must belong to the same team as its scrim
  constraint scrim_map_results_same_team foreign key (scrim_id, team_id)
    references public.scrims (id, team_id) on delete cascade on update cascade
);
create index if not exists scrim_map_results_team on public.scrim_map_results (team_id);

-- operator bans on each map: up to 3 attackers and 3 defenders, for us and for the other team
alter table public.scrim_map_results
  add column if not exists our_atk_bans text[] not null default '{}',
  add column if not exists our_def_bans text[] not null default '{}',
  add column if not exists their_atk_bans text[] not null default '{}',
  add column if not exists their_def_bans text[] not null default '{}';
alter table public.scrim_map_results drop constraint if exists scrim_map_results_three_bans;
alter table public.scrim_map_results add constraint scrim_map_results_three_bans check (
  cardinality(our_atk_bans) <= 3 and cardinality(our_def_bans) <= 3
  and cardinality(their_atk_bans) <= 3 and cardinality(their_def_bans) <= 3);

alter table public.scrim_map_results enable row level security;

-- same rule as the scrims themselves: only this team's coaches, assistant coaches and analysts,
-- plus the owner and admins, can see or change these
drop policy if exists scrim_map_results_read on public.scrim_map_results;
create policy scrim_map_results_read on public.scrim_map_results for select to authenticated
  using (public.can_see_scrims(team_id));
drop policy if exists scrim_map_results_write on public.scrim_map_results;
create policy scrim_map_results_write on public.scrim_map_results for all to authenticated
  using (public.can_edit_scrims(team_id)) with check (public.can_edit_scrims(team_id));

grant select, insert, update, delete on public.scrim_map_results to authenticated;

-- a scrim on the schedule also appears in the scrim list. This is the same as stage2.sql, with one addition:
-- a scrim with map results or bans now counts as having something recorded, so deleting it from the schedule keeps it
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
    and not exists (select 1 from scrim_player_notes n where n.scrim_id = s.id and btrim(n.notes) <> '')
    and not exists (select 1 from scrim_map_results r where r.scrim_id = s.id);
  update scrims set schedule_entry_id = null where schedule_entry_id = old.id;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

-- tell Supabase to pick up the new table straight away
notify pgrst, 'reload schema';
