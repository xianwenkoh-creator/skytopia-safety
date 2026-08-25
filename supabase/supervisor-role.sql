-- ============================================================================
-- KKL CMS: the Supervisor role
-- Run this once in Supabase Dashboard -> SQL Editor.
--
-- A supervisor conducts LMRAs at his workface and reports near misses.
-- He reads what the workface needs (crew, appointments, work activities,
-- approved RA) and writes exactly two stores: lmra and observations.
-- No inspections, no infringements, no RA editing, no approvals.
-- ============================================================================

-- ---------- READ ----------
-- Same site-scoped read a non-HQ WSHO has (minus nothing extra: memberPrivate,
-- auditEvents, organisations etc. are already excluded for non-HQ site roles),
-- and INCLUDING the RA project stores so the LMRA can show RA control lines.
drop policy if exists rec_read on records;
create policy rec_read on records for select using (
  org_id = my_org() and (
    ( my_hq() and (
        my_role() = 'admin'
        or (my_role() = 'wsho' and store <> 'memberPrivate')
        or (my_role() = 'hr' and store <> all (array['ra','raLibrary','raMasters','raMasterVersions','legacyDocs','raAdoptions','raProjectVersions','reviewTriggers']))
        or (my_role() = 'viewer' and store <> all (array['ra','raLibrary','raMasters','raMasterVersions','legacyDocs','raAdoptions','raProjectVersions','reviewTriggers','auditEvents','memberPrivate']))
    ))
    or (
      (not my_hq())
      and my_role() = any (array['wsho','viewer','supervisor'])
      and (my_project() is null or project_id = my_project() or project_id = '_company')
      and ( project_id <> '_company'
            or store = any (array['members','equipment','training','competencyTypes','workerCompetencies','sicProfiles','companyDocs','_meta'])
            or (my_role() = any (array['wsho','supervisor']) and store = any (array['raLibrary','raMasters','raMasterVersions'])) )
      and store <> all (array['auditEvents','organisations','clientTemplates','legacyDocs','memberPrivate'])
      and ( my_role() <> 'viewer'
            or store <> all (array['ra','raLibrary','raMasters','raMasterVersions','raAdoptions','raProjectVersions','reviewTriggers']) )
    )
    or (
      my_role() = 'subcon'
      and (my_project() is null or project_id = my_project() or project_id = '_company')
      and ( store = any (array['_project','_meta','sicProfiles','competencyTypes','organisations','locations','layouts','layoutVersions','locGeoms','spatialZones','zoneGeoms'])
            or (store = 'workerProjectAccess' and lower(coalesce(data->>'company','')) = lower(coalesce(my_subcon(),'')))
            or subcon_scope(store, data) )
    )
  )
);

-- ---------- WRITE: lmra + observations only, own site only ----------
drop policy if exists rec_supervisor_insert on records;
create policy rec_supervisor_insert on records for insert with check (
  org_id = my_org()
  and my_role() = 'supervisor'
  and store in ('lmra','observations')
  and project_id <> '_company'
  and (my_project() is null or project_id = my_project())
);

drop policy if exists rec_supervisor_update on records;
create policy rec_supervisor_update on records for update using (
  org_id = my_org()
  and my_role() = 'supervisor'
  and store in ('lmra','observations')
  and project_id <> '_company'
  and (my_project() is null or project_id = my_project())
);

-- ---------- verify ----------
-- select policyname, cmd from pg_policies where tablename = 'records';
-- Expect: rec_read, rec_staff_insert, rec_staff_update, rec_hr_insert,
--         rec_hr_update, rec_subcon_insert, rec_subcon_update,
--         rec_supervisor_insert, rec_supervisor_update

-- ---------- STORAGE: supervisors file LMRA reports and photos ----------
drop policy if exists "reports read staff" on storage.objects;
create policy "reports read staff" on storage.objects for select using (
  bucket_id = 'reports'
  and my_role() = any (array['admin','wsho','hr','viewer','supervisor'])
  and (my_hq() or my_project() is null or split_part(name,'/',1) = my_project())
);

drop policy if exists "reports write staff" on storage.objects;
create policy "reports write staff" on storage.objects for insert with check (
  bucket_id = 'reports'
  and my_role() = any (array['admin','wsho','hr','supervisor'])
  and (my_hq() or my_project() is null or split_part(name,'/',1) = my_project())
);
