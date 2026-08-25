# Turning on email approval for worker documents

The app already works without any of this: Safety raises a request at
**#/pack**, HR releases it at **#/docreq**, and only then can the pack be
downloaded. Everything below just means the HR manager can decide **from his
inbox**, without opening the app.

Three steps remain, about 15 minutes.

---

## 1. Database rules — ✅ DONE (applied 26 Aug 2026)

`supabase/doc-requests.sql` is live: `docRequests` is in the read/write
policies, and the `trg_docreq_guard` trigger is installed and **verified by
test** — an insert born `Approved` and a non-HR status flip were both rejected
by the database itself. The rule in the app's screens is a convenience; this
trigger is the enforcement.

---

## 2. Approval function — ✅ DEPLOYED (26 Aug 2026, verify_jwt off)

Live at `https://wrxyajtopaxgdfuxoxxl.supabase.co/functions/v1/docapproval`.
`verify_jwt` is off deliberately: the HR manager is **not signed in** when he
opens the link — the link's own signed token is the credential. Smoke-tested:
bare GET renders a neutral page, cron endpoint answers 401 without the secret.

It does nothing until the secrets in step 3 exist. To redeploy after editing:

```
supabase functions deploy docapproval --project-ref wrxyajtopaxgdfuxoxxl --no-verify-jwt
```

---

## 3. Set the secrets  *(you paste these, not me)*

Secrets are **project-wide**, not stored inside a function — do not go looking
for them under `docapproval`. Sidebar → **Edge Functions → Secrets**, or go
straight to:

```
https://supabase.com/dashboard/project/wrxyajtopaxgdfuxoxxl/functions/secrets
```


| Secret | What to put |
|---|---|
| `DOCREQ_SECRET` | A long random string. Signs the approval links. Change it and every outstanding link dies — which is how you revoke them. |
| `DOCREQ_CRON_SECRET` | Another long random string. Stops anyone but the scheduler triggering a send. |
| `RESEND_API_KEY` | From resend.com. Free tier is 3,000 emails a month — far more than you'll use. |
| `DOCREQ_FROM` | e.g. `KKL CMS <cms@kklenterprise.com.sg>`. Until the domain is verified at Resend, leave it unset and it falls back to their test sender. |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically.

To verify your domain, Resend gives you two DNS records to add. Worth doing —
mail from an unverified domain often lands in Junk, and an approval nobody sees
is an approval that doesn't happen.

---

## 4. Schedule the sending  *(after step 3 — the cron secret must exist first)*

SQL Editor → paste `supabase/doc-approval-schedule.sql`, **replacing both
`REPLACE_WITH_CRON_SECRET` placeholders** with the `DOCREQ_CRON_SECRET` from
step 3 → Run.

- **digest** — 18:00 Singapore daily, everything still waiting, one button each
- **urgent** — every 15 minutes, but only requests Safety ticked *Needed today*

To change the digest time, remember pg_cron runs on UTC: subtract 8 hours.

---

## 5. Test it before telling anyone

1. Sign in as Safety, raise a request at **#/pack** for one worker, tick
   *Needed today*.
2. Within 15 minutes the HR manager gets an email. Or force it now:

   ```
   curl -X POST -H "x-cron-secret: YOUR_CRON_SECRET" \
     "https://wrxyajtopaxgdfuxoxxl.supabase.co/functions/v1/docapproval?a=send&mode=urgent"
   ```

   It replies with how many were sent, and names any address it couldn't reach.
3. Open the link. You should see the request **and the worker names** — those
   appear only here, never in the email.
4. Press **Release the records**. Check the app: status Approved, decided *By
   email*, and the download buttons live for 14 days.

---

## Things worth knowing

**The email deliberately contains no worker names** — only the request number,
the count, the purpose and the recipient. Personal data stays in Singapore and
is shown only on the approval page. It also means Resend never processes
personal data, which keeps them out of scope under PDPA.

**Opening the link decides nothing.** Outlook Safe Links and Defender pre-click
links in email to scan them; a plain "Approve" URL would silently approve
anything that passed a scanner. The link only renders the page — the button
POSTs.

**Links expire after 7 days** and stop working the moment the request is
decided, so a forwarded email is not a second vote. If a link is ever
mishandled, rotating `DOCREQ_SECRET` kills every outstanding one at once.

**The token names the approver.** If that person stops being HR or admin, their
old links stop working — the function re-checks the role at the moment of the
decision, not when the mail was sent.

**If email is ever down, nothing is blocked** — HR can still open the app and
decide at `#/docreq`. Email is a way of reaching him, not the system of record.
