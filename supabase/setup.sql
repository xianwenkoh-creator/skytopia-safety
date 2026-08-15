-- ============================================================
-- SKYTOPIA Site Safety — Supabase setup (run once)
-- Paste this whole file into Supabase → SQL Editor → Run.
-- Creates: orgs, profiles, records + triggers + row-level security
-- enforcing the company → project → subcontractor tiers.
-- ============================================================

-- ---------- tables ----------
create table if not exists public.orgs (
  id         uuid primary key default gen_random_uuid(),
  name       text not null default 'My Company',
  created_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  org_id       uuid not null references public.orgs(id),
  email        text,
  display_name text,
  role         text not null default 'viewer'
               check (role in ('admin','wsho','subcon','viewer')),
  subcon       text,          -- subcontractor company name, only for role='subcon'
  created_at   timestamptz not null default now()
);

create table if not exists public.records (
  org_id     uuid not null references public.orgs(id),
  id         text not null,
  project_id text not null,   -- '_company' for company-level stores
  store      text not null,   -- module key, or '_project' / '_meta'
  data       jsonb not null default '{}'::jsonb,
  deleted    boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (org_id, id)
);
create index if not exists records_sync_idx on public.records (org_id, updated_at);

-- ---------- triggers ----------
create or replace function public.records_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists records_touch on public.records;
create trigger records_touch
  before insert or update on public.records
  for each row execute function public.records_touch();

-- First user to sign up becomes admin of a fresh org; later users start as
-- 'viewer' in the same org until the admin changes their role.
create or replace function public.handle_new_user()
returns trigger security definer set search_path = public
language plpgsql as $$
declare v_org uuid; v_role text;
begin
  select id into v_org from public.orgs limit 1;
  if v_org is null then
    insert into public.orgs(name) values ('My Company') returning id into v_org;
  end if;
  select case when exists(select 1 from public.profiles) then 'viewer' else 'admin' end into v_role;
  insert into public.profiles(id, org_id, email, role)
  values (new.id, v_org, new.email, v_role)
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- role helpers (security definer avoids RLS recursion) ----------
create or replace function public.my_org() returns uuid
language sql stable security definer set search_path = public as
$$ select org_id from public.profiles where id = auth.uid() $$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as
$$ select role from public.profiles where id = auth.uid() $$;

create or replace function public.my_subcon() returns text
language sql stable security definer set search_path = public as
$$ select subcon from public.profiles where id = auth.uid() $$;

-- Which rows a subcontractor account may touch: observations/defects tagged
-- with their company, their own workers/plant/training submissions, and the
-- project/company meta rows (read context).
create or replace function public.subcon_scope(store text, data jsonb) returns boolean
language sql stable as $$
  select (store in ('observations','defects')
            and lower(coalesce(data->>'subcon',''))  = lower(coalesce(public.my_subcon(),'')))
      or (store in ('members','equipment','training')
            and lower(coalesce(data->>'company','')) = lower(coalesce(public.my_subcon(),'')))
$$;

-- ---------- row-level security ----------
alter table public.orgs     enable row level security;
alter table public.profiles enable row level security;
alter table public.records  enable row level security;

drop policy if exists orgs_read on public.orgs;
create policy orgs_read on public.orgs
  for select using (id = public.my_org());

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles
  for select using (id = auth.uid()
                    or (org_id = public.my_org() and public.my_role() = 'admin'));

drop policy if exists profiles_admin_update on public.profiles;
create policy profiles_admin_update on public.profiles
  for update using (org_id = public.my_org() and public.my_role() = 'admin')
  with check (org_id = public.my_org());

-- read: admin/wsho see everything; viewers see everything EXCEPT the RA/SWP
-- register (company safety personnel only); subcons see only their scope
drop policy if exists rec_read on public.records;
create policy rec_read on public.records
  for select using (
    org_id = public.my_org()
    and ( public.my_role() in ('admin','wsho')
          or (public.my_role() = 'viewer' and store <> 'ra')
          or ( public.my_role() = 'subcon'
               and (store in ('_project','_meta') or public.subcon_scope(store, data)) ) )
  );

-- write: admin + wsho anywhere in the org
drop policy if exists rec_staff_insert on public.records;
create policy rec_staff_insert on public.records
  for insert with check (org_id = public.my_org() and public.my_role() in ('admin','wsho'));

drop policy if exists rec_staff_update on public.records;
create policy rec_staff_update on public.records
  for update using (org_id = public.my_org() and public.my_role() in ('admin','wsho'))
  with check (org_id = public.my_org());

-- write: subcon only inside their scope (and cannot re-tag rows to another company)
drop policy if exists rec_subcon_insert on public.records;
create policy rec_subcon_insert on public.records
  for insert with check (
    org_id = public.my_org() and public.my_role() = 'subcon'
    and public.subcon_scope(store, data)
  );

drop policy if exists rec_subcon_update on public.records;
create policy rec_subcon_update on public.records
  for update using (
    org_id = public.my_org() and public.my_role() = 'subcon'
    and public.subcon_scope(store, data)
  )
  with check (
    org_id = public.my_org() and public.subcon_scope(store, data)
  );

-- viewers get no insert/update/delete policies → read-only by default.
-- No delete policies at all: the app never deletes rows, it tombstones
-- (deleted=true) via update, so history survives.
