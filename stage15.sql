-- Liv Analytics, stage 15: remembering dead siege.gg links, so Missing data can list them.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run all the earlier stage files first. This file is safe to run more than once.

-- MATCH LIBRARY: true when siege.gg has no page for this game's link
alter table public.scout_matches
  add column if not exists gg_missing boolean not null default false;

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
