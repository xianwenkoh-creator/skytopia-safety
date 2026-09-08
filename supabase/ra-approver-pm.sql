-- ============================================================
-- The RA approver is the site Project Manager - Sep 2026
--
-- Owner: "approver should be the PM of the site". KKL's own RAs are signed
-- Conducted by (RA team) -> Reviewed by (WSHO) -> Approved by (Project
-- Manager), and the subcontractors' RAs use the same block.
--
-- The app has no PM role - the man who signs as PM (Chen Kok Yong) holds
-- 'hr', which rec_read blocks from every RA store. So approval is made an
-- APPOINTMENT rather than a role: whoever the admin designates
-- (profiles.ra_approver) can read and sign off RAs, whatever their role.
-- raver_guard already tests the flag alone, so the gate itself is unchanged.
-- ============================================================

create or replace function public.my_ra_approver() returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce(ra_approver, false) from public.profiles where id = auth.uid() $$;

-- 1) READ: a designated approver reaches the RA stores whatever their role.
--    Reproduced from the live policy with one added branch.
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
      /* the designated RA approver - the site PM - sees the RA register and
         the workforce context needed to judge a revision, nothing more */
      or ( public.my_ra_approver()
           and store = any (array['ra','raLibrary','raMasters','raMasterVersions','raAdoptions',
                                  'raProjectVersions','reviewTriggers','raProjectVersions','workActivities',
                                  '_project','_meta']) )
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

-- 2) WRITE: the approver may sign off a revision (and leave comments on it).
drop policy if exists rec_ra_approver_update on public.records;
create policy rec_ra_approver_update on public.records
  for update using (
    org_id = public.my_org() and public.my_ra_approver()
    and store = any (array['raAdoptions','raProjectVersions','raMasterVersions','raMasters','reviewTriggers'])
  )
  with check (org_id = public.my_org());

drop policy if exists rec_ra_approver_insert on public.records;
create policy rec_ra_approver_insert on public.records
  for insert with check (
    org_id = public.my_org() and public.my_ra_approver()
    and store = any (array['raProjectVersions','raMasterVersions','reviewTriggers','auditEvents'])
  );
