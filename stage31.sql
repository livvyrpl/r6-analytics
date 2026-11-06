-- Liv Analytics, stage 31: a team is the same in Admin and on every Scouting page, colour, logo and aliases included.
-- Paste this whole file into Supabase > SQL Editor > Run. Run stage30.sql first. Safe to run more than once.
--
-- Kept in step both ways from now on: name, aliases, region, league, colour, logo and Liquipedia link.
-- A change on a Scouting page changes the team in Admin and every other Scouting copy; a change in Admin changes every Scouting copy.

-- logos the site can show (Liquipedia image links can't be shown)
create or replace function public.logo_shows(u text) returns boolean language sql immutable as $$
  select coalesce(u, '') ~ '^https://' and coalesce(u, '') !~* 'liquipedia\.net'
$$;
-- a list of names without blanks, repeats or the team's own name
create or replace function public.alias_set(l text[], own text) returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct btrim(x) order by btrim(x)), '{}') from unnest(coalesce(l, '{}')) x
  where btrim(x) <> '' and lower(btrim(x)) <> lower(btrim(coalesce(own, '')))
$$;

-- 1. THE SITE TEAM'S DETAILS GO TO EVERY SCOUTING COPY (all but p_skip). A renamed copy keeps its old name as an alias.
create or replace function public.push_team_to_copies(p_team uuid, p_skip uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t teams; s scout_teams;
begin
  select * into t from teams where id = p_team;
  if t.id is null then return; end if;
  for s in select * from scout_teams where site_team_id = t.id and id is distinct from p_skip loop
    begin
      update scout_teams set
        name = btrim(t.name),
        aliases = alias_set(coalesce(t.aliases, '{}') || case when name_key <> lower(btrim(t.name)) then array[name] else '{}'::text[] end, t.name),
        region = coalesce(t.region, ''), league = coalesce(t.league, ''), color = coalesce(t.color, color), logo_url = coalesce(t.logo_url, ''),
        source_ids = case when coalesce(t.liquipedia, '') <> '' then source_ids || jsonb_build_object('liquipedia', t.liquipedia) else source_ids - 'liquipedia' end
      where id = s.id;
    exception when others then null;  -- that list already has another team with this name: merge them in Manage Teams
    end;
  end loop;
end $$;
revoke execute on function public.push_team_to_copies(uuid, uuid) from public, anon, authenticated;

drop trigger if exists sync_team_to_scout on public.teams;
create trigger sync_team_to_scout after update of name, aliases, region, league, color, logo_url, liquipedia on public.teams
  for each row when (old.name is distinct from new.name or old.aliases is distinct from new.aliases or old.region is distinct from new.region
    or old.league is distinct from new.league or old.color is distinct from new.color or old.logo_url is distinct from new.logo_url
    or old.liquipedia is distinct from new.liquipedia)
  execute function public.sync_team_to_scout();

-- 2. A SCOUTING COPY CHANGED: the site team takes it, then every other copy
create or replace function public.sync_scout_to_team() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 or new.site_team_id is null then return new; end if;
  begin
    update teams set
      name = btrim(new.name),
      aliases = alias_set(coalesce(new.aliases, '{}') || case when lower(btrim(name)) <> lower(btrim(new.name)) then array[name] else '{}'::text[] end, new.name),
      region = nullif(new.region, ''), league = nullif(new.league, ''), color = new.color, logo_url = nullif(new.logo_url, ''),
      liquipedia = coalesce(new.source_ids ->> 'liquipedia', '')
    where id = new.site_team_id;
    perform push_team_to_copies(new.site_team_id, new.id);
  exception when others then null;
  end;
  return new;
end $$;
drop trigger if exists sync_scout_to_team on public.scout_teams;
create trigger sync_scout_to_team after update of name, aliases, region, league, color, logo_url, source_ids on public.scout_teams
  for each row when (old.name is distinct from new.name or old.aliases is distinct from new.aliases or old.region is distinct from new.region
    or old.league is distinct from new.league or old.color is distinct from new.color or old.logo_url is distinct from new.logo_url
    or (old.source_ids ->> 'liquipedia') is distinct from (new.source_ids ->> 'liquipedia'))
  execute function public.sync_scout_to_team();

-- 3. CATCH UP: every site team takes the colour, logo and aliases of its best Scouting copy
-- (a copy with its own colour and a logo that shows first, then the most filled in, then the oldest).
-- The default pink is not a chosen colour, and a logo that shows always beats one that doesn't.
update public.teams t set
  color = case when lower(coalesce(s.color, '')) not in ('', '#e07cc0') then s.color else t.color end,
  logo_url = case when logo_shows(s.logo_url) then s.logo_url when logo_shows(t.logo_url) then t.logo_url else coalesce(nullif(s.logo_url, ''), t.logo_url) end,
  aliases = alias_set(coalesce(t.aliases, '{}') || coalesce(s.aliases, '{}'), t.name)
from (
  select distinct on (site_team_id) site_team_id, color, logo_url, aliases
  from public.scout_teams
  where site_team_id is not null
  order by site_team_id,
    (lower(coalesce(color, '')) not in ('', '#e07cc0'))::int + logo_shows(logo_url)::int desc,
    ((coalesce(league, '') <> '')::int + (coalesce(region, '') not in ('', 'Other'))::int + coalesce(cardinality(aliases), 0)) desc,
    created_at
) s
where s.site_team_id = t.id;
-- the update above already reached every copy through the sync, but a team whose details didn't change is brought in line too
do $$ declare t uuid; begin
  for t in select id from teams loop perform push_team_to_copies(t, null); end loop;
end $$;

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
