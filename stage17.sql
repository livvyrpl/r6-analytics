-- Liv Analytics, stage 17: Falcons and Falcons Esports count as the same team.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run all the earlier stage files first. This file is safe to run more than once.

-- a team's name without words like Esports, Gaming and Team
create or replace function public.team_core(t text) returns text language sql immutable as $$
  select coalesce(nullif(
    lower(regexp_replace(
      regexp_replace(lower(coalesce(t, '')), '\m(e[ -]?sports?|gaming|team|club|gg|the)\M', '', 'g'),
      '[^a-z0-9]', '', 'g')), ''), public.team_key(t))
$$;

-- finds the site team with this name or alias, or creates it
create or replace function public.site_team_for(p_name text, p_region text, p_league text, p_color text, p_logo text)
returns uuid language plpgsql security definer set search_path = public as $$
declare found uuid;
begin
  select t.id into found from teams t
  where team_key(p_name) <> ''
    and (team_core(t.name) = team_core(p_name)
      or exists (select 1 from unnest(t.aliases) a where team_core(a) = team_core(p_name)))
  order by t.created_at limit 1;
  if found is null then
    insert into teams (name, region, league, color, logo_url)
    values (btrim(p_name), nullif(p_region, ''), nullif(p_league, ''), coalesce(nullif(p_color, ''), '#e07cc0'), nullif(p_logo, ''))
    returning id into found;
  end if;
  return found;
end $$;
revoke execute on function public.site_team_for(text, text, text, text, text) from public, anon, authenticated;

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
