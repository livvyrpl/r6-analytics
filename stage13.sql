-- Liv Analytics, stage 13: team aliases.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run all the earlier stage files first. This file is safe to run more than once.

-- other names a team goes by in replay files, like SR for Shopify Rebellion
alter table public.scout_teams add column if not exists aliases text[] not null default '{}';
alter table public.teams add column if not exists aliases text[] not null default '{}';

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
