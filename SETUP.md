# Cloud sync setup (Supabase) — one time, ~10 minutes

The app works standalone (data stays in the browser). Connecting Supabase adds
team sync: company registers + all projects shared across devices, with roles.

## 1. Create the project
1. Sign in at https://supabase.com/dashboard (free account).
2. **New project** → any name (e.g. `skytopia-safety`) → region **Southeast Asia
   (Singapore)** → set a database password (keep it somewhere safe) → Create.
   Free tier is fine.

## 2. Run the setup SQL
1. In the project: left sidebar → **SQL Editor** → **New query**.
2. Paste the entire contents of [`supabase/setup.sql`](supabase/setup.sql) → **Run**.
   You should see "Success. No rows returned".

## 3. Create your login (you = admin)
1. Left sidebar → **Authentication** → **Users** → **Add user** → **Create new user**.
2. Enter your email + a password, tick **Auto Confirm User**, create.
   *The first user created automatically becomes the org **admin**.*

## 4. Connect the app
1. In Supabase: **Settings → API** — copy the **Project URL** and the
   **anon / public** key (never the service_role key).
2. Open the app → **Settings → Cloud sync (Supabase)** → paste both → **Save
   connection** → sign in with the email + password from step 3.
3. The dot on the gear icon turns green. Your device's data uploads on first sync.

## 5. Add teammates
For each person: **Authentication → Users → Add user** (auto-confirm), then set
their role: **Table Editor → profiles** → edit their row:

| role     | can do |
|----------|--------|
| `admin`  | everything, all projects + manage users |
| `wsho`   | read/write everything in all projects |
| `subcon` | sees & updates ONLY observations/defects tagged with their company, and submits their own workers/equipment/training. Set the `subcon` column to their company name exactly as it is typed on records (case-insensitive). |
| `viewer` | read-only everything (client / RE / auditor) |

New sign-ups default to `viewer` until promoted.

On each teammate's device: open the app → Settings → Cloud sync → paste the same
URL + anon key → they sign in with their own account.

## Notes
- **Free tier pauses after 7 days without traffic** (data kept). Restore it in
  the dashboard, or just use the app at least weekly. Upgrade to Pro (US$25/mo)
  removes this when the tool goes commercial.
- Sync is offline-first: the site team keeps working with no signal; changes
  push when back online. If the same record is edited on two devices, the most
  recently synced edit wins.
- Photos currently live inside the record data (compressed). At roughly 6,000+
  photos the free 500 MB database fills — the upgrade path is moving photos to
  Supabase Storage (1 GB free), a later change.
- The anon key is safe to share with the team (it only grants what the
  row-level security allows). The **service_role** key and the database
  password must never be shared or pasted into the app.
