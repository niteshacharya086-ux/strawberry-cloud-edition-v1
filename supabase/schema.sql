-- Strawberry Strategic Planner: multi-guild schema
-- Run the entire file in Supabase SQL Editor on a NEW project.
-- Then sign up with your own account and insert its auth.users UUID into platform_admins.

create extension if not exists pgcrypto;

create table if not exists public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.guilds (
  id uuid primary key default gen_random_uuid(),
  guild_code text not null unique check (guild_code ~ '^[A-Z0-9-]{3,32}$'),
  name text not null check (char_length(name) between 2 and 80),
  status text not null default 'active' check (status in ('active','suspended')),
  created_at timestamptz not null default now()
);

create table if not exists public.guild_memberships (
  guild_id uuid not null references public.guilds(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('guild_admin','planner','member')),
  created_at timestamptz not null default now(),
  primary key (guild_id,user_id)
);

create table if not exists public.guild_registration_requests (
  id uuid primary key default gen_random_uuid(),
  requested_name text not null check (char_length(requested_name) between 2 and 80),
  requested_code text not null check (requested_code ~ '^[A-Z0-9-]{3,32}$'),
  contact_note text,
  requester_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now()
);

create table if not exists public.guild_membership_requests (
  id uuid primary key default gen_random_uuid(),
  guild_id uuid not null references public.guilds(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  unique(guild_id,user_id)
);

create table if not exists public.guild_workspaces (
  guild_id uuid primary key references public.guilds(id) on delete cascade,
  workspace jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id)
);

create table if not exists public.participation_entries (
  id uuid primary key default gen_random_uuid(),
  guild_id uuid not null references public.guilds(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 60),
  note text check (char_length(coalesce(note,'')) <= 200),
  created_at timestamptz not null default now()
);

