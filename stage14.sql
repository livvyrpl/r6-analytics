-- Liv Analytics, stage 14: linked teams, opponent rosters with roles, and match check details.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run all the earlier stage files first. This file is safe to run more than once.

-- SCOUTING: which team on the site a scouted team is, and its roster with roles and other names
alter table public.scout_teams
  add column if not exists site_team_id uuid references public.teams(id) on delete set null,
  add column if not exists roster jsonb not null default '[]';

-- MATCH LIBRARY: what each source said, so a disagreement can show who says what
alter table public.scout_matches
  add column if not exists check_sources jsonb not null default '[]';

-- link scouted teams to site teams with the same name, ignoring spaces, capitals and punctuation
update public.scout_teams s set site_team_id = t.id
from public.teams t
where s.site_team_id is null
  and lower(regexp_replace(s.name, '[^a-zA-Z0-9]', '', 'g')) = lower(regexp_replace(t.name, '[^a-zA-Z0-9]', '', 'g'));

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
