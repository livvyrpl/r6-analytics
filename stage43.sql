-- STAGE 43: auto-fill, one series per request
-- Every 5 minutes the database picks up to 40 series with an official or siege.gg match ID that are due a check, and sends
-- the auto-fill Edge Function one request per series (plus one for the score check). Each request is small, and no function
-- calls another, which Supabase limits. Update the auto-fill Edge Function with the new auto-fill.ts first, then run this.

-- when a series was last sent to auto-fill, so one that keeps failing is tried every 30 minutes, not every 5
alter table public.scout_matches add column if not exists src_tried_at timestamptz;

create or replace function public.liv_auto_fill_dispatch(p_limit integer default 40) returns integer
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n integer := 0;
  k text := 'sb_publishable_91fUHDwka-sQOMN5A8J8CQ_KyfQVsc7'; -- the site's public key (the same one in index.html), not a secret
  u text := 'https://hyfycayfadqjhxucpfnm.supabase.co/functions/v1/auto-fill';
  h jsonb;
begin
  h := jsonb_build_object('Content-Type', 'application/json', 'apikey', k, 'Authorization', 'Bearer ' || k);
  for r in
    select owner_team_id as owner, coalesce(nullif(r6esports_id, ''), '') as r6,
           case when coalesce(r6esports_id, '') = '' then coalesce(siegegg_id, '') else '' end as gg, max(match_date) as d
    from scout_matches
    where (coalesce(r6esports_id, '') <> '' or coalesce(siegegg_id, '') <> '')
      and (src_tried_at is null or src_tried_at < now() - interval '30 minutes')
      and (src_checked_at is null
           or (src_checked_at < now() - interval '1 day' and match_date >= current_date - 45)
           or src_checked_at < now() - interval '7 days')
    group by 1, 2, 3
    order by d desc
    limit p_limit
  loop
    update scout_matches set src_tried_at = now()
      where owner_team_id = r.owner and ((r.r6 <> '' and r6esports_id = r.r6) or (r.r6 = '' and siegegg_id = r.gg));
    perform net.http_post(url := u, headers := h, body := jsonb_build_object('owner', r.owner, 'r6', r.r6, 'gg', r.gg), timeout_milliseconds := 60000);
    n := n + 1;
  end loop;
  perform net.http_post(url := u, headers := h, body := '{"scores":true}'::jsonb, timeout_milliseconds := 140000);
  return n;
end $$;
revoke execute on function public.liv_auto_fill_dispatch(integer) from public, anon, authenticated;

-- every 5 minutes
select cron.unschedule('liv-auto-fill') where exists (select 1 from cron.job where jobname = 'liv-auto-fill');
select cron.schedule('liv-auto-fill', '*/5 * * * *', 'select public.liv_auto_fill_dispatch()');
