-- Liv Analytics, schedule. Paste this whole file into Supabase > SQL Editor > Run.
-- Run schema.sql first. This file adds to it and is safe to run more than once.

-- assistant coaches can now add, edit and delete scrims, the same as coaches
create or replace function public.can_edit_scrims(t uuid) returns boolean language sql security definer stable set search_path = public as
$$ select public.is_staff() or exists(select 1 from team_members tm join profiles p on p.id = tm.user_id
   where tm.team_id = t and tm.user_id = auth.uid() and not p.suspended
   and tm.roles && array['coach','assistant_coach','analyst']) $$;

create table if not exists public.schedule_entries (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  kind text not null check (kind in ('scrim','gameday','off_day')),
  title text not null check (char_length(btrim(title)) between 1 and 120),
  entry_date date not null,
  entry_time time,
  notes text not null default '',
  opponent text,
  maps text[] not null default '{}',
  -- whose off day it is; empty means the whole team
  user_id uuid references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  -- off days have no opponent or maps; only off days belong to one person
  check (kind = 'off_day' or user_id is null),
  check (kind <> 'off_day' or (opponent is null and maps = '{}'))
);
create index if not exists schedule_team_date on public.schedule_entries (team_id, entry_date);

alter table public.schedule_entries enable row level security;

-- helper checks (they bypass RLS on purpose, the same way as the ones in schema.sql)
create or replace function public.can_edit_schedule(t uuid) returns boolean language sql security definer stable set search_path = public as
$$ select public.is_staff() or exists(select 1 from team_members tm join profiles p on p.id = tm.user_id
   where tm.team_id = t and tm.user_id = auth.uid() and not p.suspended
   and tm.roles && array['coach','assistant_coach']) $$;
create or replace function public.is_team_player(t uuid) returns boolean language sql security definer stable set search_path = public as
$$ select exists(select 1 from team_members tm join profiles p on p.id = tm.user_id
   where tm.team_id = t and tm.user_id = auth.uid() and not p.suspended
   and tm.roles && array['player']) $$;

-- the whole team can see the schedule
drop policy if exists schedule_read on public.schedule_entries;
create policy schedule_read on public.schedule_entries for select to authenticated
  using (public.is_staff() or public.is_member_of(team_id));
-- coaches, assistant coaches, the owner and admins can change everything
drop policy if exists schedule_write on public.schedule_entries;
create policy schedule_write on public.schedule_entries for all to authenticated
  using (public.can_edit_schedule(team_id)) with check (public.can_edit_schedule(team_id));
-- players can add, change and remove only their own off days
drop policy if exists schedule_own_off_add on public.schedule_entries;
create policy schedule_own_off_add on public.schedule_entries for insert to authenticated
  with check (kind = 'off_day' and user_id = auth.uid() and public.is_team_player(team_id));
drop policy if exists schedule_own_off_edit on public.schedule_entries;
create policy schedule_own_off_edit on public.schedule_entries for update to authenticated
  using (kind = 'off_day' and user_id = auth.uid() and public.is_team_player(team_id))
  with check (kind = 'off_day' and user_id = auth.uid() and public.is_team_player(team_id));
drop policy if exists schedule_own_off_remove on public.schedule_entries;
create policy schedule_own_off_remove on public.schedule_entries for delete to authenticated
  using (kind = 'off_day' and user_id = auth.uid() and public.is_team_player(team_id));

grant select, insert, update, delete on public.schedule_entries to authenticated;
