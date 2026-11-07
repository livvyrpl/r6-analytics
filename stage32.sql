-- STAGE 32: Liquipedia events for Scouting
-- Each team keeps a list of events (added from a Liquipedia link in the Analyst Deck) and the teams playing in them,
-- so the Scouting page can show only the teams in one event. Safe to run more than once.

create table if not exists public.scout_events (
  id uuid primary key default gen_random_uuid(),
  owner_team_id uuid not null references public.teams(id) on delete cascade,
  name text not null,
  page text not null,
  url text not null default '',
  pages text[] not null default '{}',
  teams text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_team_id, page)
);

alter table public.scout_events enable row level security;

-- the same people who see and change this team's scouting
drop policy if exists scout_events_read on public.scout_events;
create policy scout_events_read on public.scout_events for select to authenticated using (public.can_see_scrims(owner_team_id));
drop policy if exists scout_events_write on public.scout_events;
create policy scout_events_write on public.scout_events for all to authenticated using (public.can_edit_scrims(owner_team_id)) with check (public.can_edit_scrims(owner_team_id));
grant select, insert, update, delete on public.scout_events to authenticated;
