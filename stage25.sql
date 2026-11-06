-- Liv Analytics, stage 25: Anti-Strat rounds and map blueprints.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run stage24.sql first. This file is safe to run more than once.

-- Each logged round can now have a strat title, where each operator was on the map,
-- and the time in the VOD where the round starts.
alter table public.prep_logs add column if not exists title text not null default '';
alter table public.prep_logs add column if not exists pins jsonb not null default '[]';
alter table public.prep_logs add column if not exists vod_at integer;
alter table public.prep_logs drop constraint if exists prep_logs_title_len;
alter table public.prep_logs add constraint prep_logs_title_len check (char_length(title) <= 120);
alter table public.prep_logs drop constraint if exists prep_logs_pins_ok;
alter table public.prep_logs add constraint prep_logs_pins_ok check (jsonb_typeof(pins) = 'array' and jsonb_array_length(pins) <= 15);
alter table public.prep_logs drop constraint if exists prep_logs_vod_at_ok;
alter table public.prep_logs add constraint prep_logs_vod_at_ok check (vod_at is null or (vod_at >= 0 and vod_at < 360000));

-- Map blueprints: one picture per floor of each map, shared by every team on the site.
-- Only the site owner and admins add them, in Admin > Map Blueprints
create table if not exists public.map_blueprints (
  id uuid primary key default gen_random_uuid(),
  map text not null check (char_length(btrim(map)) between 1 and 100),
  floor text not null check (char_length(btrim(floor)) between 1 and 60),
  sort integer not null default 0,
  image_url text not null check (image_url ~ '^https://' and char_length(image_url) <= 1000),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists map_blueprints_map on public.map_blueprints (map);
alter table public.map_blueprints enable row level security;
drop policy if exists map_blueprints_read on public.map_blueprints;
create policy map_blueprints_read on public.map_blueprints for select to authenticated using (true);
drop policy if exists map_blueprints_write on public.map_blueprints;
create policy map_blueprints_write on public.map_blueprints for all to authenticated
  using (public.is_staff()) with check (public.is_staff());
grant select, insert, update, delete on public.map_blueprints to authenticated;
drop trigger if exists log_change on public.map_blueprints;
create trigger log_change after insert or update or delete on public.map_blueprints for each row execute function public.log_change();

-- where the blueprint pictures are kept
insert into storage.buckets (id, name, public) values ('blueprints', 'blueprints', true) on conflict do nothing;
drop policy if exists blueprints_read on storage.objects;
create policy blueprints_read on storage.objects for select using (bucket_id = 'blueprints');
drop policy if exists blueprints_add on storage.objects;
create policy blueprints_add on storage.objects for insert to authenticated with check (bucket_id = 'blueprints' and public.is_staff());
drop policy if exists blueprints_edit on storage.objects;
create policy blueprints_edit on storage.objects for update to authenticated using (bucket_id = 'blueprints' and public.is_staff());
drop policy if exists blueprints_remove on storage.objects;
create policy blueprints_remove on storage.objects for delete to authenticated using (bucket_id = 'blueprints' and public.is_staff());

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
