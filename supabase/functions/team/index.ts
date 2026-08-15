// Team management edge function — invite / setRole / remove.
// Runs with the service role; every call verifies the caller is an org admin.
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
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: { user } } = await admin.auth.getUser(jwt);
    if (!user) return json({ error: "Not signed in" }, 401);
    const { data: me } = await admin.from("profiles").select("*").eq("id", user.id).single();
    if (!me || me.role !== "admin") return json({ error: "Admins only" }, 403);

    const b = await req.json();

    if (b.action === "invite") {
      const email = String(b.email || "").trim().toLowerCase();
      if (!/^\S+@\S+\.\S+$/.test(email)) return json({ error: "Invalid email" }, 400);
      const role = ["admin", "wsho", "subcon", "viewer"].includes(b.role) ? b.role : "viewer";
      const { data, error } = await admin.auth.admin.inviteUserByEmail(email, {
        redirectTo: b.redirectTo || undefined,
      });
      if (error) return json({ error: error.message }, 400);
      // the on_auth_user_created trigger has made a viewer profile; set the real role
      await admin.from("profiles").update({
        role, subcon: role === "subcon" ? (b.subcon || null) : null,
      }).eq("id", data.user.id);
      return json({ ok: true, userId: data.user.id });
    }

    if (b.action === "setRole") {
      const role = ["admin", "wsho", "subcon", "viewer"].includes(b.role) ? b.role : null;
      if (!role || !b.userId) return json({ error: "Bad request" }, 400);
      if (b.userId === user.id) return json({ error: "Change your own role via another admin" }, 400);
      const { data: target } = await admin.from("profiles").select("org_id").eq("id", b.userId).single();
      if (!target || target.org_id !== me.org_id) return json({ error: "Not in your org" }, 404);
      await admin.from("profiles").update({
        role, subcon: role === "subcon" ? (b.subcon || null) : null,
      }).eq("id", b.userId);
      return json({ ok: true });
    }

    if (b.action === "remove") {
      if (!b.userId) return json({ error: "Bad request" }, 400);
      if (b.userId === user.id) return json({ error: "You cannot remove yourself" }, 400);
      const { data: target } = await admin.from("profiles").select("org_id").eq("id", b.userId).single();
      if (!target || target.org_id !== me.org_id) return json({ error: "Not in your org" }, 404);
      const { error } = await admin.auth.admin.deleteUser(b.userId);
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    return json({ error: "Unknown action" }, 400);
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});
