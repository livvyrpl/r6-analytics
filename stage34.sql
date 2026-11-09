-- STAGE 34: merging and combining teams no longer times out
-- Merging two teams, or combining two copies of a team, renames their games. Each renamed game has its rounds
-- looked up by the game's id, written as lower(btrim(match_id)); nothing let the database jump straight to those,
-- so every renamed game searched all of the saved rounds. With tens of thousands of rounds from replays this ran
-- past Supabase's time limit ("canceling statement due to statement timeout").
-- These indexes match exactly how the rounds and games are looked up. Nothing else changes. Safe to run more than once.

create index if not exists scout_rounds_owner_ref on public.scout_rounds (owner_team_id, lower(btrim(match_id)), round_number);
create index if not exists scout_rounds_owner_day on public.scout_rounds (owner_team_id, round_date);
create index if not exists scout_matches_owner_team_name on public.scout_matches (owner_team_id, lower(btrim(team)));
create index if not exists scout_matches_owner_opp_name on public.scout_matches (owner_team_id, lower(btrim(opponent)));
create index if not exists scout_vetoes_owner_team_name on public.scout_vetoes (owner_team_id, lower(btrim(team)));
create index if not exists scout_vetoes_owner_opp_name on public.scout_vetoes (owner_team_id, lower(btrim(opponent)));
create index if not exists player_round_stats_game_round on public.player_round_stats (scout_match_id, round_number, player_key);
create index if not exists prep_logs_round on public.prep_logs (scout_round_id);

analyze public.scout_rounds; analyze public.scout_matches; analyze public.scout_vetoes; analyze public.player_round_stats; analyze public.prep_logs;
