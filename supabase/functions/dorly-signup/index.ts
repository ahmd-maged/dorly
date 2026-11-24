// Dorly sign-up: creates the auth user, profile and (for sellers) the seller record with the service role,
// so browsers can never pick their own role, badges or another user's data.
// Deployed with verify_jwt = false (anonymous visitors sign up); all input is validated here.
// No phone/e-mail verification for now (no SMS or e-mail service connected); dorly-otp can be re-enabled later.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { checkSignup } from "./rules.ts";   // all input rules (also unit-tested locally)

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let b: any;
  try { b = await req.json(); } catch { return json({ error: "bad_json" }, 400); }

  const plan = checkSignup(b);
  if ("error" in plan) return json({ error: plan.error }, 400);
  const { role, name, phone, email, password } = plan;

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: taken } = await admin.rpc("dorly_taken", { p_phone: phone, p_email: email });
  if (taken) return json({ error: "taken_" + taken }, 409);

  const login = `p${phone}@phone.dorly.app`;
  const { data: created, error: cErr } = await admin.auth.admin.createUser({ email: login, password, email_confirm: true, user_metadata: { app: "dorly" } });
  if (cErr || !created?.user) return json({ error: cErr?.message?.includes("already") ? "taken_phone" : "create_failed" }, cErr?.message?.includes("already") ? 409 : 500);
  const uid = created.user.id;

  try {
    let sellerId: string | null = null;
    if (plan.seller) {
      sellerId = "S" + Date.now() + Math.random().toString(36).slice(2, 6);
      const { pub, priv, city } = plan.seller;
      const seller = { id: sellerId, name: plan.seller.name, type: role, city, badges: [], since: String(new Date().getFullYear()), profile: pub };
      let r = await admin.from("dorly_sellers").insert({ id: sellerId, owner: uid, sample: false, data: seller });
      if (r.error) throw r.error;
      r = await admin.from("dorly_seller_private").insert({ seller_id: sellerId, owner: uid, data: priv });
      if (r.error) throw r.error;
      for (const v of plan.verifs) {
        const id = "V" + Date.now() + String(v.kind)[0] + Math.random().toString(36).slice(2, 5);
        r = await admin.from("dorly_verifs").insert({ id, seller_id: sellerId, status: "pending", data: { id, seller: sellerId, kind: v.kind, docs: v.docs, status: "pending", reason: "", time: plan.today, sample: false } });
        if (r.error) throw r.error;
      }
    }
    const r = await admin.from("dorly_profiles").insert({ id: uid, role, name, phone, email, seller_id: sellerId, created: plan.today });
    if (r.error) throw r.error;
    return json({ ok: true, login, sellerId });
  } catch (e) {
    console.error(e);
    await admin.auth.admin.deleteUser(uid);
    return json({ error: "create_failed" }, 500);
  }
});
