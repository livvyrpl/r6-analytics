-- Liv Analytics, stage 36: a game in Missing data can be marked as resolved, when the missing information can't be found.
-- Paste this whole file into Supabase > SQL Editor > Run. Safe to run more than once.

-- true once someone marks the game resolved in Missing data; it then stops showing there (Undo brings it back)
alter table public.scout_matches add column if not exists gaps_resolved boolean not null default false;

-- tell Supabase to pick up the change straight away
notify pgrst, 'reload schema';
