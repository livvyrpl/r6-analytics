-- 2D replays: where every player was in each round, saved when replays are read on the Import page.
-- Files go in a private bucket, one folder per team: <team id>/<replay match id>/R<round>.json.gz
-- Only that team's coaches, assistant coaches and analysts (and site staff) can read or add them.
insert into storage.buckets (id, name, public) values ('replays', 'replays', false) on conflict do nothing;

drop policy if exists replays_read on storage.objects;
create policy replays_read on storage.objects for select to authenticated
  using (bucket_id = 'replays' and public.can_see_scrims(((storage.foldername(name))[1])::uuid));
drop policy if exists replays_add on storage.objects;
create policy replays_add on storage.objects for insert to authenticated
  with check (bucket_id = 'replays' and public.can_edit_scrims(((storage.foldername(name))[1])::uuid));
drop policy if exists replays_edit on storage.objects;
create policy replays_edit on storage.objects for update to authenticated
  using (bucket_id = 'replays' and public.can_edit_scrims(((storage.foldername(name))[1])::uuid));
drop policy if exists replays_remove on storage.objects;
create policy replays_remove on storage.objects for delete to authenticated
  using (bucket_id = 'replays' and public.can_edit_scrims(((storage.foldername(name))[1])::uuid));

-- How each map's floor plans line up with the positions in replays (set in Admin, Default Plans, Replay maps).
alter table public.site_settings add column if not exists replay_maps jsonb not null default '{}';
