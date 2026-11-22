// Dorly phone verification through Twilio Verify.
//   {action:"send",  phone, purpose:"signup"|"reset"}          -> sends an SMS code
//   {action:"check", phone, code, purpose}                       -> returns a short-lived signed token
//   {action:"reset", phone, token, password}                     -> sets a new password (needs a "reset" token)
// Secrets (Supabase > Edge Functions > Secrets): TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_VERIFY_SID
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { makeToken, readToken } from "./token.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const toEn = (s: string) => String(s).replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 1632)).replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 1776));
function normPhone(s: string) {
  s = toEn(s || "").replace(/[\s\-()]/g, "");
  if (s.startsWith("+20")) s = "0" + s.slice(3);
  else if (s.startsWith("0020")) s = "0" + s.slice(4);
  else if (/^20\d{10}$/.test(s)) s = "0" + s.slice(2);
  return s;
}
const okPhone = (s: string) => /^01[0125]\d{8}$/.test(s);
const e164 = (p: string) => "+20" + p.slice(1);

const SID = Deno.env.get("TWILIO_ACCOUNT_SID") || "";
const TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN") || "";
const VSID = Deno.env.get("TWILIO_VERIFY_SID") || "";

async function twilio(path: string, form: Record<string, string>) {
  const r = await fetch(`https://verify.twilio.com/v2/Services/${VSID}/${path}`, {
    method: "POST",
    headers: { Authorization: "Basic " + btoa(`${SID}:${TOKEN}`), "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(form),
  });
  const body = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, body };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let b: any;
  try { b = await req.json(); } catch { return json({ error: "bad_json" }, 400); }

  const action = String(b.action || "");
  const purpose = b.purpose === "reset" ? "reset" : "signup";
  const phone = normPhone(String(b.phone || ""));
  if (!okPhone(phone)) return json({ error: "phone" }, 400);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: prof } = await admin.from("dorly_profiles").select("id, disabled").eq("phone", phone).maybeSingle();

  if (action === "reset") {
    const t = await readToken(String(b.token || ""));
    const pw = String(b.password || "");
    if (!t || t.phone !== phone || t.purpose !== "reset") return json({ error: "token" }, 400);
    if (pw.length < 8 || pw.length > 72 || !/\d/.test(pw) || !/[A-Za-z؀-ۿ]/.test(pw)) return json({ error: "password" }, 400);
    if (prof && !prof.disabled) {
      const { error } = await admin.auth.admin.updateUserById(prof.id, { password: pw });
      if (error) return json({ error: "update_failed" }, 500);
    }
    return json({ ok: true });
  }

  if (!SID || !TOKEN || !VSID) return json({ error: "sms_not_configured" }, 503);

  if (action === "send") {
    if (purpose === "signup" && prof) return json({ error: "taken_phone" }, 409);
    // reset for an unknown number: answer "ok" without sending, so numbers can't be probed
    if (purpose === "reset" && (!prof || prof.disabled)) return json({ ok: true });
    const r = await twilio("Verifications", { To: e164(phone), Channel: "sms", Locale: "ar" });
    if (!r.ok) {
      console.error("twilio send", r.status, r.body?.code, r.body?.message);
      return json({ error: r.status === 429 || r.body?.code === 60203 ? "too_many" : "send_failed" }, r.status === 429 ? 429 : 502);
    }
    return json({ ok: true });
  }

  if (action === "check") {
    const code = toEn(String(b.code || "")).replace(/\D/g, "");
    if (code.length < 4 || code.length > 10) return json({ error: "code" }, 400);
    const r = await twilio("VerificationCheck", { To: e164(phone), Code: code });
    if (!r.ok) {
      // 404 = no pending verification (expired, used, or too many wrong tries)
      return json({ error: r.status === 404 ? "expired" : r.status === 429 ? "too_many" : "check_failed" }, r.status === 404 ? 410 : 502);
    }
    if (r.body?.status !== "approved") return json({ error: "wrong_code" }, 400);
    return json({ ok: true, token: await makeToken(phone, purpose) });
  }

  return json({ error: "action" }, 400);
});
