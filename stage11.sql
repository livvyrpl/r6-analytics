-- Liv Analytics, stage 11: match cross-checks and map rating settings.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run all the earlier stage files first. This file is safe to run more than once.

-- MATCH LIBRARY: the siege.gg match ID, and the result of checking each game against the official page and siege.gg
-- check_status: empty = not checked yet, ok = agrees, mismatch = disagrees, unavailable = no source to check, reviewed = a person looked at it
alter table public.scout_matches
  add column if not exists siegegg_id text not null default '',
  add column if not exists check_status text not null default '',
  add column if not exists check_notes text not null default '',
  add column if not exists check_at timestamptz;

-- MAP RANKS: each team's own map weights and rating factors
create table if not exists public.scout_settings (
  owner_team_id uuid primary key references public.teams(id) on delete cascade,
  map_weights jsonb not null default '{}',
  factors jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.scout_settings enable row level security;

-- same rule as the rest of scouting: this team's coaches, assistant coaches and analysts, plus the owner and admins
drop policy if exists scout_settings_read on public.scout_settings;
create policy scout_settings_read on public.scout_settings for select to authenticated
  using (public.can_see_scrims(owner_team_id));
drop policy if exists scout_settings_write on public.scout_settings;
create policy scout_settings_write on public.scout_settings for all to authenticated
  using (public.can_edit_scrims(owner_team_id)) with check (public.can_edit_scrims(owner_team_id));
grant select, insert, update, delete on public.scout_settings to authenticated;

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
