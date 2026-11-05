-- Liv Analytics, scrims. Paste this whole file into Supabase > SQL Editor > Run.
-- Run schema.sql first. This file adds to it and is safe to run more than once.

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

alter table public.scrims enable row level security;
alter table public.scrim_player_notes enable row level security;

-- helper checks (they bypass RLS on purpose, the same way as the ones in schema.sql)
-- coaches, assistant coaches, analysts, the owner and admins can see a team's scrims
create or replace function public.can_see_scrims(t uuid) returns boolean language sql security definer stable set search_path = public as
$$ select public.is_staff() or exists(select 1 from team_members tm join profiles p on p.id = tm.user_id
   where tm.team_id = t and tm.user_id = auth.uid() and not p.suspended
   and tm.roles && array['coach','assistant_coach','analyst']) $$;
-- so can they add, edit and delete them
create or replace function public.can_edit_scrims(t uuid) returns boolean language sql security definer stable set search_path = public as
$$ select public.is_staff() or exists(select 1 from team_members tm join profiles p on p.id = tm.user_id
   where tm.team_id = t and tm.user_id = auth.uid() and not p.suspended
   and tm.roles && array['coach','assistant_coach','analyst']) $$;

-- who can see and change what
drop policy if exists scrims_read on public.scrims;
create policy scrims_read on public.scrims for select to authenticated
  using (public.can_see_scrims(team_id));
drop policy if exists scrims_write on public.scrims;
create policy scrims_write on public.scrims for all to authenticated
  using (public.can_edit_scrims(team_id)) with check (public.can_edit_scrims(team_id));

drop policy if exists scrim_notes_read on public.scrim_player_notes;
create policy scrim_notes_read on public.scrim_player_notes for select to authenticated
  using (exists(select 1 from public.scrims s where s.id = scrim_player_notes.scrim_id and public.can_see_scrims(s.team_id)));
drop policy if exists scrim_notes_write on public.scrim_player_notes;
create policy scrim_notes_write on public.scrim_player_notes for all to authenticated
  using (exists(select 1 from public.scrims s where s.id = scrim_player_notes.scrim_id and public.can_edit_scrims(s.team_id)))
  with check (exists(select 1 from public.scrims s where s.id = scrim_player_notes.scrim_id and public.can_edit_scrims(s.team_id)));

grant select, insert, update, delete on public.scrims, public.scrim_player_notes to authenticated;
