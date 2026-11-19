-- STAGE 38: map pictures
-- The site owner can upload their own picture for each map in Admin > Site Settings. It is used everywhere on the site
-- instead of the built-in picture. Stored as { "Bank": "https://...", ... }; an empty list means the built-in pictures.
alter table public.site_settings add column if not exists map_photos jsonb not null default '{}'::jsonb;
notify pgrst, 'reload schema';
