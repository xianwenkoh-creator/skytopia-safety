// Worker-document approval by email.
//
// The HR manager does not live in this app, so he should not have to. He gets
// an email, clicks through to one page, and presses a button. No login, no
// password, no app.
//
// Two rules shape the whole design:
//
//  1. The email carries NO worker names — only the request number, the count,
//     the purpose and the recipient. The personal data stays in Singapore and
//     is shown only on the approval page. That keeps the mail vendor out of
//     scope as a data processor.
//
//  2. Opening the link must never decide anything. Outlook Safe Links and
//     Defender pre-click links to scan them; a plain "Approve" URL would
//     silently approve everything that passed through a scanner. So GET only
//     renders, and the button POSTs.
//
// Routes:
//   GET  ?t=<token>                 -> the approval page
//   POST (form: token, act, note)   -> the decision, then a confirmation page
//   POST ?a=send&mode=urgent|digest -> outbound mail (cron; x-cron-secret)
import { createClient } from "npm:@supabase/supabase-js@2";

const APP_NAME = "KKL CMS";
const TOKEN_DAYS = 7;

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

const b64u = (b: ArrayBuffer | Uint8Array) => {
  const a = b instanceof Uint8Array ? b : new Uint8Array(b);
  return btoa(String.fromCharCode(...a)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

async function sign(payload: string): Promise<string> {
  const secret = Deno.env.get("DOCREQ_SECRET");
  if (!secret) throw new Error("DOCREQ_SECRET is not set");
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return b64u(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload)));
}

/* token = <requestId>.<approverProfileId>.<expiryEpoch>.<signature> */
async function makeToken(reqId: string, who: string): Promise<string> {
  const exp = Math.floor(Date.now() / 1000) + TOKEN_DAYS * 86400;
  const body = `${reqId}.${who}.${exp}`;
  return `${body}.${await sign(body)}`;
}
async function readToken(tok: string) {
  const p = String(tok || "").split(".");
  if (p.length !== 4) return null;
  const [reqId, who, exp, sig] = p;
  const good = await sign(`${reqId}.${who}.${exp}`);
  /* constant-time-ish: compare full strings of equal length */
  if (sig.length !== good.length) return null;
  let diff = 0;
  for (let i = 0; i < sig.length; i++) diff |= sig.charCodeAt(i) ^ good.charCodeAt(i);
  if (diff !== 0) return null;
  if (Number(exp) * 1000 < Date.now()) return { expired: true, reqId, who };
  return { expired: false, reqId, who };
}

