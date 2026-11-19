-- STAGE 42: auto-fill runs every 5 minutes instead of every 15 (each run now reads 6 series at a time for about 2 minutes).
-- Update the auto-fill Edge Function with the new auto-fill.ts first, then run this.
select cron.unschedule('liv-auto-fill') where exists (select 1 from cron.job where jobname = 'liv-auto-fill');
select cron.schedule('liv-auto-fill', '*/5 * * * *', $$
  select net.http_post(
    url := 'https://hyfycayfadqjhxucpfnm.supabase.co/functions/v1/auto-fill',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', 'sb_publishable_91fUHDwka-sQOMN5A8J8CQ_KyfQVsc7', 'Authorization', 'Bearer sb_publishable_91fUHDwka-sQOMN5A8J8CQ_KyfQVsc7'),
    body := '{}'::jsonb,
    timeout_milliseconds := 150000
  );
$$);
