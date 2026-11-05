-- Liv Analytics, stage 8: scouting. All scouting data belongs to one team (owner_team_id).
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run schema.sql and stage2.sql first. This file is safe to run more than once.

-- the opponents this team is tracking
create table if not exists public.scout_teams (
  id uuid primary key default gen_random_uuid(),
  owner_team_id uuid not null references public.teams(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 120),
  short_name text not null default '',
  region text not null default '',
  league text not null default '',
  logo_url text not null default '' check (logo_url = '' or logo_url ~ '^https://'),
  color text not null default '#e07cc0' check (color ~ '^#[0-9a-fA-F]{6}$'),
  source_ids jsonb not null default '{}',
  players text[] not null default '{}',
  coach_notes text not null default '',
  created_at timestamptz not null default now(),
  name_key text generated always as (lower(btrim(name))) stored,
  unique (owner_team_id, name_key)
);

create table if not exists public.scout_matches (
  id uuid primary key default gen_random_uuid(),
  owner_team_id uuid not null references public.teams(id) on delete cascade,
  match_date date not null,
  team text not null default '',
  opponent text not null check (char_length(btrim(opponent)) >= 1),
  map text not null check (char_length(btrim(map)) >= 1),
  league text not null default '',
  phase text not null default '',
  start_side text not null default '',
  picked_by text not null default '',
  our_atk_ban text not null default '',
  our_def_ban text not null default '',
  opp_atk_ban text not null default '',
  opp_def_ban text not null default '',
  split_score text not null default '',
  round_score text not null default '',
  total_rounds integer check (total_rounds is null or total_rounds >= 0),
  ot_start text not null default '',
  result text not null default '',
  vod_link text not null default '',
  source_name text not null default '',
  source_link text not null default '',
  replay_status text not null default '',
  created_at timestamptz not null default now(),
  -- re-importing the same game never makes a second copy within a team
  dedupe_key text generated always as (lower(btrim(team)) || '|' || lower(btrim(opponent)) || '|' || lower(btrim(map)) || '|' || lower(btrim(phase))) stored,
  unique (owner_team_id, match_date, dedupe_key)
);

create table if not exists public.scout_vetoes (
  id uuid primary key default gen_random_uuid(),
  owner_team_id uuid not null references public.teams(id) on delete cascade,
  veto_date date not null,
  team text not null default '',
  opponent text not null check (char_length(btrim(opponent)) >= 1),
  league text not null default '',
  phase text not null default '',
  t1_ban_1 text not null default '', t1_ban_2 text not null default '', t1_ban_3 text not null default '', t1_ban_4 text not null default '',
  t2_ban_1 text not null default '', t2_ban_2 text not null default '', t2_ban_3 text not null default '', t2_ban_4 text not null default '',
  t1_pick text not null default '',
  t2_pick text not null default '',
  decider text not null default '',
  format text not null default '',
  source text not null default '',
  created_at timestamptz not null default now(),
  dedupe_key text generated always as (lower(btrim(team)) || '|' || lower(btrim(opponent)) || '|' || lower(btrim(phase))) stored,
  unique (owner_team_id, veto_date, dedupe_key)
);

create table if not exists public.scout_rounds (
  id uuid primary key default gen_random_uuid(),
  owner_team_id uuid not null references public.teams(id) on delete cascade,
  match_id text not null check (char_length(btrim(match_id)) >= 1),
  round_date date,
  league text not null default '',
  map text not null default '',
  round_number integer not null check (round_number >= 1),
  team text not null default '',
  opponent text not null default '',
  ban_1 text not null default '',
  ban_2 text not null default '',
  side text not null default '',
  site text not null default '',
  result text not null default '',
  operator_1 text not null default '', operator_2 text not null default '', operator_3 text not null default '', operator_4 text not null default '', operator_5 text not null default '',
  opponent_operators text not null default '',
  created_at timestamptz not null default now(),
  dedupe_key text generated always as (lower(btrim(match_id)) || '|' || lower(btrim(team))) stored,
  unique (owner_team_id, round_number, dedupe_key)
);

create index if not exists scout_matches_owner on public.scout_matches (owner_team_id, match_date desc);
create index if not exists scout_vetoes_owner on public.scout_vetoes (owner_team_id, veto_date desc);
create index if not exists scout_rounds_owner on public.scout_rounds (owner_team_id);

alter table public.scout_teams enable row level security;
alter table public.scout_matches enable row level security;
alter table public.scout_vetoes enable row level security;
alter table public.scout_rounds enable row level security;

-- only this team's coaches, assistant coaches and analysts, plus the owner and admins, can see or change its scouting data
do $$
declare t text;
begin
  foreach t in array array['scout_teams','scout_matches','scout_vetoes','scout_rounds'] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.can_see_scrims(owner_team_id))', t || '_read', t);
    execute format('drop policy if exists %I on public.%I', t || '_write', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.can_edit_scrims(owner_team_id)) with check (public.can_edit_scrims(owner_team_id))', t || '_write', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- TEAM SETTINGS: coaches and assistant coaches can edit their own team (the owner and admins already can)
drop policy if exists teams_coach_edit on public.teams;
create policy teams_coach_edit on public.teams for update to authenticated
  using (public.can_edit_schedule(id)) with check (public.can_edit_schedule(id));

-- and can upload a team logo
create or replace function public.is_any_coach() returns boolean language sql security definer stable set search_path = public as
$$ select exists(select 1 from team_members tm join profiles p on p.id = tm.user_id
   where tm.user_id = auth.uid() and not p.suspended and tm.roles && array['coach','assistant_coach']) $$;
drop policy if exists logos_add_coach on storage.objects;
create policy logos_add_coach on storage.objects for insert to authenticated
  with check (bucket_id = 'logos' and public.is_any_coach());

-- tell Supabase to pick up the new tables straight away
notify pgrst, 'reload schema';
