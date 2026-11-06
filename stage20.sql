-- Liv Analytics, stage 20: a second VOD link for each map of a scrim.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run stage19.sql first. This file is safe to run more than once.

alter table public.scrim_map_results
  add column if not exists vod_link_2 text not null default '';

alter table public.scrim_map_results drop constraint if exists scrim_map_results_vod_link_2;
alter table public.scrim_map_results add constraint scrim_map_results_vod_link_2
  check (vod_link_2 = '' or (vod_link_2 ~* '^https?://' and char_length(vod_link_2) <= 1000));

-- tell Supabase to pick up the new column straight away
notify pgrst, 'reload schema';
