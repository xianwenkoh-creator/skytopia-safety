-- ============================================================
-- Worker document requests (docRequests) - Aug 2026
--
-- Personal records do not leave the company on one officer's say-so. Safety
-- raises a request naming the men, the purpose and the recipient; the HR
-- manager releases or declines it; only then can the pack be downloaded.
--
-- The app enforces this in its screens, but screens are not security. The
-- trigger at the bottom is the real gate: whatever a client sends, only HR
-- (or admin) can move a request out of 'Pending' or set the release window.
--
-- NOTE: rec_read / rec_staff_update below are the LIVE policies read back from
-- pg_policies, reproduced verbatim with only the docRequests clauses added.
-- Do not regenerate them from setup.sql - the live versions carry later
-- hardening (supervisor+engineer folded into the non-HQ branch; the
-- auditEvents append-only guard on rec_staff_update) that setup.sql predates.
-- ============================================================

-- 1) READ: site Safety officers see document requests; supervisors, engineers,
--    viewers and subcontractors do not - it is personal-data traffic.
drop policy if exists rec_read on public.records;
create policy rec_read on public.records
  for select using (
    org_id = public.my_org()
    and (
      ( public.my_hq() and (
            public.my_role() = 'admin'
            or (public.my_role() = 'wsho' and store <> 'memberPrivate')
            or (public.my_role() = 'hr' and store <> all (array['ra','raLibrary','raMasters','raMasterVersions',
                  'legacyDocs','raAdoptions','raProjectVersions','reviewTriggers']))
            or (public.my_role() = 'viewer' and store <> all (array['ra','raLibrary','raMasters','raMasterVersions',
                  'legacyDocs','raAdoptions','raProjectVersions','reviewTriggers','auditEvents','memberPrivate',
                  'docRequests'])) ) )
      or ( not public.my_hq()
           and public.my_role() = any (array['wsho','viewer','supervisor','engineer'])
           and (public.my_project() is null or project_id = public.my_project() or project_id = '_company')
           and ( project_id <> '_company'
                 or store = any (array['members','equipment','training','competencyTypes','workerCompetencies',
                                       'sicProfiles','companyDocs','_meta'])
                 or (public.my_role() = any (array['wsho','supervisor','engineer'])
                     and store = any (array['raLibrary','raMasters','raMasterVersions']))
                 or (public.my_role() = 'wsho' and store = 'docRequests') )
           and store <> all (array['auditEvents','organisations','clientTemplates','legacyDocs','memberPrivate'])
           and (public.my_role() <> 'viewer' or store <> all (array['ra','raLibrary','raMasters','raMasterVersions',
                  'raAdoptions','raProjectVersions','reviewTriggers']))
           and (store <> 'docRequests' or public.my_role() = 'wsho') )
      or ( public.my_role() = 'subcon'
           and (public.my_project() is null or project_id = public.my_project() or project_id = '_company')
           and (store = any (array['_project','_meta','sicProfiles','competencyTypes','organisations',
                                   'locations','layouts','layoutVersions','locGeoms','spatialZones','zoneGeoms'])
                or (store = 'workerProjectAccess'
                    and lower(coalesce(data->>'company','')) = lower(coalesce(public.my_subcon(),'')))
                or public.subcon_scope(store, data)) )
    )
  );

-- 2) WRITE: Safety may raise and amend requests; HR may raise and decide them.
drop policy if exists rec_staff_insert on public.records;
create policy rec_staff_insert on public.records
  for insert with check (
    org_id = public.my_org()
    and ( (public.my_role() = any (array['admin','wsho']) and public.my_hq())
          or (public.my_role() = 'wsho' and not public.my_hq()
              and (public.my_project() is null or project_id = public.my_project() or project_id = '_company')
              and (project_id <> '_company'
                   or store = any (array['members','equipment','training','competencyTypes',
                                         'workerCompetencies','docRequests']))) )
  );

drop policy if exists rec_staff_update on public.records;
create policy rec_staff_update on public.records
  for update using (
    org_id = public.my_org()
    and store <> 'auditEvents'          -- append-only, keep this
    and ( (public.my_role() = any (array['admin','wsho']) and public.my_hq())
          or (public.my_role() = 'wsho' and not public.my_hq()
              and (public.my_project() is null or project_id = public.my_project() or project_id = '_company')
              and (project_id <> '_company'
                   or store = any (array['members','equipment','training','competencyTypes',
                                         'workerCompetencies','docRequests']))) )
  )
  with check (org_id = public.my_org());

drop policy if exists rec_hr_insert on public.records;
create policy rec_hr_insert on public.records
  for insert with check (
    org_id = public.my_org() and public.my_role() = 'hr'
    and store = any (array['members','memberPrivate','workerCompetencies','training',
                           'organisations','auditEvents','docRequests'])
  );

drop policy if exists rec_hr_update on public.records;
create policy rec_hr_update on public.records
  for update using (
    org_id = public.my_org() and public.my_role() = 'hr'
    and store = any (array['members','memberPrivate','workerCompetencies','training',
                           'organisations','docRequests'])
  )
  with check (org_id = public.my_org());

-- 3) THE ACTUAL GATE. Screens can be bypassed; this cannot.
--    For anyone but HR/admin a request is born Pending and its decision fields
--    are read-only forever. The requester may still stamp their own download.
create or replace function public.docreq_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare r text;
begin
  if new.store <> 'docRequests' then return new; end if;
  r := public.my_role();
  if r in ('admin','hr') then return new; end if;

  if tg_op = 'INSERT' then
    if coalesce(new.data->>'status','') <> 'Pending' then
      raise exception 'A document request starts as Pending - only HR releases it.';
    end if;
    return new;
  end if;

  if coalesce(new.data->>'status','')    is distinct from coalesce(old.data->>'status','')
  or coalesce(new.data->>'decidedBy','') is distinct from coalesce(old.data->>'decidedBy','')
  or coalesce(new.data->>'decidedAt','') is distinct from coalesce(old.data->>'decidedAt','')
  or coalesce(new.data->>'expiresAt','') is distinct from coalesce(old.data->>'expiresAt','') then
    raise exception 'Only HR can release or decline a document request.';
  end if;
  return new;
end $$;

drop trigger if exists trg_docreq_guard on public.records;
create trigger trg_docreq_guard
  before insert or update on public.records
  for each row execute function public.docreq_guard();
