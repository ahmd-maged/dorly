// Input rules for dorly-signup, kept free of Deno/Supabase APIs so the exact same code can be unit-tested
// locally (Node strips the type annotations). The limits are the same as in dorly.html (LIM) and in the
// database validation (supabase/proposed/phase1_input_validation.sql). Nothing is shortened silently:
// a value that is too long is refused with an error code the sign-up page explains.

export const PUBLIC_KEYS = ["bio", "hours", "activity", "branches", "web", "gov", "area"];
export const PRIVATE_KEYS = ["address", "crNo", "taxNo", "owner", "whatsapp"]; // whatsapp: members only (dorly_seller_whatsapp)
export const DOC_KINDS = ["merchant", "identity"];
// characters, counted like the database (an emoji = 1)
export const LIMITS: Record<string, number> = {
  name: 80, sellerName: 80, area: 100, hours: 100, gov: 60, activity: 100, branches: 300, bio: 300, web: 300,
  address: 300, crNo: 50, taxNo: 50, owner: 80, whatsapp: 30, city: 160, docLabel: 200, docName: 255,
};

const toEn = (s: string) => String(s).replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 1632)).replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 1776));
export function normPhone(s: string): string {
  s = toEn(s || "").replace(/[\s\-()]/g, "");
  if (s.startsWith("+20")) s = "0" + s.slice(3);
  else if (s.startsWith("0020")) s = "0" + s.slice(4);
  else if (/^20\d{10}$/.test(s)) s = "0" + s.slice(2);
  return s;
}
export const okPhone = (s: string) => /^01[0125]\d{8}$/.test(s);
export const okMail = (s: string) => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(s);
export const len = (v: unknown) => Array.from(String(v ?? "").trim()).length;
export const str = (v: unknown) => String(v ?? "").trim();

// Same rule as normWeb() in dorly.html: the scheme is stored in lower case ("Https://x" -> "https://x"),
// "facebook.com/x" becomes "https://facebook.com/x"; spaces, quotes and <> are refused.
export function normWeb(v: unknown): { v: string; err?: boolean } {
  let s = String(v ?? "").trim();
  if (!s) return { v: "" };
  s = /^https?:\/\//i.test(s) ? s.replace(/^https?:\/\//i, (m) => m.toLowerCase()) : "https://" + s.replace(/^\/+/, "");
  return /^https?:\/\/[^\s"<>]+$/.test(s) && len(s) <= LIMITS.web ? { v: s } : { v: s, err: true };
}

export type Plan = {
  role: string; name: string; phone: string; email: string; password: string; today: string;
  seller: null | { name: string; city: string; pub: Record<string, string | boolean>; priv: Record<string, string> };
  verifs: { kind: string; docs: { label: string; name: string }[] }[];
};

// Validates the request body. Returns { error } or the exact values the function will store.
export function checkSignup(b: any): { error: string } | Plan {
  b = b || {};
  const role = str(b.role);
  const name = str(b.name);
  const phone = normPhone(str(b.phone));
  const email = str(b.email).toLowerCase();
  const password = String(b.password ?? "");
  if (!["customer", "individual", "merchant"].includes(role)) return { error: "role" };
  if (len(name) > LIMITS.name || name.split(/\s+/).length < 2) return { error: "name" };
  if (!okPhone(phone)) return { error: "phone" };
  if (email && (len(email) > 120 || !okMail(email))) return { error: "email" };
  if (password.length < 8 || password.length > 72 || !/\d/.test(password) || !/[A-Za-z؀-ۿ]/.test(password)) return { error: "password" };
  let seller: Plan["seller"] = null;
  const verifs: Plan["verifs"] = [];
  if (role !== "customer") {
    const s = b.seller || {}, p = s.profile || {};
    if (len(s.name) > LIMITS.sellerName) return { error: "seller_name" };
    const w = normWeb(p.web);
    if (w.err) return { error: "web" };
    const pub: Record<string, string | boolean> = {}, priv: Record<string, string> = {};
    for (const k of PUBLIC_KEYS) { if (len(p[k]) > (LIMITS[k] ?? 300)) return { error: "too_long" }; pub[k] = str(p[k]); }
    for (const k of PRIVATE_KEYS) { if (k !== "whatsapp" && len(p[k]) > (LIMITS[k] ?? 300)) return { error: "too_long" }; priv[k] = str(p[k]); }
    pub.web = w.v;
    priv.whatsapp = okPhone(normPhone(priv.whatsapp)) ? normPhone(priv.whatsapp) : "";
    pub.wa = !!priv.whatsapp; // public flag only, the number itself stays private
    const city = (pub.area ? pub.area + " – " : "") + pub.gov;
    if (len(city) > LIMITS.city) return { error: "too_long" };
    seller = { name: str(s.name) || name, city, pub, priv };
    for (const v of Array.isArray(b.verifs) ? b.verifs.slice(0, 2) : []) {
      if (!DOC_KINDS.includes(v?.kind)) continue;
      const docs = (Array.isArray(v.docs) ? v.docs.slice(0, 6) : []).map((d: any) => ({ label: str(d?.label), name: str(d?.name) }));
      if (docs.some((d: { label: string; name: string }) => len(d.label) > LIMITS.docLabel || len(d.name) > LIMITS.docName)) return { error: "too_long" };
      verifs.push({ kind: v.kind, docs });
    }
  }
  return { role, name, phone, email, password, seller, verifs, today: Array.from(str(b.today)).slice(0, 40).join("") };
}
