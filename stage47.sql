-- Stage 47: a game can be marked as having no VOD, so Missing data stops asking for one
alter table public.scout_matches add column if not exists no_vod boolean not null default false;
