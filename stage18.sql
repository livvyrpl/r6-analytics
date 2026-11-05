-- Liv Analytics, stage 18: merging two scouted teams, data included.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run all the earlier stage files first. This file is safe to run more than once.

-- the same Match ID the site builds, so rounds stay attached to their game when a team name changes
create or replace function public.scout_match_ref(d date, t text, o text, m text, ph text) returns text language sql immutable as $$
  with s as (select regexp_replace(upper(coalesce(t, '')), '[^A-Z0-9]+', '', 'g') a,
                    regexp_replace(upper(coalesce(o, '')), '[^A-Z0-9]+', '', 'g') b,
                    regexp_replace(upper(coalesce(m, '')), '[^A-Z0-9]+', '', 'g') c,
                    regexp_replace(upper(coalesce(ph, '')), '[^A-Z0-9]+', '', 'g') e)
  select concat_ws('-', to_char(d, 'YYYYMMDD'),
    nullif(case when a collate "C" <= b collate "C" then a else b end, ''),
    nullif(case when a collate "C" <= b collate "C" then b else a end, ''),
    nullif(c, ''), nullif(e, '')) from s
$$;

-- Everything happens together or not at all. The page works out the duplicates and shows them first:
-- p_drop is [{keep, drop}] for games, p_vdrop is veto ids to remove, p_self is games where the two teams played "each other".
create or replace function public.merge_scout_teams(p_from uuid, p_to uuid, p_names text[], p_drop jsonb, p_vdrop uuid[], p_self uuid[], p_team jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a scout_teams; c scout_teams; own uuid; names text[]; k scout_matches; d scout_matches; g scout_matches; item jsonb;
  old_ref text; new_ref text; same boolean; moved int := 0; removed int := 0; vmoved int := 0; rmoved int := 0;
  s_from uuid; s_to uuid; owned boolean := false; v boolean; r record;
begin
  select * into a from scout_teams where id = p_from;
  select * into c from scout_teams where id = p_to;
  if a.id is null or c.id is null then raise exception 'One of these teams no longer exists.'; end if;
  if a.id = c.id then raise exception 'Choose two different teams.'; end if;
  if a.owner_team_id <> c.owner_team_id then raise exception 'These teams belong to different scouting lists.'; end if;
  own := a.owner_team_id;
  if not can_edit_scrims(own) then raise exception 'You do not have permission to make that change.'; end if;
  select array_agg(distinct lower(btrim(n))) into names from unnest(array_append(coalesce(p_names, '{}'), a.name)) n where btrim(n) <> '';

  -- duplicates: the kept game takes anything it was missing, then the other copy goes
  for item in select * from jsonb_array_elements(coalesce(p_drop, '[]'::jsonb)) loop
    select * into k from scout_matches where id = (item ->> 'keep')::uuid and owner_team_id = own;
    select * into d from scout_matches where id = (item ->> 'drop')::uuid and owner_team_id = own;
    if k.id is null or d.id is null or k.id = d.id then raise exception 'A duplicate game could not be found. Refresh and try again.'; end if;
    old_ref := scout_match_ref(d.match_date, d.team, d.opponent, d.map, d.phase);
    new_ref := scout_match_ref(k.match_date, k.team, k.opponent, k.map, k.phase);
    delete from player_round_stats s where s.scout_match_id = d.id and exists (
      select 1 from player_round_stats x where x.scout_match_id = k.id and x.round_number = s.round_number and x.player_key = s.player_key);
    update player_round_stats set scout_match_id = k.id where scout_match_id = d.id;
    delete from scout_rounds x where x.owner_team_id = own and lower(btrim(x.match_id)) = lower(old_ref) and exists (
      select 1 from scout_rounds y where y.owner_team_id = own and lower(btrim(y.match_id)) = lower(new_ref) and y.round_number = x.round_number);
    update scout_rounds set match_id = new_ref where owner_team_id = own and lower(btrim(match_id)) = lower(old_ref);
    same := (lower(btrim(k.team)) = any(names) or lower(btrim(k.team)) = lower(btrim(c.name))) = (lower(btrim(d.team)) = any(names) or lower(btrim(d.team)) = lower(btrim(c.name)));
    delete from scout_matches where id = d.id;
    update scout_matches set
      league = coalesce(nullif(league, ''), d.league), vod_link = coalesce(nullif(vod_link, ''), d.vod_link),
      source_name = coalesce(nullif(source_name, ''), d.source_name), source_link = coalesce(nullif(source_link, ''), d.source_link),
      replay_link = coalesce(nullif(replay_link, ''), d.replay_link), replay_status = coalesce(nullif(replay_status, ''), d.replay_status),
      r6esports_id = coalesce(nullif(r6esports_id, ''), d.r6esports_id), siegegg_id = coalesce(nullif(siegegg_id, ''), d.siegegg_id),
      replay_match_id = coalesce(nullif(replay_match_id, ''), d.replay_match_id),
      check_sources = case when check_sources = '[]'::jsonb then d.check_sources else check_sources end,
      our_team_index = coalesce(our_team_index, d.our_team_index), replay_t1_index = coalesce(replay_t1_index, case when same then d.replay_t1_index else 1 - d.replay_t1_index end),
      round_score = case when round_score <> '' then round_score when same then d.round_score else '' end,
      result = case when result <> '' then result when same then d.result else '' end,
      our_atk_ban = case when our_atk_ban <> '' then our_atk_ban when same then d.our_atk_ban else d.opp_atk_ban end,
      our_def_ban = case when our_def_ban <> '' then our_def_ban when same then d.our_def_ban else d.opp_def_ban end,
      opp_atk_ban = case when opp_atk_ban <> '' then opp_atk_ban when same then d.opp_atk_ban else d.our_atk_ban end,
      opp_def_ban = case when opp_def_ban <> '' then opp_def_ban when same then d.opp_def_ban else d.our_def_ban end
    where id = k.id;
    removed := removed + 1;
  end loop;

  -- games listing these two names against each other, which can't be real once they are one team
  for g in select * from scout_matches where id = any(coalesce(p_self, '{}')) and owner_team_id = own loop
    delete from scout_rounds where owner_team_id = own and lower(btrim(match_id)) = lower(scout_match_ref(g.match_date, g.team, g.opponent, g.map, g.phase));
    delete from scout_matches where id = g.id;
    removed := removed + 1;
  end loop;

  -- every remaining game moves to the kept team's name, and its rounds stay attached
  for g in select * from scout_matches where owner_team_id = own and (lower(btrim(team)) = any(names) or lower(btrim(opponent)) = any(names)) loop
    old_ref := scout_match_ref(g.match_date, g.team, g.opponent, g.map, g.phase);
    update scout_matches set
      team = case when lower(btrim(team)) = any(names) then c.name else team end,
      opponent = case when lower(btrim(opponent)) = any(names) then c.name else opponent end,
      picked_by = case when lower(btrim(picked_by)) = any(names) then c.name else picked_by end,
      scout_team_id = case when scout_team_id = a.id then c.id else scout_team_id end,
      check_status = case when check_status = 'reviewed' then check_status else '' end
    where id = g.id returning * into g;
    new_ref := scout_match_ref(g.match_date, g.team, g.opponent, g.map, g.phase);
    if new_ref <> old_ref then
      delete from scout_rounds x where x.owner_team_id = own and lower(btrim(x.match_id)) = lower(old_ref) and exists (
        select 1 from scout_rounds y where y.owner_team_id = own and lower(btrim(y.match_id)) = lower(new_ref) and y.round_number = x.round_number);
      update scout_rounds set match_id = new_ref where owner_team_id = own and lower(btrim(match_id)) = lower(old_ref);
    end if;
    moved := moved + 1;
  end loop;

  delete from scout_vetoes where id = any(coalesce(p_vdrop, '{}')) and owner_team_id = own;
  update scout_vetoes set
    team = case when lower(btrim(team)) = any(names) then c.name else team end,
    opponent = case when lower(btrim(opponent)) = any(names) then c.name else opponent end
  where owner_team_id = own and (lower(btrim(team)) = any(names) or lower(btrim(opponent)) = any(names));
  get diagnostics vmoved = row_count;

  update scout_rounds set
    team = case when lower(btrim(team)) = any(names) then c.name else team end,
    opponent = case when lower(btrim(opponent)) = any(names) then c.name else opponent end
  where owner_team_id = own and (lower(btrim(team)) = any(names) or lower(btrim(opponent)) = any(names));
  get diagnostics rmoved = row_count;

  update player_round_stats set team_name = c.name where owner_team_id = own and lower(btrim(team_name)) = any(names);

  -- the kept team takes the other one's names, roster and notes
  update scout_teams set
    aliases = coalesce((select array_agg(x) from jsonb_array_elements_text(p_team -> 'aliases') x), aliases),
    players = coalesce((select array_agg(x) from jsonb_array_elements_text(p_team -> 'players') x), players),
    roster = coalesce(p_team -> 'roster', roster),
    coach_notes = coalesce(p_team ->> 'coach_notes', coach_notes),
    site_team_id = coalesce(site_team_id, a.site_team_id)
  where id = c.id returning site_team_id into s_to;
  s_from := a.site_team_id;
  delete from scout_teams where id = a.id;
  update teams set name = c.name, aliases = (select array_agg(distinct x) from unnest(array_append(aliases, name)) x)
    where id = s_to and name <> c.name and team_core(name) = team_core(c.name);

  -- the site team: others tracking it follow, members move if an owner or admin is doing this, and an empty leftover goes
  if s_from is not null and s_to is not null and s_from <> s_to then
    update scout_teams set site_team_id = s_to where site_team_id = s_from;
    update teams set aliases = (select array_agg(distinct x) from unnest(array_append(aliases, a.name)) x) where id = s_to;
    if is_staff() then
      insert into team_members (team_id, user_id, roles) select s_to, user_id, roles from team_members where team_id = s_from
        on conflict (team_id, user_id) do update set roles = (select array_agg(distinct x) from unnest(team_members.roles || excluded.roles) x);
      delete from team_members where team_id = s_from;
    end if;
    for r in select conrelid::regclass t, att.attname col from pg_constraint con
      join pg_attribute att on att.attrelid = con.conrelid and att.attnum = con.conkey[1]
      where con.contype = 'f' and con.confrelid = 'public.teams'::regclass loop
      execute format('select exists(select 1 from %s where %I = $1)', r.t, r.col) using s_from into v;
      if v then owned := true; end if;
    end loop;
    if not owned then delete from teams where id = s_from; end if;
  end if;
  return jsonb_build_object('moved', moved, 'removed', removed, 'vetoes', vmoved, 'rounds', rmoved, 'kept_site_team', owned);
end $$;
revoke execute on function public.merge_scout_teams(uuid, uuid, text[], jsonb, uuid[], uuid[], jsonb) from public, anon;
grant execute on function public.merge_scout_teams(uuid, uuid, text[], jsonb, uuid[], uuid[], jsonb) to authenticated;

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
