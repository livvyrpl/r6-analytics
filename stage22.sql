-- Liv Analytics, stage 22: Admin panel. Site settings, activity log, data pull stats.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run all the earlier stage files first. This file is safe to run more than once.

-- SITE SETTINGS: one row, read by everyone signed in, changed only by the owner
create table if not exists public.site_settings (
  id boolean primary key default true check (id),
  announcement text not null default '' check (char_length(announcement) <= 500),
  announcement_on boolean not null default false,
  open_signups boolean not null default false,
  default_color text not null default '#e07cc0' check (default_color ~* '^#[0-9a-f]{6}$'),
  updated_at timestamptz not null default now()
);
insert into public.site_settings (id) values (true) on conflict (id) do nothing;
alter table public.site_settings enable row level security;
drop policy if exists site_settings_read on public.site_settings;
create policy site_settings_read on public.site_settings for select to authenticated using (true);
drop policy if exists site_settings_write on public.site_settings;
create policy site_settings_write on public.site_settings for update to authenticated
  using (public.is_owner()) with check (public.is_owner());
grant select, update on public.site_settings to authenticated;

-- SIGN-UPS: invite only, unless the owner opens them. Someone who signs up without an invite joins with no team.
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
declare inv invites; a jsonb;
begin
  if not exists (select 1 from profiles where site_role = 'owner') then
    insert into profiles (id, email, site_role) values (new.id, new.email, 'owner');
    return new;
  end if;
  select * into inv from invites where email = lower(new.email);
  if not found then
    if coalesce((select open_signups from site_settings where id), false) then
      insert into profiles (id, email, site_role) values (new.id, new.email, 'member');
      return new;
    end if;
    raise exception 'This email has not been invited';
  end if;
  insert into profiles (id, email, site_role) values (new.id, new.email, inv.site_role);
  for a in select * from jsonb_array_elements(inv.assignments) loop
    insert into team_members (team_id, user_id, roles)
    values ((a->>'team_id')::uuid, new.id, array(select jsonb_array_elements_text(a->'roles')))
    on conflict (team_id, user_id) do update set roles = excluded.roles;
  end loop;
  delete from invites where email = inv.email;
  return new;
end $$;

-- ACTIVITY LOG: who added, changed or removed what. Only the owner and admins can read it; nobody can edit it.
create table if not exists public.activity_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  first_at timestamptz not null default now(),
  user_id uuid,
  user_email text not null default '',
  action text not null check (action in ('added', 'changed', 'removed')),
  tbl text not null,
  team_id uuid,
  row_id text not null default '',
  summary text not null default '',
  n integer not null default 1
);
create index if not exists activity_log_at on public.activity_log (at desc);
create index if not exists activity_log_team on public.activity_log (team_id, at desc);
create index if not exists activity_log_recent on public.activity_log (tbl, user_id, at desc);
alter table public.activity_log enable row level security;
drop policy if exists activity_log_read on public.activity_log;
create policy activity_log_read on public.activity_log for select to authenticated using (public.is_staff());
revoke insert, update, delete on public.activity_log from public, anon, authenticated;
grant select on public.activity_log to authenticated;

create or replace function public.log_change() returns trigger language plpgsql security definer set search_path = public as $$
declare
  r jsonb := case when TG_OP = 'DELETE' then to_jsonb(OLD) else to_jsonb(NEW) end;
  skip text[] := array['updated_at', 'check_status', 'check_notes', 'gg_missing', 'check_sources'];
  act text := case TG_OP when 'INSERT' then 'added' when 'UPDATE' then 'changed' else 'removed' end;
  uid uuid := auth.uid(); em text := 'System'; tid uuid; rid text; s text; hit bigint;
begin
  -- an edit that changes nothing worth knowing is not logged
  if TG_OP = 'UPDATE' and (to_jsonb(NEW) - skip) = (to_jsonb(OLD) - skip) then return null; end if;
  tid := coalesce(nullif(r->>'team_id', '')::uuid, nullif(r->>'owner_team_id', '')::uuid,
                  case when TG_TABLE_NAME = 'teams' then (r->>'id')::uuid end);
  rid := coalesce(r->>'id', r->>'email', concat_ws('|', r->>'team_id', r->>'user_id', r->>'scrim_id', r->>'map'));
  s := case TG_TABLE_NAME
    when 'team_members' then (select coalesce(display_name, email) from profiles where id = (r->>'user_id')::uuid)
    when 'scrim_player_notes' then (select coalesce(display_name, email) from profiles where id = (r->>'user_id')::uuid)
    when 'journal_notes' then ''
    else coalesce(nullif(r->>'name', ''),
      case when r ? 'opponent' then concat_ws(' vs ', nullif(r->>'team', ''), nullif(r->>'opponent', '')) end,
      nullif(r->>'title', ''), nullif(r->>'email', ''), '') end;
  if r ? 'map' and coalesce(r->>'map', '') <> '' then s := concat_ws(', ', nullif(s, ''), r->>'map'); end if;
  s := left(coalesce(s, ''), 160);
  if uid is not null then select coalesce(display_name, email) into em from profiles where id = uid; end if;
  -- a run of the same change becomes one line: edits to one thing for 10 minutes, or a batch of adds or removes
  if TG_OP = 'UPDATE' then
    update activity_log set at = now(), n = n + 1 where id = (select id from activity_log
      where tbl = TG_TABLE_NAME and user_id is not distinct from uid and action = act and row_id = rid
        and at > now() - interval '10 minutes' order by at desc limit 1) returning id into hit;
  else
    update activity_log set at = now(), n = n + 1 where id = (select id from activity_log
      where tbl = TG_TABLE_NAME and user_id is not distinct from uid and action = act and team_id is not distinct from tid
        and at > now() - interval '2 minutes' order by at desc limit 1) returning id into hit;
  end if;
  if hit is null then
    insert into activity_log (user_id, user_email, action, tbl, team_id, row_id, summary)
    values (uid, coalesce(em, ''), act, TG_TABLE_NAME, tid, rid, s);
  end if;
  -- keep a year
  if random() < 0.002 then delete from activity_log where at < now() - interval '1 year'; end if;
  return null;
end $$;
revoke execute on function public.log_change() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['teams','team_members','invites','profiles','scout_teams','scout_matches','scout_vetoes',
    'scout_settings','scrims','scrim_map_results','scrim_player_notes','scrim_vod_notes','schedule_entries','strats',
    'team_roster','journal_goals','journal_notes','site_settings'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists log_change on public.%I', t);
      execute format('create trigger log_change after insert or update or delete on public.%I for each row execute function public.log_change()', t);
    end if;
  end loop;
end $$;

-- DATA PULLS: how big the Liquipedia cache is (owner and admins), and emptying it (owner only)
create or replace function public.lp_cache_stats() returns jsonb language sql security definer stable set search_path = public as
$$ select case when public.is_staff() then (select jsonb_build_object('pages', count(*), 'newest', max(fetched_at),
     'oldest', min(fetched_at), 'kb', coalesce(sum(octet_length(body)), 0) / 1024) from lp_cache) end $$;
create or replace function public.lp_cache_clear() returns integer language plpgsql security definer set search_path = public as $$
declare k integer;
begin
  if not public.is_owner() then raise exception 'Only the owner can empty the cache'; end if;
  delete from lp_cache where true; get diagnostics k = row_count; return k;
end $$;
revoke execute on function public.lp_cache_stats(), public.lp_cache_clear() from public, anon;
grant execute on function public.lp_cache_stats(), public.lp_cache_clear() to authenticated;

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
