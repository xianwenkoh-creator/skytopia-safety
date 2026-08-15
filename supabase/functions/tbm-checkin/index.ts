// Worker QR check-in for toolbox meetings. Workers have no accounts: the QR
// code carries a one-off token stored in the TBM record; this function
// validates it, serves the roster + a random check question, and appends
// the worker's check-in (with quiz correctness) to the record.
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
    const { projectId, tbmId, token } = b;
    if (!projectId || !tbmId || !token || String(token).length < 10) return json({ error: "Bad request" }, 400);

    // token gates everything: the row must match id + project + qrToken
    const { data: rows, error } = await admin.from("records")
      .select("org_id, project_id, data")
      .eq("id", tbmId).eq("project_id", projectId).eq("store", "tbm").eq("deleted", false)
      .limit(1);
    if (error) return json({ error: error.message }, 500);
    const row = rows?.[0];
    if (!row || row.data?.qrToken !== token) return json({ error: "This check-in code is not valid or has expired." }, 404);

    // meeting must be from today or yesterday (codes go stale after that)
    const recDate = row.data?.date || "";
    const ageDays = (Date.now() - new Date(recDate + "T00:00").getTime()) / 864e5;
    if (!(ageDays >= -1 && ageDays < 2)) return json({ error: "This toolbox meeting's check-in has closed." }, 410);

    const quiz: { q: string; o: string[]; a: number }[] = row.data?.quiz || [];

    if (b.action === "info") {
      const { data: proj } = await admin.from("records").select("data")
        .eq("org_id", row.org_id).eq("id", projectId).eq("store", "_project").limit(1).single();
      const { data: mems } = await admin.from("records").select("id, data")
        .eq("org_id", row.org_id).eq("project_id", "_company").eq("store", "members").eq("deleted", false)
        .limit(500);
      const qIdx = quiz.length ? Math.floor(Math.random() * quiz.length) : null;
      return json({
        project: proj?.data?.settings?.project || "",
        date: recDate,
        members: (mems || []).map((m) => ({ id: m.id, name: m.data?.name || "" })).filter((m) => m.name),
        qIdx,
        question: qIdx === null ? null : { q: quiz[qIdx].q, o: quiz[qIdx].o }, // answer key stays server-side
      });
    }

    if (b.action === "submit") {
      const name = String(b.name || "").trim().slice(0, 80);
      if (!name) return json({ error: "Name required" }, 400);
      const checkins = row.data.checkins || [];
      if (checkins.length >= 300) return json({ error: "Check-in list is full" }, 429);
      if (checkins.some((c: { name: string }) => c.name.toLowerCase() === name.toLowerCase()))
        return json({ error: "You have already checked in.", already: true }, 409);
      const qIdx = typeof b.qIdx === "number" && quiz[b.qIdx] ? b.qIdx : null;
      const answer = typeof b.answer === "number" ? b.answer : null;
      const correct = qIdx !== null && answer !== null ? quiz[qIdx].a === answer : null;
      checkins.push({
        name, memberId: b.memberId || null, company: String(b.company || "").slice(0, 80),
        qIdx, answer, correct, at: new Date().toISOString(),
      });
      const data = { ...row.data, checkins };
      const { error: upErr } = await admin.from("records").update({ data })
        .eq("org_id", row.org_id).eq("id", tbmId);
      if (upErr) return json({ error: upErr.message }, 500);
      return json({ ok: true, correct, answerKey: qIdx !== null ? quiz[qIdx].a : null });
    }

    return json({ error: "Unknown action" }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
