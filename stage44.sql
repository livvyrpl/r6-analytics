-- STAGE 44: games with no official or siege.gg ID look for their official match by date and teams
-- Every 5 minutes, besides the series that have an ID, up to 20 series with no ID are sent to auto-fill, which looks them up
-- on the official calendar. When exactly one official match has those two teams on that date, every map gets its ID and is
-- filled in. A game that is not on the calendar (a scrim, say) is looked for again after 3 days.
-- Update the auto-fill and match-bans Edge Functions with the new files first, then run this.

alter table public.scout_matches add column if not exists src_find_at timestamptz;

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
  -- series with an ID that are due a check
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
  -- series with no ID: look for the official match by date and teams
  for r in
    select owner_team_id as owner, match_date as d, min(team) as team, min(opponent) as opponent
    from scout_matches
    where coalesce(r6esports_id, '') = '' and coalesce(siegegg_id, '') = ''
      and coalesce(team, '') <> '' and coalesce(opponent, '') <> ''
      and (src_find_at is null or src_find_at < now() - interval '3 days')
    group by owner_team_id, match_date, least(lower(team), lower(opponent)), greatest(lower(team), lower(opponent))
    order by match_date desc
    limit 20
  loop
    update scout_matches set src_find_at = now()
      where owner_team_id = r.owner and match_date = r.d and coalesce(r6esports_id, '') = '' and coalesce(siegegg_id, '') = ''
        and least(lower(team), lower(opponent)) = least(lower(r.team), lower(r.opponent))
        and greatest(lower(team), lower(opponent)) = greatest(lower(r.team), lower(r.opponent));
    perform net.http_post(url := u, headers := h, body := jsonb_build_object('owner', r.owner, 'find', jsonb_build_object('date', r.d, 'team', r.team, 'opponent', r.opponent)), timeout_milliseconds := 60000);
    n := n + 1;
  end loop;
  perform net.http_post(url := u, headers := h, body := '{"scores":true}'::jsonb, timeout_milliseconds := 140000);
  return n;
end $$;
revoke execute on function public.liv_auto_fill_dispatch(integer) from public, anon, authenticated;
