-- Liv Analytics, stage 10: Pull from Liquipedia.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run all the earlier stage files first. This file is safe to run more than once.

-- MATCH LIBRARY: exact rounds per side, the official match ID, and the link to the official replay file
alter table public.scout_matches
  add column if not exists replay_link text not null default '',
  add column if not exists r6esports_id text not null default '',
  add column if not exists t1_atk integer, add column if not exists t1_def integer,
  add column if not exists t1_ot_atk integer, add column if not exists t1_ot_def integer,
  add column if not exists t2_atk integer, add column if not exists t2_def integer,
  add column if not exists t2_ot_atk integer, add column if not exists t2_ot_def integer;
create index if not exists scout_matches_r6 on public.scout_matches (owner_team_id, r6esports_id);

-- CACHE: pages already fetched, so the same data is never requested twice.
-- It holds public Liquipedia pages only. Row Level Security with no rules means only the Edge Function can use it.
create table if not exists public.lp_cache (
  key text primary key,
  revid bigint,
  body text not null,
  fetched_at timestamptz not null default now()
);
alter table public.lp_cache enable row level security;
revoke all on public.lp_cache from public, anon, authenticated;

-- RATE LIMIT: shared by every running copy of the function, so the limits hold whatever happens
create table if not exists public.lp_rate (
  kind text primary key,
  next_at timestamptz not null default now()
);
alter table public.lp_rate enable row level security;
revoke all on public.lp_rate from public, anon, authenticated;

-- books the next free slot and says how many milliseconds to wait for it
create or replace function public.lp_slot(p_kind text, p_gap_ms integer) returns integer
language plpgsql security definer set search_path = public as $$
declare slot timestamptz;
begin
  insert into lp_rate (kind, next_at) values (p_kind, now() + make_interval(secs => p_gap_ms / 1000.0))
  on conflict (kind) do update set next_at = greatest(lp_rate.next_at, now()) + make_interval(secs => p_gap_ms / 1000.0)
  returning next_at - make_interval(secs => p_gap_ms / 1000.0) into slot;
  return greatest(0, ceil(extract(epoch from slot - now()) * 1000))::integer;
end $$;
revoke execute on function public.lp_slot(text, integer) from public, anon, authenticated;
grant execute on function public.lp_slot(text, integer) to service_role;

-- tell Supabase to pick up the changes straight away
notify pgrst, 'reload schema';
