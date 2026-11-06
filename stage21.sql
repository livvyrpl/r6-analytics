-- Liv Analytics, stage 21: timestamp notes on scrim VODs, with roster players tagged.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run stage9.sql (roster) and stage19.sql first. This file is safe to run more than once.

create table if not exists public.scrim_vod_notes (
  id uuid primary key default gen_random_uuid(),
  scrim_id uuid not null,
  team_id uuid not null references public.teams(id) on delete cascade,
  map text not null default '',
  vod smallint not null default 1 check (vod in (1, 2)),
  at_seconds integer not null default 0 check (at_seconds >= 0 and at_seconds < 360000),
  body text not null default '' check (char_length(body) <= 4000),
  roster_ids uuid[] not null default '{}',
  -- copied from the scrim so a tagged player can see what the note is about without seeing the scrims themselves
  scrim_date date,
  opponent text not null default '',
  vod_url text not null default '' check (vod_url = '' or (vod_url ~* '^https?://' and char_length(vod_url) <= 1000)),
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  -- a note belongs to the same team as its scrim, and goes when the scrim is deleted
  constraint scrim_vod_notes_same_team foreign key (scrim_id, team_id)
    references public.scrims (id, team_id) on delete cascade on update cascade
);
create index if not exists scrim_vod_notes_team on public.scrim_vod_notes (team_id);
create index if not exists scrim_vod_notes_scrim on public.scrim_vod_notes (scrim_id);

-- the roster names linked to the person signed in, on one team
create or replace function public.my_roster_ids(p_team uuid) returns uuid[]
language sql security definer stable set search_path = public as
$$ select coalesce(array_agg(id), '{}') from team_roster where team_id = p_team and linked_user_id = auth.uid() $$;
revoke all on function public.my_roster_ids(uuid) from public;
grant execute on function public.my_roster_ids(uuid) to authenticated;

alter table public.scrim_vod_notes enable row level security;

-- coaches, assistant coaches, analysts, the owner and admins see every note;
-- a player sees only the notes their roster name is tagged in
drop policy if exists scrim_vod_notes_read on public.scrim_vod_notes;
create policy scrim_vod_notes_read on public.scrim_vod_notes for select to authenticated
  using (public.can_see_scrims(team_id) or roster_ids && public.my_roster_ids(team_id));
-- only the people who can edit scrims can add, change or remove notes
drop policy if exists scrim_vod_notes_write on public.scrim_vod_notes;
create policy scrim_vod_notes_write on public.scrim_vod_notes for all to authenticated
  using (public.can_edit_scrims(team_id)) with check (public.can_edit_scrims(team_id));
grant select, insert, update, delete on public.scrim_vod_notes to authenticated;

-- tell Supabase to pick up the new table straight away
notify pgrst, 'reload schema';
