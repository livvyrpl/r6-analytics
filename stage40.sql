-- STAGE 40: scoreboards
-- One row per player per map: typed in on a game's edit page, or read from the official match page.
-- side 1 is the game's Team 1, side 2 is Team 2. Deleting a game deletes its scoreboard.
create table if not exists public.scout_scoreboard (
  id uuid primary key default gen_random_uuid(),
  owner_team_id uuid not null references public.teams(id) on delete cascade,
  scout_match_id uuid not null references public.scout_matches(id) on delete cascade,
  side smallint not null check (side in (1, 2)),
  slot smallint not null check (slot between 1 and 6),
  player text not null default '',
  kills integer check (kills >= 0),
  deaths integer check (deaths >= 0),
  assists integer check (assists >= 0),
  headshots integer check (headshots >= 0),
  opening_kills integer check (opening_kills >= 0),
  opening_deaths integer check (opening_deaths >= 0),
  kost numeric check (kost >= 0 and kost <= 100),
  plants integer check (plants >= 0),
  clutches integer check (clutches >= 0),
  source text not null default 'manual',
  updated_at timestamptz not null default now(),
  unique (scout_match_id, side, slot)
);
create index if not exists scout_scoreboard_owner on public.scout_scoreboard (owner_team_id);

-- same people as the rest of the scouting data: this team's coaches, assistant coaches and analysts, plus the owner and admins
alter table public.scout_scoreboard enable row level security;
drop policy if exists scout_scoreboard_read on public.scout_scoreboard;
create policy scout_scoreboard_read on public.scout_scoreboard for select to authenticated using (public.can_see_scrims(owner_team_id));
drop policy if exists scout_scoreboard_write on public.scout_scoreboard;
create policy scout_scoreboard_write on public.scout_scoreboard for all to authenticated
  using (public.can_edit_scrims(owner_team_id)) with check (public.can_edit_scrims(owner_team_id));
grant select, insert, update, delete on public.scout_scoreboard to authenticated;
-- a map whose scoreboard can't be found: marked No data on its edit page, so it is not flagged as missing
alter table public.scout_matches add column if not exists board_none boolean not null default false;
notify pgrst, 'reload schema';
