-- STAGE 33: speed
-- Every page asks "may this person see this row?" for each row it reads. That check looked up the person's teams again
-- for every single row, which is slow now that replays have added tens of thousands of rows.
-- This works out the person's teams once per request instead, with exactly the same rules, and adds indexes
-- so long lists are read in order without sorting the whole table each time. Safe to run more than once.

-- the teams this person can see scouting and scrims for (owner and admins: every team)
create or replace function public.my_see_teams() returns uuid[] language sql security definer stable set search_path = public as
$$ select case when public.is_staff() then coalesce((select array_agg(id) from teams), '{}')
   else coalesce((select array_agg(tm.team_id) from team_members tm join profiles p on p.id = tm.user_id
     where tm.user_id = auth.uid() and not p.suspended and tm.roles && array['coach','assistant_coach','analyst']), '{}') end $$;
-- the teams this person can change scouting and scrims for (the same people today, kept apart like before)
create or replace function public.my_edit_teams() returns uuid[] language sql security definer stable set search_path = public as
$$ select case when public.is_staff() then coalesce((select array_agg(id) from teams), '{}')
   else coalesce((select array_agg(tm.team_id) from team_members tm join profiles p on p.id = tm.user_id
     where tm.user_id = auth.uid() and not p.suspended and tm.roles && array['coach','assistant_coach','analyst']), '{}') end $$;
-- the teams this person is a member of
create or replace function public.my_member_teams() returns uuid[] language sql security definer stable set search_path = public as
$$ select coalesce((select array_agg(tm.team_id) from team_members tm join profiles p on p.id = tm.user_id
     where tm.user_id = auth.uid() and not p.suspended), '{}') $$;
grant execute on function public.my_see_teams() to authenticated;
grant execute on function public.my_edit_teams() to authenticated;
grant execute on function public.my_member_teams() to authenticated;

-- every rule that used the per-row checks now uses the once-per-request lists
do $$
declare p record; q text; c text;
  fix constant text[] := array['can_see_scrims','my_see_teams','can_edit_scrims','my_edit_teams','is_member_of','my_member_teams'];
  i int;
begin
  for p in select * from pg_policies where schemaname = 'public'
    and (coalesce(qual, '') ~ '(can_see_scrims|can_edit_scrims|is_member_of)\(' or coalesce(with_check, '') ~ '(can_see_scrims|can_edit_scrims|is_member_of)\(') loop
    q := p.qual; c := p.with_check;
    for i in 0..2 loop
      q := regexp_replace(q, '(public\.)?' || fix[i*2+1] || '\(([a-z_.]+)\)', '(\2 = ANY ((SELECT public.' || fix[i*2+2] || '())::uuid[]))', 'g');
      c := regexp_replace(c, '(public\.)?' || fix[i*2+1] || '\(([a-z_.]+)\)', '(\2 = ANY ((SELECT public.' || fix[i*2+2] || '())::uuid[]))', 'g');
    end loop;
    if q is not null and c is not null then execute format('alter policy %I on public.%I using (%s) with check (%s)', p.policyname, p.tablename, q, c);
    elsif q is not null then execute format('alter policy %I on public.%I using (%s)', p.policyname, p.tablename, q);
    elsif c is not null then execute format('alter policy %I on public.%I with check (%s)', p.policyname, p.tablename, c);
    end if;
  end loop;
end $$;

-- long lists are read 1,000 rows at a time in id order
create index if not exists scout_matches_owner_id on public.scout_matches (owner_team_id, id);
create index if not exists scout_vetoes_owner_id on public.scout_vetoes (owner_team_id, id);
create index if not exists scout_rounds_owner_id on public.scout_rounds (owner_team_id, id);
create index if not exists player_round_stats_owner_id on public.player_round_stats (owner_team_id, id);
create index if not exists player_round_stats_owner_match on public.player_round_stats (owner_team_id, match_id);
create index if not exists scout_matches_owner_replay on public.scout_matches (owner_team_id, replay_match_id);
analyze public.scout_matches; analyze public.scout_vetoes; analyze public.scout_rounds; analyze public.player_round_stats;
