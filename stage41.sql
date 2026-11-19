-- STAGE 41: things that fill in on their own, with nobody on the site
-- Every 15 minutes Supabase runs the auto-fill Edge Function. It reads op bans, the map veto, the map order and scoreboards
-- from official and siege.gg pages for games that have a match ID, and sets scores to what complete rounds add up to.
-- Before running this, create the auto-fill Edge Function (auto-fill.ts) in Supabase > Edge Functions.

-- when a game was last checked against its official / siege.gg page, so it is not read again every 15 minutes
alter table public.scout_matches add column if not exists src_checked_at timestamptz;

-- the timer (pg_cron) and the web request it makes (pg_net), both part of Supabase
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- run auto-fill every 15 minutes. The key below is the site's public key (the same one in index.html), not a secret.
select cron.unschedule('liv-auto-fill') where exists (select 1 from cron.job where jobname = 'liv-auto-fill');
select cron.schedule('liv-auto-fill', '*/15 * * * *', $$
  select net.http_post(
    url := 'https://hyfycayfadqjhxucpfnm.supabase.co/functions/v1/auto-fill',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', 'sb_publishable_91fUHDwka-sQOMN5A8J8CQ_KyfQVsc7', 'Authorization', 'Bearer sb_publishable_91fUHDwka-sQOMN5A8J8CQ_KyfQVsc7'),
    body := '{}'::jsonb,
    timeout_milliseconds := 140000
  );
$$);

notify pgrst, 'reload schema';
