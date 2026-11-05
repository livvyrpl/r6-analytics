-- Liv Analytics, stage 12: importing replays.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run all the earlier stage files first. This file is safe to run more than once.

-- MATCH LIBRARY: which replay a game came from, and how its two replay teams map onto it
alter table public.scout_matches
  add column if not exists replay_match_id text not null default '',
  add column if not exists scout_team_id uuid references public.scout_teams(id) on delete set null,
  add column if not exists our_team_index integer check (our_team_index is null or our_team_index in (0, 1)),
  add column if not exists replay_t1_index integer check (replay_t1_index is null or replay_t1_index in (0, 1));

-- the same replay can only be one game per team
create unique index if not exists scout_matches_one_per_replay
  on public.scout_matches (owner_team_id, replay_match_id) where replay_match_id <> '';

-- PLAYER NUMBERS: one row per player per round
create table if not exists public.player_round_stats (
  id uuid primary key default gen_random_uuid(),
  owner_team_id uuid not null references public.teams(id) on delete cascade,
  -- deleting a game from the Match Library removes its player numbers too
  scout_match_id uuid references public.scout_matches(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  match_id text not null check (char_length(btrim(match_id)) >= 1),
  round_number integer not null check (round_number >= 1),
  match_date date,
  map text not null default '',
  player_username text not null check (char_length(btrim(player_username)) >= 1),
  player_key text generated always as (lower(btrim(player_username))) stored,
  team_name text not null default '',
  is_our_team boolean not null default false,
  operator text not null default '',
  operator_id text not null default '',
  side text not null default '' check (side in ('', 'attack', 'defense')),
  kills integer not null default 0 check (kills >= 0),
  deaths integer not null default 0 check (deaths in (0, 1)),
  assists integer not null default 0 check (assists >= 0),
  headshots integer not null default 0 check (headshots >= 0 and headshots <= kills),
  -- the in-game running total for the match so far, not the points from this round
  match_score integer not null default 0,
  kost_point boolean not null default false,
  created_at timestamptz not null default now(),
  -- importing the same replay twice never makes a second copy
  unique (owner_team_id, match_id, round_number, player_key)
);
create index if not exists player_round_stats_player on public.player_round_stats (owner_team_id, player_key);
create index if not exists player_round_stats_match on public.player_round_stats (scout_match_id);

alter table public.player_round_stats enable row level security;

-- this team's coaches, assistant coaches and analysts, plus the owner and admins, see all of it;
-- a player sees rows saved to their account, or under a roster name linked to them
drop policy if exists player_round_stats_read on public.player_round_stats;
create policy player_round_stats_read on public.player_round_stats for select to authenticated
  using (public.can_see_scrims(owner_team_id)
    or (public.is_member_of(owner_team_id) and (user_id = auth.uid() or exists (
      select 1 from public.team_roster r
      where r.team_id = player_round_stats.owner_team_id
        and r.name_key = player_round_stats.player_key
        and r.linked_user_id = auth.uid()))));

-- the people who can edit scouting can import
drop policy if exists player_round_stats_write on public.player_round_stats;
create policy player_round_stats_write on public.player_round_stats for all to authenticated
  using (public.can_edit_scrims(owner_team_id)) with check (public.can_edit_scrims(owner_team_id));
grant select, insert, update, delete on public.player_round_stats to authenticated;

-- My Stats now reads this table, so any rows in the old one are copied across. The old table is left in place.
insert into public.player_round_stats
  (owner_team_id, user_id, match_id, round_number, player_username, operator, side, kills, deaths, assists, headshots, kost_point, created_at)
select team_id, user_id, match_id, round_number, player_username, operator, side, kills, case when died then 1 else 0 end, assists, headshots, kost_point, created_at
from public.round_stats
on conflict (owner_team_id, match_id, round_number, player_key) do nothing;

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
