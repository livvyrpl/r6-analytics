-- Liv Analytics, stage 3: player hub (journal and stats).
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run schema.sql and stage2.sql first. This file is safe to run more than once.

-- TEAM COLORS: must be a full hex code, such as #e07cc0
alter table public.teams drop constraint if exists teams_color_is_hex;
alter table public.teams add constraint teams_color_is_hex check (color ~ '^#[0-9a-fA-F]{6}$') not valid;

-- TABLES: every row belongs to one team and one person

create table if not exists public.journal_goals (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  description text not null default '',
  deadline date,
  status text not null default 'not_started' check (status in ('not_started','in_progress','done')),
  created_at timestamptz not null default now(),
  unique (id, team_id, user_id)
);
create index if not exists journal_goals_owner on public.journal_goals (team_id, user_id);

create table if not exists public.journal_notes (
  id uuid primary key default gen_random_uuid(),
  goal_id uuid not null,
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  note_date date not null,
  body text not null check (char_length(btrim(body)) >= 1),
  created_at timestamptz not null default now(),
  -- a note must have the same team and owner as its goal
  constraint journal_notes_same_goal foreign key (goal_id, team_id, user_id)
    references public.journal_goals (id, team_id, user_id) on delete cascade on update cascade
);
create index if not exists journal_notes_owner on public.journal_notes (team_id, user_id);
create index if not exists journal_notes_goal on public.journal_notes (goal_id);

-- one row per player, per round. Empty until the replay parser fills it.
create table if not exists public.round_stats (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  player_username text not null,
  match_id text not null,
  round_number integer not null check (round_number >= 1),
  operator text not null,
  side text not null check (side in ('attack','defense')),
  kills integer not null default 0 check (kills >= 0),
  died boolean not null default false,
  assists integer not null default 0 check (assists >= 0),
  headshots integer not null default 0 check (headshots >= 0 and headshots <= kills),
  kost_point boolean not null default false,
  created_at timestamptz not null default now(),
  unique (team_id, match_id, round_number, user_id)
);
create index if not exists round_stats_owner on public.round_stats (team_id, user_id);

alter table public.journal_goals enable row level security;
alter table public.journal_notes enable row level security;
alter table public.round_stats enable row level security;

-- HELPER CHECKS (they bypass RLS on purpose, the same way as the ones in schema.sql)

-- the owner, admins, and this team's coaches and assistant coaches can read a player's journal and stats
create or replace function public.can_read_player_data(t uuid) returns boolean language sql security definer stable set search_path = public as
$$ select public.is_staff() or exists(select 1 from team_members tm join profiles p on p.id = tm.user_id
   where tm.team_id = t and tm.user_id = auth.uid() and not p.suspended
   and tm.roles && array['coach','assistant_coach']) $$;
-- people with the Player role on this team can keep their own journal
create or replace function public.has_player_role(t uuid) returns boolean language sql security definer stable set search_path = public as
$$ select exists(select 1 from team_members tm join profiles p on p.id = tm.user_id
   where tm.team_id = t and tm.user_id = auth.uid() and not p.suspended
   and tm.roles && array['player']) $$;

-- WHO CAN SEE AND CHANGE WHAT

-- players read their own journal; coaches, assistant coaches, admins and the owner read only
drop policy if exists journal_goals_read on public.journal_goals;
create policy journal_goals_read on public.journal_goals for select to authenticated
  using ((user_id = auth.uid() and public.is_member_of(team_id)) or public.can_read_player_data(team_id));
drop policy if exists journal_goals_write on public.journal_goals;
create policy journal_goals_write on public.journal_goals for all to authenticated
  using (user_id = auth.uid() and public.has_player_role(team_id))
  with check (user_id = auth.uid() and public.has_player_role(team_id));

drop policy if exists journal_notes_read on public.journal_notes;
create policy journal_notes_read on public.journal_notes for select to authenticated
  using ((user_id = auth.uid() and public.is_member_of(team_id)) or public.can_read_player_data(team_id));
drop policy if exists journal_notes_write on public.journal_notes;
create policy journal_notes_write on public.journal_notes for all to authenticated
  using (user_id = auth.uid() and public.has_player_role(team_id))
  with check (user_id = auth.uid() and public.has_player_role(team_id));

-- players read their own stats; coaches, assistant coaches, admins and the owner read their team's
-- nobody can write from the website yet; that permission is added when the replay parser is built
drop policy if exists round_stats_read on public.round_stats;
create policy round_stats_read on public.round_stats for select to authenticated
  using ((user_id = auth.uid() and public.is_member_of(team_id)) or public.can_read_player_data(team_id));

grant select, insert, update, delete on public.journal_goals, public.journal_notes to authenticated;
grant select on public.round_stats to authenticated;

-- tell Supabase to pick up the new tables straight away
notify pgrst, 'reload schema';
