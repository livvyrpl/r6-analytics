-- Liv Analytics, stage 29: rounds always stay with their game.
-- Paste this whole file into Supabase > SQL Editor > Run. Run stage28.sql first. Safe to run more than once.
--
-- Rounds point at their game by an id made of the date, both team names, the map and the stage.
-- When a game was renamed or combined with another copy (for example a replay saved as "FIVE FEARS vs FOR FUN"
-- and then the Liquipedia game "For Fun Esports vs Five Fears, Group Stage"), its rounds could be left behind,
-- and importing the replay again saved every round a second time.

-- a team as one key: the Scouting team whose name or alias it matches, ignoring capitals, spaces and words like Esports
create or replace function public.scout_team_key(p_owner uuid, n text) returns text language sql stable set search_path = public as $$
  select coalesce((select team_core(s.name) from scout_teams s
    where s.owner_team_id = p_owner and (team_core(s.name) = team_core(n) or exists (select 1 from unnest(s.aliases) a where team_core(a) = team_core(n)))
    order by s.created_at limit 1), team_core(n))
$$;
create or replace function public.scout_pair_key(p_owner uuid, a text, b text) returns text language sql stable set search_path = public as $$
  select least(scout_team_key(p_owner, a), scout_team_key(p_owner, b)) || '|' || greatest(scout_team_key(p_owner, a), scout_team_key(p_owner, b))
$$;
create or replace function public.map_key(m text) returns text language sql immutable as $$
  select regexp_replace(lower(coalesce(m, '')), '[^a-z]', '', 'g')
$$;

-- rounds whose id matches no game, for the same day, map and teams as game g, join g.
-- A round g already has (same round number) is a duplicate: its Anti-Strat notes move over if g's round has none, then it goes.
create or replace function public.scout_adopt_rounds(g public.scout_matches) returns integer
language plpgsql security definer set search_path = public as $$
declare ref text := scout_match_ref(g.match_date, g.team, g.opponent, g.map, g.phase); pair text := scout_pair_key(g.owner_team_id, g.team, g.opponent);
  o scout_rounds; k scout_rounds; n integer := 0;
begin
  for o in select r.* from scout_rounds r
    where r.owner_team_id = g.owner_team_id and r.round_date = g.match_date and map_key(r.map) = map_key(g.map)
      and lower(btrim(r.match_id)) <> lower(ref)
      and not exists (select 1 from scout_matches x where x.owner_team_id = r.owner_team_id and x.match_date = r.round_date
        and lower(scout_match_ref(x.match_date, x.team, x.opponent, x.map, x.phase)) = lower(btrim(r.match_id)))
      and scout_pair_key(g.owner_team_id, r.team, r.opponent) = pair loop
    select * into k from scout_rounds where owner_team_id = o.owner_team_id and lower(btrim(match_id)) = lower(ref) and round_number = o.round_number
      order by created_at limit 1;
    if k.id is null then
      begin
        update scout_rounds set match_id = ref where id = o.id;
      exception when unique_violation then null;
      end;
    else
      update prep_logs p set scout_round_id = k.id where p.scout_round_id = o.id
        and not exists (select 1 from prep_logs q where q.scout_round_id = k.id and q.owner_team_id = p.owner_team_id);
      delete from scout_rounds where id = o.id;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.scout_adopt_rounds(public.scout_matches) from public, anon, authenticated;

-- a game added or renamed: its rounds follow, and any left behind for it join it
create or replace function public.scout_rounds_follow() returns trigger
language plpgsql security definer set search_path = public as $$
declare old_ref text; new_ref text;
begin
  if tg_op = 'UPDATE' then
    old_ref := scout_match_ref(old.match_date, old.team, old.opponent, old.map, old.phase);
    new_ref := scout_match_ref(new.match_date, new.team, new.opponent, new.map, new.phase);
    if lower(old_ref) <> lower(new_ref) then
      -- a round the renamed game already has under its new id is a duplicate
      delete from scout_rounds x where x.owner_team_id = new.owner_team_id and lower(btrim(x.match_id)) = lower(old_ref) and exists (
        select 1 from scout_rounds y where y.owner_team_id = new.owner_team_id and lower(btrim(y.match_id)) = lower(new_ref) and y.round_number = x.round_number);
      update scout_rounds set match_id = new_ref where owner_team_id = new.owner_team_id and lower(btrim(match_id)) = lower(old_ref);
    end if;
  end if;
  perform scout_adopt_rounds(new);
  return new;
end $$;
drop trigger if exists scout_rounds_follow on public.scout_matches;
create trigger scout_rounds_follow after insert or update of match_date, team, opponent, map, phase on public.scout_matches
  for each row execute function public.scout_rounds_follow();

-- CLEAN UP what is already there: every game takes back its left-behind rounds, and the second copies go
do $$ declare g scout_matches; n integer := 0; begin
  for g in select * from scout_matches order by created_at loop
    n := n + scout_adopt_rounds(g);
  end loop;
  raise notice 'Rounds put back with their game or removed as duplicates: %', n;
end $$;

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
