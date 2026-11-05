-- Liv Analytics, stage 6: score, split and starting side on each map of a scrim.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run schema.sql, stage2.sql and stage5.sql first. This file is safe to run more than once.

alter table public.scrim_map_results
  add column if not exists score text,
  add column if not exists split text,
  add column if not exists started_on text;

alter table public.scrim_map_results
  drop constraint if exists scrim_map_results_score_format,
  drop constraint if exists scrim_map_results_split_format,
  drop constraint if exists scrim_map_results_started_on;

-- maps that already have rounds entered get a score worked out from them
update public.scrim_map_results
  set score = (atk_won + def_won) || '-' || (atk_lost + def_lost)
  where score is null and atk_won + def_won + atk_lost + def_lost > 0;

alter table public.scrim_map_results
  add constraint scrim_map_results_score_format check (score is null or score ~ '^[0-9]+-[0-9]+$'),
  add constraint scrim_map_results_split_format check (split is null or split ~ '^[0-9]+-[0-9]+$'),
  add constraint scrim_map_results_started_on check (started_on is null or started_on in ('attack','defense'));

-- tell Supabase to pick up the new columns straight away
notify pgrst, 'reload schema';
