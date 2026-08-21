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
               check (role in ('admin','wsho','hr','subcon','viewer')),
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
      or (store in ('members','equipment','training','workerCompetencies')
            and lower(coalesce(data->>'company','')) = lower(coalesce(public.my_subcon(),'')))
      or (store in ('raAdoptions','raProjectVersions')
            and lower(coalesce(data->>'subcon','')) = lower(coalesce(public.my_subcon(),'')))
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

-- read: admin/wsho see everything; hr sees everything except the RA/SWP system;
-- viewers additionally lose HR-restricted records; subcons see only their scope
drop policy if exists rec_read on public.records;
create policy rec_read on public.records
  for select using (
    org_id = public.my_org()
    and ( public.my_role() in ('admin','wsho')
          or (public.my_role() = 'hr' and store not in
              ('ra','raLibrary','raMasters','raMasterVersions','legacyDocs','raAdoptions','raProjectVersions','reviewTriggers'))
          or (public.my_role() = 'viewer' and store not in
              ('ra','raLibrary','raMasters','raMasterVersions','legacyDocs','raAdoptions','raProjectVersions','reviewTriggers','auditEvents','memberPrivate'))
          or ( public.my_role() = 'subcon'
               and (store in ('_project','_meta','sicProfiles','competencyTypes','organisations')
                    or (store = 'workerProjectAccess'
                        and lower(coalesce(data->>'company','')) = lower(coalesce(public.my_subcon(),'')))
                    or public.subcon_scope(store, data)) ) )
  );

-- write: admin + wsho anywhere in the org
drop policy if exists rec_staff_insert on public.records;
create policy rec_staff_insert on public.records
  for insert with check (org_id = public.my_org() and public.my_role() in ('admin','wsho'));

drop policy if exists rec_staff_update on public.records;
create policy rec_staff_update on public.records
  for update using (org_id = public.my_org() and public.my_role() in ('admin','wsho'))
  with check (org_id = public.my_org());

-- write: hr maintains HR-owned worker information only
drop policy if exists rec_hr_insert on public.records;
create policy rec_hr_insert on public.records
  for insert with check (
    org_id = public.my_org() and public.my_role() = 'hr'
    and store in ('members','memberPrivate','workerCompetencies','training','organisations')
  );

drop policy if exists rec_hr_update on public.records;
create policy rec_hr_update on public.records
  for update using (
    org_id = public.my_org() and public.my_role() = 'hr'
    and store in ('members','memberPrivate','workerCompetencies','training','organisations')
  )
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

-- ============================================================
-- TWO-LEVEL ACCESS (Company HQ vs Project) — supersedes the
-- rec_read / rec_staff_* / rec_subcon_* policies defined above.
-- HQ users: admins + hr always, others via profiles.hq.
-- Non-HQ users are pinned to profiles.project_id (NULL = all,
-- for backward compatibility until the admin assigns projects).
-- ============================================================
alter table public.profiles add column if not exists hq boolean not null default false;
alter table public.profiles add column if not exists project_id text;

create or replace function public.my_hq() returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce(role in ('admin','hr') or hq, false) from public.profiles where id = auth.uid() $$;

create or replace function public.my_project() returns text
language sql stable security definer set search_path = public as
$$ select project_id from public.profiles where id = auth.uid() $$;

drop policy if exists rec_read on public.records;
create policy rec_read on public.records
  for select using (
    org_id = public.my_org()
    and (
      /* HQ users keep the per-role visibility, across all projects.
         memberPrivate is admin + hr ONLY (hardening, Aug 2026). */
      ( public.my_hq() and (
            public.my_role() = 'admin'
            or (public.my_role() = 'wsho' and store <> 'memberPrivate')
            or (public.my_role() = 'hr' and store not in
                ('ra','raLibrary','raMasters','raMasterVersions','legacyDocs','raAdoptions','raProjectVersions','reviewTriggers'))
            or (public.my_role() = 'viewer' and store not in
                ('ra','raLibrary','raMasters','raMasterVersions','legacyDocs','raAdoptions','raProjectVersions','reviewTriggers','auditEvents','memberPrivate')) ) )
      /* project-level staff: own project rows + shared operational company registers */
      or ( not public.my_hq() and public.my_role() in ('wsho','viewer')
           and (public.my_project() is null or project_id = public.my_project() or project_id = '_company')
           and ( project_id <> '_company'
                 or store in ('members','equipment','training','competencyTypes','workerCompetencies','sicProfiles','companyDocs','_meta')
                 or (public.my_role() = 'wsho' and store in ('raLibrary','raMasters','raMasterVersions')) )
           and store not in ('auditEvents','organisations','clientTemplates','legacyDocs','memberPrivate')
           and (public.my_role() <> 'viewer' or store not in
                ('ra','raLibrary','raMasters','raMasterVersions','raAdoptions','raProjectVersions','reviewTriggers')) )
      /* subcon: unchanged scope, plus the project pin when assigned */
      or ( public.my_role() = 'subcon'
           and (public.my_project() is null or project_id = public.my_project() or project_id = '_company')
           and (store in ('_project','_meta','sicProfiles','competencyTypes','organisations',
                          'locations','layouts','layoutVersions','locGeoms','spatialZones','zoneGeoms')
                or (store = 'workerProjectAccess'
                    and lower(coalesce(data->>'company','')) = lower(coalesce(public.my_subcon(),'')))
                or public.subcon_scope(store, data)) )
    )
  );

