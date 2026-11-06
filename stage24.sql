-- Liv Analytics, stage 24: Drone Prep and Strat Prep.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run stage22.sql first. This file is safe to run more than once.

-- One row per team per round: where that team's drones sat at 2:40 (attack only),
-- and each player's operator and room at 2:40 and 1:30. Rooms are typed by coaches and analysts.
create table if not exists public.prep_logs (
  id uuid primary key default gen_random_uuid(),
  owner_team_id uuid not null references public.teams(id) on delete cascade,
  scout_round_id uuid not null references public.scout_rounds(id) on delete cascade,
  team_name text not null check (char_length(btrim(team_name)) between 1 and 200),
  map text not null default '' check (char_length(map) <= 100),
  drones text[] not null default '{}' check (cardinality(drones) <= 20),
  at_240 jsonb not null default '[]' check (jsonb_typeof(at_240) = 'array' and jsonb_array_length(at_240) <= 10),
  at_130 jsonb not null default '[]' check (jsonb_typeof(at_130) = 'array' and jsonb_array_length(at_130) <= 10),
  notes text not null default '' check (char_length(notes) <= 2000),
  updated_by uuid default auth.uid(),
  updated_at timestamptz not null default now(),
  unique (owner_team_id, scout_round_id, team_name)
);
create index if not exists prep_logs_owner on public.prep_logs (owner_team_id);
create index if not exists prep_logs_round on public.prep_logs (scout_round_id);

-- the same people who see and edit the scouting library see and edit these
alter table public.prep_logs enable row level security;
drop policy if exists prep_logs_read on public.prep_logs;
create policy prep_logs_read on public.prep_logs for select to authenticated using (public.can_see_scrims(owner_team_id));
drop policy if exists prep_logs_write on public.prep_logs;
create policy prep_logs_write on public.prep_logs for all to authenticated
  using (public.can_edit_scrims(owner_team_id)) with check (public.can_edit_scrims(owner_team_id));
grant select, insert, update, delete on public.prep_logs to authenticated;

-- changes show up in Admin > Activity log
drop trigger if exists log_change on public.prep_logs;
create trigger log_change after insert or update or delete on public.prep_logs for each row execute function public.log_change();

-- tell Supabase to pick up the new table straight away
notify pgrst, 'reload schema';
