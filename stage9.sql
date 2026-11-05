-- Liv Analytics, stage 9: team roster (in-game names), and the same game counted once whichever way round it was imported.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run all the earlier stage files first. This file is safe to run more than once.

-- THE ROSTER: in-game names only. These are not site accounts.
-- A coach can link a name to a player's account so that player can see their stats.
create table if not exists public.team_roster (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  linked_user_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  name_key text generated always as (lower(btrim(name))) stored,
  unique (team_id, name_key)
);
create index if not exists team_roster_linked on public.team_roster (linked_user_id);

alter table public.team_roster enable row level security;

-- this team's members, plus the owner and admins, can see the roster
drop policy if exists team_roster_read on public.team_roster;
create policy team_roster_read on public.team_roster for select to authenticated
  using (public.is_staff() or public.is_member_of(team_id));
-- coaches, assistant coaches, the owner and admins can change it, and can only link a name to a player on this team
drop policy if exists team_roster_write on public.team_roster;
create policy team_roster_write on public.team_roster for all to authenticated
  using (public.can_edit_schedule(team_id))
  with check (public.can_edit_schedule(team_id) and (linked_user_id is null or public.goal_target_is_player(team_id, linked_user_id)));
grant select, insert, update, delete on public.team_roster to authenticated;

-- PLAYER STATS: the replay parser saves stats by in-game name, so a row no longer needs an account
alter table public.round_stats alter column user_id drop not null;
alter table public.round_stats drop constraint if exists round_stats_team_id_match_id_round_number_user_id_key;
alter table public.round_stats add column if not exists player_key text generated always as (lower(btrim(player_username))) stored;
alter table public.round_stats drop constraint if exists round_stats_one_per_round;
alter table public.round_stats add constraint round_stats_one_per_round unique (team_id, match_id, round_number, player_key);

-- players see stats saved to their account, or under a roster name linked to them; coaches, admins and the owner see their team's
drop policy if exists round_stats_read on public.round_stats;
create policy round_stats_read on public.round_stats for select to authenticated
  using (public.can_read_player_data(team_id)
    or (public.is_member_of(team_id) and (user_id = auth.uid() or exists (
      select 1 from public.team_roster r
      where r.team_id = round_stats.team_id and r.name_key = round_stats.player_key and r.linked_user_id = auth.uid()))));

-- MATCH LIBRARY: Team 1 v Team 2 is the same game as Team 2 v Team 1, so it can only be stored once per team
-- any copies already there are removed first, keeping the oldest
delete from public.scout_matches a using public.scout_matches b
  where a.owner_team_id = b.owner_team_id and a.match_date = b.match_date
    and lower(btrim(a.team)) = lower(btrim(b.opponent)) and lower(btrim(a.opponent)) = lower(btrim(b.team))
    and lower(btrim(a.map)) = lower(btrim(b.map)) and lower(btrim(a.phase)) = lower(btrim(b.phase))
    and (a.created_at, a.id) > (b.created_at, b.id);
alter table public.scout_matches drop column if exists dedupe_key;
alter table public.scout_matches add column dedupe_key text generated always as (
  least(lower(btrim(team)), lower(btrim(opponent))) || '|' || greatest(lower(btrim(team)), lower(btrim(opponent)))
  || '|' || lower(btrim(map)) || '|' || lower(btrim(phase))) stored;
alter table public.scout_matches add constraint scout_matches_one_per_game unique (owner_team_id, match_date, dedupe_key);

-- VETOES: second picks, used in Bo5
alter table public.scout_vetoes
  add column if not exists t1_pick_2 text not null default '',
  add column if not exists t2_pick_2 text not null default '';

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
