-- Liv Analytics, stage 27: merging Anti-Strat rounds into one strat.
-- Paste this whole file into Supabase > SQL Editor > Run. Run stage25.sql first. Safe to run more than once.

-- Rounds that share a strat_id are one strat, even when an operator or two changed.
-- Rounds without one are grouped by their operators, as before.
alter table public.prep_logs add column if not exists strat_id uuid;
create index if not exists prep_logs_strat on public.prep_logs (strat_id) where strat_id is not null;

-- tell Supabase to pick up the change straight away
notify pgrst, 'reload schema';
