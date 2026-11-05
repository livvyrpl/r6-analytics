-- Liv Analytics, stage 1. Paste this whole file into Supabase > SQL Editor > Run.

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text,
  site_role text not null default 'member' check (site_role in ('owner','admin','member')),
  suspended boolean not null default false,
  created_at timestamptz not null default now()
);
create table public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  region text, league text,
  color text not null default '#e07cc0',
  logo_url text,
  created_at timestamptz not null default now()
);
create table public.team_members (
  team_id uuid references public.teams(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  roles text[] not null default '{}',
  primary key (team_id, user_id),
  check (roles <@ array['coach','assistant_coach','analyst','player'])
);
create table public.invites (
  email text primary key,
  site_role text not null default 'member' check (site_role in ('admin','member')),
  assignments jsonb not null default '[]',
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
alter table public.teams enable row level security;
alter table public.team_members enable row level security;
alter table public.invites enable row level security;

-- helper checks (they bypass RLS on purpose so policies don't loop)
create function public.is_staff() returns boolean language sql security definer stable set search_path = public as
$$ select exists(select 1 from profiles where id = auth.uid() and site_role in ('owner','admin') and not suspended) $$;
create function public.is_owner() returns boolean language sql security definer stable set search_path = public as
$$ select exists(select 1 from profiles where id = auth.uid() and site_role = 'owner' and not suspended) $$;
create function public.is_member_of(t uuid) returns boolean language sql security definer stable set search_path = public as
$$ select exists(select 1 from team_members tm join profiles p on p.id = tm.user_id
   where tm.team_id = t and tm.user_id = auth.uid() and not p.suspended) $$;
create function public.shares_team(u uuid) returns boolean language sql security definer stable set search_path = public as
$$ select exists(select 1 from team_members a join team_members b on a.team_id = b.team_id
   where a.user_id = auth.uid() and b.user_id = u) $$;

-- who can see and change what
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_staff() or public.shares_team(id));
create policy teams_read on public.teams for select to authenticated
  using (public.is_staff() or public.is_member_of(id));
create policy teams_write on public.teams for all to authenticated
  using (public.is_staff()) with check (public.is_staff());
create policy tm_read on public.team_members for select to authenticated
  using (public.is_staff() or user_id = auth.uid() or public.is_member_of(team_id));
create policy tm_write on public.team_members for all to authenticated
  using (public.is_staff()) with check (public.is_staff());
create policy invites_all on public.invites for all to authenticated
  using (public.is_staff()) with check (public.is_staff() and (site_role = 'member' or public.is_owner()));

grant select on public.profiles to authenticated;
grant select, insert, update, delete on public.teams, public.team_members, public.invites to authenticated;

-- the first person to sign up becomes the owner; everyone after needs an invite
create function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
declare inv invites; a jsonb;
begin
  if not exists (select 1 from profiles where site_role = 'owner') then
    insert into profiles (id, email, site_role) values (new.id, new.email, 'owner');
    return new;
  end if;
  select * into inv from invites where email = lower(new.email);
  if not found then raise exception 'This email has not been invited'; end if;
  insert into profiles (id, email, site_role) values (new.id, new.email, inv.site_role);
  for a in select * from jsonb_array_elements(inv.assignments) loop
    insert into team_members (team_id, user_id, roles)
    values ((a->>'team_id')::uuid, new.id, array(select jsonb_array_elements_text(a->'roles')))
    on conflict (team_id, user_id) do update set roles = excluded.roles;
  end loop;
  delete from invites where email = inv.email;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- actions with extra rules
create function public.set_site_role(target uuid, new_role text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'Only the owner can change admins'; end if;
  if new_role not in ('admin','member') then raise exception 'Bad role'; end if;
  update profiles set site_role = new_role where id = target and site_role <> 'owner';
end $$;
create function public.set_suspended(target uuid, flag boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Not allowed'; end if;
  update profiles set suspended = flag where id = target and site_role <> 'owner'
    and (site_role = 'member' or public.is_owner());
end $$;
create function public.update_my_name(n text) returns void language sql security definer set search_path = public as
$$ update profiles set display_name = left(n, 60) where id = auth.uid() $$;
grant execute on function public.set_site_role, public.set_suspended, public.update_my_name to authenticated;

-- team logos
insert into storage.buckets (id, name, public) values ('logos', 'logos', true) on conflict do nothing;
create policy logos_read on storage.objects for select using (bucket_id = 'logos');
create policy logos_add on storage.objects for insert to authenticated with check (bucket_id = 'logos' and public.is_staff());
create policy logos_edit on storage.objects for update to authenticated using (bucket_id = 'logos' and public.is_staff());
