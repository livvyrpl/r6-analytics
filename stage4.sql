-- Liv Analytics, stage 4: coaches can set goals for players.
-- Paste this whole file into Supabase > SQL Editor > Run.
-- Run schema.sql, stage2.sql and stage3.sql first. This file is safe to run more than once.

-- who set the goal; empty means the player set it themselves
alter table public.journal_goals add column if not exists assigned_by uuid references public.profiles(id) on delete set null;

-- is this person a player on this team?
create or replace function public.goal_target_is_player(t uuid, u uuid) returns boolean language sql security definer stable set search_path = public as
$$ select exists(select 1 from team_members tm join profiles p on p.id = tm.user_id
   where tm.team_id = t and tm.user_id = u and not p.suspended and tm.roles && array['player']) $$;
revoke execute on function public.goal_target_is_player(uuid, uuid) from public, anon;
grant execute on function public.goal_target_is_player(uuid, uuid) to authenticated;

-- the database fills in who set a goal, so nobody can fake it, and it protects coach-set goals:
-- a goal cannot move to another player or team, and a player can only change the status of a goal a coach set
create or replace function public.guard_journal_goal() returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.assigned_by := case when auth.uid() = new.user_id then null else auth.uid() end;
    return new;
  end if;
  new.assigned_by := old.assigned_by;
  if auth.uid() is not null then
    if new.user_id <> old.user_id or new.team_id <> old.team_id then
      raise exception 'A goal cannot be moved to another player or team';
    end if;
    if old.assigned_by is not null and auth.uid() = old.user_id
      and (new.title <> old.title or new.description <> old.description or new.deadline is distinct from old.deadline) then
      raise exception 'This goal was set by a coach. You can update its status and add progress notes.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists journal_goal_guard on public.journal_goals;
create trigger journal_goal_guard before insert or update on public.journal_goals
  for each row execute function public.guard_journal_goal();

-- WHO CAN CHANGE WHAT (reading stays as it was in stage3.sql)

drop policy if exists journal_goals_write on public.journal_goals;

-- players add and edit their own goals, and delete only the ones they set themselves
drop policy if exists journal_goals_own_add on public.journal_goals;
create policy journal_goals_own_add on public.journal_goals for insert to authenticated
  with check (user_id = auth.uid() and public.has_player_role(team_id));
drop policy if exists journal_goals_own_edit on public.journal_goals;
create policy journal_goals_own_edit on public.journal_goals for update to authenticated
  using (user_id = auth.uid() and public.has_player_role(team_id))
  with check (user_id = auth.uid() and public.has_player_role(team_id));
drop policy if exists journal_goals_own_remove on public.journal_goals;
create policy journal_goals_own_remove on public.journal_goals for delete to authenticated
  using (user_id = auth.uid() and assigned_by is null and public.has_player_role(team_id));

-- coaches, assistant coaches, admins and the owner add goals for this team's players,
-- and edit or delete goals set by coaches. A player's own goals stay read only for them.
drop policy if exists journal_goals_coach_add on public.journal_goals;
create policy journal_goals_coach_add on public.journal_goals for insert to authenticated
  with check (user_id <> auth.uid() and public.can_edit_schedule(team_id) and public.goal_target_is_player(team_id, user_id));
drop policy if exists journal_goals_coach_edit on public.journal_goals;
create policy journal_goals_coach_edit on public.journal_goals for update to authenticated
  using (assigned_by is not null and public.can_edit_schedule(team_id))
  with check (assigned_by is not null and public.can_edit_schedule(team_id));
drop policy if exists journal_goals_coach_remove on public.journal_goals;
create policy journal_goals_coach_remove on public.journal_goals for delete to authenticated
  using (assigned_by is not null and public.can_edit_schedule(team_id));

-- tell Supabase to pick up the new column straight away
notify pgrst, 'reload schema';
