// Supabase Edge Function: vote
// POST /functions/v1/vote  {poll_id, option_id, fingerprint, turnstile_token?}
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, IP_SALT, TURNSTILE_SECRET (optional)
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

async function verifyTurnstile(token: string, ip: string): Promise<boolean> {
  const secret = Deno.env.get("TURNSTILE_SECRET");
  if (!secret) return true; // not configured -> skip
  try {
    const r = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ secret, response: token, remoteip: ip }),
    });
    const j = await r.json();
    return j.success === true;
  } catch {
    return false;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const ipSalt = Deno.env.get("IP_SALT") || "change-me";

  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: "bad_request" }, 400); }
  const { poll_id, option_id, fingerprint, turnstile_token } = body || {};
  if (!poll_id || !option_id || !fingerprint || typeof fingerprint !== "string" || fingerprint.length < 16) {
    return json({ ok: false, error: "bad_request" }, 400);
  }

  const ip = (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || "unknown";
  const ipHash = await sha256Hex(ip + "::" + ipSalt);

  // poll must exist and be votable
  const { data: poll } = await supabase.from("polls").select("*").eq("id", poll_id).single();
  if (!poll) return json({ ok: false, error: "poll_not_found" }, 404);
  const now = Date.now();
  const votable =
    poll.status === "open" ||
    (poll.status === "scheduled" &&
      (!poll.scheduled_opens_at || now >= new Date(poll.scheduled_opens_at).getTime()) &&
      (!poll.scheduled_closes_at || now <= new Date(poll.scheduled_closes_at).getTime()));
  if (!votable) return json({ ok: false, error: "poll_closed" }, 400);

  // option must belong to poll
  const { data: opt } = await supabase.from("poll_options")
    .select("id").eq("id", option_id).eq("poll_id", poll_id).single();
  if (!opt) return json({ ok: false, error: "invalid_option" }, 400);

  // bans
  const { data: ban } = await supabase.from("bans").select("id,expires_at")
    .or(`fingerprint_hash.eq.${fingerprint},ip_hash.eq.${ipHash}`)
    .or(`expires_at.is.null,expires_at.gt.${new Date().toISOString()}`).limit(1).single();
  if (ban) return json({ ok: false, error: "banned" }, 403);

  // rate limit: >20 votes/hour from one IP hash
  const hourAgo = new Date(now - 3600_000).toISOString();
  const { count: recentIp } = await supabase.from("votes")
    .select("id", { count: "exact", head: true })
    .eq("ip_hash", ipHash).gte("created_at", hourAgo);
  if ((recentIp || 0) > 20) {
    await supabase.from("votes").insert({
      poll_id, option_id, fingerprint_hash: fingerprint, ip_hash: ipHash,
      status: "flagged", flag_reason: "rate_limited",
    });
    return json({ ok: false, error: "rate_limited" }, 429);
  }

  // duplicate: same fingerprint already voted valid on this poll
  const { data: existing } = await supabase.from("votes").select("id")
    .eq("poll_id", poll_id).eq("fingerprint_hash", fingerprint).eq("status", "valid")
    .limit(1).single();
  const { data: results } = await supabase.rpc("get_public_results", { p_poll_id: poll_id });
  if (existing) return json({ ok: true, already_voted: true, results });

  // burst heuristic: >5 distinct fingerprints from this IP in 10 min -> flag
  const tenMinAgo = new Date(now - 600_000).toISOString();
  const { data: burst } = await supabase.from("votes")
    .select("fingerprint_hash").eq("ip_hash", ipHash).gte("created_at", tenMinAgo);
  const distinct = new Set((burst || []).map((r: any) => r.fingerprint_hash)).size;
  const flagged = distinct >= 5;

  // captcha
  let turnstileOk = false;
  if (poll.require_captcha) {
    if (!turnstile_token) return json({ ok: false, error: "captcha_required" }, 400);
    turnstileOk = await verifyTurnstile(turnstile_token, ip);
    if (!turnstileOk) return json({ ok: false, error: "captcha_failed" }, 400);
  }

  const { error } = await supabase.from("votes").insert({
    poll_id, option_id,
    fingerprint_hash: fingerprint,
    ip_hash: ipHash,
    country_code: (req.headers.get("cf-ipcountry") || req.headers.get("x-vercel-ip-country") || null),
    status: flagged ? "flagged" : "valid",
    flag_reason: flagged ? "burst_from_ip" : null,
    turnstile_ok: turnstileOk,
  });
  if (error) return json({ ok: false, error: "db_error" }, 500);

  const { data: results2 } = await supabase.rpc("get_public_results", { p_poll_id: poll_id });
  return json({ ok: true, already_voted: false, flagged, results: results2 });
});
