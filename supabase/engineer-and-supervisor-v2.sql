-- ============================================================================
-- KKL CMS: access changes 26 Aug 2026
--   - Supervisor now also writes toolbox meetings, checklists and inspections
--     (two-stage closure: he rectifies, safety verifies - enforced in-app,
--     stamped on every step).
--   - New role `engineer` (Manager / Engineer / Project Coordinator): writes
--     work activities on his own site, reads the site registers.
-- ============================================================================

-- ---------- supervisor: wider write list ----------
drop policy if exists rec_supervisor_insert on records;
create policy rec_supervisor_insert on records for insert with check (
  org_id = my_org()
  and my_role() = 'supervisor'
  and store in ('lmra','observations','tbm','checklists','inspections')
  and project_id <> '_company'
  and (my_project() is null or project_id = my_project())
);

drop policy if exists rec_supervisor_update on records;
create policy rec_supervisor_update on records for update using (
  org_id = my_org()
  and my_role() = 'supervisor'
  and store in ('lmra','observations','tbm','checklists','inspections')
  and project_id <> '_company'
  and (my_project() is null or project_id = my_project())
);

-- ---------- engineer: work activities only ----------
drop policy if exists rec_engineer_insert on records;
create policy rec_engineer_insert on records for insert with check (
  org_id = my_org()
  and my_role() = 'engineer'
  and store = 'workActivities'
  and project_id <> '_company'
  and (my_project() is null or project_id = my_project())
);

drop policy if exists rec_engineer_update on records;
create policy rec_engineer_update on records for update using (
  org_id = my_org()
  and my_role() = 'engineer'
  and store = 'workActivities'
  and project_id <> '_company'
  and (my_project() is null or project_id = my_project())
);

-- ---------- read: engineer joins the site-scoped read branch ----------
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
      and my_role() = any (array['wsho','viewer','supervisor','engineer'])
      and (my_project() is null or project_id = my_project() or project_id = '_company')
      and ( project_id <> '_company'
            or store = any (array['members','equipment','training','competencyTypes','workerCompetencies','sicProfiles','companyDocs','_meta'])
            or (my_role() = any (array['wsho','supervisor','engineer']) and store = any (array['raLibrary','raMasters','raMasterVersions'])) )
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

-- ---------- storage: engineers can read the report library ----------
drop policy if exists "reports read staff" on storage.objects;
create policy "reports read staff" on storage.objects for select using (
  bucket_id = 'reports'
  and my_role() = any (array['admin','wsho','hr','viewer','supervisor','engineer'])
  and (my_hq() or my_project() is null or split_part(name,'/',1) = my_project())
);
