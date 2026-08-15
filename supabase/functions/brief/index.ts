// AI toolbox briefing — refines the deterministic briefing into a tight
// 60-second brief, reads the day's work-area photos for hazards, and
// translates for the site's workforce. Requires ANTHROPIC_API_KEY secret;
// callers must be signed-in org members (any role that can run a TBM).
import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const SCHEMA = {
  type: "object",
  properties: {
    brief_en: {
      type: "string",
      description: "The 60-second toolbox briefing in simple English. Structure: today's top 3 risks -> what can kill or injure you -> what controls MUST be in place. Short imperative sentences a worker with basic English follows. End with the one-line permit reminder if permits were given.",
    },
    photo_hazards: {
      type: "array", items: { type: "string" },
      description: "Specific hazards or things to check visible in the supplied site photos, one short line each, empty array if no photos or nothing notable.",
    },
    translations: {
      type: "object",
      properties: {
        bn: { type: "string" }, ta: { type: "string" }, zh: { type: "string" },
        my: { type: "string" }, ms: { type: "string" },
      },
      required: ["bn", "ta", "zh", "my", "ms"],
      additionalProperties: false,
      description: "Faithful translations of brief_en into Bangla (bn), Tamil (ta), Simplified Chinese (zh), Burmese (my) and Bahasa Melayu (ms), in the everyday register migrant construction workers in Singapore actually speak.",
    },
  },
  required: ["brief_en", "photo_hazards", "translations"],
  additionalProperties: false,
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!apiKey) return json({ error: "AI briefing is not configured (no ANTHROPIC_API_KEY secret set)." }, 503);

    // caller must be a signed-in org member
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: { user } } = await admin.auth.getUser(jwt);
    if (!user) return json({ error: "Not signed in" }, 401);
    const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).single();
    if (!me || me.role === "viewer") return json({ error: "Viewers cannot generate briefings" }, 403);

    const b = await req.json();
    const photos: string[] = (b.photos || []).slice(0, 3);

    const content: Anthropic.MessageParam["content"] = [];
    for (const p of photos) {
      const m = /^data:(image\/\w+);base64,(.+)$/.exec(p);
      if (m) {
        content.push({
          type: "image",
          source: { type: "base64", media_type: m[1] as "image/jpeg", data: m[2] },
        });
      }
    }
    content.push({
      type: "text",
      text: [
        "You are the WSH officer's assistant on a Singapore construction site. Produce today's toolbox briefing.",
        "",
        "Today's activities: " + (b.activities || []).join(", "),
        b.ptw ? "Permits issued (ePTW): " + b.ptw : "No permits recorded.",
        b.weather ? "Weather: " + b.weather : "",
        "",
        "Baseline top risks (from the site's hazard library):",
        ...(b.risks || []).map((r: { h: string; c: string }, i: number) => `${i + 1}. ${r.h} — controls: ${r.c}`),
        (b.ra || []).length ? "\nSite risk assessments in force:" : "",
        ...(b.ra || []).map((r: { activity: string; hazards: string[] }) =>
          `- ${r.activity}: ${(r.hazards || []).join("; ")}`),
        (b.yesterday || []).length ? "\nYesterday's lessons / recent near misses:" : "",
        ...(b.yesterday || []).map((y: string) => "- " + y),
        "",
        photos.length
          ? "The attached photos are TODAY'S actual work areas. Look at them carefully for real, visible hazards or things the crew should check (access, edges, housekeeping, plant position, exclusion zones)."
          : "No photos supplied.",
        "",
        "Keep brief_en readable aloud in about 60 seconds. Simple words. Singapore site vocabulary (banksman, PTW, LS, WAH).",
      ].filter(Boolean).join("\n"),
    });

    const client = new Anthropic({ apiKey });
    const response = await (client.beta.messages.create as any)({
      model: "claude-opus-5",
      max_tokens: 6000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      output_config: { effort: "low", format: { type: "json_schema", schema: SCHEMA } },
      messages: [{ role: "user", content }],
    });

    if (response.stop_reason === "refusal") {
      return json({ error: "The AI declined this request — use the built-in briefing." }, 502);
    }
    const text = (response.content || []).find((c: { type: string }) => c.type === "text");
    if (!text) return json({ error: "Empty AI response" }, 502);
    return json(JSON.parse(text.text));
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
