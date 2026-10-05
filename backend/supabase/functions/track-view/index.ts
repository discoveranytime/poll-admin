// Supabase Edge Function: track-view
// POST /functions/v1/track-view  {poll_id, fingerprint}
// Counts max one view per fingerprint per hour (anti-inflation).
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, IP_SALT
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false }, 405);
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false }, 400); }
  const { poll_id, fingerprint } = body || {};
  if (!poll_id) return json({ ok: false }, 400);

  const ip = (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || "unknown";
  const ipHash = await sha256Hex(ip + "::" + (Deno.env.get("IP_SALT") || "change-me"));

  if (fingerprint) {
    const hourAgo = new Date(Date.now() - 3600_000).toISOString();
    const { data } = await supabase.from("poll_views").select("id")
      .eq("poll_id", poll_id).eq("fingerprint_hash", fingerprint)
      .gte("created_at", hourAgo).limit(1).single();
    if (data) return json({ ok: true, counted: false });
  }
  await supabase.from("poll_views").insert({
    poll_id, fingerprint_hash: fingerprint || null, ip_hash: ipHash,
  });
  return json({ ok: true, counted: true });
});
