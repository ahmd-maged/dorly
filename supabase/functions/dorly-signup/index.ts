// Dorly sign-up: creates the auth user, profile and (for sellers) the seller record with the service role,
// so browsers can never pick their own role, badges or another user's data.
// Deployed with verify_jwt = false (anonymous visitors sign up); all input is validated here,
// and the phone number must carry a signed proof of SMS verification from dorly-otp.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { readToken } from "./token.ts";

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
const okMail = (s: string) => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(s);
const str = (v: unknown, max = 300) => String(v ?? "").trim().slice(0, max);
const PUBLIC_KEYS = ["bio", "hours", "whatsapp", "activity", "branches", "web", "gov", "area"];
const PRIVATE_KEYS = ["address", "crNo", "taxNo", "owner"];
const DOC_KINDS = ["merchant", "identity"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let b: any;
  try { b = await req.json(); } catch { return json({ error: "bad_json" }, 400); }

  const role = str(b.role, 20);
  const name = str(b.name, 80);
  const phone = normPhone(str(b.phone, 30));
  const email = str(b.email, 120).toLowerCase();
  const password = String(b.password ?? "");
  if (!["customer", "individual", "merchant"].includes(role)) return json({ error: "role" }, 400);
  if (name.split(/\s+/).length < 2) return json({ error: "name" }, 400);
  if (!okPhone(phone)) return json({ error: "phone" }, 400);
  // the phone must have been verified by SMS (dorly-otp) within the last 30 minutes
  const otp = await readToken(String(b.otpToken || ""));
  if (!otp || otp.phone !== phone || otp.purpose !== "signup") return json({ error: "otp" }, 400);
  if (email && !okMail(email)) return json({ error: "email" }, 400);
  if (password.length < 8 || password.length > 72 || !/\d/.test(password) || !/[A-Za-z؀-ۿ]/.test(password)) return json({ error: "password" }, 400);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: taken } = await admin.rpc("dorly_taken", { p_phone: phone, p_email: email });
  if (taken) return json({ error: "taken_" + taken }, 409);

  const login = `p${phone}@phone.dorly.app`;
  const { data: created, error: cErr } = await admin.auth.admin.createUser({ email: login, password, email_confirm: true, user_metadata: { app: "dorly" } });
  if (cErr || !created?.user) return json({ error: cErr?.message?.includes("already") ? "taken_phone" : "create_failed" }, cErr?.message?.includes("already") ? 409 : 500);
  const uid = created.user.id;

  try {
    let sellerId: string | null = null;
    if (role !== "customer") {
      const s = b.seller || {};
      const p = s.profile || {};
      sellerId = "S" + Date.now() + Math.random().toString(36).slice(2, 6);
      const pub: Record<string, string> = {};
      for (const k of PUBLIC_KEYS) pub[k] = str(p[k]);
      if (pub.whatsapp) pub.whatsapp = okPhone(normPhone(pub.whatsapp)) ? normPhone(pub.whatsapp) : "";
      if (pub.web && !/^https?:\/\//i.test(pub.web)) pub.web = "";
      const priv: Record<string, string> = {};
      for (const k of PRIVATE_KEYS) priv[k] = str(p[k]);
      const sName = str(s.name, 80) || name;
      const city = (pub.area ? pub.area + " – " : "") + pub.gov;
      const seller = { id: sellerId, name: sName, type: role, city, badges: ["phone"], since: String(new Date().getFullYear()), profile: pub };
      let r = await admin.from("dorly_sellers").insert({ id: sellerId, owner: uid, sample: false, data: seller });
      if (r.error) throw r.error;
      r = await admin.from("dorly_seller_private").insert({ seller_id: sellerId, owner: uid, data: priv });
      if (r.error) throw r.error;
      const verifs = Array.isArray(b.verifs) ? b.verifs.slice(0, 2) : [];
      for (const v of verifs) {
        if (!DOC_KINDS.includes(v?.kind)) continue;
        const id = "V" + Date.now() + String(v.kind)[0] + Math.random().toString(36).slice(2, 5);
        const docs = (Array.isArray(v.docs) ? v.docs.slice(0, 6) : []).map((d: any) => ({ label: str(d?.label, 60), name: str(d?.name, 120) }));
        r = await admin.from("dorly_verifs").insert({ id, seller_id: sellerId, status: "pending", data: { id, seller: sellerId, kind: v.kind, docs, status: "pending", reason: "", time: str(b.today, 40), sample: false } });
        if (r.error) throw r.error;
      }
    }
    const r = await admin.from("dorly_profiles").insert({ id: uid, role, name, phone, email, seller_id: sellerId, created: str(b.today, 40) });
    if (r.error) throw r.error;
    return json({ ok: true, login, sellerId });
  } catch (e) {
    console.error(e);
    await admin.auth.admin.deleteUser(uid);
    return json({ error: "create_failed" }, 500);
  }
});
