-- ============================================================
-- RA approval is a named appointment - Sep 2026
--
-- Owner's ruling: approving your own draft is allowed, but ONLY the Safety
-- Manager and Deputy Safety Manager may approve at all. The admin ticks the
-- two of them on the Team page; this trigger makes the rule real - whatever
-- any screen shows, nobody else can move an RA revision into an approved
-- status, and nobody can quietly tamper with one that is already approved.
-- ============================================================

alter table public.profiles add column if not exists ra_approver boolean not null default false;

create or replace function public.raver_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare ok boolean; st_new text; st_old text;
begin
  if new.store not in ('raProjectVersions','raMasterVersions') then return new; end if;
  if auth.uid() is null then return new; end if;   /* service / management path */

  st_new := coalesce(new.data->>'status','');
  st_old := case when tg_op = 'UPDATE' then coalesce(old.data->>'status','') else '' end;
  if st_new = st_old then return new; end if;      /* status untouched: normal edit */

  /* entering an approved status, or leaving one (supersede/unlock), is the
     approver's act alone */
  if st_new in ('APPROVED','LEGACY-APPROVED')
     or st_old in ('APPROVED','LEGACY-APPROVED') then
    select ra_approver into ok from profiles where id = auth.uid();
    if not coalesce(ok, false) then
      raise exception 'Only the Safety Manager or Deputy Safety Manager can approve an RA revision.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_raver_guard on public.records;
create trigger trg_raver_guard
  before insert or update on public.records
  for each row execute function public.raver_guard();
