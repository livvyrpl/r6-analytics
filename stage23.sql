-- Liv Analytics, stage 23: Google Drive for replay imports.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run stage22.sql first. This file is safe to run more than once.

-- The Google app the Parse page uses to open your Drive. These three values are public identifiers, not passwords:
-- Google only accepts them from your site's own address, and each person still signs in to their own Google account.
alter table public.site_settings
  add column if not exists google_client_id text not null default '' check (google_client_id = '' or google_client_id ~ '^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$'),
  add column if not exists google_api_key text not null default '' check (google_api_key = '' or google_api_key ~ '^AIza[0-9A-Za-z_-]{35}$'),
  add column if not exists google_project_number text not null default '' check (google_project_number = '' or google_project_number ~ '^[0-9]{6,20}$');

-- tell Supabase to pick up the new columns straight away
notify pgrst, 'reload schema';
