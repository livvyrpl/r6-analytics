-- STAGE 37: team date range
-- Each team can pick a date range in Team Settings. Games, vetoes, rounds, scrims, player stats and the schedule
-- outside it are hidden everywhere on the site for that team. Nothing is deleted; clearing the range shows everything again.
-- Empty "to" means no end (up to today and anything planned after).
alter table public.teams add column if not exists view_from date;
alter table public.teams add column if not exists view_to date;
notify pgrst, 'reload schema';
