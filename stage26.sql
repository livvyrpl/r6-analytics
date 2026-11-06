-- Liv Analytics, stage 26: a Liquipedia link on each team, set in Team Settings.
-- Paste this whole file into Supabase > SQL Editor > Run. Safe to run more than once.

-- the Liquipedia page name, for example Cloud9 (from https://liquipedia.net/rainbowsix/Cloud9)
alter table public.teams add column if not exists liquipedia text not null default '';
alter table public.teams drop constraint if exists teams_liquipedia_len;
alter table public.teams add constraint teams_liquipedia_len check (char_length(liquipedia) <= 200);

-- fill it in from any scouted copy of the team that already has its link saved
update public.teams t set liquipedia = s.lp
from (select distinct on (site_team_id) site_team_id, source_ids->>'liquipedia' as lp
      from public.scout_teams
      where site_team_id is not null and coalesce(source_ids->>'liquipedia','') <> ''
      order by site_team_id, created_at) s
where s.site_team_id = t.id and t.liquipedia = '';

-- tell Supabase to pick up the change straight away
notify pgrst, 'reload schema';
