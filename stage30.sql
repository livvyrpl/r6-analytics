-- Liv Analytics, stage 30: site teams take their region, league, logo and Liquipedia link from Scouting.
-- Paste this whole file into Supabase > SQL Editor > Run. Run stage29.sql first. Safe to run more than once.
--
-- Teams made before stage 28 kept whatever region they were created with (often Other), while their Scouting copy
-- was filled in later. For each team this takes the best Scouting copy: one with a real region first, then the one
-- with the most filled in, then the oldest (usually the one a coach set up by hand). The stage 28 sync then gives
-- every other Scouting copy of the team the same details.

update public.teams t set
  region = case when coalesce(s.region, '') not in ('', 'Other') then s.region else t.region end,
  league = coalesce(nullif(s.league, ''), t.league),
  logo_url = case when coalesce(t.logo_url, '') = '' and coalesce(s.logo_url, '') <> '' and s.logo_url !~* 'liquipedia\.net' then s.logo_url else t.logo_url end,
  liquipedia = case when coalesce(t.liquipedia, '') = '' then coalesce(s.source_ids ->> 'liquipedia', '') else t.liquipedia end
from (
  select distinct on (site_team_id) site_team_id, region, league, logo_url, source_ids
  from public.scout_teams
  where site_team_id is not null
  order by site_team_id,
    (coalesce(region, '') not in ('', 'Other')) desc,
    ((coalesce(league, '') <> '')::int + (coalesce(logo_url, '') <> '')::int + (coalesce(source_ids ->> 'liquipedia', '') <> '')::int) desc,
    created_at
) s
where s.site_team_id = t.id
  and (t.region is distinct from case when coalesce(s.region, '') not in ('', 'Other') then s.region else t.region end
    or t.league is distinct from coalesce(nullif(s.league, ''), t.league)
    or (coalesce(t.logo_url, '') = '' and coalesce(s.logo_url, '') <> '' and s.logo_url !~* 'liquipedia\.net')
    or (coalesce(t.liquipedia, '') = '' and coalesce(s.source_ids ->> 'liquipedia', '') <> ''));

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
