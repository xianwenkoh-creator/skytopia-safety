// Anonymous hazard reporting: QR poster carries a per-project token; anyone can
// submit an observation without an account. Token lives in the project's
// settings (data.settings.hazardToken on the '_project' row).
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const b = await req.json();
    const { projectId, token } = b;
    if (!projectId || !token || String(token).length < 12) return json({ error: "Bad request" }, 400);

    const { data: rows, error } = await admin.from("records")
      .select("org_id, data").eq("id", projectId).eq("store", "_project").eq("deleted", false).limit(1);
    if (error) return json({ error: error.message }, 500);
    const row = rows?.[0];
    if (!row || row.data?.settings?.hazardToken !== token)
      return json({ error: "This reporting code is not valid." }, 404);

    // basic abuse guard: max 60 anonymous reports per project per day
    const today = new Date().toISOString().slice(0, 10);
    const { count } = await admin.from("records")
      .select("id", { count: "exact", head: true })
      .eq("org_id", row.org_id).eq("project_id", projectId).eq("store", "observations")
      .like("id", "anon-" + today + "%");
    if ((count ?? 0) >= 60) return json({ error: "Report limit reached for today — please inform a supervisor directly." }, 429);

    const desc = String(b.desc || "").trim().slice(0, 1200);
    if (!desc) return json({ error: "Description required" }, 400);
    const photo = typeof b.photo === "string" && b.photo.startsWith("data:image/") && b.photo.length < 900000 ? b.photo : null;
    const id = "anon-" + today + "-" + Math.random().toString(36).slice(2, 8);
    const now = new Date();
    const rec: Record<string, unknown> = {
      id, date: today, time: now.toISOString().slice(11, 16),
      kind: "Negative — safety non-compliance", category: "Others",
      desc: "[Anonymous QR report] " + desc,
      location: String(b.area || "").slice(0, 120),
      initiator: "Anonymous (QR)", severity: "2", status: "Open",
    };
    if (photo) rec.photos = [photo];
    if (b.geo && typeof b.geo.lat === "number" && typeof b.geo.lng === "number")
      rec.geo = { lat: b.geo.lat, lng: b.geo.lng };
    const { error: insErr } = await admin.from("records").insert({
      org_id: row.org_id, id, project_id: projectId, store: "observations", data: rec,
    });
    if (insErr) return json({ error: insErr.message }, 500);
    return json({ ok: true });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