create table if not exists public.audit_logs (
  id bigint generated always as identity primary key,
  guild_id uuid references public.guilds(id) on delete set null,
  actor_id uuid references auth.users(id) on delete set null,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.is_platform_admin()
returns boolean language sql stable security definer
set search_path = public, pg_temp
as $$ select exists(select 1 from public.platform_admins where user_id = auth.uid()) $$;

create or replace function public.guild_role(p_guild uuid)
returns text language sql stable security definer
set search_path = public, pg_temp
as $$ select role from public.guild_memberships where guild_id=p_guild and user_id=auth.uid() $$;

create or replace function public.can_access_guild(p_guild uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp
as $$ select public.is_platform_admin() or exists(
  select 1 from public.guild_memberships m join public.guilds g on g.id=m.guild_id
  where m.guild_id=p_guild and m.user_id=auth.uid() and g.status='active'
) $$;

create or replace function public.guard_workspace_update()
returns trigger language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r text;
begin
  if public.is_platform_admin() then return new; end if;
  r := public.guild_role(old.guild_id);
  if r = 'guild_admin' then
    return new;
  elsif r = 'planner' then
    if (new.workspace->'players') is distinct from (old.workspace->'players')
       or (new.workspace->'pool') is distinct from (old.workspace->'pool') then
      raise exception 'Planner role cannot change the player roster or extra player pool';
    end if;
    return new;
  else
    raise exception 'Only guild admins and planners may edit the workspace';
  end if;
end $$;

drop trigger if exists trg_guard_workspace_update on public.guild_workspaces;
create trigger trg_guard_workspace_update before update on public.guild_workspaces
for each row execute function public.guard_workspace_update();

create or replace function public.request_guild_membership(p_guild_code text)
returns uuid language plpgsql security definer
set search_path = public, pg_temp
as $$
declare gid uuid; rid uuid;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select id into gid from public.guilds where guild_code=upper(trim(p_guild_code)) and status='active';
  if gid is null then raise exception 'Guild not found or inactive'; end if;
  insert into public.guild_membership_requests(guild_id,user_id)
  values(gid,auth.uid()) on conflict(guild_id,user_id) do update set status='pending'
  returning id into rid;
  return rid;
end $$;

create or replace function public.review_guild_membership(p_request_id uuid,p_approve boolean)
returns void language plpgsql security definer
set search_path = public, pg_temp
as $$
declare req public.guild_membership_requests%rowtype; r text;
begin
  select * into req from public.guild_membership_requests where id=p_request_id;
  if not found then raise exception 'Request not found'; end if;
  r:=public.guild_role(req.guild_id);
  if not (public.is_platform_admin() or r='guild_admin') then raise exception 'Not authorized'; end if;
  update public.guild_membership_requests set status=case when p_approve then 'approved' else 'rejected' end where id=p_request_id;
  if p_approve then
    insert into public.guild_memberships(guild_id,user_id,role) values(req.guild_id,req.user_id,'member')
    on conflict(guild_id,user_id) do nothing;
  end if;
end $$;

create or replace function public.create_guild(p_name text,p_code text,p_admin_user uuid default null)
returns uuid language plpgsql security definer
set search_path = public, pg_temp
as $$
declare gid uuid;
begin
  if not public.is_platform_admin() then raise exception 'Platform admin only'; end if;
  insert into public.guilds(name,guild_code) values(trim(p_name),upper(trim(p_code))) returning id into gid;
  insert into public.guild_workspaces(guild_id) values(gid);
  if p_admin_user is not null then
    insert into public.guild_memberships(guild_id,user_id,role) values(gid,p_admin_user,'guild_admin');
  end if;
  return gid;
end $$;

create or replace function public.review_guild_registration(p_request_id uuid,p_approve boolean)
returns void language plpgsql security definer
set search_path = public, pg_temp
as $$
declare req public.guild_registration_requests%rowtype; gid uuid;
begin
  if not public.is_platform_admin() then raise exception 'Platform admin only'; end if;
  select * into req from public.guild_registration_requests where id=p_request_id for update;
  if not found then raise exception 'Request not found'; end if;
  if p_approve then
    insert into public.guilds(name,guild_code) values(req.requested_name,req.requested_code) returning id into gid;
    insert into public.guild_workspaces(guild_id) values(gid);
    insert into public.guild_memberships(guild_id,user_id,role) values(gid,req.requester_id,'guild_admin');
  end if;
  update public.guild_registration_requests set status=case when p_approve then 'approved' else 'rejected' end where id=p_request_id;
end $$;

alter table public.platform_admins enable row level security;
alter table public.guilds enable row level security;
alter table public.guild_memberships enable row level security;
alter table public.guild_registration_requests enable row level security;
alter table public.guild_membership_requests enable row level security;
alter table public.guild_workspaces enable row level security;
alter table public.participation_entries enable row level security;
alter table public.audit_logs enable row level security;

-- Platform admin roster is not writable from the browser.
drop policy if exists platform_admin_select_self on public.platform_admins;
create policy platform_admin_select_self on public.platform_admins for select to authenticated
using (user_id=auth.uid());

drop policy if exists guild_select_members on public.guilds;
create policy guild_select_members on public.guilds for select to authenticated
using (public.can_access_guild(id));

drop policy if exists membership_select_self_or_admin on public.guild_memberships;
create policy membership_select_self_or_admin on public.guild_memberships for select to authenticated
using (user_id=auth.uid() or public.is_platform_admin() or public.guild_role(guild_id)='guild_admin');

drop policy if exists registration_insert_self on public.guild_registration_requests;
create policy registration_insert_self on public.guild_registration_requests for insert to authenticated
with check (requester_id=auth.uid() and status='pending');
drop policy if exists registration_select_platform on public.guild_registration_requests;
create policy registration_select_platform on public.guild_registration_requests for select to authenticated
using (public.is_platform_admin());

drop policy if exists membership_request_select on public.guild_membership_requests;
create policy membership_request_select on public.guild_membership_requests for select to authenticated
using (user_id=auth.uid() or public.is_platform_admin() or public.guild_role(guild_id)='guild_admin');

drop policy if exists workspace_select_members on public.guild_workspaces;
create policy workspace_select_members on public.guild_workspaces for select to authenticated
using (public.can_access_guild(guild_id));
drop policy if exists workspace_insert_admin on public.guild_workspaces;
create policy workspace_insert_admin on public.guild_workspaces for insert to authenticated
with check (public.is_platform_admin() or public.guild_role(guild_id)='guild_admin');
drop policy if exists workspace_update_admin_planner on public.guild_workspaces;
create policy workspace_update_admin_planner on public.guild_workspaces for update to authenticated
using (public.is_platform_admin() or public.guild_role(guild_id) in ('guild_admin','planner'))
with check (public.is_platform_admin() or public.guild_role(guild_id) in ('guild_admin','planner'));

drop policy if exists participation_select_guild on public.participation_entries;
create policy participation_select_guild on public.participation_entries for select to authenticated
using (public.can_access_guild(guild_id));
drop policy if exists participation_insert_self on public.participation_entries;
create policy participation_insert_self on public.participation_entries for insert to authenticated
with check (user_id=auth.uid() and public.can_access_guild(guild_id) and public.guild_role(guild_id)='member');
drop policy if exists participation_delete_admin on public.participation_entries;
create policy participation_delete_admin on public.participation_entries for delete to authenticated
using (public.is_platform_admin() or public.guild_role(guild_id)='guild_admin');

drop policy if exists audit_select_admin on public.audit_logs;
create policy audit_select_admin on public.audit_logs for select to authenticated
using (public.is_platform_admin() or public.guild_role(guild_id)='guild_admin');

-- Keep RPC execution scoped to signed-in users; each function performs its own authorization checks.
revoke all on function public.request_guild_membership(text) from public;
revoke all on function public.review_guild_membership(uuid,boolean) from public;
revoke all on function public.create_guild(text,text,uuid) from public;
revoke all on function public.review_guild_registration(uuid,boolean) from public;
grant execute on function public.request_guild_membership(text) to authenticated;
grant execute on function public.review_guild_membership(uuid,boolean) to authenticated;
grant execute on function public.create_guild(text,text,uuid) to authenticated;
grant execute on function public.review_guild_registration(uuid,boolean) to authenticated;

grant select on public.platform_admins,public.guilds,public.guild_memberships,
  public.guild_registration_requests,public.guild_membership_requests,
  public.guild_workspaces,public.participation_entries,public.audit_logs to authenticated;
grant insert on public.guild_registration_requests,public.participation_entries to authenticated;
grant insert,update on public.guild_workspaces to authenticated;
grant delete on public.participation_entries to authenticated;

-- Restrict direct invocation of helper functions used by RLS policies.
revoke all on function public.is_platform_admin() from public;
revoke all on function public.guild_role(uuid) from public;
revoke all on function public.can_access_guild(uuid) from public;
grant execute on function public.is_platform_admin() to authenticated;
grant execute on function public.guild_role(uuid) to authenticated;
grant execute on function public.can_access_guild(uuid) to authenticated;
