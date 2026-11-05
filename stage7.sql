-- Liv Analytics, stage 7: strats.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run schema.sql and stage2.sql first. This file is safe to run more than once.

create table if not exists public.strats (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  map text not null check (char_length(btrim(map)) between 1 and 120),
  side text not null check (side in ('attack','defense')),
  -- only real Google Slides links can be saved, because the site opens them in a frame
  slides_url text not null check (slides_url ~ '^https://docs\.google\.com/presentation/d/(e/)?[A-Za-z0-9_-]+/(edit|pub)$'),
  notes text not null default '',
  created_at timestamptz not null default now(),
  unique (id, team_id)
);
create index if not exists strats_team on public.strats (team_id);

-- when each person last opened a strat, for "recently opened" on the coach overview
create table if not exists public.strat_opens (
  strat_id uuid not null,
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  opened_at timestamptz not null default now(),
  primary key (strat_id, user_id),
  constraint strat_opens_same_team foreign key (strat_id, team_id)
    references public.strats (id, team_id) on delete cascade on update cascade
);
create index if not exists strat_opens_user on public.strat_opens (user_id, opened_at desc);

alter table public.strats enable row level security;
alter table public.strat_opens enable row level security;

-- this team's members, plus the owner and admins, can see its strats
drop policy if exists strats_read on public.strats;
create policy strats_read on public.strats for select to authenticated
  using (public.is_staff() or public.is_member_of(team_id));
-- coaches, assistant coaches, the owner and admins can add, edit and delete them
drop policy if exists strats_write on public.strats;
create policy strats_write on public.strats for all to authenticated
  using (public.can_edit_schedule(team_id)) with check (public.can_edit_schedule(team_id));

-- people record and see only their own opens; the owner and admins can see everything
drop policy if exists strat_opens_read on public.strat_opens;
create policy strat_opens_read on public.strat_opens for select to authenticated
  using (public.is_staff() or (user_id = auth.uid() and public.is_member_of(team_id)));
drop policy if exists strat_opens_add on public.strat_opens;
create policy strat_opens_add on public.strat_opens for insert to authenticated
  with check (user_id = auth.uid() and (public.is_staff() or public.is_member_of(team_id)));
drop policy if exists strat_opens_edit on public.strat_opens;
create policy strat_opens_edit on public.strat_opens for update to authenticated
  using (user_id = auth.uid() and (public.is_staff() or public.is_member_of(team_id)))
  with check (user_id = auth.uid() and (public.is_staff() or public.is_member_of(team_id)));

grant select, insert, update, delete on public.strats to authenticated;
grant select, insert, update on public.strat_opens to authenticated;

-- tell Supabase to pick up the new tables straight away
notify pgrst, 'reload schema';
