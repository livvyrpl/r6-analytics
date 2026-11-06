-- Liv Analytics, stage 28: site teams and scouted teams are the same teams.
-- Paste this whole file into Supabase > SQL Editor > Run. Run stage27.sql first. Safe to run more than once.
--
-- * Every scouted team already gets a site team (stage 16). Now every site team also shows on every Scouting page.
-- * Changing a team's name, region, league, colour, logo or Liquipedia link in one place changes it everywhere.
-- * Admin > Manage Teams merges two teams across every Scouting list at once.

-- 1. PUT EVERY SITE TEAM ON A SCOUTING LIST (a team is never on its own list)
create or replace function public.scout_fill(p_owner uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer := 0; t teams;
begin
  if not can_edit_scrims(p_owner) then return 0; end if;
  for t in select * from teams x where x.id <> p_owner
    and not exists (select 1 from scout_teams s where s.owner_team_id = p_owner and s.site_team_id = x.id) loop
    begin
      insert into scout_teams (owner_team_id, name, region, league, color, logo_url, site_team_id, source_ids)
      values (p_owner, btrim(t.name), coalesce(t.region, ''), coalesce(t.league, ''), coalesce(t.color, '#e07cc0'), coalesce(t.logo_url, ''), t.id,
              case when coalesce(t.liquipedia, '') <> '' then jsonb_build_object('liquipedia', t.liquipedia) else '{}'::jsonb end)
      on conflict (owner_team_id, name_key) do update set site_team_id = coalesce(scout_teams.site_team_id, excluded.site_team_id);
      n := n + 1;
    exception when others then null;  -- a bad logo link or the like: skip that one team
    end;
  end loop;
  return n;
end $$;
revoke execute on function public.scout_fill(uuid) from public, anon;
grant execute on function public.scout_fill(uuid) to authenticated;

-- every team already using Scouting gets the missing teams now
do $$ declare o uuid; t teams; begin
  for o in select distinct owner_team_id from scout_teams loop
    for t in select * from teams x where x.id <> o
      and not exists (select 1 from scout_teams s where s.owner_team_id = o and s.site_team_id = x.id) loop
      begin
        insert into scout_teams (owner_team_id, name, region, league, color, logo_url, site_team_id, source_ids)
        values (o, btrim(t.name), coalesce(t.region, ''), coalesce(t.league, ''), coalesce(t.color, '#e07cc0'), coalesce(t.logo_url, ''), t.id,
                case when coalesce(t.liquipedia, '') <> '' then jsonb_build_object('liquipedia', t.liquipedia) else '{}'::jsonb end)
        on conflict (owner_team_id, name_key) do update set site_team_id = coalesce(scout_teams.site_team_id, excluded.site_team_id);
      exception when others then null;
      end;
    end loop;
  end loop;
end $$;

-- 2. KEEP THE DETAILS THE SAME EVERYWHERE
-- a site team changed: every scouted copy follows. A renamed copy keeps its old name as an alias so its games still match.
-- copies the site team's details onto its scouted copies (all but p_skip)
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
        aliases = case when name_key <> lower(btrim(t.name)) then (select coalesce(array_agg(distinct x), '{}') from unnest(array_append(aliases, name)) x where lower(btrim(x)) <> lower(btrim(t.name))) else aliases end,
        region = coalesce(t.region, ''), league = coalesce(t.league, ''), color = coalesce(t.color, color), logo_url = coalesce(t.logo_url, ''),
        source_ids = case when coalesce(t.liquipedia, '') <> '' then source_ids || jsonb_build_object('liquipedia', t.liquipedia) else source_ids - 'liquipedia' end
      where id = s.id;
    exception when others then null;  -- that list already has another team with this name: merge them in Manage Teams
    end;
  end loop;
end $$;
revoke execute on function public.push_team_to_copies(uuid, uuid) from public, anon, authenticated;

create or replace function public.sync_team_to_scout() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 then return new; end if;
  perform push_team_to_copies(new.id, null);
  return new;
end $$;
drop trigger if exists sync_team_to_scout on public.teams;
create trigger sync_team_to_scout after update of name, region, league, color, logo_url, liquipedia on public.teams
  for each row when (old.name is distinct from new.name or old.region is distinct from new.region or old.league is distinct from new.league
    or old.color is distinct from new.color or old.logo_url is distinct from new.logo_url or old.liquipedia is distinct from new.liquipedia)
  execute function public.sync_team_to_scout();

-- a scouted copy changed on a Scouting page: the site team follows, and through it every other copy
create or replace function public.sync_scout_to_team() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 or new.site_team_id is null then return new; end if;
  begin
    update teams set
      name = btrim(new.name),
      aliases = case when lower(btrim(name)) <> lower(btrim(new.name)) then (select coalesce(array_agg(distinct x), '{}') from unnest(array_append(aliases, name)) x where lower(btrim(x)) <> lower(btrim(new.name))) else aliases end,
      region = nullif(new.region, ''), league = nullif(new.league, ''), color = new.color, logo_url = nullif(new.logo_url, ''),
      liquipedia = coalesce(new.source_ids ->> 'liquipedia', '')
    where id = new.site_team_id;
    perform push_team_to_copies(new.site_team_id, new.id);
  exception when others then null;
  end;
  return new;
end $$;
drop trigger if exists sync_scout_to_team on public.scout_teams;
create trigger sync_scout_to_team after update of name, region, league, color, logo_url, source_ids on public.scout_teams
  for each row when (old.name is distinct from new.name or old.region is distinct from new.region or old.league is distinct from new.league
    or old.color is distinct from new.color or old.logo_url is distinct from new.logo_url
    or (old.source_ids ->> 'liquipedia') is distinct from (new.source_ids ->> 'liquipedia'))
  execute function public.sync_scout_to_team();

-- 3. MANAGE TEAMS (owner and admins)
-- what belongs to a team besides its members and its place on Scouting lists: scrims, schedule, its own Scouting list and so on
create or replace function public.site_team_usage(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; n bigint; out jsonb := '{}';
begin
  if not is_staff() then raise exception 'Only the owner and admins can do this.'; end if;
  for r in select conrelid::regclass t, att.attname col from pg_constraint con
    join pg_attribute att on att.attrelid = con.conrelid and att.attnum = con.conkey[1]
    where con.contype = 'f' and con.confrelid = 'public.teams'::regclass loop
    if r.t::text in ('team_members', 'public.team_members') then continue; end if;
    if r.t::text in ('scout_teams', 'public.scout_teams') and r.col = 'site_team_id' then continue; end if;
    execute format('select count(*) from %s where %I = $1', r.t, r.col) using p_id into n;
    if n > 0 then out := out || jsonb_build_object(replace(r.t::text, 'public.', ''), n); end if;
  end loop;
  return out;
end $$;
revoke execute on function public.site_team_usage(uuid) from public, anon;
grant execute on function public.site_team_usage(uuid) to authenticated;

-- the last step of a merge, once each Scouting list's copies were merged: the kept team takes the other's names,
-- members and missing details, every leftover copy points at it, and the other team goes if nothing else is on it
create or replace function public.merge_site_teams(p_from uuid, p_to uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a teams; c teams; left_over jsonb;
begin
  if not is_staff() then raise exception 'Only the owner and admins can merge teams.'; end if;
  select * into a from teams where id = p_from;
  select * into c from teams where id = p_to;
  if c.id is null then raise exception 'The team to keep no longer exists.'; end if;
  -- already removed by a Scouting list merge: just bring every copy's name in line
  if a.id is null then perform push_team_to_copies(c.id, null); return jsonb_build_object('removed', true); end if;
  if a.id = c.id then raise exception 'Choose two different teams.'; end if;
  update scout_teams set site_team_id = c.id,
    aliases = (select coalesce(array_agg(distinct x), '{}') from unnest(array_append(aliases, a.name)) x where lower(btrim(x)) <> name_key)
    where site_team_id = a.id;
  update teams set
    aliases = (select coalesce(array_agg(distinct x), '{}') from unnest(coalesce(c.aliases, '{}') || coalesce(a.aliases, '{}') || array[a.name]) x where lower(btrim(x)) <> lower(btrim(c.name))),
    region = coalesce(c.region, a.region), league = coalesce(c.league, a.league), logo_url = coalesce(c.logo_url, a.logo_url),
    liquipedia = case when coalesce(c.liquipedia, '') <> '' then c.liquipedia else coalesce(a.liquipedia, '') end
  where id = c.id;
  insert into team_members (team_id, user_id, roles) select c.id, user_id, roles from team_members where team_id = a.id
    on conflict (team_id, user_id) do update set roles = (select array_agg(distinct x) from unnest(team_members.roles || excluded.roles) x);
  delete from team_members where team_id = a.id;
  perform push_team_to_copies(c.id, null);  -- every copy now carries the kept team's name, the old one as an alias
  left_over := site_team_usage(a.id);
  if left_over = '{}'::jsonb then delete from teams where id = a.id; return jsonb_build_object('removed', true); end if;
  return jsonb_build_object('removed', false, 'left', left_over);
end $$;
revoke execute on function public.merge_site_teams(uuid, uuid) from public, anon;
grant execute on function public.merge_site_teams(uuid, uuid) to authenticated;

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
