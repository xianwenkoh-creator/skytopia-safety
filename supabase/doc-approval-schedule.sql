-- ============================================================
-- When the HR manager gets emailed  (run AFTER doc-requests.sql)
--
--   digest  - once each evening, everything still waiting, one button each
--   urgent  - every 15 minutes, but only requests Safety ticked "Needed today"
--
-- Times below are UTC, because pg_cron is UTC. Singapore is UTC+8:
--   18:00 SGT = 10:00 UTC
-- ============================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- The cron secret and the function URL live in one place so they are easy to
-- rotate. Replace both values before running.
--   FUNCTION_URL = https://wrxyajtopaxgdfuxoxxl.supabase.co/functions/v1/docapproval
--   CRON_SECRET  = the same string you set as DOCREQ_CRON_SECRET in the
--                  Edge Function secrets (make up a long random one)

select cron.unschedule('docreq-digest') where exists
  (select 1 from cron.job where jobname = 'docreq-digest');
select cron.unschedule('docreq-urgent') where exists
  (select 1 from cron.job where jobname = 'docreq-urgent');

-- 18:00 Singapore, every day
select cron.schedule('docreq-digest', '0 10 * * *', $cron$
  select net.http_post(
    url     := 'https://wrxyajtopaxgdfuxoxxl.supabase.co/functions/v1/docapproval?a=send&mode=digest',
    headers := jsonb_build_object('x-cron-secret', 'REPLACE_WITH_CRON_SECRET',
                                  'Content-Type', 'application/json'),
    body    := '{}'::jsonb);
$cron$);

-- every 15 minutes, urgent only
select cron.schedule('docreq-urgent', '*/15 * * * *', $cron$
  select net.http_post(
    url     := 'https://wrxyajtopaxgdfuxoxxl.supabase.co/functions/v1/docapproval?a=send&mode=urgent',
    headers := jsonb_build_object('x-cron-secret', 'REPLACE_WITH_CRON_SECRET',
                                  'Content-Type', 'application/json'),
    body    := '{}'::jsonb);
$cron$);

-- check what is scheduled
-- select jobname, schedule, active from cron.job where jobname like 'docreq%';
-- and what happened
-- select jobname, status, return_message, start_time
--   from cron.job_run_details order by start_time desc limit 20;