drop policy if exists rec_staff_insert on public.records;
create policy rec_staff_insert on public.records
  for insert with check (
    org_id = public.my_org()
    and ( (public.my_role() in ('admin','wsho') and public.my_hq())
          or (public.my_role() = 'wsho' and not public.my_hq()
              and (public.my_project() is null or project_id = public.my_project() or project_id = '_company')
              and (project_id <> '_company'
                   or store in ('members','equipment','training','competencyTypes','workerCompetencies'))) )
  );

drop policy if exists rec_staff_update on public.records;
create policy rec_staff_update on public.records
  for update using (
    org_id = public.my_org()
    and ( (public.my_role() in ('admin','wsho') and public.my_hq())
          or (public.my_role() = 'wsho' and not public.my_hq()
              and (public.my_project() is null or project_id = public.my_project() or project_id = '_company')
              and (project_id <> '_company'
                   or store in ('members','equipment','training','competencyTypes','workerCompetencies'))) )
  )
  with check (org_id = public.my_org());

-- subcon may also SUBMIT their own workers for SIC review: they can create /
-- resubmit workerProjectAccess rows for their company, but only ever in the
-- 'SUBMITTED' state — COMPLETE / access decisions stay with main-con staff.
-- ============================================================
-- HARDENING (Aug 2026): tamper-proof audit + HR-data narrowing
-- ============================================================
-- 1) auditEvents is append-only at the DATABASE level: no role may UPDATE it
--    (tombstoning included). Staff keep INSERT; hr gains INSERT so their own
--    actions can log.
drop policy if exists rec_staff_update on public.records;
create policy rec_staff_update on public.records
  for update using (
    org_id = public.my_org()
    and store <> 'auditEvents'
    and ( (public.my_role() in ('admin','wsho') and public.my_hq())
          or (public.my_role() = 'wsho' and not public.my_hq()
              and (public.my_project() is null or project_id = public.my_project() or project_id = '_company')
              and (project_id <> '_company'
                   or store in ('members','equipment','training','competencyTypes','workerCompetencies'))) )
  )
  with check (org_id = public.my_org());

drop policy if exists rec_hr_insert on public.records;
create policy rec_hr_insert on public.records
  for insert with check (
    org_id = public.my_org() and public.my_role() = 'hr'
    and store in ('members','memberPrivate','workerCompetencies','training','organisations','auditEvents')
  );

-- 2) memberPrivate readable by admin + hr ONLY (WSHO removed): enforced by a
--    dedicated exclusion inside rec_read's wsho branch via my_hq check below.
--    (rec_read handles this: see amended policy.)

-- 3) server-side audit: sensitive-store writes and any tombstone are logged by
--    the DATABASE with a server timestamp and the authenticated user — exists
--    even if the client writes no audit event of its own.
create or replace function public.records_server_audit()
returns trigger language plpgsql security definer set search_path = public as $$
declare aid text; act text;
begin
  if new.store = 'auditEvents' then return new; end if;
  act := case
    when TG_OP = 'UPDATE' and new.deleted and not old.deleted then 'deleted'
    when new.store in ('memberPrivate','workerProjectAccess') then lower(TG_OP)
    else null end;
  if act is null then return new; end if;
  aid := 'aud-' || substr(md5(new.id || clock_timestamp()::text), 1, 14);
  insert into public.records(org_id, id, project_id, store, data)
  values (new.org_id, aid, '_company', 'auditEvents',
    jsonb_build_object('id', aid, 'at', to_char(now() at time zone 'utc','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'who', coalesce(auth.uid()::text, 'service'),
      'action', 'server:' || act, 'entity', new.store, 'entityId', new.id,
      'serverStamped', true));
  return new;
end $$;
drop trigger if exists records_server_audit on public.records;
create trigger records_server_audit
  before insert or update on public.records
  for each row execute function public.records_server_audit();

drop policy if exists rec_subcon_insert on public.records;
create policy rec_subcon_insert on public.records
  for insert with check (
    org_id = public.my_org() and public.my_role() = 'subcon'
    and (public.my_project() is null or project_id = public.my_project() or project_id = '_company')
    and ( public.subcon_scope(store, data)
          or (store = 'workerProjectAccess'
              and lower(coalesce(data->>'company','')) = lower(coalesce(public.my_subcon(),''))
              and coalesce(data->>'sicStatus','') = 'SUBMITTED') )
  );

drop policy if exists rec_subcon_update on public.records;
create policy rec_subcon_update on public.records
  for update using (
    org_id = public.my_org() and public.my_role() = 'subcon'
    and (public.my_project() is null or project_id = public.my_project() or project_id = '_company')
    and ( public.subcon_scope(store, data)
          or (store = 'workerProjectAccess'
              and lower(coalesce(data->>'company','')) = lower(coalesce(public.my_subcon(),''))) )
  )
  with check (
    org_id = public.my_org()
    and ( public.subcon_scope(store, data)
          or (store = 'workerProjectAccess'
              and lower(coalesce(data->>'company','')) = lower(coalesce(public.my_subcon(),''))
              and coalesce(data->>'sicStatus','') = 'SUBMITTED') )
  );

-- ============ REPORT REPOSITORY (21 Aug 2026) ============
-- Private bucket 'reports' (10MB cap; pdf/csv/html). Path: <project_id>/<category>/<file>
-- read: staff (admin/wsho/hr/viewer), project-pinned unless HQ; write: admin/wsho/hr; delete: admin.
-- Policies "reports read staff" / "reports write staff" / "reports update staff" /
-- "reports delete admin" on storage.objects — applied live 21 Aug 2026.
