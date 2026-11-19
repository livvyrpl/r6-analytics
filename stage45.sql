-- STAGE 45: "Not the same" on the Missing data page
-- A "Join with ..." suggestion you say no to is remembered here (per team), so it is not offered again.
alter table public.scout_settings add column if not exists not_joined jsonb not null default '[]';