const admin = () => createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const PAGE_HEAD = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>${APP_NAME} — Document Request</title><style>
:root{--ink:#1a1a1a;--mut:#666;--line:#e2e2e2;--bg:#f6f6f4;--card:#fff;--ok:#0a7a3d;--no:#c5221f;--warn:#b06000}
@media(prefers-color-scheme:dark){:root{--ink:#ececec;--mut:#a0a0a0;--line:#333;--bg:#17181a;--card:#1f2022}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);
 font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
.wrap{max-width:640px;margin:0 auto;padding:24px 16px 56px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px;margin-bottom:14px}
h1{font-size:21px;margin:0 0 4px}h2{font-size:12px;text-transform:uppercase;letter-spacing:.07em;
 color:var(--mut);margin:20px 0 8px}
.sub{color:var(--mut);font-size:14px;margin:0 0 18px}
table{width:100%;border-collapse:collapse;font-size:15px}
td{padding:7px 0;border-bottom:1px solid var(--line);vertical-align:top}
td:first-child{color:var(--mut);width:38%}tr:last-child td{border-bottom:0}
.men td:first-child{color:var(--ink);width:auto}
.btn{display:block;width:100%;padding:14px;border-radius:9px;border:1px solid var(--line);
 background:var(--card);color:var(--ink);font:inherit;font-weight:600;cursor:pointer;margin-top:10px}
.btn.ok{background:var(--ok);border-color:var(--ok);color:#fff}
.btn.no{color:var(--no)}
textarea{width:100%;padding:10px;border:1px solid var(--line);border-radius:9px;background:var(--bg);
 color:var(--ink);font:inherit;resize:vertical}
.note{color:var(--mut);font-size:13px;margin-top:16px}
.big{font-size:34px;font-weight:700;line-height:1.1;margin:0 0 6px}
</style></head><body><div class="wrap">`;
const PAGE_FOOT = `</div></body></html>`;

const html = (body: string, status = 200) =>
  new Response(PAGE_HEAD + body + PAGE_FOOT, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store, no-cache, must-revalidate",
      "X-Robots-Tag": "noindex, nofollow",
      "Referrer-Policy": "no-referrer",
    },
  });

const notice = (title: string, msg: string, status = 200) =>
  html(`<div class="card"><h1>${esc(title)}</h1><p class="sub" style="margin:6px 0 0">${esc(msg)}</p></div>`, status);

async function loadRequest(reqId: string) {
  const { data } = await admin().from("records").select("*")
    .eq("store", "docRequests").eq("id", reqId).maybeSingle();
  return data;
}

/* ---------------- the approval page ---------------- */
async function renderPage(tok: string) {
  const t = await readToken(tok);
  if (!t) return notice("This link is not valid", "Ask Safety to send the request again.", 400);
  if (t.expired) return notice("This link has expired", "Links are good for 7 days. Ask Safety to send it again.", 410);

  const row = await loadRequest(t.reqId);
  if (!row) return notice("Request not found", "It may have been withdrawn.", 404);
  const d = row.data ?? {};
  const men: any[] = Array.isArray(d.memberIds) ? d.memberIds : [];

  if (d.status && d.status !== "Pending") {
    return notice(
      `Already ${String(d.status).toLowerCase()}`,
      `${d.no ?? "This request"} was ${String(d.status).toLowerCase()} by ${d.decidedByName ?? "someone"}` +
      `${d.decidedAt ? " on " + String(d.decidedAt).slice(0, 10) : ""}. Nothing more to do.`);
  }

  /* names are shown HERE, never in the email */
  const { data: mrows } = await admin().from("records").select("id,data")
    .eq("store", "members").eq("org_id", row.org_id).in("id", men.slice(0, 500));
  const byId = new Map((mrows ?? []).map((m: any) => [m.id, m.data ?? {}]));
  const list = men.map((id, i) => {
    const m: any = byId.get(id) ?? {};
    return `<tr><td>${i + 1}. ${esc(m.name ?? "(not found)")}</td><td style="text-align:right;color:var(--mut)">${
      esc([m.wid, m.company].filter(Boolean).join(" · "))}</td></tr>`;
  }).join("");

  return html(`
<div class="card">
  <h1>${esc(d.no ?? "Document request")}</h1>
  <p class="sub">${APP_NAME} · records for ${men.length} worker${men.length === 1 ? "" : "s"}</p>
  <table>
    <tr><td>Purpose</td><td>${esc(d.purpose ?? "")}</td></tr>
    <tr><td>Goes to</td><td>${esc(d.recipient ?? "")}</td></tr>
    <tr><td>Requested by</td><td>${esc(d.requestedByName ?? "")}</td></tr>
    <tr><td>Requested on</td><td>${esc(String(d.requestedAt ?? "").slice(0, 10))}</td></tr>
    ${d.note ? `<tr><td>Their note</td><td>${esc(d.note)}</td></tr>` : ""}
  </table>
</div>
<h2>Workers in this request</h2>
<div class="card"><table class="men">${list || "<tr><td>None listed.</td></tr>"}</table></div>
<form method="POST" class="card">
  <input type="hidden" name="token" value="${esc(tok)}">
  <h2 style="margin-top:0">Your decision</h2>
  <textarea name="note" rows="2" placeholder="Note for the requester (optional)"></textarea>
  <button class="btn ok" name="act" value="approve" type="submit">Release the records</button>
  <button class="btn no" name="act" value="decline" type="submit">Decline</button>
  <p class="note">Releasing opens a 14-day window for Safety to download the pack. The download is
  recorded against this request.</p>
</form>`);
}

/* ---------------- the decision ---------------- */
async function decide(form: FormData) {
  const t = await readToken(String(form.get("token") ?? ""));
  if (!t) return notice("This link is not valid", "Nothing was changed.", 400);
  if (t.expired) return notice("This link has expired", "Nothing was changed. Ask Safety to send it again.", 410);

  const act = String(form.get("act") ?? "");
  if (act !== "approve" && act !== "decline") return notice("Unknown action", "Nothing was changed.", 400);

  const row = await loadRequest(t.reqId);
  if (!row) return notice("Request not found", "It may have been withdrawn.", 404);
  const d = { ...(row.data ?? {}) };

  /* whoever the token was issued to must still be someone who may decide */
  const { data: who } = await admin().from("profiles").select("id,role,email,org_id")
    .eq("id", t.who).maybeSingle();
  if (!who || !["hr", "admin"].includes(who.role) || who.org_id !== row.org_id)
    return notice("Not permitted", "This link was issued to an account that can no longer release records.", 403);

  /* already decided in the app or on another device — do not overwrite */
  if (d.status && d.status !== "Pending")
    return notice(`Already ${String(d.status).toLowerCase()}`,
      `${d.no ?? "This request"} was handled by ${d.decidedByName ?? "someone"}. Nothing was changed.`);

  d.status = act === "approve" ? "Approved" : "Declined";
  d.decidedBy = who.id;
  d.decidedByName = who.email ?? "HR";
  d.decidedAt = new Date().toISOString();
  d.decisionNote = String(form.get("note") ?? "").trim();
  d.decidedVia = "email";
  if (act === "approve") {
    const e = new Date(Date.now() + 14 * 86400000);
    d.expiresAt = e.toISOString().slice(0, 10);
  }

  await admin().from("records").update({ data: d }).eq("id", row.id).eq("store", "docRequests");
  await admin().from("records").insert({
    id: crypto.randomUUID(), org_id: row.org_id, project_id: "_company", store: "auditEvents",
    data: {
      id: crypto.randomUUID(), at: new Date().toISOString(), who: d.decidedByName,
      action: act === "approve" ? "RELEASE" : "DECLINE", entity: "docRequests", entityId: row.id,
      prev: null, next: null,
      reason: `${d.no ?? ""} · ${(d.memberIds ?? []).length} worker(s) → ${d.recipient ?? ""} (by email)`,
    },
  });

  return act === "approve"
    ? html(`<div class="card"><p class="big" style="color:var(--ok)">Released</p>
        <p class="sub" style="margin:0">${esc(d.no ?? "")} — ${(d.memberIds ?? []).length} worker records.
        ${esc(d.requestedByName ?? "Safety")} can download the pack until ${esc(d.expiresAt ?? "")}.
        You can close this page.</p></div>`)
    : html(`<div class="card"><p class="big" style="color:var(--no)">Declined</p>
        <p class="sub" style="margin:0">${esc(d.no ?? "")} — nothing will be released.
        ${esc(d.requestedByName ?? "Safety")} will see this in the app${
          d.decisionNote ? ", together with your note" : ""}. You can close this page.</p></div>`);
}

/* ---------------- outbound mail ---------------- */
async function sendMail(to: string, subject: string, body: string) {
  const key = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("DOCREQ_FROM") ?? "KKL CMS <onboarding@resend.dev>";
  if (!key) throw new Error("RESEND_API_KEY is not set");
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to: [to], subject, html: body }),
  });
  if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
}

const mailShell = (inner: string) => `
<div style="font:15px/1.55 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;
 color:#1a1a1a;max-width:600px;margin:0 auto;padding:8px">${inner}
<p style="color:#888;font-size:12px;margin-top:26px;border-top:1px solid #e2e2e2;padding-top:12px">
Sent by ${APP_NAME}. Worker names are not included in this email — open the link to see them.
Links stop working after 7 days.</p></div>`;

/* one block per pending request. No worker names — only the count. */
async function reqBlock(row: any, who: string, base: string) {
  const d = row.data ?? {};
  const n = (d.memberIds ?? []).length;
  const url = `${base}?t=${encodeURIComponent(await makeToken(row.id, who))}`;
  const age = Math.floor((Date.now() - Date.parse(d.requestedAt ?? "")) / 86400000);
  return `<div style="border:1px solid #e2e2e2;border-radius:10px;padding:14px;margin:12px 0">
  <div style="font-weight:700;font-size:16px">${esc(d.no ?? "Request")} — ${n} worker${n === 1 ? "" : "s"}</div>
  <div style="color:#555;margin:4px 0 2px">${esc(d.purpose ?? "")} → ${esc(d.recipient ?? "")}</div>
  <div style="color:#888;font-size:13px">Raised by ${esc(d.requestedByName ?? "")}${
    Number.isFinite(age) && age >= 1 ? ` · waiting ${age} day${age === 1 ? "" : "s"}` : ""}${
    d.urgent ? ` · <b style="color:#b06000">marked urgent</b>` : ""}</div>
  <a href="${esc(url)}" style="display:inline-block;margin-top:11px;background:#0a7a3d;color:#fff;
   text-decoration:none;padding:10px 18px;border-radius:8px;font-weight:600">Review and decide</a>
</div>`;
}

async function runSend(mode: string, base: string) {
  const sb = admin();
  const { data: rows } = await sb.from("records").select("*")
    .eq("store", "docRequests").eq("data->>status", "Pending");
  let pend = rows ?? [];
  if (mode === "urgent") pend = pend.filter((r: any) => r.data?.urgent && !r.data?.notifiedAt);
  if (!pend.length) return { ok: true, mode, sent: 0, pending: 0 };

  const byOrg = new Map<string, any[]>();
  for (const r of pend) byOrg.set(r.org_id, [...(byOrg.get(r.org_id) ?? []), r]);

  let sent = 0;
  const problems: string[] = [];
  for (const [org, list] of byOrg) {
    const { data: approvers } = await sb.from("profiles").select("id,email,role")
      .eq("org_id", org).in("role", ["hr", "admin"]);
    const to = (approvers ?? []).filter((a: any) => a.role === "hr" && a.email);
    const recips = to.length ? to : (approvers ?? []).filter((a: any) => a.email);
    if (!recips.length) { problems.push(`org ${org}: nobody to email`); continue; }

    for (const person of recips) {
      const blocks: string[] = [];
      for (const r of list) blocks.push(await reqBlock(r, person.id, base));
      const urgent = mode === "urgent";
      const subject = urgent
        ? `Urgent: worker records need your approval (${list.length})`
        : list.length === 1
          ? `1 worker-record request needs your approval`
          : `${list.length} worker-record requests need your approval`;
      const lead = urgent
        ? `<p>Safety has marked ${list.length === 1 ? "this request" : "these requests"} urgent.</p>`
        : `<p>These requests are waiting on you. Each one opens a page where you can release or decline it —
           no login needed.</p>`;
      try {
        await sendMail(person.email, subject,
          mailShell(`<h2 style="font-size:19px;margin:0 0 6px">Worker records awaiting release</h2>${lead}${blocks.join("")}`));
        sent++;
      } catch (e) { problems.push(`${person.email}: ${e instanceof Error ? e.message : String(e)}`); }
    }
  }

  /* stamp so an urgent request is not chased twice */
  if (mode === "urgent" && sent) {
    for (const r of pend) {
      await sb.from("records").update({ data: { ...(r.data ?? {}), notifiedAt: new Date().toISOString() } })
        .eq("id", r.id).eq("store", "docRequests");
    }
  }
  return { ok: problems.length === 0, mode, sent, pending: pend.length, problems };
}

/* ---------------- router ---------------- */
Deno.serve(async (req) => {
  const url = new URL(req.url);
  const base = `${url.origin}${url.pathname}`;
  try {
    if (url.searchParams.get("a") === "send") {
      const want = Deno.env.get("DOCREQ_CRON_SECRET");
      if (!want || req.headers.get("x-cron-secret") !== want)
        return new Response(JSON.stringify({ error: "no" }), { status: 401 });
      const out = await runSend(url.searchParams.get("mode") ?? "digest", base);
      return new Response(JSON.stringify(out), { headers: { "Content-Type": "application/json" } });
    }
    if (req.method === "GET") {
      const t = url.searchParams.get("t");
      if (!t) return notice("Nothing to show", "Open the link from your email.", 400);
      return await renderPage(t);
    }
    if (req.method === "POST") return await decide(await req.formData());
    return notice("Not supported", "", 405);
  } catch (e) {
    console.error(e);
    return notice("Something went wrong", "Nothing was changed. Please try the link again.", 500);
  }
});
