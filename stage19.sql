-- Liv Analytics, stage 19: a VOD link for each map of a scrim.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run stage5.sql and stage6.sql first. This file is safe to run more than once.

alter table public.scrim_map_results
  add column if not exists vod_link text not null default '';

alter table public.scrim_map_results drop constraint if exists scrim_map_results_vod_link;
alter table public.scrim_map_results add constraint scrim_map_results_vod_link
  check (vod_link = '' or (vod_link ~* '^https?://' and char_length(vod_link) <= 1000));

-- tell Supabase to pick up the new column straight away
notify pgrst, 'reload schema';
