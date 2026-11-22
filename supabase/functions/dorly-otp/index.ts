// Dorly e-mail verification codes (sent with Brevo).
//   {action:"send",  email, purpose:"signup"|"reset"}   -> e-mails a 6-digit code (valid 10 minutes)
//   {action:"check", email, code, purpose}              -> returns a signed 30-minute proof token
//   {action:"reset", email, token, password}            -> sets a new password (needs a "reset" token)
// Secrets (Supabase > Edge Functions > Secrets): BREVO_API_KEY, DORLY_MAIL_FROM (the sender address verified in Brevo)
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { makeToken, readToken, sha256 } from "./token.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const toEn = (s: string) => String(s).replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 1632)).replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 1776));
const okMail = (s: string) => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(s) && s.length <= 120;

const BREVO = Deno.env.get("BREVO_API_KEY") || "";
const FROM = Deno.env.get("DORLY_MAIL_FROM") || "";
const PEPPER = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const MAX_SENDS_PER_HOUR = 5, MAX_TRIES = 5, CODE_MINUTES = 10;

const codeHash = (email: string, purpose: string, code: string) => sha256(`${PEPPER}|${email}|${purpose}|${code}`);
function newCode() {
  const n = crypto.getRandomValues(new Uint32Array(1))[0] % 1000000;
  return String(n).padStart(6, "0");
}
async function sendMail(to: string, code: string, purpose: string) {
  const title = purpose === "reset" ? "كود تغيير كلمة السر" : "كود تأكيد حسابك";
  const html = `<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;font-size:16px;color:#0f172a">
    <p>أهلاً بيك في <b>دورلي</b> 👋</p><p>${title}:</p>
    <p style="font-size:30px;letter-spacing:8px;font-weight:bold;color:#2563eb;direction:ltr">${code}</p>
    <p>الكود صالح لمدة ${CODE_MINUTES} دقايق. متقولش الكود ده لأي حد.</p>
    <p style="color:#64748b;font-size:13px">لو انت مش اللي طلبت الكود، تجاهل الرسالة دي.</p></div>`;
  const r = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: { "api-key": BREVO, "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ sender: { name: "دورلي", email: FROM }, to: [{ email: to }], subject: `${title}: ${code}`, htmlContent: html }),
  });
  if (!r.ok) console.error("brevo", r.status, await r.text().catch(() => ""));
  return r.ok;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let b: any;
  try { b = await req.json(); } catch { return json({ error: "bad_json" }, 400); }

  const action = String(b.action || "");
  const purpose = b.purpose === "reset" ? "reset" : "signup";
  const email = String(b.email || "").trim().toLowerCase();
  if (!okMail(email)) return json({ error: "email" }, 400);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: prof } = await admin.from("dorly_profiles").select("id, disabled").eq("email", email).maybeSingle();

  if (action === "reset") {
    const t = await readToken(String(b.token || ""));
    const pw = String(b.password || "");
    if (!t || t.sub !== email || t.purpose !== "reset") return json({ error: "token" }, 400);
    if (pw.length < 8 || pw.length > 72 || !/\d/.test(pw) || !/[A-Za-z؀-ۿ]/.test(pw)) return json({ error: "password" }, 400);
    if (prof && !prof.disabled) {
      const { error } = await admin.auth.admin.updateUserById(prof.id, { password: pw });
      if (error) return json({ error: "update_failed" }, 500);
    }
    return json({ ok: true });
  }

  if (action === "send") {
    if (!BREVO || !FROM) return json({ error: "mail_not_configured" }, 503);
    if (purpose === "signup" && prof) return json({ error: "taken_email" }, 409);
    // unknown address on reset: answer "ok" without sending, so addresses can't be probed
    if (purpose === "reset" && (!prof || prof.disabled)) return json({ ok: true });
    const since = new Date(Date.now() - 3600_000).toISOString();
    const { count } = await admin.from("dorly_otp_codes").select("id", { count: "exact", head: true }).eq("target", email).gte("created_at", since);
    if ((count || 0) >= MAX_SENDS_PER_HOUR) return json({ error: "too_many" }, 429);
    const code = newCode();
    const { error } = await admin.from("dorly_otp_codes").insert({ target: email, purpose, code_hash: await codeHash(email, purpose, code), expires_at: new Date(Date.now() + CODE_MINUTES * 60_000).toISOString() });
    if (error) return json({ error: "send_failed" }, 500);
    if (!(await sendMail(email, code, purpose))) return json({ error: "send_failed" }, 502);
    return json({ ok: true });
  }

  if (action === "check") {
    const code = toEn(String(b.code || "")).replace(/\D/g, "");
    if (code.length !== 6) return json({ error: "code" }, 400);
    const { data: row } = await admin.from("dorly_otp_codes").select("*").eq("target", email).eq("purpose", purpose)
      .order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (!row || new Date(row.expires_at).getTime() < Date.now() || row.tries >= MAX_TRIES) return json({ error: "expired" }, 410);
    if (row.code_hash !== await codeHash(email, purpose, code)) {
      await admin.from("dorly_otp_codes").update({ tries: row.tries + 1 }).eq("id", row.id);
      return json({ error: "wrong_code" }, 400);
    }
    await admin.from("dorly_otp_codes").delete().eq("target", email).eq("purpose", purpose);
    return json({ ok: true, token: await makeToken(email, purpose) });
  }

  return json({ error: "action" }, 400);
});
