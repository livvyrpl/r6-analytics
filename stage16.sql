-- Liv Analytics, stage 16: every scouted team is also a team on the site, and teams can be deleted.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run all the earlier stage files first. This file is safe to run more than once.

-- the same team under a different spelling: "Cloud 9" and "Cloud9" count as one
create or replace function public.team_key(t text) returns text language sql immutable as
$$ select lower(regexp_replace(coalesce(t, ''), '[^a-zA-Z0-9]', '', 'g')) $$;

-- finds the site team with this name or alias, or creates it
create or replace function public.site_team_for(p_name text, p_region text, p_league text, p_color text, p_logo text)
returns uuid language plpgsql security definer set search_path = public as $$
declare found uuid;
begin
  select t.id into found from teams t
  where team_key(p_name) <> ''
    and (team_key(t.name) = team_key(p_name)
      or exists (select 1 from unnest(t.aliases) a where team_key(a) = team_key(p_name)))
  order by t.created_at limit 1;
  if found is null then
    insert into teams (name, region, league, color, logo_url)
    values (btrim(p_name), nullif(p_region, ''), nullif(p_league, ''), coalesce(nullif(p_color, ''), '#e07cc0'), nullif(p_logo, ''))
    returning id into found;
  end if;
  return found;
end $$;

-- runs however a scouted team is added: the Add opponent form, a Liquipedia pull, or a replay
create or replace function public.link_scout_team() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.site_team_id is null then
    new.site_team_id := site_team_for(new.name, new.region, new.league, new.color, new.logo_url);
  end if;
  return new;
end $$;
drop trigger if exists scout_teams_link on public.scout_teams;
create trigger scout_teams_link before insert on public.scout_teams
  for each row execute function public.link_scout_team();

-- only the trigger uses these, nobody can call them directly
revoke execute on function public.site_team_for(text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.link_scout_team() from public, anon, authenticated;

-- scouted teams already there
do $$
declare r record;
begin
  for r in select id, name, region, league, color, logo_url from public.scout_teams where site_team_id is null order by created_at loop
    update public.scout_teams set site_team_id = public.site_team_for(r.name, r.region, r.league, r.color, r.logo_url) where id = r.id;
  end loop;
end $$;

-- deleting a site team also removes it from everyone's scouted opponents. Games and vetoes other teams saved stay in their libraries.
alter table public.scout_teams drop constraint if exists scout_teams_site_team_id_fkey;
alter table public.scout_teams add constraint scout_teams_site_team_id_fkey
  foreign key (site_team_id) references public.teams(id) on delete cascade;

-- a deleted team is taken off pending invites, otherwise that person could not sign up
create or replace function public.clean_invites_for_team() returns trigger language plpgsql security definer set search_path = public as $$
begin
  update invites set assignments = (
    select coalesce(jsonb_agg(a), '[]'::jsonb) from jsonb_array_elements(assignments) a where a ->> 'team_id' <> old.id::text)
  where assignments @> jsonb_build_array(jsonb_build_object('team_id', old.id));
  return old;
end $$;
revoke execute on function public.clean_invites_for_team() from public, anon, authenticated;
drop trigger if exists teams_clean_invites on public.teams;
create trigger teams_clean_invites before delete on public.teams
  for each row execute function public.clean_invites_for_team();

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
