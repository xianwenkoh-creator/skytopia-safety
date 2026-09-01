// Open a machinery document from inside the app.
//
// The 3.9 GB of PDFs stay in S3 and are never copied. A signed-in member of
// staff asks for one document; this function checks who they are, then hands
// back a link that works for ten minutes and only for that exact file.
//
// The AWS key lives here as a secret and never reaches a phone. Nobody can
// browse the bucket through this - only fetch a key that the equipment
// register already lists, which is what makes it safe to expose at all.
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const BUCKET = "kklmachinery";
const REGION = "ap-southeast-1";
const TTL = 600; // ten minutes is long enough to open, short enough to not be a copy

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) =>
  [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const sha256 = async (s: string) => hex(await crypto.subtle.digest("SHA-256", enc.encode(s)));

async function hmac(key: Uint8Array, msg: string): Promise<Uint8Array> {
  const raw = key.buffer.slice(key.byteOffset, key.byteOffset + key.byteLength) as ArrayBuffer;
  const k = await crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(msg)));
}

/* AWS Signature V4, query-string form - a presigned GET URL */
async function presign(key: string): Promise<string> {
  const ak = Deno.env.get("AWS_ACCESS_KEY_ID");
  const sk = Deno.env.get("AWS_SECRET_ACCESS_KEY");
  if (!ak || !sk) throw new Error("AWS credentials are not set");

  const now = new Date();
  const stamp = now.toISOString().replace(/[:-]|\.\d{3}/g, "");   // 20260901T101530Z
  const day = stamp.slice(0, 8);
  const scope = `${day}/${REGION}/s3/aws4_request`;
  const host = `${BUCKET}.s3.${REGION}.amazonaws.com`;
  const canonicalKey = key.split("/").map(encodeURIComponent).join("/");

  const q = new URLSearchParams({
    "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
    "X-Amz-Credential": `${ak}/${scope}`,
    "X-Amz-Date": stamp,
    "X-Amz-Expires": String(TTL),
    "X-Amz-SignedHeaders": "host",
  });
  q.sort();

  const canonical = [
    "GET", "/" + canonicalKey, q.toString(),
    `host:${host}\n`, "host", "UNSIGNED-PAYLOAD",
  ].join("\n");

  const toSign = ["AWS4-HMAC-SHA256", stamp, scope, await sha256(canonical)].join("\n");
  let k = await hmac(enc.encode("AWS4" + sk), day);
  k = await hmac(k, REGION);
  k = await hmac(k, "s3");
  k = await hmac(k, "aws4_request");
  const sigBytes = await hmac(k, toSign);
  const sig = hex(sigBytes.buffer.slice(sigBytes.byteOffset, sigBytes.byteOffset + sigBytes.byteLength) as ArrayBuffer);

  return `https://${host}/${canonicalKey}?${q.toString()}&X-Amz-Signature=${sig}`;
}

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
    const { data: me } = await admin.from("profiles").select("role, org_id").eq("id", user.id).single();
    if (!me) return json({ error: "No profile" }, 403);
    /* subcontractors do not get the company's machinery paperwork */
    if (!["admin", "wsho", "hr", "supervisor", "engineer", "viewer"].includes(me.role))
      return json({ error: "Not permitted" }, 403);

    const { key } = await req.json();
    if (typeof key !== "string" || !key.startsWith("documents/") || key.includes(".."))
      return json({ error: "Bad key" }, 400);

    /* the key must already be listed on an equipment record - this function is
       a door to the register's documents, not a window into the bucket */
    const { data: hit } = await admin.from("records").select("id")
      .eq("store", "equipment").eq("org_id", me.org_id)
      .filter("data->s3docs", "cs", JSON.stringify([{ k: key }]))
      .limit(1).maybeSingle();
    if (!hit) return json({ error: "That document is not in the register" }, 404);

    return json({ url: await presign(key), expiresIn: TTL });
  } catch (e) {
    console.error(e);
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
